import std/[unittest, options, tables, json]
import leaf
from leaf/canvas_input import PointerTarget, PointerSample, CanvasRouteTarget,
  newCanvasPointerMachine, press, release, drain, canvasDeliveryInternal, pointerTargetInternal
import leaf/[backend, backend_session, host_reconcile, native_host_adapter]
import leaf/backends/headless
import ../fixture_app

component InteractiveScene:
  state:
    count = 0
  view:
    column:
      text count:
        key: "count"
      canvas:
        key: "scene"
        group:
          key: "group"
          onClick:
            count += 10
          circle:
            key: "dot"
            center: (20, 20)
            radius: 10
            onClick(e):
              count += 1
              e.stopPropagation()
            onDrag(e):
              count += int(e.delta.x)

proc clickEvent(): CanvasPointerEvent =
  let m = newCanvasPointerMachine(vec2(4, 4))
  let t = PointerTarget(id: CanvasBindingId(session: 1, mount: 1, binding: 1, generation: 1),
    frameId: 1, canvasFromScreen: identityMatrix(), parentFromCanvas: identityMatrix(),
    localFromCanvas: identityMatrix())
  m.press(PointerSample(pointerId: 1, button: PointerButton.primary,
    buttons: {PointerButton.primary}, screenPosition: vec2(20, 20)), t)
  m.release(PointerSample(pointerId: 1, button: PointerButton.primary,
    screenPosition: vec2(20, 20)), some(t), some(t.id))
  m.drain()[0]

