## Task 1: immutable component routing configuration and managed navigation
## State. Exercises the controller directly through StateStore/MountContext
## fixtures; page outlets and rendering belong to later tasks.
import std/[unittest, strutils]
import leaf/[core, component_state, component_description, component_routing]
import leaf/routing

var buildCalls = 0
proc stubBuild(view: string): UiDescription =
  inc buildCalls
  discard view
  nil

proc page(name: string, views: seq[string],
    retention = PageRetention.retainState): ComponentPageDefinition =
  ComponentPageDefinition(name: name, views: views, build: stubBuild, retention: retention)

let testRoutes = @[
  Route(name: "home", path: "/", page: "home", view: "main"),
  Route(name: "about", path: "/about", page: "about", view: "main")]
let testPages = @[
  page("home", @["main"]),
  page("about", @["main"], PageRetention.disposeOnLeave)]

type Fixture = object
  store: StateStore
  ctx: MountContext
  router: ComponentRouter

proc fixture(owner: uint64 = 7, routes = testRoutes, pages = testPages,
    initial = "/"): Fixture =
  result.store = newStateStore(1)
  result.store.setPhase(StatePhase.initializing)
  result.ctx = newMountContext(result.store, owner)
  result.router = newComponentRouter(result.ctx, routes, pages, initial)
  result.store.setPhase(StatePhase.idle)

proc rejected(routes: seq[Route], pages: seq[ComponentPageDefinition], initial = "") =
  let store = newStateStore(1)
  store.setPhase(StatePhase.initializing)
  try:
    var accepted = true
    try:
      discard newComponentRouter(newMountContext(store, 1), routes, pages, initial)
    except UiError:
      accepted = false
    if accepted: fail("invalid router configuration was accepted")
  finally:
    store.setPhase(StatePhase.idle)

suite "immutable component routing configuration":
  test "configuration_is_validated_before_mount":
    buildCalls = 0
    rejected(@[], testPages)
    rejected(@[Route(name: "home", path: "/", page: "home", view: "main"),
      Route(name: "home", path: "/x", page: "home", view: "main")], testPages)
    rejected(@[Route(name: "home", path: "/", page: "home", view: "main"),
      Route(name: "other", path: "/", page: "home", view: "main")], testPages)
    rejected(testRoutes, @[page("home", @["main"]), page("home", @["main"])])
    rejected(testRoutes, @[page("home", @["main", "main"]), page("about", @["main"])])
    rejected(testRoutes, @[ComponentPageDefinition(name: "home", views: @["main"]),
      page("about", @["main"])])
    rejected(@[Route(name: "ghost", path: "/ghost", page: "ghost", view: "main")], testPages)
    rejected(@[Route(name: "ghost", path: "/ghost", page: "home", view: "ghost")], testPages)
    rejected(testRoutes, testPages, "/missing")
    rejected(@[Route(name: "relative", path: "relative", page: "home", view: "main")], testPages)
    rejected(@[Route(name: "/absolute", path: "/absolute", page: "home", view: "main")], testPages)
    rejected(@[Route(name: "bad\xff", path: "/bad", page: "home", view: "main")], testPages)
    rejected(@[Route(name: repeat("a", MaxStringBytes + 1), path: "/big",
      page: "home", view: "main")], testPages)
    var manyRoutes: seq[Route]
    for i in 0 .. MaxNodes:
      manyRoutes.add(Route(name: "r" & $i, path: "/p" & $i, page: "home", view: "main"))
    rejected(manyRoutes, testPages)
    var bigRoutes: seq[Route]
    for i in 0 ..< 18:
      let prefix = "/" & $i
      bigRoutes.add(Route(name: "big" & $i, path: prefix &
        repeat("p", MaxStringBytes - prefix.len), page: "home", view: "main"))
    rejected(bigRoutes, testPages)
    check buildCalls == 0

  test "configuration_is_detached_from_callers":
    var routes = testRoutes
    var pages = testPages
    let f = fixture(routes = routes, pages = pages)
    routes[0].name = "mutated"
    routes[0].path = "/mutated"
    routes.add(Route(name: "extra", path: "/extra", page: "home", view: "main"))
    pages[0].name = "mutated"
    pages[0].views[0] = "other"
    pages.add(page("extra", @["main"]))
    var exposed = f.router.routes()
    exposed[0].path = "/exposed"
    check f.router.currentRoute().path == "/"
    check f.router.routes()[0].path == "/"
    check f.router.routes().len == testRoutes.len

  test "navigation_joins_state_attempt":
    let f = fixture()
    check f.router.currentRoute().name == "home"
    # A queued address is only a candidate until the State attempt is accepted.
    check f.router.navigate("about") == StateWriteResult.queued
    check f.router.currentRoute().name == "home"
    let first = f.store.beginAttempt()
    f.store.setPhase(StatePhase.rendering)
    check currentRoute(newComponentContext(f.store, first, 7), f.router).name == "about"
    f.store.setPhase(StatePhase.idle)
    f.store.reject(first)
    check f.router.currentRoute().name == "home"
    # Commit an initial address so the next batch differs from accepted.
    check f.router.navigate("about") == StateWriteResult.queued
    f.store.accept(f.store.beginAttempt())
    check f.router.currentRoute().name == "about"
    # Two navigations in one batch: the last address wins.
    check f.router.navigate("about") == StateWriteResult.queued
    check f.router.navigate("home") == StateWriteResult.queued
    let last = f.store.beginAttempt()
    f.store.setPhase(StatePhase.rendering)
    check currentRoute(newComponentContext(f.store, last, 7), f.router).name == "home"
    f.store.setPhase(StatePhase.idle)
    f.store.accept(last)
    check f.router.currentRoute().name == "home"
    # The same address produces no dirty owner.
    check f.router.navigate("home") == StateWriteResult.queued
    let same = f.store.beginAttempt()
    check same.dirtyOwners().len == 0
    f.store.accept(same)
    # Render-time writes are rejected.
    f.store.setPhase(StatePhase.rendering)
    expect UiError:
      discard f.router.navigate("about")
    f.store.setPhase(StatePhase.idle)
    # Wrong owner and cross-Runtime candidate reads are rejected.
    let attempt = f.store.beginAttempt()
    f.store.setPhase(StatePhase.rendering)
    check currentRoute(newComponentContext(f.store, attempt, 7), f.router).name == "home"
    expect UiError:
      discard currentRoute(newComponentContext(f.store, attempt, 999), f.router)
    let other = newStateStore(2)
    let otherAttempt = other.beginAttempt()
    expect UiError:
      discard currentRoute(newComponentContext(other, otherAttempt, 7), f.router)
    f.store.setPhase(StatePhase.idle)
    f.store.reject(attempt)
    other.reject(otherAttempt)
    # A disposed router reports disposed before validating the address.
    f.store.disposeOwner(7)
    check f.router.navigate("missing") == StateWriteResult.disposed
