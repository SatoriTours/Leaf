import std/[unittest, options]
import leaf
import leaf/[backend, backend_session, host_reconcile, canvas_input, canvas_bindings]
import leaf/backends/headless

var seen: seq[string]
var deltas: seq[float64]
var duringClick: proc() {.closure.}
component QueuedCanvas:
  state:
    count = 0
  view:
    column:
      text count:
        key: "value"
      canvas:
        key: "scene"
        circle:
          key: "dot"
          center: (0, 0)
          radius: 10
          onClick:
            if duringClick != nil: duringClick()
            seen.add("canvas")
            count += 1
          onDragStart:
            seen.add("start")
          onDrag(e):
            deltas.add(e.delta.x)
            count += int(e.delta.x)
      button "Reset":
        key: "reset"
        onClick:
          seen.add("reset")
          count = 0

proc sample(x: float64, held: bool): PointerSample =
  PointerSample(pointerId: 1, screenPosition: vec2(x, 0), button: PointerButton.primary,
    buttons: (if held: {PointerButton.primary} else: {}))

suite "Canvas uses the existing native event FIFO":
  test "projection waits for the ordinary drain and does not reverse a later native reset":
    seen = @[]; deltas = @[]
    let runtime = newRuntime(componentApplication(component(QueuedCanvas, ()), "queued"))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend,
      HostContext(sessionId: 26, mountGeneration: 1, contentWidth: 640, contentHeight: 480, scale: 1))
    defer:
      session.dispose()
      runtime.closeRuntime()
    let frame = runtime.find("scene").node.canvasFrame.get
    var nextSlot = 0'u64
    let bindings = prepareCanvasBindings(frame, 26, 7, nextSlot)
    var key: string
    for entry in frame.interactions: key = entry.key
    let target = bindings.pointerTarget(bindings.binding(key).get.id, 1, identityMatrix()).get
    var projected = 0
    recording.backend.projectCanvasInput = proc(handle: NodeHandle, source: CanvasPointerEvent): Option[CanvasDelivery] =
      inc projected
      var route: seq[CanvasRouteTarget]
      for entry in source.sourceRouteInternal:
        let key = bindings.bindingKey(entry.id)
        if key.isSome:
          route.add(CanvasRouteTarget(key: key.get,
            target: bindings.pointerTarget(entry.id, 1, identityMatrix(), includeRoute=false).get))
      some(canvasDeliveryInternal(source, route))
    let m = newCanvasPointerMachine(vec2(4, 4))
    m.press(sample(0, true), target)
    m.release(sample(0, false), some(target), some(target.id))
    let fact = m.drain()[0]
    let canvasHandle = session.handleFor(runtime.find("scene").id)
    let resetHandle = session.handleFor(runtime.find("reset").id)
    check session.enqueue(EventEnvelope(session: 26, mountGeneration: 1, handle: canvasHandle,
      sequence: 1, observedRevision: runtime.acceptedRevision,
      event: Event(kind: EventKind.canvasInput, canvas: nativeCanvasDeliveryInternal(fact)), source: sourceUser))
    check session.enqueue(EventEnvelope(session: 26, mountGeneration: 1, handle: resetHandle,
      sequence: 2, observedRevision: runtime.acceptedRevision, event: Event(kind: click), source: sourceUser))
    check projected == 0
    check seen.len == 0
    check runtime.find("value").node.text == "0"
    session.drainEvents()
    check projected == 1
    check seen == @["canvas", "reset"]
    check runtime.find("value").node.text == "0"

  test "adjacent drag facts coalesce physical deltas without losing a critical start":
    seen = @[]; deltas = @[]
    let runtime = newRuntime(componentApplication(component(QueuedCanvas, ()), "drag"))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend,
      HostContext(sessionId: 27, mountGeneration: 1, contentWidth: 640, contentHeight: 480, scale: 1))
    defer:
      session.dispose()
      runtime.closeRuntime()
    var counter = 0'u64
    let frame = runtime.find("scene").node.canvasFrame.get
    let bindings = prepareCanvasBindings(frame, 27, 8, counter)
    var key: string
    for entry in frame.interactions: key = entry.key
    let target = bindings.pointerTarget(bindings.binding(key).get.id, 1, identityMatrix()).get
    recording.backend.projectCanvasInput = proc(handle: NodeHandle, source: CanvasPointerEvent): Option[CanvasDelivery] =
      some(canvasDeliveryInternal(source, @[CanvasRouteTarget(key: key, target: target)]))
    let machine = newCanvasPointerMachine(vec2(4, 4))
    machine.press(sample(0, true), target)
    let handle = session.handleFor(runtime.find("scene").id)
    var sequence = 0'u64
    for x in [5.0, 15.0]:
      machine.move(sample(x, true), some(target))
      for event in machine.drain():
        inc sequence
        check session.enqueue(EventEnvelope(session: 27, mountGeneration: 1, handle: handle,
          sequence: sequence, observedRevision: runtime.acceptedRevision,
          event: Event(kind: EventKind.canvasInput, canvas: nativeCanvasDeliveryInternal(event)), source: sourceUser))
    session.drainEvents()
    check seen == @["start"]
    check deltas == @[15.0]
    check runtime.find("value").node.text == "15"


  test "critical reset is a move coalescing barrier":
    seen = @[]; deltas = @[]
    let runtime = newRuntime(componentApplication(component(QueuedCanvas, ()), "barrier"))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend,
      HostContext(sessionId: 28, mountGeneration: 1, contentWidth: 640, contentHeight: 480, scale: 1))
    defer:
      session.dispose()
      runtime.closeRuntime()
    var counter = 0'u64
    let frame = runtime.find("scene").node.canvasFrame.get
    let bindings = prepareCanvasBindings(frame, 28, 8, counter)
    var key: string
    for entry in frame.interactions: key = entry.key
    let target = bindings.pointerTarget(bindings.binding(key).get.id, 1, identityMatrix()).get
    recording.backend.projectCanvasInput = proc(handle: NodeHandle, source: CanvasPointerEvent): Option[CanvasDelivery] =
      some(canvasDeliveryInternal(source, @[CanvasRouteTarget(key: key, target: target)]))
    let machine = newCanvasPointerMachine(vec2(4, 4))
    machine.press(sample(0, true), target)
    let handle = session.handleFor(runtime.find("scene").id)
    var sequence = 0'u64
    for x in [5.0, 15.0]:
      machine.move(sample(x, true), some(target))
      for event in machine.drain():
        inc sequence
        check session.enqueue(EventEnvelope(session: 28, mountGeneration: 1, handle: handle,
          sequence: sequence, observedRevision: runtime.acceptedRevision,
          event: Event(kind: EventKind.canvasInput, canvas: nativeCanvasDeliveryInternal(event)), source: sourceUser))
      if x == 5:
        inc sequence
        check session.enqueue(EventEnvelope(session: 28, mountGeneration: 1,
          handle: session.handleFor(runtime.find("reset").id), sequence: sequence,
          observedRevision: runtime.acceptedRevision, event: Event(kind: click), source: sourceUser))
    session.drainEvents()
    check seen == @["start", "reset"]
    check deltas == @[5.0, 10.0]
    check runtime.find("value").node.text == "10"

  test "256 critical Canvas facts include the active drain in the ownership limit":
    seen = @[]; deltas = @[]
    let runtime = newRuntime(componentApplication(component(QueuedCanvas, ()), "bound"))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend,
      HostContext(sessionId: 29, mountGeneration: 1, contentWidth: 640, contentHeight: 480, scale: 1))
    defer:
      duringClick = nil
      session.dispose()
      runtime.closeRuntime()
    var counter = 0'u64
    let frame = runtime.find("scene").node.canvasFrame.get
    let bindings = prepareCanvasBindings(frame, 29, 8, counter)
    var key: string
    for entry in frame.interactions: key = entry.key
    let target = bindings.pointerTarget(bindings.binding(key).get.id, 1, identityMatrix()).get
    recording.backend.projectCanvasInput = proc(handle: NodeHandle, source: CanvasPointerEvent): Option[CanvasDelivery] =
      some(canvasDeliveryInternal(source, @[CanvasRouteTarget(key: key, target: target)]))
    let machine = newCanvasPointerMachine(vec2(4, 4))
    machine.press(sample(0, true), target)
    machine.release(sample(0, false), some(target), some(target.id))
    let fact = nativeCanvasDeliveryInternal(machine.drain()[0])
    let handle = session.handleFor(runtime.find("scene").id)
    proc envelope(sequence: uint64): EventEnvelope =
      EventEnvelope(session: 29, mountGeneration: 1, handle: handle, sequence: sequence,
        observedRevision: runtime.acceptedRevision,
        event: Event(kind: EventKind.canvasInput, canvas: fact), source: sourceUser)
    for i in 1..256: check session.enqueue(envelope(uint64(i)))
    expect UiError: discard session.enqueue(envelope(257))
    var overflow = false
    duringClick = proc() =
      duringClick = nil
      try: discard session.enqueue(envelope(258))
      except UiError: overflow = true
    session.drainEvents()
    check overflow
    check seen.len == 256
    check runtime.find("value").node.text == "256"