proc route(key: string, id = 1'u64): CanvasRouteTarget =
  var t = clickEvent().pointerTargetInternal
  t.id.binding = id
  CanvasRouteTarget(key: key, target: t)

suite "Canvas event DSL and managed delivery":
  test "handlers stay outside immutable geometry and run in the existing state batch":
    let runtime = newRuntime(componentApplication(component(InteractiveScene, ()), "input"))
    defer: runtime.closeRuntime()
    let frame = runtime.find("scene").node.canvasFrame.get
    var keys: seq[string]
    for binding in frame.interactions: keys.add(binding.key)
    check keys.len == 2
    check frame.commandCount == 3
    check runtime.find("count").node.text == "0" # Construction never calls handlers.
    let packet = canvasDeliveryInternal(clickEvent(), @[
      route(keys[1]), route(keys[0], 2)])
    check runtime.dispatch("scene", Event(kind: EventKind.canvasInput, canvas: packet))
    check runtime.find("count").node.text == "1" # Child stops group bubbling.
    check frame == runtime.find("scene").node.canvasFrame.get # Handler bodies aren't frame data.

  test "same-parent duplicate explicit keys fail before a frame is published":
    expect GraphicsError:
      discard canvas:
        circle:
          key: "same"
          center: (0, 0)
          radius: 3
          onClick: discard
        circle:
          key: "same"
          center: (10, 0)
          radius: 3
          onClick: discard

  test "loop keys are stable across reorder and callbacks retain their own values":
    var clicked: seq[int]
    proc scene(ids: seq[int]): Node =
      canvas:
        for id in ids:
          circle:
            key: id
            center: (id * 10, 0)
            radius: 4
            onClick:
              clicked.add(id)
    let first = scene(@[1, 2])
    let second = scene(@[2, 1])
    var before, after: seq[string]
    for binding in first.canvasFrame.get.interactions: before.add(binding.key)
    for binding in second.canvasFrame.get.interactions: after.add(binding.key)
    check before == @[after[1], after[0]]
    first.handler(EventKind.canvasInput)(Event(kind: EventKind.canvasInput,
      canvas: canvasDeliveryInternal(clickEvent(), @[route(before[0])])) )
    first.handler(EventKind.canvasInput)(Event(kind: EventKind.canvasInput,
      canvas: canvasDeliveryInternal(clickEvent(), @[route(before[1])])) )
    check clicked == @[1, 2]

component FailingCanvasEvent:
  state:
    count = 0
  view:
    column:
      text count:
        key: "value"
      canvas:
        key: "failing"
        circle:
          center: (0, 0)
          radius: 5
          onClick:
            count += 1
            raise newException(UiError, "handler failed")

suite "Canvas event transaction and typed Host gates":
  test "handler exception drops the draft and does not replay it":
    let runtime = newRuntime(componentApplication(component(FailingCanvasEvent, ()), "failure"))
    defer: runtime.closeRuntime()
    var key: string
    for entry in runtime.find("failing").node.canvasFrame.get.interactions: key = entry.key
    let packet = canvasDeliveryInternal(clickEvent(), @[route(key)])
    expect UiError: discard runtime.dispatch("failing", Event(kind: EventKind.canvasInput, canvas: packet))
    check runtime.find("value").node.text == "0"
    expect UiError: discard runtime.dispatch("failing", Event(kind: EventKind.canvasInput, canvas: packet))
    check runtime.find("value").node.text == "0"

  test "prepare rejection preserves accepted callbacks and the managed draft":
    let runtime = newRuntime(componentApplication(component(InteractiveScene, ()), "host-input"))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend,
      HostContext(sessionId: 91, mountGeneration: 1, contentWidth: 640, contentHeight: 480, scale: 1))
    defer:
      session.dispose()
      runtime.closeRuntime()
    let frame = runtime.find("scene").node.canvasFrame.get
    var keys: seq[string]
    for entry in frame.interactions: keys.add(entry.key)
    let packet = canvasDeliveryInternal(clickEvent(), @[route(keys[1]), route(keys[0], 2)])
    let handle = session.handleFor(runtime.find("scene").id)
    check normalizeHostProps(runtime.find("scene").node, nativeStrict).eventMask == EventCanvasInputMask
    check recording.entities[handle].canvas.get == frame
    recording.failPrepare = true
    expect UiError: discard runtime.dispatch("scene", Event(kind: EventKind.canvasInput, canvas: packet))
    check runtime.find("count").node.text == "0"
    recording.failPrepare = false
    discard runtime.dispatch("scene", Event(kind: EventKind.canvasInput, canvas: packet))
    check runtime.find("count").node.text == "1"

  test "Canvas input masks cannot be installed on ordinary controls":
    expect UiError: discard ui(NodeKind.button, onCanvasInput = proc(e: Event) = discard)
    let reconciler = newHostReconciler(92)
    let handle = reconciler.reserveHandle()
    expect UiError:
      discard reconciler.planDelta(HostChanges(upserts: @[
        HostRecord(handle: handle, nodeId: "wrong", kind: NodeKind.text,
          props: HostProps(eventMask: EventCanvasInputMask))]), 1)
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, 93)
    expect UiError:
      consumer.prepare(HostBatch(sessionId: 93, nextRevision: 1, ops: @[
        HostOp(kind: HostOpKind.create, handle: handle, nodeId: "wrong", nodeKind: NodeKind.text,
          props: HostProps(eventMask: EventCanvasInputMask))]))
    check recording.prepareCalls == 0

  test "retired route keys are rejected before any callback executes":
    let runtime = newRuntime(componentApplication(component(InteractiveScene, ()), "stale"))
    defer: runtime.closeRuntime()
    var key: string
    for entry in runtime.find("scene").node.canvasFrame.get.interactions: key = entry.key
    let packet = canvasDeliveryInternal(clickEvent(), @[route(key), route("retired", 2)])
    discard runtime.dispatch("scene", Event(kind: EventKind.canvasInput, canvas: packet))
    check runtime.find("count").node.text == "0"

static:
  doAssert not compiles(block:
    let invalid = canvas:
      for id in 0..<3:
        circle:
          center: (id * 10, 0)
          radius: 3
          onClick: discard)


suite "Canvas optional snapshot event metadata":
  test "unhandled Canvas does not add an event key to legacy snapshot fields":
    proc render(): Node =
      canvas:
        circle:
          center: (20, 20)
          radius: 10
    let runtime = newRuntime(fixtureApplication(render, "plain Canvas", 100, 100))
    defer: runtime.closeRuntime()
    let events = runtime.snapshot.toJson()["root"]["events"]
    check events.len == 3
    check not events.hasKey("canvasInput")
    check not events.hasKey("back")

  test "registered Canvas input remains observable as an optional event key":
    proc render(): Node =
      canvas:
        circle:
          center: (20, 20)
          radius: 10
          onClick: discard
    let runtime = newRuntime(fixtureApplication(render, "interactive Canvas", 100, 100))
    defer: runtime.closeRuntime()
    let events = runtime.snapshot.toJson()["root"]["events"]
    check events.len == 4
    check events["canvasInput"].getBool
    check not events.hasKey("back")
