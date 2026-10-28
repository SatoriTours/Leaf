import std/[unittest, options, strutils, tables]
import leaf

component Drawing:
  state:
    radius = 20.0
  view:
    column:
      canvas:
        key: "drawing"
        height: 360
        viewBox: (640, 360)
        background: "#101820"
        rect:
          position: (24, 24)
          size: (592, 312)
          radius: 16
          fill: "#1B2936"
        for index in 0..<3:
          circle:
            center: (120 + index * 60, 180)
            radius: radius
            fill: "#5ED5B0"
        group:
          translate: (200, 120)
          rotate: 30.deg
          scale: (1.2, 1.2)
          clip: (0, 0, 160, 120)
          line:
            start: (0, 0)
            finish: (120, 100)
            stroke: "#FFFFFF"
            strokeWidth: 2
        path:
          stroke: "#5ED5B0"
          strokeWidth: 3
          moveTo (60, 260)
          curveTo (180, 260), (220, 80), (560, 80)
        text "Leaf":
          position: (48, 48)
          size: 16
          fill: "#FFFFFF"
        text 42:
          position: (48, 70)
      button "larger":
        key: "larger"
        onClick:
          radius += 1.0

suite "Canvas DSL lowering":
  test "software rendering is an explicit application choice":
    let app = componentApplication(component(Drawing, ()), "renderer")
    let software = app.withCanvasRenderer(CanvasRenderer.software)
    check app.canvasRenderer == CanvasRenderer.hardware
    check software.canvasRenderer == CanvasRenderer.software
    check software.title == app.title
    check compiles(run(Drawing, canvasRenderer = CanvasRenderer.software))

  test "a Canvas is one host, not one node per primitive":
    let runtime = newRuntime(componentApplication(component(Drawing, ()), "drawing"))
    defer: runtime.closeRuntime()
    let canvas = runtime.find("drawing").node
    check canvas.kind == NodeKind.canvasHost
    check canvas.children.len == 0
    check canvas.styles["width"] == "full"
    check canvas.styles["height"] == "360"
    let frame = canvas.canvasFrame.get
    check frame.commandCount == 10
    check frame.pathSegmentCount == 2
    check frame.viewBox.get == vec2(640, 360)
    check frame.background == color("#101820")
    check runtime.snapshot.root.children.len == 2

  test "managed values only rebuild their owning component and new frame":
    let runtime = newRuntime(componentApplication(component(Drawing, ()), "drawing"))
    defer: runtime.closeRuntime()
    let accepted = runtime.find("drawing").node.canvasFrame.get
    discard runtime.dispatch("larger", Event(kind: click))
    let updated = runtime.find("drawing").node.canvasFrame.get
    var oldRadius, newRadius: float64
    for command in accepted.commands:
      if command.kind == DrawKind.circle: oldRadius = command.radius
    for command in updated.commands:
      if command.kind == DrawKind.circle: newRadius = command.radius
    check oldRadius == 20.0
    check newRadius == 21.0
    check accepted != updated

  test "group scope restores on ordinary loop break and continue":
    let drawing = canvas:
      height: 200
      for index in 0..<3:
        group:
          translate: (index * 20, 0)
          if index == 1:
            break
          circle:
            center: (10, 10)
            radius: 5
    check drawing.canvasFrame.get.commandCount == 5

  test "component identities still originate in the caller module":
    check "test_canvas_dsl.nim::Drawing" in Drawing.typeId

static:
  doAssert not compiles(block:
    let invalid = canvas:
      height: 200
      circle:
        radius: 10)
  doAssert not compiles(block:
    let invalid = canvas:
      height: 200
      circle:
        center: (10, 10)
        radius: 5
        fill: "#nothex")
  doAssert not compiles(block:
    let invalid = canvas:
      height: 200
      rect:
        position: (0, 0)
        size: (10, 10)
        unknown: 4)

suite "sealed path reuse in Canvas DSL":
  test "geometry keeps immutable path contents and rejects conflicting commands":
    let builder = newPathBuilder()
    builder.moveTo(vec2(0,0))
    builder.lineTo(vec2(10,10))
    builder.closePath()
    let sealed = builder.finishPath()
    let node = canvas:
      path:
        geometry: sealed
        fill: "#5ED5B0"
    check node.canvasFrame.get.commandAt(0).path == sealed
    check node.canvasFrame.get.pathSegmentCount == 3
    expect GraphicsError: builder.lineTo(vec2(20,20))
    doAssert not compiles(block:
      discard canvas:
        path:
          geometry: sealed
          fill: "#5ED5B0"
          moveTo (1,2))
    doAssert not compiles(block:
      discard canvas:
        path:
          geometry: sealed
          fill: "#5ED5B0"
          fillRule: evenOdd)
