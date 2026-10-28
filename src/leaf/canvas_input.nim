## Pure input protocol state. The existing UI turn is responsible for consuming
## deliveries and calling application handlers; this module never calls them.
## Screen positions/thresholds are physical pixels. Projection removes window,
## DPI and viewBox transforms before calculating parent/local coordinates.
import std/[math, options, sequtils]
import ./graphics

const MaxCanvasPointerEvents* = 256

type
  CanvasBindingId* = object
    session*, mount*, binding*, generation*: uint64
  CanvasSourceRoute* = object
    id*: CanvasBindingId
    mask*: uint32
  PointerButton* {.pure.} = enum primary, secondary, middle
  PointerModifier* {.pure.} = enum shift, control, alt, meta
  PointerSample* = object
    pointerId*: uint32
    screenPosition*: Vec2
    button*: PointerButton
    buttons*: set[PointerButton]
    modifiers*: set[PointerModifier]
  PointerTarget* = object
    id*: CanvasBindingId
    frameId*: uint64
    canvasFromScreen*, parentFromCanvas*, localFromCanvas*: Matrix3x2
    routeSnapshot: seq[CanvasSourceRoute]
  PointerEventKind* {.pure.} = enum enter, leave, click, dragStart, drag, dragEnd, dragCancel,
    pointerDown, pointerMove, pointerUp, wheel, keyDown
  PointerCancelReason* {.pure.} = enum captureLost, focusLost, nonInvertible, buttonLost
  CanvasPropagation = ref object
    stopped: bool
  CanvasPointerEvent* = object
    kind*: PointerEventKind
    sample*: PointerSample
    cancelReason*: PointerCancelReason
    wheelDelta*: Vec2
    keyCode*: uint32
    keyRepeat*: bool
    projection: PointerTarget
    screenDelta: Vec2
    sourceRoute: seq[CanvasSourceRoute]
    sourceFrameId: uint64
    initialTarget: CanvasBindingId
    propagation: CanvasPropagation
  CanvasRouteTarget* = object
    key*: string
    target*: PointerTarget
  CanvasDeliveryStorage = ref object
    source: CanvasPointerEvent
    route: seq[CanvasRouteTarget]
  CanvasDelivery* = object
    owned: CanvasDeliveryStorage
  CanvasPointerMachine* = ref object
    threshold: Vec2
    maxEvents: int
    pending: seq[CanvasPointerEvent]
    hovered: seq[PointerTarget]
    owner: PointerTarget
    down, last: PointerSample
    active, dragging, failed: bool

proc fail(message: string) {.noreturn.} = raise newException(GraphicsError, message)
proc finite(value: float64): bool = classify(value) notin {fcNan, fcInf, fcNegInf}
proc valid(p: Vec2): bool = finite(p.x) and finite(p.y)
proc valid(target: PointerTarget): bool =
  target.id.session != 0 and target.id.mount != 0 and target.id.binding != 0 and
    target.id.generation != 0 and target.frameId != 0 and
    target.canvasFromScreen.inverse.isSome and target.parentFromCanvas.inverse.isSome and
    target.localFromCanvas.inverse.isSome
proc id*(event: CanvasPointerEvent): CanvasBindingId = event.projection.id
proc frameId*(event: CanvasPointerEvent): uint64 = event.sourceFrameId
proc pointerId*(event: CanvasPointerEvent): uint32 = event.sample.pointerId
proc button*(event: CanvasPointerEvent): PointerButton = event.sample.button
proc buttons*(event: CanvasPointerEvent): set[PointerButton] = event.sample.buttons
proc modifiers*(event: CanvasPointerEvent): set[PointerModifier] = event.sample.modifiers
proc canvasPosition*(event: CanvasPointerEvent): Vec2 =
  event.projection.canvasFromScreen.transformPoint(event.sample.screenPosition)
proc position*(event: CanvasPointerEvent): Vec2 =
  event.projection.parentFromCanvas.transformPoint(event.canvasPosition)
proc localPosition*(event: CanvasPointerEvent): Vec2 =
  event.projection.localFromCanvas.transformPoint(event.canvasPosition)
proc delta*(event: CanvasPointerEvent): Vec2 =
  (event.projection.parentFromCanvas * event.projection.canvasFromScreen).transformVector(event.screenDelta)
