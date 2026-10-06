import std/[unittest, tables]
import leaf

proc panel(children: seq[Node], key = "", styles = default(Styles)): Node =
  column(children, key, styles)

suite "Indented UI descriptions":
  test "nested components and colon properties preserve the tree":
    let accent = style({"color": "#93C5FD"})
    let tree = view:
      column:
        key: "root"
        styles: {"padding": "24", "gap": "12"}
        text "你好":
          styles: accent
        row:
          key: "actions"
          button "Add":
            key: "add"
            disabled: true
            variant: "outline"
          separator()
    check tree.kind == NodeKind.column
    check tree.key == "root"
    check tree.styles["gap"] == "12"
    check tree.children[0].text == "你好"
    check tree.children[0].styles == accent
    let action = tree.children[1].children[0]
    check action.key == "add"
    check action.disabled
    check action.attributes["variant"] == "outline"

  test "event blocks capture state and receive typed events":
    var value, submitted: string
    var clicks = 0
    proc render(ctx: BuildContext): Node =
      view:
        column:
          input value:
            key: "entry"
            onChange(e): value = e.value
            onSubmit(e):
              submitted = e.value
              inc clicks
          button "Add":
            key: "add"
            onClick(e):
              inc clicks
              value = "次数：" & $clicks
    let runtime = newRuntime(Application(title: "Events", width: 640, height: 480, render: render))
    check runtime.dispatch("entry", Event(kind: change, value: "中文 👋"))
    check runtime.find("entry").node.text == "中文 👋"
    check runtime.dispatch("entry", Event(kind: submit, value: value))
    check submitted == "中文 👋"
    check runtime.dispatch("add", Event(kind: click))
    check runtime.find("entry").node.text == "次数：2"

  test "loops conditionals and case branches append only visible children":
    let tree = view:
      column:
        let items = [0, 1, 2, 3]
        for i in items:
          if i == 1: continue
          let name = "item_" & $i
          case i
          of 0:
            text "zero":
              key: name
          of 2:
            row:
              text name
          else:
            text "other"
        when sizeof(int) >= 4:
          block:
            var i = 0
            while i < 2:
              text $i
              inc i
    check tree.children.len == 5
    check tree.children[0].key == "item_0"
    check tree.children[1].children[0].text == "item_2"
    check tree.children[2].text == "other"
    check tree.children[4].text == "1"

  test "custom containers existing nodes and explicit children compose":
    let child = text("existing")
    let tree = view:
      panel:
        key: "panel"
        styles: {"gap": "8"}
        child
        column:
          children: @[text("dynamic")]
        row:
          styles: {"gap": "4"}
    check tree.children.len == 3
    check tree.children[0] == child
    check tree.children[1].children[0].text == "dynamic"
    check tree.children[2].children.len == 0

  test "virtual list builders remain lazy and existing callbacks work":
    var builds, clicks = 0
    proc build(index: int): Node =
      inc builds
      view:
        text $index
    let clicked: Callback = proc(e: Event) = inc clicks
    proc render(ctx: BuildContext): Node =
      view:
        column:
          virtualList "list", @["a", "b"], build:
            rowHeight: 24.0
            styles: {"height": "200"}
          button "Click":
            key: "click"
            onClick: clicked
    let runtime = newRuntime(Application(title: "List", width: 640, height: 480, render: render))
    check builds == 0
    let rows = runtime.materialize("list", 1, 2)
    check builds == 1
    check rows[0].node.text == "1"
    check runtime.dispatch("click", Event(kind: click))
    check clicks == 1

  test "sibling sequences evaluate computations and callbacks once":
    var computations, clicks = 0
    proc build(): Node =
      inc computations
      text("built")
    let siblings = views:
      inc computations
      build()
      button "Click":
        onClick(e): inc clicks
      for i in 0..1:
        text $i
    check siblings.len == 4
    check computations == 2
    check siblings[0].text == "built"
    siblings[1].handler(click)(Event(kind: click))
    check clicks == 1

  test "invalid descriptions fail at compile time":
    check not compiles(block:
      discard view:
        "not a node")
    check not compiles(block:
      discard view:
        text "one"
        text "two")
    check not compiles(block:
      discard view:
        column:
          key: "one"
          key: "two")
    check not compiles(block:
      discard view:
        column:
          children: @[text("one")]
          text "two")
    check not compiles(block:
      discard view:
        text "leaf":
          text "child")
    check not compiles(block:
      discard view:
        column:
          if true:
            styles: {"gap": "12"})
