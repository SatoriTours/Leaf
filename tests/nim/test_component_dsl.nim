import std/[unittest, options, tables]
import leaf

var initializations = 0
proc initialCount(): int =
  inc initializations
  0

component Counter:
  state:
    count = initialCount()
  view:
    column:
      padding: 24
      gap: 12
      text count:
        key: "count"
      button "增加":
        key: "add"
        onClick:
          count += 1
      button "重置":
        key: "reset"
        onClick:
          count = 0
      button "连续":
        key: "sequence"
        onClick:
          count = 0
          count += 1
          count += 1
          doAssert count == 2
      button "失败":
        key: "fail"
        onClick:
          count = 90
          raise newException(UiError, "handler rejected")
      button "遮蔽":
        key: "shadow"
        onClick:
          let count = 99
          doAssert count == 99

component Plain:
  view:
    text "plain"

type CounterProps = object
  initial: int
component WithProps(props: CounterProps):
  state:
    count = props.initial
  view:
    column:
      text count:
        key: "props-count"
      button "change":
        key: "props-add"
        onClick(e):
          count += 1

proc double(value: int): int = value * 2
component Lexical:
  state:
    count = 2
    total = 0
    selected = true
  view:
    column:
      let copied = double(count)
      text copied:
        key: "copied"
      for count in 0..<2:
        text count:
          key: "loop-" & $count
      if selected:
        text total:
          key: "total"
      button "loop":
        key: "loop"
        onClick:
          for count in 0..<3:
            total += count
          block:
            var count = 50
            count += 1
            doAssert count == 51
          total += double(count)

type MutableCount = ref object
  number: int
proc copyCount(value: MutableCount): MutableCount = MutableCount(number: value.number)
proc sameCount(a, b: MutableCount): bool = a.number == b.number
component SnapshotCounter:
  state:
    value = stateValue(MutableCount(number: 0), snapshot = copyCount, equal = sameCount)
  view:
    column:
      text value.number:
        key: "snapshot-count"
      button "change":
        key: "snapshot-add"
        onClick:
          let next = copyCount(value)
          next.number += 1
          value = next

component StringFillState:
  state:
    fill = "#ff0000"
  view:
    column:
      width: fill
      text fill:
        key: "fill-text"
      canvas:
        key: "fill-canvas"
        width: fill
        height: 20
        circle:
          center: (10, 10)
          radius: 5
          fill: fill
      button "change":
        key: "fill-change"
        onClick:
          fill = "#0000ff"

component NumericFillState:
  state:
    fill = 7
  view:
    column:
      width: fill
      text fill:
        key: "fill-number"
      text "computed width":
        key: "fill-computed"
        width: fill * 2
      button "change":
        key: "fill-increment"
        onClick:
          fill += 1

proc app(): Application = componentApplication(component(Counter, ()), "counter")
proc label(runtime: Runtime): string = runtime.find("count").node.text