proc project*(event: CanvasPointerEvent, current: PointerTarget): Option[CanvasPointerEvent] =
  ## Repaint may advance frameId without changing a binding. Keep the source
  ## frame for audit, reject future/non-presented sources and retired identities,
  ## and project retained screen displacement through the current parent map.
  if not current.valid or event.id != current.id or event.frameId == 0 or event.frameId > current.frameId:
    return none(CanvasPointerEvent)
  var projected = event
  projected.projection = current
  some(projected)
proc newCanvasPointerMachine*(dragThreshold: Vec2, maxEvents = MaxCanvasPointerEvents): CanvasPointerMachine =
  if not dragThreshold.valid or dragThreshold.x < 0 or dragThreshold.y < 0 or
      maxEvents <= 0 or maxEvents > MaxCanvasPointerEvents:
    fail("invalid Canvas pointer threshold or event quota")
  CanvasPointerMachine(threshold: dragThreshold, maxEvents: maxEvents)
proc check(machine: CanvasPointerMachine) =
  if machine == nil or machine.failed: fail("Canvas input is unavailable or faulted")
proc captureWanted*(machine: CanvasPointerMachine): bool = machine != nil and machine.active
proc faulted*(machine: CanvasPointerMachine): bool = machine == nil or machine.failed
proc fault(machine: CanvasPointerMachine, message: string) {.noreturn.} =
  machine.failed = true
  machine.active = false
  machine.dragging = false
  machine.pending.setLen(0)
  machine.hovered.setLen(0)
  fail(message)
proc checkedSample(machine: CanvasPointerMachine, sample: PointerSample) =
  if not sample.screenPosition.valid: machine.fault("Canvas pointer position must be finite")
proc enqueue(machine: CanvasPointerMachine, event: sink CanvasPointerEvent) =
  if machine.pending.len > 0 and event.kind == PointerEventKind.drag:
    let previous = machine.pending[^1]
    if previous.kind == PointerEventKind.drag and previous.id == event.id and
        previous.sample.pointerId == event.sample.pointerId:
      let total = previous.screenDelta + event.screenDelta
      if not total.valid: machine.fault("Canvas pointer delta overflow")
      machine.pending[^1] = event
      machine.pending[^1].screenDelta = total
      return
  if machine.pending.len >= machine.maxEvents:
    machine.fault("Canvas pointer queue overflow; capture retired")
  machine.pending.add(event)
proc emit(machine: CanvasPointerMachine, kind: PointerEventKind, target: PointerTarget,
    sample: PointerSample, delta = vec2(0, 0), reason = PointerCancelReason.captureLost) =
  machine.enqueue(CanvasPointerEvent(kind: kind, projection: target, sample: sample,
    screenDelta: delta, sourceRoute: target.routeSnapshot, sourceFrameId: target.frameId, initialTarget: target.id, cancelReason: reason))
proc drain*(machine: CanvasPointerMachine): seq[CanvasPointerEvent] =
  if machine == nil: return @[]
  result = move(machine.pending)
  machine.pending = @[]
proc retire*(machine: CanvasPointerMachine, id: CanvasBindingId) =
  ## Dispose/unmount: no business Cancel and no queued events for a dead owner.
  if machine == nil: return
  if machine.active and machine.owner.id == id:
    machine.active = false
    machine.dragging = false
  machine.pending.keepItIf(it.id != id)
  machine.hovered.keepItIf(it.id != id)
proc cancel*(machine: CanvasPointerMachine, reason: PointerCancelReason) =
  machine.check()
  if not machine.active: return
  let notify = machine.dragging
  machine.active = false
  machine.dragging = false
  if notify: machine.emit(PointerEventKind.dragCancel, machine.owner, machine.last, reason = reason)
proc press*(machine: CanvasPointerMachine, sample: PointerSample, target: PointerTarget) =
  machine.check()
  if machine.active or sample.button != PointerButton.primary: return
  machine.checkedSample(sample)
  if not target.valid: fail("Canvas press needs a live invertible target")
  if PointerButton.primary notin sample.buttons: return
  machine.owner = target
  machine.down = sample
  machine.last = sample
  machine.active = true
  machine.dragging = false
