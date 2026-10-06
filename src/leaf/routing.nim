## Named desktop routes share lazily created page groups and their Nim state.
import std/[tables, sets, strutils]
import ./core

type
  PageRender* = proc(ctx: BuildContext, view: string): Node {.closure.}
  PageGroup* = ref object
    render*: PageRender
  PageFactory* = proc(): PageGroup {.closure.}
  PageDefinition* = object
    name*: string
    views*: seq[string]
    create*: PageFactory
  Route* = object
    name*, path*, page*, view*: string
  Router* = ref object
    definitions: Table[string, PageDefinition]
    mounted: Table[string, PageGroup]
    registered: seq[Route]
    names, paths: Table[string, int]
    active: int

proc newRouter*(routes: seq[Route], pages: seq[PageDefinition], initial = ""): Router =
  result = Router()
  for page in pages:
    if page.name.len == 0 or page.create == nil or page.views.len == 0:
      fail("page definition requires a name, views and factory")
    if page.name in result.definitions: fail("duplicate page: " & page.name)
    var seen: HashSet[string]
    for panel in page.views:
      if panel.len == 0 or panel in seen: fail("empty or duplicate page view: " & page.name)
      seen.incl(panel)
    result.definitions[page.name] = page
  if routes.len == 0: fail("router needs at least one route")
  for i, route in routes:
    if route.name.len == 0 or not route.path.startsWith("/"):
      fail("route requires a name and absolute desktop path")
    if route.name.startsWith("/"): fail("route names cannot start with /; use a path to navigate")
    if route.name in result.names: fail("duplicate route name: " & route.name)
    if route.path in result.paths: fail("duplicate route path: " & route.path)
    if route.page notin result.definitions: fail("unknown route page: " & route.page)
    if route.view notin result.definitions[route.page].views:
      fail("unknown route view: " & route.page & "." & route.view)
    result.names[route.name] = i
    result.paths[route.path] = i
    result.registered.add(route)
  if initial.len > 0:
    if initial in result.names: result.active = result.names[initial]
    elif initial in result.paths: result.active = result.paths[initial]
    else: fail("unknown initial route: " & initial)

proc routes*(router: Router): seq[Route] = router.registered
proc currentRoute*(router: Router): Route = router.registered[router.active]

proc navigate*(router: Router, target: string) =
  if target in router.names: router.active = router.names[target]
  elif target in router.paths: router.active = router.paths[target]
  else: fail("unknown route: " & target)

proc renderPage*(router: Router, ctx: BuildContext): Node =
  let route = router.currentRoute
  if route.page notin router.mounted:
    let page = router.definitions[route.page].create()
    if page == nil or page.render == nil: fail("page factory returned no renderer: " & route.page)
    router.mounted[route.page] = page
  router.mounted[route.page].render(ctx, route.view)
