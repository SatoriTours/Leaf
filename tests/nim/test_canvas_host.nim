import std/[unittest, tables, options]
import leaf
import leaf/[backend, backend_session, host_reconcile, native_host_adapter]
import leaf/backends/headless

component Scene:
  state:
    radius = 10.0
  view:
    column:
      canvas:
        key: "canvas"
        height: 200
        circle:
          center: (40, 40)
          radius: radius
      button "grow":
        key: "grow"
        onClick:
          radius += 1.0

proc circleRadius(frame: CanvasFrame): float64 =
  for command in frame.commands:
    if command.kind == DrawKind.circle: return command.radius

suite "typed Canvas host ownership":
  test "typed host adapter transports complete owned frames and diffs geometry":
    let runtime = newRuntime(componentApplication(component(Scene, ()), "canvas"))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend,
      HostContext(sessionId: 51, mountGeneration: 1, contentWidth: 640, contentHeight: 480, scale: 1))
    defer:
      session.dispose()
      runtime.closeRuntime()
    let handle = session.handleFor(runtime.find("canvas").id)
    check recording.entities[handle].canvas.isSome
    check recording.entities[handle].canvas.get.circleRadius == 10.0
    let created = recording.creates
    discard runtime.dispatch("grow", Event(kind: click))
    check recording.entities[handle].canvas.get.circleRadius == 11.0
    check recording.creates == created

  test "prepare and partial apply rejection preserve frame and managed State":
    let runtime = newRuntime(componentApplication(component(Scene, ()), "canvas"))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend,
      HostContext(sessionId: 52, mountGeneration: 1, contentWidth: 640, contentHeight: 480, scale: 1))
    defer:
      session.dispose()
      runtime.closeRuntime()
    let handle = session.handleFor(runtime.find("canvas").id)
    recording.failPrepare = true
    expect UiError: discard runtime.dispatch("grow", Event(kind: click))
    recording.failPrepare = false
    check recording.entities[handle].canvas.get.circleRadius == 10.0
    recording.failApplyAt = 1
    expect UiError: discard runtime.dispatch("grow", Event(kind: click))
    recording.failApplyAt = 0
    check recording.entities[handle].canvas.get.circleRadius == 10.0
    discard runtime.dispatch("grow", Event(kind: click))
    check recording.entities[handle].canvas.get.circleRadius == 11.0
    check not session.faulted

  test "raw protocol gates refuse absent or misplaced Canvas sidecars":
    let builder = newCanvasBuilder()
    let frame = builder.finishFrame()
    for kind in [NodeKind.text, NodeKind.canvasHost]:
      let props = HostProps(canvas: (if kind == NodeKind.text: some(frame) else: none(CanvasFrame)))
      let reconciler = newHostReconciler(55)
      let handle = reconciler.reserveHandle()
      expect UiError:
        discard reconciler.planDelta(HostChanges(upserts: @[
          HostRecord(handle: handle, nodeId: "invalid", kind: kind, props: props)]), 1)
      let recording = newRecordingBackend(fullCapabilities())
      let consumer = nativeHostConsumer(recording.backend, 56)
      expect UiError:
        consumer.prepare(HostBatch(sessionId: 56, nextRevision: 1, ops: @[
          HostOp(kind: HostOpKind.create, handle: handle, nodeId: "invalid", nodeKind: kind, props: props)]))
      check recording.prepareCalls == 0