proc beyond(machine: CanvasPointerMachine, sample: PointerSample): bool =
  let delta = sample.screenPosition-machine.down.screenPosition
  abs(delta.x) > machine.threshold.x or abs(delta.y) > machine.threshold.y
proc resolve(machine: CanvasPointerMachine, current: Option[PointerTarget]): bool =
  if current.isNone or current.get.id != machine.owner.id:
    machine.retire(machine.owner.id)
    return false
  if not current.get.valid:
    machine.cancel(PointerCancelReason.nonInvertible)
    return false
  machine.owner = current.get
  true
proc advance(machine: CanvasPointerMachine, sample: PointerSample,
    current: Option[PointerTarget], releasing = false) =
  if not machine.active or sample.pointerId != machine.down.pointerId: return
  machine.checkedSample(sample)
  if not machine.resolve(current): return
  if not releasing and PointerButton.primary notin sample.buttons:
    machine.cancel(PointerCancelReason.buttonLost)
    return
  let previous = if machine.dragging: machine.last.screenPosition else: machine.down.screenPosition
  let delta = sample.screenPosition-previous
  if not delta.valid: machine.fault("Canvas pointer delta overflow")
  machine.last = sample
  if not machine.dragging and machine.beyond(sample):
    machine.dragging = true
    machine.emit(PointerEventKind.dragStart, machine.owner, sample)
  if machine.dragging and delta != vec2(0, 0):
    machine.emit(PointerEventKind.drag, machine.owner, sample, delta)
proc move*(machine: CanvasPointerMachine, sample: PointerSample, current: Option[PointerTarget]) =
  machine.check()
  machine.advance(sample, current)
proc release*(machine: CanvasPointerMachine, sample: PointerSample,
    current: Option[PointerTarget], releasedHit: Option[CanvasBindingId]) =
  machine.check()
  if not machine.active or sample.pointerId != machine.down.pointerId or
      sample.button != PointerButton.primary: return
  machine.checkedSample(sample)
  if not machine.resolve(current): return
  if machine.dragging: machine.advance(sample, current, releasing = true)
  let dragging = machine.dragging
  machine.active = false
  machine.dragging = false
  if dragging:
    machine.emit(PointerEventKind.dragEnd, machine.owner, sample)
  elif not machine.beyond(sample) and releasedHit.isSome and releasedHit.get == machine.owner.id:
    machine.emit(PointerEventKind.click, machine.owner, sample)
proc updateHover*(machine: CanvasPointerMachine, sample: PointerSample,
    route: openArray[PointerTarget]) =
  machine.check()
  machine.checkedSample(sample)
  if route.len > MaxCanvasDepth+1: fail("Canvas hover route exceeds group depth")
  for i, target in route:
    if not target.valid: fail("Canvas hover needs live invertible targets")
    for j in 0..<i:
      if route[j].id == target.id: fail("Canvas hover route repeats an identity")
  # Membership, not longest common suffix: an existing structural ancestor
  # can gain a listener without changing the identity/bounds of its children.
  for previous in machine.hovered:
    var retained = false
    for current in route:
      if previous.id == current.id:
        retained = true
        break
    if not retained: machine.emit(PointerEventKind.leave, previous, sample)
  for i in countdown(route.high, 0):
    var retained = false
    for previous in machine.hovered:
      if route[i].id == previous.id:
        retained = true
        break
    if not retained: machine.emit(PointerEventKind.enter, route[i], sample)
  machine.hovered = @route


proc pointerTargetInternal*(event: CanvasPointerEvent): PointerTarget = event.projection
proc target*(event: CanvasPointerEvent): CanvasBindingId = event.initialTarget
proc stopPropagation*(event: CanvasPointerEvent) =
  if event.propagation == nil: fail("stopPropagation needs an active Canvas delivery")
  event.propagation.stopped = true
proc propagationStoppedInternal*(event: CanvasPointerEvent): bool =
  event.propagation != nil and event.propagation.stopped
proc beginDeliveryInternal*(event: CanvasPointerEvent): CanvasPointerEvent =
  result = event
  result.propagation = CanvasPropagation()
proc atTargetInternal*(event: CanvasPointerEvent, target: PointerTarget): CanvasPointerEvent =
  result = event
  result.projection = target
