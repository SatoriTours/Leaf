import std/[unittest, options, math]
import leaf/graphics

suite "owned Canvas graphics":
  test "colors, vectors and group order have explicit typed semantics":
    check color("#5ED5B0").a == 1.0'f32
    check abs(color("#ffffff80").a - 128.0'f32 / 255.0'f32) < 0.0001'f32
    expect GraphicsError: discard color("red")
    expect GraphicsError: discard color("#12345z")
    check vec2(1, 2) + vec2(3, 4) == vec2(4, 6)
    let transform = groupTransform(translate = vec2(10, 20), rotate = 90.deg, scale = vec2(2, 3))
    let p = transform.transformPoint(vec2(1, 0))
    check abs(p.x - 10) < 0.000001
    check abs(p.y - 22) < 0.000001
    check transform.inverse.isSome
    check groupTransform(scale = vec2(0, 1)).inverse.isNone

  test "a frame owns typed shapes, paths and Unicode text":
    let path = newPathBuilder()
    path.moveTo(vec2(0, 0))
    path.curveTo(vec2(10, 0), vec2(10, 10), vec2(20, 10))
    path.closePath()
    let geometry = path.finishPath()
    let builder = newCanvasBuilder(viewBox = some(vec2(640, 360)), background = color("#101820"))
    builder.addRect(vec2(24, 24), vec2(592, 312), radius = 16)
    builder.beginGroup(groupTransform(translate = vec2(20, 20)), some(rectangle(0, 0, 100, 100)))
    builder.addCircle(vec2(40, 40), 20)
    builder.endGroup()
    builder.addPath(geometry, paint(fill = none(Color), stroke = some(color("#5ED5B0")), strokeWidth = 3))
    builder.addText("Leaf 中文 ✓", vec2(48, 48), 16)
    let frame = builder.finishFrame()
    check frame.commandCount == 6
    check frame.pathSegmentCount == 3
    check frame.viewBox.get == vec2(640, 360)
    check frame.ownedBytes > 0
    var kinds: seq[DrawKind]
    for command in frame.commands: kinds.add(command.kind)
    check kinds == @[DrawKind.rectangle, DrawKind.beginGroup, DrawKind.circle,
      DrawKind.endGroup, DrawKind.path, DrawKind.text]
    expect GraphicsError: builder.addCircle(vec2(0, 0), 5)
    expect GraphicsError: path.lineTo(vec2(3, 3))

  test "invalid geometry, paint, Unicode and unbalanced scopes fail before sealing":
    let builder = newCanvasBuilder()
    expect GraphicsError: builder.addCircle(vec2(NaN, 0), 1)
    expect GraphicsError: builder.addCircle(vec2(0, 0), -1)
    expect GraphicsError: builder.addRect(vec2(0, 0), vec2(-1, 20))
    expect GraphicsError: builder.addText("\xff", vec2(0, 0), 16)
    expect GraphicsError: builder.endGroup()
    let path = newPathBuilder()
    expect GraphicsError: path.lineTo(vec2(1, 2))
    path.moveTo(vec2(0, 0))
    path.lineTo(vec2(1, 2))
    expect GraphicsError: builder.addPath(path.finishPath(), paint(fill = none(Color)))
    builder.beginGroup(groupTransform())
    expect GraphicsError: discard builder.finishFrame()
    builder.endGroup()
    check builder.finishFrame().commandCount == 2

  test "finite quotas reject without truncating or poisoning the frame":
    let limits = CanvasLimits(maxCommands: 2, maxPathSegments: 2, maxBytes: MaxCanvasFrameBytes, maxDepth: 1)
    let builder = newCanvasBuilder(limits = limits)
    builder.addCircle(vec2(0, 0), 1)
    builder.addCircle(vec2(2, 2), 1)
    expect GraphicsError: builder.addCircle(vec2(4, 4), 1)
    check builder.finishFrame().commandCount == 2
    let groups = newCanvasBuilder(limits = limits)
    groups.beginGroup(groupTransform())
    expect GraphicsError: groups.beginGroup(groupTransform())
    groups.endGroup()
    check groups.finishFrame().commandCount == 2

  test "viewBox contain uses the same invertible coordinate map":
    let box = some(vec2(640, 360))
    let map = canvasTransform(box, vec2(800, 600))
    check map.transformPoint(vec2(0, 0)) == vec2(0, 75)
    check map.transformPoint(vec2(640, 360)) == vec2(800, 525)
    check map.inverse.get.transformPoint(vec2(400, 300)) == vec2(320, 180)
    expect GraphicsError: discard canvasTransform(box, vec2(0, 600))

  test "interaction metadata is owned, budgeted and capped before publishing":
    let b = newCanvasBuilder()
    for index in 0..<10_001:
      b.addCircle(vec2(index, 0), 1)
      if index < 10_000:
        b.addInteractionInternal(CanvasInteraction(commandIndex: index, key: $index,
          eventMask: 1, hitTest: true))
      else:
        expect GraphicsError:
          b.addInteractionInternal(CanvasInteraction(commandIndex: index, key: $index,
            eventMask: 1, hitTest: true))
    let frame = b.finishFrame()
    var count = 0
    for entry in frame.interactions: inc count
    check count == 10_000
    let duplicate = newCanvasBuilder()
    duplicate.addCircle(vec2(0, 0), 1)
    duplicate.addInteractionInternal(CanvasInteraction(commandIndex: 0, key: "opaque-id", eventMask: 1, hitTest: true))
    duplicate.addCircle(vec2(10, 0), 1)
    expect GraphicsError:
      duplicate.addInteractionInternal(CanvasInteraction(commandIndex: 1, key: "opaque-id", eventMask: 1, hitTest: true))


suite "Canvas ordered finite guards":
  test "signed zeros subnormals and finite double extrema remain legal neutral values":
    for value in [0.0,-0.0,1e-320,-1e-320,1e308,-1e308]:
      let b=newCanvasBuilder()
      b.addCircle(vec2(value,value),abs(value))
      b.beginGroup(Matrix3x2(xx:1,yy:1,dx:value,dy:value))
      b.endGroup()
      check b.finishFrame().commandCount==3
  test "nonfinite channels coordinates and dimensions fail before any append":
    for value in [NaN,Inf,NegInf]:
      let b=newCanvasBuilder()
      expect GraphicsError:b.addCircle(vec2(value,0),1)
      expect GraphicsError:b.addCircle(vec2(0,0),value)
      expect GraphicsError:b.beginGroup(Matrix3x2(xx:value,yy:1))
      expect GraphicsError:b.addCircle(vec2(0,0),1,paint(fill=some(Color(r:float32(value),g:0,b:0,a:1))))
      check b.finishFrame().commandCount==0
