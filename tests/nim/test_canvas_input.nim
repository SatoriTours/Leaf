import std/[unittest, options]
import leaf/[graphics, canvas_input, canvas_hit]

proc target(id = 1'u64, generation = 1'u64, frame = 1'u64,
    scale = 1.0, translate = 0.0): PointerTarget =
  PointerTarget(id: CanvasBindingId(session: 1, mount: 2, binding: id, generation: generation),
    frameId: frame, canvasFromScreen: identityMatrix(),
    parentFromCanvas: groupTransform(translate = vec2(translate, 0), scale = vec2(scale, scale)),
    localFromCanvas: identityMatrix())
proc sample(x, y: float64, pointer = 1'u32, primary = true): PointerSample =
  PointerSample(pointerId: pointer, screenPosition: vec2(x, y),
    button: PointerButton.primary, buttons: (if primary: {PointerButton.primary} else: {}))

suite "Canvas pointer state and bounded delivery":
  test "threshold starts once with full displacement; capture end suppresses click":
    let m = newCanvasPointerMachine(vec2(4, 4))
    let t = target()
    m.press(sample(0, 0), t)
    check m.captureWanted
    m.move(sample(3, 2), some(t))
    check m.drain().len == 0
    m.move(sample(6, 2), some(t))
    let started = m.drain()
    check started.len == 2
    check started[0].kind == PointerEventKind.dragStart
    check started[1].kind == PointerEventKind.drag
    check started[1].delta == vec2(6, 2)
    m.release(sample(6, 2, primary = false), some(t), none(CanvasBindingId))
    let ended = m.drain()
    check ended.len == 1
    check ended[0].kind == PointerEventKind.dragEnd
    check not m.captureWanted

  test "click requires primary release on same identity and no threshold crossing":
    let m = newCanvasPointerMachine(vec2(4, 4))
    let t = target()
    m.press(sample(0, 0), t)
    m.release(sample(2, 1, primary = false), some(t), some(t.id))
    let events = m.drain()
    check events.len == 1
    check events[0].kind == PointerEventKind.click
    m.press(sample(0, 0), t)
    m.release(sample(20, 0, primary = false), some(t), some(t.id))
    check m.drain().len == 0
    m.press(sample(0, 0), t)
    m.release(sample(0, 0, primary = false), some(t), some(target(2).id))
    check m.drain().len == 0

  test "coalescing retains screen displacement and uses newest parent vector map":
    let m = newCanvasPointerMachine(vec2(4, 4))
    m.press(sample(0, 0), target())
    m.move(sample(6, 0), some(target()))
    m.move(sample(8, 0), some(target(frame = 2, scale = 0.5, translate = -100)))
    let events = m.drain()
    check events.len == 2
    check events[1].delta == vec2(4, 0)
    check events[1].position == vec2(-96, 0)
    check events[1].localPosition == vec2(8, 0)
    m.move(sample(8, 0), some(target(frame = 3, scale = 0.5, translate = -200)))
    check m.drain().len == 0 # Parent motion is not pointer motion.
    m.move(sample(10, 0), some(target(frame = 3, scale = 0.5, translate = -200)))
    check m.drain()[0].delta == vec2(1, 0)

  test "release flushes an unsampled final displacement before its unique End":
    let m = newCanvasPointerMachine(vec2(4, 4))
    let t = target()
    m.press(sample(0, 0), t)
    m.move(sample(6, 0), some(t))
    discard m.drain()
    m.release(sample(8, 1, primary = false), some(t), none(CanvasBindingId))
    let events = m.drain()
    check events.len == 2
    check events[0].kind == PointerEventKind.drag
    check events[0].delta == vec2(2, 1)
    check events[1].kind == PointerEventKind.dragEnd
    check events[1].delta == vec2(0, 0)

  test "capture loss cancels once while disposal retires silently":
    let m = newCanvasPointerMachine(vec2(4, 4))
    let t = target()
    m.press(sample(0, 0), t); m.move(sample(6, 0), some(t))
    discard m.drain()
    m.cancel(PointerCancelReason.captureLost)
    m.cancel(PointerCancelReason.captureLost)
    let events = m.drain()
    check events.len == 1
    check events[0].kind == PointerEventKind.dragCancel
    check events[0].cancelReason == PointerCancelReason.captureLost
    check not m.captureWanted
    m.press(sample(0, 0), t); m.move(sample(6, 0), some(t))
    m.retire(t.id)
    check m.drain().len == 0
    check not m.captureWanted

  test "invalid transforms cancel and stale generations never inherit capture":
    let m = newCanvasPointerMachine(vec2(4, 4))
    let t = target()
    m.press(sample(0, 0), t); m.move(sample(6, 0), some(t))
    discard m.drain()
    m.move(sample(7, 0), some(target(scale = 0)))
    check m.drain()[0].cancelReason == PointerCancelReason.nonInvertible
    m.press(sample(0, 0), t); m.move(sample(6, 0), some(t))
    m.move(sample(7, 0), some(target(generation = 2)))
    check m.drain().len == 0
    check not m.captureWanted

  test "queue overflow faults explicitly, releases capture and does not strand dragging":
    let m = newCanvasPointerMachine(vec2(4, 4), maxEvents = 2)
    let t = target()
    m.press(sample(0, 0), t); m.move(sample(6, 0), some(t))
    m.move(sample(8, 0), some(t)) # A move coalesces even when queue is full.
    expect GraphicsError:
      m.release(sample(8, 0, primary = false), some(t), none(CanvasBindingId))
    check m.faulted
    check not m.captureWanted
    check m.drain().len == 0
    expect GraphicsError: m.press(sample(0, 0), t)

  test "hover boundaries leave inward-to-outward and enter outward-to-inward":
    let m = newCanvasPointerMachine(vec2(4, 4))
    m.updateHover(sample(0, 0), @[target(1), target(3)])
    let entered = m.drain()
    check entered.len == 2
    check entered[0].kind == PointerEventKind.enter
    check entered[0].id.binding == 3
    check entered[1].id.binding == 1
    m.updateHover(sample(1, 0), @[target(2), target(3)])
    let changed = m.drain()
    check changed.len == 2
    check changed[0].kind == PointerEventKind.leave
    check changed[0].id.binding == 1
    check changed[1].kind == PointerEventKind.enter
    check changed[1].id.binding == 2
    m.retire(target(2).id)
    m.updateHover(sample(2, 0), @[target(3)])
    check m.drain().len == 0

  test "other pointers and secondary buttons cannot replace an active primary gesture":
    let m = newCanvasPointerMachine(vec2(4, 4))
    let t = target()
    var secondary = sample(0, 0)
    secondary.button = PointerButton.secondary
    m.press(secondary, t)
    check not m.captureWanted
    m.press(sample(0, 0), t)
    m.move(sample(20, 0, pointer = 2), some(t))
    m.release(sample(20, 0, pointer = 2, primary = false), some(t), some(t.id))
    check m.captureWanted
    check m.drain().len == 0
    m.release(sample(0, 0, primary = false), some(t), some(t.id))
    check m.drain()[0].kind == PointerEventKind.click

  test "delivery accepts repaint of same binding but rejects wrong identity and future frame":
    let m = newCanvasPointerMachine(vec2(4, 4))
    let t = target()
    m.press(sample(0, 0), t)
    m.release(sample(1, 0, primary = false), some(t), some(t.id))
    let event = m.drain()[0]
    check event.project(t).isSome
    check event.project(target(generation = 2)).isNone
    # Successful repaint increments frameId even without changing the binding.
    check event.project(target(frame = 2)).isSome
    check event.project(target(frame = 2)).get.frameId == 1
    var future = target(frame = 3)
    let next = newCanvasPointerMachine(vec2(4, 4))
    next.press(sample(0, 0), future)
    next.release(sample(0, 0, primary = false), some(future), some(future.id))
    check next.drain()[0].project(t).isNone
    var remounted = t
    remounted.id.mount = 3
    check event.project(remounted).isNone
    expect GraphicsError: discard newCanvasPointerMachine(vec2(-1, 2))
    expect GraphicsError: discard newCanvasPointerMachine(vec2(4, 4), maxEvents = 257)


  test "adding an ancestor listener does not re-enter an unchanged hovered child":
    # The same immutable geometry and structural parent chain in both snapshots:
    # outer group -> inner group -> circle. Only inner gains a binding.
    let b = newCanvasBuilder()
    b.beginGroup(); b.beginGroup(); b.addCircle(vec2(0, 0), 10)
    b.endGroup(); b.endGroup()
    let frame = b.finishFrame()
    let before = prepareHitSnapshot(frame, @[
      HitBinding(commandIndex: 0, key: "outer"), HitBinding(commandIndex: 2, key: "leaf")])
    let after = prepareHitSnapshot(frame, @[
      HitBinding(commandIndex: 0, key: "outer"), HitBinding(commandIndex: 1, key: "inner"),
      HitBinding(commandIndex: 2, key: "leaf")])
    proc route(snapshot: CanvasHitSnapshot, frameId: uint64): seq[PointerTarget] =
      for entry in snapshot.hitTest(vec2(0, 0)).get.route:
        result.add(target(uint64(entry.commandIndex+1), frame = frameId))
    let oldRoute = route(before, 1)
    let newRoute = route(after, 2)
    check oldRoute[0].id == newRoute[0].id # No reparenting or generation reuse.
    let m = newCanvasPointerMachine(vec2(4, 4))
    m.updateHover(sample(0, 0), oldRoute)
    discard m.drain()
    m.updateHover(sample(0, 0), newRoute)
    let events = m.drain()
    check events.len == 1
    if events.len == 1:
      check events[0].kind == PointerEventKind.enter
      check events[0].id.binding == 2
    # Retiring the ancestor binding must not notify that dead owner, nor disturb
    # the surviving hovered child and outer group.
    m.retire(newRoute[1].id)
    m.updateHover(sample(0, 0), route(before, 3))
    check m.drain().len == 0
