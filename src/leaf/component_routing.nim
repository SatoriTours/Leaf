## Immutable component route configuration with transactional navigation State.
## A router is created during a component's initialization and owns one
## State[NavigationState] holding the accepted history; navigation joins the
## ordinary State queue and is accepted together with the rest of the batch.
import std/[tables, sets, strutils, unicode, options]
import ./[core, component_state, component_description]
import ./routing
import ./navigation_state
export navigation_state.NavigationBackProposal

type
  NavigationRequests = ref object
    ## Request lifecycle is separate from accepted history: cancelling a
    ## gesture, or consuming a completion whose candidate later fails, must
    ## fence late callbacks without publishing a different page/history.
    offered, revision: uint64
    pending: Table[uint64, NavigationBackProposal]

  ComponentPageDefinition* = object
    name*: string
    views*: seq[string]
    build*: proc(view: string): UiDescription {.closure.}
    retention*: PageRetention

  ComponentRouter* = object
    registered: seq[Route]
    definitions: Table[string, ComponentPageDefinition]
    names, paths: Table[string, int]
    route: State[NavigationState]
    token: uint64
    configurationBytes: int
    requests: NavigationRequests

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
  result.requests = NavigationRequests()
  result.route = ctx.state(initialNavigation(result.token,
    configuration.registered.len, configuration.initialIndex),
    equal = proc(a, b: NavigationState): bool = a == b,
    snapshot = snapshotNavigation)

proc routes*(router: ComponentRouter): seq[Route] = router.registered

proc routeIndex(router: ComponentRouter, target: string): int =
  if target in router.names: result = router.names[target]
  elif target in router.paths: result = router.paths[target]
  else: fail("unknown route: " & target)

proc navigate*(router: ComponentRouter, target: string): StateWriteResult =
  ## Select the current address without appending a history entry. Unknown
  ## addresses are refused before queuing; disposed routers stay terminal.
  if not stateAlive(router.route): return StateWriteResult.disposed
  let index = router.routeIndex(target)
  router.route.queueUpdate(proc(value: NavigationState): NavigationState =
    value.selectRoute(index))

proc push*(router: ComponentRouter, target: string): StateWriteResult =
  if not stateAlive(router.route): return StateWriteResult.disposed
  let index = router.routeIndex(target)
  router.route.queueUpdate(proc(value: NavigationState): NavigationState =
    value.pushRoute(index))

proc replace*(router: ComponentRouter, target: string): StateWriteResult =
  if not stateAlive(router.route): return StateWriteResult.disposed
  let index = router.routeIndex(target)
  router.route.queueUpdate(proc(value: NavigationState): NavigationState =
    value.replaceRoute(index))

proc pop*(router: ComponentRouter): StateWriteResult =
  if not stateAlive(router.route): return StateWriteResult.disposed
  router.route.queueUpdate(proc(value: NavigationState): NavigationState =
    value.popRoute())

proc history*(router: ComponentRouter): seq[Route] =
  ## Export accepted addresses in root-to-current order. Entries/closures remain
  ## owned by the immutable controller configuration and State snapshot policy.
  for entry in router.route.readAccepted().entries:
    result.add(router.registered[entry.routeIndex])

proc history*(ctx: ComponentContext, router: ComponentRouter): seq[Route] =
  if ctx == nil: fail("navigation history requires a component context")
  if not ctx.ownsState(router.route): fail("router State is not owned by this component")
  for entry in ctx.value(router.route).entries:
    result.add(router.registered[entry.routeIndex])

proc canPop*(router: ComponentRouter): bool = router.route.readAccepted().depth > 1

proc syncRequests(router: ComponentRouter, history: NavigationState) =
  if router.requests.revision != history.revision:
    router.requests.pending.clear()
    router.requests.revision = history.revision

proc backProposal*(router: ComponentRouter, requestId: uint64): NavigationBackProposal =
  ## Register a request without writing accepted history. The platform supplies
  ## monotonic ids within this router and must also check its session/mount.
  if not stateAlive(router.route): return
  router.route.requireStateExecution()
  if requestId == 0: fail("navigation back request identity must be nonzero")
  let history = router.route.readAccepted()
  router.syncRequests(history)
  if requestId <= router.requests.offered: return
  result = history.proposeBack(requestId)
  if result.requestId == 0: return
  if router.requests.pending.len >= MaxNodes:
    fail("pending navigation requests exceed 10000 entries")
  router.requests.pending[requestId] = result
  router.requests.offered = requestId

proc cancelBack*(router: ComponentRouter, requestId: uint64): bool =
  ## Cancellation is valid until confirmBack queues the ordinary State update.
  ## It never changes the accepted history or causes a page render.
  if not stateAlive(router.route): return false
  router.route.requireStateExecution()
  router.syncRequests(router.route.readAccepted())
  if requestId notin router.requests.pending: return false
  router.requests.pending.del(requestId)
  true

proc confirmBack*(router: ComponentRouter,
    proposal: NavigationBackProposal): bool =
  ## Consume the registered completion only after queueing succeeds. The same
  ## completion cannot retry a failed batch; the host must issue a new request.
  if not stateAlive(router.route): return false
  router.route.requireStateExecution()
  router.syncRequests(router.route.readAccepted())
  if proposal.requestId == 0 or
      router.requests.pending.getOrDefault(proposal.requestId) != proposal:
    return false
  result = router.route.queueUpdate(proc(value: NavigationState): NavigationState =
    value.acceptBack(proposal)) == StateWriteResult.queued
  if result: router.requests.pending.del(proposal.requestId)

proc currentRoute*(router: ComponentRouter): Route =
  ## The last accepted address; queued candidates are not exposed here.
  router.registered[router.route.readAccepted().current.routeIndex]

proc currentRoute*(ctx: ComponentContext, router: ComponentRouter): Route =
  ## The current candidate address during render; owner and Runtime are checked.
  if ctx == nil: fail("current route requires a component context")
  if not ctx.ownsState(router.route): fail("router State is not owned by this component")
  router.registered[ctx.value(router.route).current.routeIndex]

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

proc renderNavigation*(ctx: ComponentContext, router: ComponentRouter,
    key = "navigation"): UiDescription =
  ## Opt in to a typed native container. The ordinary outlet remains lazy and
  ## retains page State; the native adapter must explicitly support this kind.
  let page = renderPage(ctx, router)
  let metadata = ctx.value(router.route).hostNavigationProps()
  hostShell(ui(NodeKind.navigation, key = key, navigation = some(metadata),
    onBack = proc(event: Event) =
      if event.navigationRequestId == 0: return
      let proposal = router.backProposal(event.navigationRequestId)
      discard router.confirmBack(proposal)), @[page])