proc isNil*(delivery: CanvasDelivery): bool = delivery.owned == nil
proc canvasDeliveryInternal*(source: CanvasPointerEvent, route: openArray[CanvasRouteTarget]): CanvasDelivery =
  if route.len == 0 or route.len > MaxCanvasDepth+2 or source.frameId == 0:
    fail("invalid Canvas event route")
  for i, entry in route:
    if not entry.target.valid or entry.key.len == 0 or
        entry.target.id.session != source.id.session or entry.target.id.mount != source.id.mount or
        entry.target.frameId < source.frameId or (i == 0 and entry.target.id != source.id):
      fail("invalid Canvas event route identity")
  CanvasDelivery(owned: CanvasDeliveryStorage(source: source, route: @route))
proc sourceInternal*(delivery: CanvasDelivery): CanvasPointerEvent = delivery.owned.source
iterator routeInternal*(delivery: CanvasDelivery): CanvasRouteTarget =
  for entry in delivery.owned.route: yield entry


proc withSourceRouteInternal*(target: PointerTarget, route: openArray[CanvasSourceRoute]): PointerTarget =
  if route.len == 0 or route.len > MaxCanvasDepth+2 or route[0].id != target.id or target.frameId == 0:
    fail("invalid Canvas source route")
  for i, entry in route:
    if entry.id.session != target.id.session or entry.id.mount != target.id.mount or
        entry.id.binding == 0 or entry.id.generation == 0 or entry.mask == 0 or (entry.mask and not CanvasEventMask) != 0:
      fail("invalid Canvas source route identity or mask")
    for j in 0..<i:
      if route[j].id == entry.id: fail("duplicate Canvas source route identity")
  result = target
  result.routeSnapshot = @route
iterator sourceRouteInternal*(event: CanvasPointerEvent): CanvasSourceRoute =
  for entry in event.sourceRoute: yield entry


proc rawCanvasEventInternal*(target: PointerTarget, kind: PointerEventKind, sample: PointerSample,
    wheelDelta = vec2(0, 0), keyCode = 0'u32, keyRepeat = false): CanvasPointerEvent =
  if kind notin {PointerEventKind.pointerDown, PointerEventKind.pointerMove, PointerEventKind.pointerUp,
      PointerEventKind.wheel, PointerEventKind.keyDown} or not target.valid or not sample.screenPosition.valid or
      not wheelDelta.valid:
    fail("invalid raw Canvas input")
  CanvasPointerEvent(kind: kind, sample: sample, projection: target, initialTarget: target.id,
    sourceFrameId: target.frameId, sourceRoute: target.routeSnapshot, wheelDelta: wheelDelta,
    keyCode: keyCode, keyRepeat: keyRepeat)

proc sourceAllowsInternal*(source: CanvasPointerEvent, id: CanvasBindingId): bool =
  if source.sourceRoute.len == 0: return true # Already-projected programmatic delivery.
  for entry in source.sourceRoute:
    if entry.id == id: return (entry.mask and (1'u32 shl ord(source.kind))) != 0

proc nativeCanvasDeliveryInternal*(source: CanvasPointerEvent): CanvasDelivery =
  if source.frameId == 0 or source.sourceRoute.len == 0:
    fail("native Canvas input needs an owned source route")
  CanvasDelivery(owned: CanvasDeliveryStorage(source: source))
proc needsProjectionInternal*(delivery: CanvasDelivery): bool =
  delivery.owned != nil and delivery.owned.route.len == 0
proc mergeCanvasMovesInternal*(previous, latest: CanvasDelivery): Option[CanvasDelivery] =
  if not previous.needsProjectionInternal or not latest.needsProjectionInternal: return none(CanvasDelivery)
  let a = previous.owned.source
  var b = latest.owned.source
  if a.kind notin {PointerEventKind.drag, PointerEventKind.pointerMove} or b.kind != a.kind or a.id != b.id or
      a.sample.pointerId != b.sample.pointerId or a.sample.buttons != b.sample.buttons or
      a.sample.modifiers != b.sample.modifiers: return none(CanvasDelivery)
  b.screenDelta = a.screenDelta + b.screenDelta
  if not b.screenDelta.valid: fail("Canvas queued pointer delta overflow")
  some(nativeCanvasDeliveryInternal(b))

iterator targetRouteInternal*(target: PointerTarget): CanvasSourceRoute =
  for entry in target.routeSnapshot: yield entry