suite "simple component DSL":
  test "real component state initializes once and text accepts numbers":
    let before = initializations
    let runtime = newRuntime(app())
    defer: runtime.closeRuntime()
    check initializations == before + 1
    check runtime.label == "0"
    discard runtime.dispatch("add", Event(kind: click))
    check runtime.label == "1"
    check initializations == before + 1
    discard runtime.dispatch("reset", Event(kind: click))
    check runtime.label == "0"

  test "handlers read their draft and callbacks share one outer batch":
    let runtime = newRuntime(app())
    defer: runtime.closeRuntime()
    discard runtime.dispatch("sequence", Event(kind: click))
    check runtime.label == "2"
    let add = runtime.find("add").node.handler(click)
    runtime.uiTask(proc() =
      add(Event(kind: click))
      add(Event(kind: click)))
    check runtime.label == "4"

  test "handler exception drops draft and does not poison the next event":
    let runtime = newRuntime(app())
    defer: runtime.closeRuntime()
    expect UiError: discard runtime.dispatch("fail", Event(kind: click))
    check runtime.label == "0"
    discard runtime.dispatch("add", Event(kind: click))
    check runtime.label == "1"

  test "candidate rejection leaves accepted value and consumes failed writes":
    let runtime = newRuntime(app())
    defer: runtime.closeRuntime()
    var rejecting = false
    runtime.setValidator(proc(snapshot: Snapshot) =
      if rejecting: raise newException(UiError, "reject"))
    rejecting = true
    expect UiError: discard runtime.dispatch("add", Event(kind: click))
    check runtime.label == "0"
    rejecting = false
    discard runtime.dispatch("add", Event(kind: click))
    check runtime.label == "1"

  test "local state name shadowing remains ordinary Nim":
    let runtime = newRuntime(app())
    defer: runtime.closeRuntime()
    discard runtime.dispatch("shadow", Event(kind: click))
    check runtime.label == "0"

  test "instances do not share state and props initialize their own slot":
    let a = newRuntime(app())
    let b = newRuntime(app())
    let p = newRuntime(componentApplication(component(WithProps, CounterProps(initial: 7)), "props"))
    defer:
      a.closeRuntime()
      b.closeRuntime()
      p.closeRuntime()
    discard a.dispatch("add", Event(kind: click))
    check a.label == "1"
    check b.label == "0"
    check p.find("props-count").node.text == "7"
    discard p.dispatch("props-add", Event(kind: click))
    check p.find("props-count").node.text == "8"

  test "Nim control flow respects loop and nested block scope":
    let runtime = newRuntime(componentApplication(component(Lexical, (), key = "lexical"), "scope"))
    defer: runtime.closeRuntime()
    check runtime.find("copied").node.text == "4"
    check runtime.find("loop-0").node.text == "0"
    check runtime.find("loop-1").node.text == "1"
    discard runtime.dispatch("loop", Event(kind: click))
    check runtime.find("total").node.text == "7"
    check runtime.find("copied").node.text == "4"

  test "configured mutable values keep accepted snapshots after rejection":
    let runtime = newRuntime(componentApplication(component(SnapshotCounter, ()), "snapshot"))
    defer: runtime.closeRuntime()
    var rejecting = false
    runtime.setValidator(proc(snapshot: Snapshot) =
      if rejecting: raise newException(UiError, "reject mutable"))
    rejecting = true
    expect UiError: discard runtime.dispatch("snapshot-add", Event(kind: click))
    check runtime.find("snapshot-count").node.text == "0"
    rejecting = false
    discard runtime.dispatch("snapshot-add", Event(kind: click))
    check runtime.find("snapshot-count").node.text == "1"

  test "width fill remains a layout keyword with string state of the same name":
    let runtime = newRuntime(componentApplication(component(StringFillState, ()), "fill-keyword"))
    defer: runtime.closeRuntime()
    check runtime.snapshot.root.node.styles["width"] == "full"
    check runtime.find("fill-text").node.text == "#ff0000"
    check runtime.find("fill-canvas").node.styles["width"] == "full"
    let first = runtime.find("fill-canvas").node.canvasFrame.get
    for command in first.commands:
      check command.paint.fill.get == color("#ff0000")
    discard runtime.dispatch("fill-change", Event(kind: click))
    check runtime.snapshot.root.node.styles["width"] == "full"
    check runtime.find("fill-text").node.text == "#0000ff"
    for command in runtime.find("fill-canvas").node.canvasFrame.get.commands:
      check command.paint.fill.get == color("#0000ff")
    for command in first.commands:
      check command.paint.fill.get == color("#ff0000")

  test "width fill cannot silently become the numeric state value":
    let runtime = newRuntime(componentApplication(component(NumericFillState, ()), "fill-number"))
    defer: runtime.closeRuntime()
    check runtime.snapshot.root.node.styles["width"] == "full"
    check runtime.find("fill-number").node.text == "7"
    check runtime.find("fill-computed").node.styles["width"] == "14"
    discard runtime.dispatch("fill-increment", Event(kind: click))
    check runtime.snapshot.root.node.styles["width"] == "full"
    check runtime.find("fill-number").node.text == "8"
    check runtime.find("fill-computed").node.styles["width"] == "16"

  test "components without state keep the ordinary host tree":
    let runtime = newRuntime(componentApplication(component(Plain, ()), "plain"))
    defer: runtime.closeRuntime()
    check runtime.snapshot.root.node.text == "plain"

static:
  doAssert not compiles(block:
    component BadDeepWrite:
      state:
        value = stateValue(MutableCount(number: 0), snapshot = copyCount)
      view:
        button "bad":
          onClick:
            value.number = 1)
  doAssert not compiles(block:
    component BadVarArgument:
      state:
        count = 0
      view:
        button "bad":
          onClick:
            inc count)
  doAssert not compiles(block:
    component BadWrite:
      state:
        count = 0
      view:
        column:
          count = 1
          text count)
