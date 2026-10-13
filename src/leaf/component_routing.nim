## Immutable component route configuration with transactional navigation State.
## A router is created during a component's initialization and owns one
## State[int] holding the accepted route index; navigation joins the ordinary
## State queue so the address is accepted together with the rest of the batch.
import std/[tables, sets, strutils, unicode]
import ./[core, component_state, component_description]
import ./routing

type
  ComponentPageDefinition* = object
    name*: string
    views*: seq[string]
    build*: proc(view: string): UiDescription {.closure.}
    retention*: PageRetention

  ComponentRouter* = object
    registered: seq[Route]
    definitions: Table[string, ComponentPageDefinition]
    names, paths: Table[string, int]
    route: State[int]
    token: uint64
    configurationBytes: int

const RouterMetadataBytes = 64

var nextRouterToken {.threadvar.}: uint64

proc routerToken(): uint64 =
  ## Thread-local monotonic router identity; overflow is refused explicitly.
  if nextRouterToken == high(uint64): fail("component router identity space exhausted")
  inc nextRouterToken
  nextRouterToken

proc validField(value, what: string) =
  if value.len > MaxStringBytes: fail(what & " exceeds 1 MiB")
  if validateUtf8(value) != -1: fail(what & " is not valid UTF-8")

type RouterConfiguration = object
  registered: seq[Route]
  definitions: Table[string, ComponentPageDefinition]
  names, paths: Table[string, int]
  initialIndex: int
  entries, bytes: int

proc validateConfiguration(routes: seq[Route], pages: seq[ComponentPageDefinition],
    initial: string): RouterConfiguration =
  ## Validate and copy the address configuration before any page is mounted.
  ## Page build callbacks are never invoked here.
  result.initialIndex = 0
  result.entries = pages.len
  for page in pages:
    validField(page.name, "page name")
    if page.name.len == 0: fail("page definition requires a name")
    if page.name in result.definitions: fail("duplicate page: " & page.name)
    if page.build == nil: fail("page definition requires a build function: " & page.name)
    if page.views.len == 0: fail("page definition requires at least one view: " & page.name)
    var seen: HashSet[string]
    for view in page.views:
      validField(view, "page view")
      if view.len == 0: fail("empty page view: " & page.name)
      if view in seen: fail("duplicate page view: " & page.name & "." & view)
      seen.incl(view)
      inc result.entries
      result.bytes += RouterMetadataBytes + view.len
    result.bytes += RouterMetadataBytes + page.name.len
    result.definitions[page.name] = ComponentPageDefinition(name: page.name,
      views: page.views, build: page.build, retention: page.retention)
  if routes.len == 0: fail("router needs at least one route")
  for route in routes:
    validField(route.name, "route name")
    validField(route.path, "route path")
    validField(route.page, "route page")
    validField(route.view, "route view")
    if route.name.len == 0: fail("route requires a name")
    if route.name.startsWith("/"): fail("route names cannot start with /; use a path to navigate")
    if not route.path.startsWith("/"): fail("route requires an absolute path: " & route.path)
    if route.name in result.names: fail("duplicate route name: " & route.name)
    if route.path in result.paths: fail("duplicate route path: " & route.path)
    if route.page notin result.definitions: fail("unknown route page: " & route.page)
    if route.view notin result.definitions[route.page].views:
      fail("unknown route view: " & route.page & "." & route.view)
    result.names[route.name] = result.registered.len
    result.paths[route.path] = result.registered.len
    result.registered.add(route)
    result.bytes += RouterMetadataBytes + route.name.len + route.path.len +
      route.page.len + route.view.len
  if initial.len > 0:
    validField(initial, "initial route")
    if initial in result.names: result.initialIndex = result.names[initial]
    elif initial in result.paths: result.initialIndex = result.paths[initial]
    else: fail("unknown initial route: " & initial)
  result.entries += result.registered.len
  if result.entries > MaxNodes: fail("router configuration exceeds 10000 entries")
  if result.bytes > MaxTreeBytes: fail("router configuration exceeds 16 MiB")

proc newComponentRouter*(ctx: MountContext, routes: seq[Route],
    pages: seq[ComponentPageDefinition], initial = ""): ComponentRouter =
  if ctx == nil: fail("component router requires a mount context")
  let configuration = validateConfiguration(routes, pages, initial)
  result.registered = configuration.registered
  result.definitions = configuration.definitions
  result.names = configuration.names
  result.paths = configuration.paths
  result.configurationBytes = configuration.bytes
  result.token = routerToken()
  result.route = ctx.state(configuration.initialIndex,
    equal = proc(a, b: int): bool = a == b)

proc routes*(router: ComponentRouter): seq[Route] = router.registered

proc navigate*(router: ComponentRouter, target: string): StateWriteResult =
  ## Unknown addresses are refused before queuing; a disposed router reports
  ## disposed without touching released pages.
  if not stateAlive(router.route): return StateWriteResult.disposed
  var index: int
  if target in router.names: index = router.names[target]
  elif target in router.paths: index = router.paths[target]
  else: fail("unknown route: " & target)
  result = router.route.queueSet(index)

proc currentRoute*(router: ComponentRouter): Route =
  ## The last accepted address; queued candidates are not exposed here.
  router.registered[router.route.readAccepted()]

proc currentRoute*(ctx: ComponentContext, router: ComponentRouter): Route =
  ## The current candidate address during render; owner and Runtime are checked.
  if ctx == nil: fail("current route requires a component context")
  if not ctx.ownsState(router.route): fail("router State is not owned by this component")
  router.registered[ctx.value(router.route)]
