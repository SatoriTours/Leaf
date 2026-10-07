import std/[unittest, json, tables, strutils]
import leaf

proc app(render: RenderProc): Application =
  Application(title: "测试", width: 640, height: 480, render: render)

suite "Native Nim component runtime":
  test "generic execution scope surrounds render and later callbacks":
    var active = false
    var rendered, handled: int
    proc scope(body: proc() {.closure.}) =
      let previous = active
      active = true
      try: body()
      finally: active = previous
    proc render(ctx: BuildContext): Node =
      doAssert active
      inc rendered
      button("Event", key = "event", onClick = proc(e: Event) =
        doAssert active
        inc handled)
    let runtime = newRuntime(Application(title: "scope", width: 640, height: 480,
      render: render, executionScope: scope))
    check not active
    check runtime.dispatch("event", Event(kind: click))
    check rendered == 2
    check handled == 1
    check not active

  test "state belongs to each application and events use typed values":
    var a, b = 0
    proc counter(value: ptr int): Runtime =
      newRuntime(app(proc(ctx: BuildContext): Node =
        column(@[
          text($value[], key = "count"),
          button("Add", key = "add", onClick = proc(e: Event) = inc value[])])))
    let left = counter(addr a)
    let right = counter(addr b)
    check left.dispatch("add", Event(kind: click))
    check left.find("count").node.text == "1"
    check right.find("count").node.text == "0"
    check right.stats.renders == 1

  test "disabled events never execute callbacks":
    var calls = 0
    let runtime = newRuntime(app(proc(ctx: BuildContext): Node =
      button("Disabled", key = "no", disabled = true,
        onClick = proc(e: Event) = inc calls)))
    check not runtime.dispatch("no", Event(kind: click))
    check calls == 0
    check runtime.stats.renders == 1

  test "failed render keeps previous snapshot and recovery handlers":
    var broken = false
    let runtime = newRuntime(app(proc(ctx: BuildContext): Node =
      if broken: raise newException(ValueError, "bad render")
      column(@[
        button("Break", key = "break", onClick = proc(e: Event) = broken = true),
        button("Recover", key = "recover", onClick = proc(e: Event) = broken = false)])))
    let old = runtime.snapshot.root
    expect ValueError: discard runtime.dispatch("break", Event(kind: click))
    check runtime.snapshot.root == old
    check runtime.stats.renders == 1
    check runtime.dispatch("recover", Event(kind: click))
    check runtime.stats.renders == 2

  test "event errors release reentrancy guard":
    var calls = 0
    let runtime = newRuntime(app(proc(ctx: BuildContext): Node =
      column(@[
        button("Error", key = "error", onClick = proc(e: Event) =
          raise newException(ValueError, "callback")),
        button("OK", key = "ok", onClick = proc(e: Event) = inc calls)])))
    expect ValueError: discard runtime.dispatch("error", Event(kind: click))
    check runtime.dispatch("ok", Event(kind: click))
    check calls == 1

  test "input change and submit preserve Unicode":
    var value = ""
    var submitted = ""
    let runtime = newRuntime(app(proc(ctx: BuildContext): Node =
      input(value, key = "name",
        onChange = proc(e: Event) = value = e.value,
        onSubmit = proc(e: Event) = submitted = e.value)))
    check runtime.dispatch("name", Event(kind: change, value: "你好 👋"))
    check runtime.find("name").node.text == "你好 👋"
    check runtime.dispatch("name", Event(kind: submit, value: value))
    check submitted == value

  test "full IDs disambiguate child component keys containing slashes":
    let runtime = newRuntime(app(proc(ctx: BuildContext): Node =
      row(@[
        column(@[text("A", key = "x/y")], key = "left"),
        column(@[text("B", key = "x/y")], key = "right")], key = "root")))
    expect UiError: discard runtime.find("x/y")
    check runtime.find("k:4:root/k:4:left/k:3:x/y").node.text == "A"
    check runtime.find("k:4:root/k:5:right/k:3:x/y").node.text == "B"

  test "duplicate sibling keys fail without publishing":
    var duplicate = false
    let runtime = newRuntime(app(proc(ctx: BuildContext): Node =
      column(@[text("A", key = "one"), text("B", key = (if duplicate: "one" else: "two"))])))
    let old = runtime.snapshot.root
    duplicate = true
    expect UiError: discard runtime.refresh()
    check runtime.snapshot.root == old

  test "returned descriptions cannot mutate a committed tree":
    let original = column(@[text("A")], styles = style({"gap": "12"}))
    var children = original.children
    children.add(text("B"))
    var styles = original.styles
    styles["gap"] = "99"
    check original.children.len == 1
    check original.styles["gap"] == "12"

  test "nested cache dependencies survive warm parent hits":
    var parentBuilds, childBuilds = 0
    let runtime = newRuntime(app(proc(ctx: BuildContext): Node =
      ctx.cached("parent", "1", proc(): Node =
        inc parentBuilds
        column(@[ctx.cached("child", "1", proc(): Node =
          inc childBuilds
          text("cached"))]))))
    for i in 0..<10: discard runtime.refresh()
    check parentBuilds == 1
    check childBuilds == 1
    check runtime.stats.cachedSubtrees == 2
    check runtime.stats.cacheHits == 10

  test "cache invalidation and failed candidates are transactional":
    var revision = 1
    var broken = false
    var builds = 0
    let runtime = newRuntime(app(proc(ctx: BuildContext): Node =
      let child = ctx.cached("child", $revision, proc(): Node =
        inc builds
        text($revision, key = "value"))
      if broken: raise newException(ValueError, "abort")
      column(@[child])))
    revision = 2
    broken = true
    expect ValueError: discard runtime.refresh()
    check runtime.find("value").node.text == "1"
    revision = 1
    broken = false
    discard runtime.refresh()
    check builds == 2
    revision = 3
    discard runtime.refresh()
    check builds == 3
    check runtime.find("value").node.text == "3"

  test "unmounted caches and closures are released":
    var show = true
    let runtime = newRuntime(app(proc(ctx: BuildContext): Node =
      if show: ctx.cached("gone", "1", proc(): Node = text("gone"))
      else: text("empty")))
    check runtime.stats.cachedSubtrees == 1
    show = false
    discard runtime.refresh()
    check runtime.stats.cachedSubtrees == 0

  test "recursive cache dependencies are rejected":
    expect UiError:
      discard newRuntime(app(proc(ctx: BuildContext): Node =
        ctx.cached("same", "1", proc(): Node =
          ctx.cached("same", "1", proc(): Node = text("no")))))

  test "limits and invalid control shapes are enforced":
    expect UiError: discard ui(NodeKind.text, children = @[text("child")])
    expect UiError: discard text("\xff")
    expect UiError: discard text(repeat('x', MaxStringBytes + 1))
    expect UiError: discard ui(NodeKind.input, onClick = proc(e: Event) = discard)

  test "tree node, depth, byte and window limits":
    var wide: seq[Node]
    for i in 0..<MaxNodes: wide.add(text(""))
    expect UiError:
      discard newRuntime(app(proc(ctx: BuildContext): Node = column(wide)))
    var deep = text("leaf")
    for i in 0..MaxDepth: deep = column(@[deep])
    expect UiError:
      discard newRuntime(app(proc(ctx: BuildContext): Node = deep))
    let big = text(repeat('x', MaxStringBytes))
    var large: seq[Node]
    for i in 0..<17: large.add(big)
    expect UiError:
      discard newRuntime(app(proc(ctx: BuildContext): Node = column(large)))
    expect UiError:
      discard newRuntime(Application(title: "bad", width: 0, height: 1,
        render: proc(ctx: BuildContext): Node = text("")))

  test "snapshot JSON preserves the existing tooling shape":
    let runtime = newRuntime(app(proc(ctx: BuildContext): Node =
      column(@[checkbox("Accept", true, key = "accept"), switch("Notify", false)])))
    let snapshot = runtime.snapshot.toJson()
    check snapshot["title"].getStr == "测试"
    check snapshot["root"]["children"][0]["attributes"]["checked"].getStr == "true"
    check snapshot["root"]["children"][1]["kind"].getStr == "switch"
