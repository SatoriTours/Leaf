import std/[unittest, options]
import leaf
import leaf/canvas_input

component RawInputPage:
  state:
    total = 0
  view:
    column:
      text total:
        key: "total"
      canvas:
        key: "raw"
        height: 200
        focusable: true
        accessibleLabel: "交互画布"
        onPointerDown(e):
          total += int(e.button == PointerButton.primary)
        onPointerMove(e):
          total += int(e.position.x)
        onPointerUp(e):
          total += int(PointerModifier.shift in e.modifiers)
        onWheel(e):
          total += int(e.wheelDelta.y)
        onKeyDown(e):
          total += int(e.keyCode)
        circle:
          center: (20, 20)
          radius: 10

proc rawTarget(): PointerTarget =
  let id = CanvasBindingId(session: 1, mount: 1, binding: 1, generation: 1)
  PointerTarget(id: id, frameId: 1, canvasFromScreen: identityMatrix(),
    parentFromCanvas: identityMatrix(), localFromCanvas: identityMatrix()).withSourceRouteInternal(
      [CanvasSourceRoute(id: id, mask: (1'u32 shl 12)-1)])

suite "Canvas raw input and focus metadata":
  test "raw Canvas handlers share the managed transaction":
    let runtime = newRuntime(componentApplication(component(RawInputPage, ()), "raw"))
    defer: runtime.closeRuntime()
    let node = runtime.find("raw").node
    check node.text == "交互画布"
    check node.canvasFrame.get.focusable
    var rootKey: string
    for entry in node.canvasFrame.get.interactions:
      if entry.commandIndex == -1: rootKey = entry.key
    let target = rawTarget()
    var sample = PointerSample(pointerId: 1, button: PointerButton.primary,
      screenPosition: vec2(3, 5), modifiers: {PointerModifier.shift})
    for kind in [PointerEventKind.pointerDown, PointerEventKind.pointerMove, PointerEventKind.pointerUp,
        PointerEventKind.wheel, PointerEventKind.keyDown]:
      let source = rawCanvasEventInternal(target, kind, sample, wheelDelta=vec2(0, 2), keyCode=4)
      let packet = canvasDeliveryInternal(source, [CanvasRouteTarget(key: rootKey, target: target)])
      check runtime.dispatch("raw", Event(kind: EventKind.canvasInput, canvas: packet))
    check runtime.find("total").node.text == "11"

  test "frame equality includes focusability and labels are validated":
    let plain = canvas:
      height: 100
    let focusable = canvas:
      height: 100
      focusable: true
    check plain.canvasFrame.get != focusable.canvasFrame.get
    expect GraphicsError:
      discard canvas:
        accessibleLabel: "bad\0label"

  test "raw source factory rejects derived drag events and retains modifiers":
    let sample = PointerSample(pointerId: 1, screenPosition: vec2(1, 2),
      modifiers: {PointerModifier.control})
    expect GraphicsError:
      discard rawCanvasEventInternal(rawTarget(), PointerEventKind.drag, sample)
    let source = rawCanvasEventInternal(rawTarget(), PointerEventKind.pointerMove, sample)
    check source.pointerId == 1
    check source.modifiers == {PointerModifier.control}
    check source.position == vec2(1, 2)

static:
  doAssert not compiles(block:
    let invalid = canvas:
      circle:
        center: (0, 0)
        radius: 3
        onKeyDown: discard)
