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

proc charge(configuration: var RouterConfiguration, bytes: int) =
  ## Check the running total before any oversized entry is retained.
  configuration.bytes += bytes
  if configuration.bytes > MaxTreeBytes:
    fail("router configuration exceeds 16 MiB")

proc charge(configuration: var RouterConfiguration, value: string) =
  ## Every stored string, including an index's own key, owns its bytes.
  charge(configuration, RouterMetadataBytes + value.len)

proc countEntry(configuration: var RouterConfiguration) =
  inc configuration.entries
  if configuration.entries > MaxNodes:
    fail("router configuration exceeds 10000 entries")

proc validateConfiguration(routes: seq[Route], pages: seq[ComponentPageDefinition],
    initial: string): RouterConfiguration =
  ## Validate and copy the address configuration before any page is mounted.
  ## Page build callbacks are never invoked here. The bounded ledger counts
  ## every string the controller retains, including copied table keys, so it
  ## can never hide more bytes than the MaxTreeBytes budget allows.
  result.initialIndex = 0
  for page in pages:
    validField(page.name, "page name")
    if page.name.len == 0: fail("page definition requires a name")
    if page.name in result.definitions: fail("duplicate page: " & page.name)
    if page.build == nil: fail("page definition requires a build function: " & page.name)
    if page.views.len == 0: fail("page definition requires at least one view: " & page.name)
    result.countEntry()
    # The definition value and its table key each retain a copy of the name.
    result.charge(page.name)
    result.charge(page.name)
    var seen: HashSet[string]
    for view in page.views:
      validField(view, "page view")
      if view.len == 0: fail("empty page view: " & page.name)
      if view in seen: fail("duplicate page view: " & page.name & "." & view)
      seen.incl(view)
      result.countEntry()
      result.charge(view)
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
    result.countEntry()
    # The registered route and the name/path index keys each retain a copy.
    result.charge(route.name)
    result.charge(route.name)
    result.charge(route.path)
    result.charge(route.path)
    result.charge(route.page)
    result.charge(route.view)
    result.names[route.name] = result.registered.len
    result.paths[route.path] = result.registered.len
    result.registered.add(route)
  if initial.len > 0:
    validField(initial, "initial route")
    if initial in result.names: result.initialIndex = result.names[initial]
    elif initial in result.paths: result.initialIndex = result.paths[initial]
    else: fail("unknown initial route: " & initial)

proc newComponentRouter*(ctx: MountContext, routes: seq[Route],
    pages: seq[ComponentPageDefinition], initial = ""): ComponentRouter =
  if ctx == nil: fail("component router requires a mount context")
  let configuration = validateConfiguration(routes, pages, initial)
  ctx.accountOwnedDescriptionBytes(configuration.bytes)
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

proc renderPage*(ctx: ComponentContext, router: ComponentRouter,
    key = "page-outlet"): UiDescription =
  ## Public outlet for the candidate page/view. Owner and Runtime are validated
  ## through the router State, and the page callback stays lazy: the closure
  ## captures only the selected build and view, never the router configuration.
  if ctx == nil: fail("renderPage requires a component context")
  let route = currentRoute(ctx, router)
  let definition = router.definitions.getOrDefault(route.page)
  if definition.build == nil: fail("route page is not defined: " & route.page)
  let build = definition.build
  let view = route.view
  pageOutlet(PageOutletSpec(routerId: router.token, page: route.page, view: view,
    retention: definition.retention, configurationBytes: 0,
    build: proc(): UiDescription = build(view)), key)
