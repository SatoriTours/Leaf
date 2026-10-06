import std/unittest
import leaf

suite "Page groups and desktop routes":
  test "page groups mount lazily once and retain state across views":
    var creates = 0
    var value = 0
    let page = PageDefinition(name: "home", views: @["index", "search"],
      create: proc(): PageGroup =
        inc creates
        PageGroup(render: proc(ctx: BuildContext, panel: string): Node =
          if panel == "index":
            button($value, key = "add", onClick = proc(e: Event) = inc value)
          else:
            text("search " & $value, key = "value")))
    let router = newRouter(@[
      Route(name: "home", path: "/", page: "home", view: "index"),
      Route(name: "search", path: "/search", page: "home", view: "search")], @[page])
    check creates == 0
    let rt = newRuntime(Application(title: "Routes", width: 400, height: 300,
      render: proc(ctx: BuildContext): Node = router.renderPage(ctx)))
    check creates == 1
    discard rt.dispatch("add", Event(kind: click))
    router.navigate("/search")
    discard rt.refresh()
    check rt.find("value").node.text == "search 1"
    router.navigate("home")
    discard rt.refresh()
    check rt.find("add").node.text == "1"
    check creates == 1
    expect UiError: router.navigate("missing")
    check router.currentRoute.name == "home"

  test "invalid routes and page definitions fail before creating pages":
    var creates = 0
    let page = PageDefinition(name: "home", views: @["index"],
      create: proc(): PageGroup =
        inc creates
        PageGroup(render: proc(ctx: BuildContext, panel: string): Node = text(panel)))
    let valid = Route(name: "home", path: "/", page: "home", view: "index")
    for invalid in [
      Route(name: "home", path: "/other", page: "home", view: "index"),
      Route(name: "other", path: "/", page: "home", view: "index"),
      Route(name: "other", path: "/other", page: "missing", view: "index"),
      Route(name: "other", path: "/other", page: "home", view: "missing"),
      Route(name: "other", path: "relative", page: "home", view: "index")]:
      expect UiError: discard newRouter(@[valid, invalid], @[page])
    expect UiError: discard newRouter(@[valid], @[page, page])
    expect UiError: discard newRouter(@[], @[page])
    expect UiError: discard newRouter(@[valid], @[page], "missing")
    expect UiError:
      discard newRouter(@[valid], @[PageDefinition(name: "home", views: @["index"])])
    check creates == 0

  test "failed page factories are retried rather than cached":
    var creates = 0
    let page = PageDefinition(name: "home", views: @["index"],
      create: proc(): PageGroup =
        inc creates
        if creates == 1: raise newException(ValueError, "try again")
        PageGroup(render: proc(ctx: BuildContext, panel: string): Node = text("ready")))
    let router = newRouter(@[Route(name: "home", path: "/", page: "home", view: "index")], @[page])
    expect ValueError: discard router.renderPage(nil)
    check router.renderPage(nil).text == "ready"
    check creates == 2
