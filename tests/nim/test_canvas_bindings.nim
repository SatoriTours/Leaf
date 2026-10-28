import std/[unittest, options]
import leaf
import leaf/[canvas_bindings, canvas_input]

proc scene(ids: seq[int]): CanvasFrame =
  let node = canvas:
    group:
      key: "parent"
      translate: (10, 20)
      for id in ids:
        circle:
          key: id
          center: (id * 10, 0)
          radius: 4
          onClick: discard
  node.canvasFrame.get

proc keys(frame: CanvasFrame): seq[string] =
  for entry in frame.interactions:
    if entry.eventMask != 0: result.add(entry.key)

suite "prepared Canvas binding identities":
  test "reorder preserves live slots and current transforms without mutating the old snapshot":
    var nextSlot = 0'u64
    let f = scene(@[1, 2])
    let a = prepareCanvasBindings(f, 11, 7, nextSlot)
    let firstKeys = f.keys
    let first = a.binding(firstKeys[0]).get.id
    let reverse = prepareCanvasBindings(scene(@[2, 1]), 11, 7, nextSlot, a)
    check reverse.binding(firstKeys[0]).get.id == first
    check a.binding(firstKeys[0]).get.id == first
    let projected = reverse.pointerTarget(first, 3, identityMatrix()).get
    check projected.parentFromCanvas.transformPoint(vec2(13, 25)) == vec2(3, 5)
    check reverse.bindingKey(first).get == firstKeys[0]
    check nextSlot == 2

  test "retirement and a new mount never recycle a previously issued token":
    var nextSlot = 0'u64
    let f = scene(@[1])
    let key = f.keys[0]
    let a = prepareCanvasBindings(f, 11, 7, nextSlot)
    let old = a.binding(key).get.id
    let empty = prepareCanvasBindings(scene(@[]), 11, 7, nextSlot, a)
    check empty.bindingKey(old).isNone
    let recreated = prepareCanvasBindings(f, 11, 7, nextSlot, empty)
    check recreated.binding(key).get.id != old
    let remounted = prepareCanvasBindings(f, 11, 8, nextSlot, recreated)
    check remounted.binding(key).get.id.mount == 8
    check remounted.bindingKey(recreated.binding(key).get.id).isNone
    let rejectedCandidate = prepareCanvasBindings(scene(@[2]), 11, 8, nextSlot, remounted)
    let candidateId = rejectedCandidate.binding(scene(@[2]).keys[0]).get.id
    let replacement = prepareCanvasBindings(scene(@[2]), 11, 8, nextSlot, remounted)
    check replacement.binding(scene(@[2]).keys[0]).get.id != candidateId

  test "source route stays keyless and frozen when current projection changes":
    let id = CanvasBindingId(session: 1, mount: 2, binding: 3, generation: 1)
    let parent = CanvasBindingId(session: 1, mount: 2, binding: 4, generation: 1)
    var route = @[CanvasSourceRoute(id: id, mask: 4), CanvasSourceRoute(id: parent, mask: 4)]
    let t = withSourceRouteInternal(PointerTarget(id: id, frameId: 1,
      canvasFromScreen: identityMatrix(), parentFromCanvas: identityMatrix(), localFromCanvas: identityMatrix()), route)
    route[0].id.binding = 999
    let machine = newCanvasPointerMachine(vec2(4, 4))
    let down = PointerSample(pointerId: 1, screenPosition: vec2(1, 1), button: PointerButton.primary,
      buttons: {PointerButton.primary})
    machine.press(down, t)
    machine.release(PointerSample(pointerId: 1, screenPosition: vec2(1, 1), button: PointerButton.primary), some(t), some(id))
    let event = machine.drain()[0]
    var current = t
    current.frameId = 2
    current = withSourceRouteInternal(current, @[CanvasSourceRoute(id: id, mask: 4)])
    let projected = event.project(current).get
    var tokens: seq[CanvasBindingId]
    for entry in projected.sourceRouteInternal: tokens.add(entry.id)
    check tokens == @[id, parent]
    check projected.frameId == 1
    var counter = 0'u64
    expect GraphicsError:
      discard prepareCanvasBindings(scene(@[1]), 0, 1, counter)


  test "structural parent and kind changes retire tokens but listener additions do not":
    proc frame(parent: string, rectangular = false, listen = false): CanvasFrame =
      let b = newCanvasBuilder()
      b.beginGroup()
      if listen:
        b.addInteractionInternal(CanvasInteraction(commandIndex: 0, key: "parent", parentIdentity: "r", eventMask: 4, hitTest: true))
      if rectangular: b.addRect(vec2(0, 0), vec2(10, 10))
      else: b.addCircle(vec2(0, 0), 10)
      b.addInteractionInternal(CanvasInteraction(commandIndex: 1, key: "child", parentIdentity: parent, eventMask: 4, hitTest: true))
      b.endGroup()
      b.finishFrame()
    var counter = 0'u64
    let a = prepareCanvasBindings(frame("parent"), 1, 2, counter)
    let old = a.binding("child").get.id
    let withListener = prepareCanvasBindings(frame("parent", listen=true), 1, 2, counter, a)
    check withListener.binding("child").get.id == old
    let moved = prepareCanvasBindings(frame("different"), 1, 2, counter, withListener)
    check moved.binding("child").get.id != old
    let changed = prepareCanvasBindings(frame("parent", rectangular=true), 1, 2, counter, a)
    check changed.binding("child").get.id != old
    let m = newCanvasPointerMachine(vec2(4, 4))
    let t = withListener.pointerTarget(old, 1, identityMatrix()).get
    m.press(PointerSample(pointerId: 1, button: PointerButton.primary, buttons: {PointerButton.primary}), t)
    m.release(PointerSample(pointerId: 1, button: PointerButton.primary), some(t), some(old))
    var route: seq[CanvasBindingId]
    for entry in m.drain()[0].sourceRouteInternal: route.add(entry.id)
    check route == @[old, withListener.binding("parent").get.id]
