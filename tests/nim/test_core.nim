import std/[unittest, json, tables, strutils]
import leaf
import ../fixture_app

proc app(render: proc(): Node): Application =
  fixtureApplication(render, "测试", 640, 480)

suite "Native Nim component runtime":
  test "generic execution scope surrounds render and later callbacks":
    var active = false
    var rendered, handled: int
    proc scope(body: proc() {.closure.}) =
      let previous = active
      active = true
      try: body()
      finally: active = previous
    proc render(): Node =
      doAssert active
      inc rendered
      button("Event", key = "event", onClick = proc(e: Event) =
        doAssert active
        inc handled)
    let runtime = newRuntime(fixtureApplication(render, "scope", 640, 480, scope))
    check not active
    check runtime.dispatchRefresh("event", Event(kind: click))
    check rendered == 2
    check handled == 1
    check not active

  test "state belongs to each application and events use typed values":
    var a, b = 0
    proc counter(value: ptr int): Runtime =
      newRuntime(app(proc(): Node =
        column(@[
          text($value[], key = "count"),
          button("Add", key = "add", onClick = proc(e: Event) = inc value[])])))
    let left = counter(addr a)
    let right = counter(addr b)
    check left.dispatchRefresh("add", Event(kind: click))
    check left.find("count").node.text == "1"
    check right.find("count").node.text == "0"
    check right.stats.renders == 1

  test "disabled events never execute callbacks":
    var calls = 0
    let runtime = newRuntime(app(proc(): Node =
      button("Disabled", key = "no", disabled = true,
        onClick = proc(e: Event) = inc calls)))
    check not runtime.dispatchRefresh("no", Event(kind: click))
    check calls == 0
    check runtime.stats.renders == 1

  test "failed render keeps previous snapshot and recovery handlers":
    var broken = false
    let runtime = newRuntime(app(proc(): Node =
      if broken: raise newException(ValueError, "bad render")
      column(@[
        button("Break", key = "break", onClick = proc(e: Event) = broken = true),
        button("Recover", key = "recover", onClick = proc(e: Event) = broken = false)])))
    let old = runtime.snapshot.root
    expect ValueError: discard runtime.dispatchRefresh("break", Event(kind: click))
    check runtime.snapshot.root == old
    check runtime.stats.renders == 1
    check runtime.dispatchRefresh("recover", Event(kind: click))
    check runtime.stats.renders == 2

  test "event errors release reentrancy guard":
    var calls = 0
    let runtime = newRuntime(app(proc(): Node =
      column(@[
        button("Error", key = "error", onClick = proc(e: Event) =
          raise newException(ValueError, "callback")),
        button("OK", key = "ok", onClick = proc(e: Event) = inc calls)])))
    expect ValueError: discard runtime.dispatchRefresh("error", Event(kind: click))
    check runtime.dispatchRefresh("ok", Event(kind: click))
    check calls == 1

  test "input change and submit preserve Unicode":
    var value = ""
    var submitted = ""
    let runtime = newRuntime(app(proc(): Node =
      input(value, key = "name",
        onChange = proc(e: Event) = value = e.value,
        onSubmit = proc(e: Event) = submitted = e.value)))
    check runtime.dispatchRefresh("name", Event(kind: change, value: "你好 👋"))
    check runtime.find("name").node.text == "你好 👋"
    check runtime.dispatchRefresh("name", Event(kind: submit, value: value))
    check submitted == value

  test "full IDs disambiguate child component keys containing slashes":
    let runtime = newRuntime(app(proc(): Node =
      row(@[
        column(@[text("A", key = "x/y")], key = "left"),
        column(@[text("B", key = "x/y")], key = "right")], key = "root")))
    expect UiError: discard runtime.find("x/y")
    check runtime.find(runtime.find("left").id & "/k:3:x/y").node.text == "A"
    check runtime.find(runtime.find("right").id & "/k:3:x/y").node.text == "B"

  test "duplicate sibling keys fail without publishing":
    var duplicate = false
    let runtime = newRuntime(app(proc(): Node =
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

  test "limits and invalid control shapes are enforced":
    expect UiError: discard ui(NodeKind.text, children = @[text("child")])
    expect UiError: discard text("\xff")
    expect UiError: discard text(repeat('x', MaxStringBytes + 1))
    expect UiError: discard ui(NodeKind.input, onClick = proc(e: Event) = discard)

  test "tree node, depth, byte and window limits":
    var wide: seq[Node]
    for i in 0..<MaxNodes: wide.add(text(""))
    expect UiError:
      discard newRuntime(app(proc(): Node = column(wide)))
    var deep = text("leaf")
    for i in 0..MaxDepth: deep = column(@[deep])
    expect UiError:
      discard newRuntime(app(proc(): Node = deep))
    let big = text(repeat('x', MaxStringBytes))
    var large: seq[Node]
    for i in 0..<17: large.add(big)
    expect UiError:
      discard newRuntime(app(proc(): Node = column(large)))
    expect UiError:
      discard newRuntime(fixtureApplication(proc(): Node = text(""), "bad", 0, 1))

  test "snapshot JSON preserves the existing tooling shape":
    let runtime = newRuntime(app(proc(): Node =
      column(@[checkbox("Accept", true, key = "accept"), switch("Notify", false)])))
    let snapshot = runtime.snapshot.toJson()
    check snapshot["title"].getStr == "测试"
    check snapshot["root"]["children"][0]["attributes"]["checked"].getStr == "true"
    check snapshot["root"]["children"][1]["kind"].getStr == "switch"
