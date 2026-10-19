## r1: native accepted-metadata transaction. The consumer's accepted entity/id
## maps are prepared before apply; accept only moves prepared values. Backend
## session queries delegate to that accepted map instead of keeping a second
## MaxNodes-sized table pair.
import std/[unittest, tables, options]
import leaf/[core, widgets, components, backend, backend_session, host_protocol,
  host_reconcile, host_session, native_host_adapter, managed_runtime]
import leaf/backends/headless

proc allocCount(): int =
  when defined(nimAllocStats):
    let stats = getAllocStats()
    for name, value in fieldPairs(stats):
      when name == "allocCount": result = value
  else: 0

proc makeHost(sessionId = 17'u64, mountGeneration = 1'u64): HostContext =
  HostContext(sessionId: sessionId, mountGeneration: mountGeneration,
    contentWidth: 640, contentHeight: 480, scale: 1.0)

var counter: State[int]
var childCount: State[int]
let Counter = defineComponent[int, State[int]]("AcceptedCounter",
  proc(ctx: MountContext, p: int): State[int] =
    result = ctx.state(0); counter = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    let n = ctx.value(s)
    host(button($n, key = "counter", onClick = proc(e: Event) = discard s.update(proc(v: int): int = v + 1))))
let Rows = defineComponent[int, State[int]]("AcceptedRows",
  proc(ctx: MountContext, p: int): State[int] =
    result = ctx.state(2); childCount = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    let n = ctx.value(s)
    var children: seq[UiDescription]
    for i in 0 ..< n: children.add(host(text("r" & $i, key = "row-" & $i)))
    hostShell(column(@[]), children))

type AcceptRecorder = ref object
  calls: int
  upserts: int
  removals: int
  lastRevision: uint64
  fullCalls: int
  fullRows: int
  acceptAllocations: int
  wrapperCalls: int

proc recordingConsumer(backend: Backend, recorder: AcceptRecorder): HostConsumer =
  let base = nativeHostConsumer(backend, sessionId = 31'u64)
  result = HostConsumer(sessionId: base.sessionId, prepare: base.prepare,
    apply: base.apply, discardPrepared: base.discardPrepared,
    faultPrepared: base.faultPrepared, entityQuery: base.entityQuery,
    nodeIdQuery: base.nodeIdQuery, acceptedCount: base.acceptedCount,
    materializeAccepted: base.materializeAccepted)
  result.accept = proc(revision: uint64) {.raises: [].} =
    let before = allocCount()
    base.accept(revision)
    recorder.acceptAllocations = allocCount() - before
    inc recorder.wrapperCalls
    recorder.lastRevision = revision

proc deltaBackend(backend: var Backend, recorder: AcceptRecorder) =
  backend = Backend(capabilities: fullCapabilities(),
    prepare: proc(batch: UpdateBatch) = discard,
    apply: proc(batch: UpdateBatch) = discard,
    discardPrepared: proc() = discard,
    restore: proc(entities: Table[NodeHandle, MountedEntity]) = discard,
    dispose: proc() = discard)
  backend.acceptedDelta = proc(delta: HostAcceptedDelta) {.raises: [].} =
    inc recorder.calls
    recorder.upserts += delta.upserts.len
    recorder.removals += delta.removals.len

proc fullMetadataBackend(backend: var Backend, recorder: AcceptRecorder) =
  backend = Backend(capabilities: fullCapabilities(),
    prepare: proc(batch: UpdateBatch) = discard,
    apply: proc(batch: UpdateBatch) = discard,
    discardPrepared: proc() = discard,
    restore: proc(entities: Table[NodeHandle, MountedEntity]) = discard,
    dispose: proc() = discard)
  backend.accepted = proc(entities: Table[NodeHandle, MountedEntity],
      revision: uint64) {.raises: [].} =
    inc recorder.fullCalls
    recorder.fullRows = entities.len

suite "native accepted transaction":
  test "delta accept moves prepared values with zero allocation":
    var recorder = AcceptRecorder()
    var backend: Backend
    deltaBackend(backend, recorder)
    recorder.acceptAllocations = -1
    when defined(leafProtocolProbes): nativeAcceptAllocations = -1
    let rt = newRuntime(componentApplication(component(Counter, 0), "accept"))
    let session = attachHostSession(rt, recordingConsumer(backend, recorder))
    when defined(leafProtocolProbes) and defined(nimAllocStats):
      checkpoint("attach confirm accept allocations=" & $nativeAcceptAllocations)
      check nativeAcceptAllocations == 0
    # Attach confirms the initial full batch; measure only later commits.
    recorder.wrapperCalls = 0
    recorder.calls = 0
    recorder.upserts = 0
    # Growth across several commits exercises the per-commit prepared delta.
    for i in 1 .. 5:
      recorder.acceptAllocations = -1
      check rt.dispatch("counter", Event(kind: click))
      when defined(nimAllocStats): check recorder.acceptAllocations == 0
      check recorder.wrapperCalls == i
      check recorder.upserts >= i
    check rt.find("counter").node.text == "5"
    session.close()

  test "unmount and growth commits keep accept allocation-free":
    var recorder = AcceptRecorder()
    var backend: Backend
    deltaBackend(backend, recorder)
    recorder.acceptAllocations = -1
    let rt = newRuntime(componentApplication(component(Rows, 0), "rows-accept"))
    let session = attachHostSession(rt, recordingConsumer(backend, recorder))
    recorder.acceptAllocations = -1
    childCount.set(140)
    check rt.flush()
    when defined(nimAllocStats): check recorder.acceptAllocations == 0
    recorder.acceptAllocations = -1
    childCount.set(1)
    check rt.flush()
    when defined(nimAllocStats): check recorder.acceptAllocations == 0
    check recorder.removals > 0
    session.close()

  test "full metadata compatibility is prepared before accept":
    var recorder = AcceptRecorder()
    var backend: Backend
    fullMetadataBackend(backend, recorder)
    recorder.acceptAllocations = -1
    let rt = newRuntime(componentApplication(component(Counter, 0), "full-meta"))
    let session = attachHostSession(rt, recordingConsumer(backend, recorder))
    recorder.acceptAllocations = -1
    check rt.dispatch("counter", Event(kind: click))
    when defined(nimAllocStats): check recorder.acceptAllocations == 0
    check recorder.fullCalls >= 1
    check recorder.fullRows > 0
    session.close()

  test "managed backend session delegates accepted metadata without fixed tables":
    let rt = newRuntime(componentApplication(component(Counter, 0), "session-meta"))
    let recording = newRecordingBackend(fullCapabilities())
    GC_fullCollect()
    let before = getOccupiedMem()
    let session = attachBackend(rt, recording.backend, makeHost())
    GC_fullCollect()
    let after = getOccupiedMem()
    checkpoint("attach heap delta=" & $(after - before))
    # The previous implementation reserved two MaxNodes*4 tables here.
    check after - before < 1_000_000
    let handle = session.handleFor(rt.find("counter").id)
    check session.acceptedEntities.hasKey(handle)
    check session.acceptedEntities.len >= 1
    check rt.dispatch("counter", Event(kind: click))
    let newHandle = session.handleFor(rt.find("counter").id)
    check newHandle != NoHandle
    check session.acceptedEntities.hasKey(newHandle)
    check session.acceptedEntities.getOrDefault(newHandle).nodeId.len > 0
    session.dispose()

var decorate: State[int]
let Decorator = defineComponent[int, State[int]]("AcceptedDecorator",
  proc(ctx: MountContext, p: int): State[int] =
    result = ctx.state(0); decorate = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    let n = ctx.value(s)
    if n == 0:
      host(text("plain", key = "plain"))
    else:
      let key =
        if n == 3: "deco-alt"
        elif n == 5: "deco-two"
        elif n == 7: "deco-three"
        else: "deco"
      host(text("decorated", key = key, styles = {"color": "#204060"}.toTable)))

type DiagnosticRecorder = ref object
  deltaIssues: int
  prepareFails, applyFails: bool

proc diagnosticBackend(recorder: DiagnosticRecorder): Backend =
  var caps = fullCapabilities()
  caps.decorations.excl(dfColor)
  result = Backend(capabilities: caps,
    prepare: proc(batch: UpdateBatch) =
      if recorder.prepareFails: fail("diagnostic prepare failure"),
    apply: proc(batch: UpdateBatch) =
      if recorder.applyFails: fail("diagnostic apply failure"),
    discardPrepared: proc() = discard,
    restore: proc(entities: Table[NodeHandle, MountedEntity]) = discard,
    dispose: proc() = discard)
  result.acceptedDelta = proc(delta: HostAcceptedDelta) {.raises: [].} =
    recorder.deltaIssues = delta.issues.len

proc diagnosticHost(): HostContext =
  HostContext(sessionId: 91, mountGeneration: 1,
    contentWidth: 640, contentHeight: 480, scale: 1.0)

suite "accepted diagnostics transaction":
  test "new capability issues publish at accept with zero allocation":
    let recorder = DiagnosticRecorder()
    let rt = newRuntime(componentApplication(component(Decorator, 0), "diagnostics"))
    let session = attachBackend(rt, diagnosticBackend(recorder), diagnosticHost())
    check session.capabilityIssues().len == 0
    when defined(leafProtocolProbes):
      nativeAcceptAllocations = -1
    decorate.set(1)
    check rt.flush()
    check session.capabilityIssues().len == 1
    let firstIssues = session.capabilityIssues()
    check firstIssues[0].property == "color"
    check recorder.deltaIssues == 1
    when defined(leafProtocolProbes) and defined(nimAllocStats):
      checkpoint("new issue accept allocations=" & $nativeAcceptAllocations)
      check nativeAcceptAllocations == 0
    # Repeating the same logical issue at another commit must deduplicate and
    # still not allocate in accept.
    when defined(leafProtocolProbes):
      nativeAcceptAllocations = -1
    decorate.set(2)
    check rt.flush()
    check session.capabilityIssues().len == 1
    when defined(leafProtocolProbes) and defined(nimAllocStats):
      check nativeAcceptAllocations == 0
    session.dispose()

  test "rejected apply rolls prepared diagnostics back and retry publishes once":
    let recorder = DiagnosticRecorder()
    let rt = newRuntime(componentApplication(component(Decorator, 0), "diagnostics-rollback"))
    let session = attachBackend(rt, diagnosticBackend(recorder), diagnosticHost())
    decorate.set(1)
    # First successful commit publishes the color issue for key "deco1".
    check rt.flush()
    check session.capabilityIssues().len == 1
    # A new issue key with a failing apply must leave the visible list and the
    # dedup state untouched, then publish exactly once on retry.
    recorder.applyFails = true
    decorate.set(3)
    expect UiError: discard rt.flush()
    check session.capabilityIssues().len == 1
    recorder.applyFails = false
    decorate.set(3)
    check rt.flush()
    check session.capabilityIssues().len == 2
    let retriedIssues = session.capabilityIssues()
    check retriedIssues[1].property == "color"
    # Repeating the same failed/new key stays deduplicated.
    recorder.applyFails = true
    decorate.set(3)
    expect UiError: discard rt.flush()
    check session.capabilityIssues().len == 2
    session.dispose()

  test "rejected prepare publishes no diagnostic":
    let recorder = DiagnosticRecorder()
    let rt = newRuntime(componentApplication(component(Decorator, 0), "diagnostics-prepare"))
    let session = attachBackend(rt, diagnosticBackend(recorder), diagnosticHost())
    decorate.set(1)
    recorder.prepareFails = true
    expect UiError: discard rt.flush()
    check session.capabilityIssues().len == 0
    recorder.prepareFails = false
    decorate.set(1)
    check rt.flush()
    check session.capabilityIssues().len == 1
    session.dispose()

  test "strict mode rejects before publishing a diagnostic":
    let recorder = DiagnosticRecorder()
    let rt = newRuntime(componentApplication(component(Decorator, 0), "diagnostics-strict"))
    let session = attachBackend(rt, diagnosticBackend(recorder), diagnosticHost(), strict)
    decorate.set(1)
    expect UiError: discard rt.flush()
    check session.capabilityIssues().len == 0
    session.dispose()


type WindowRecorder = ref object
  observed: BackendSession
  active: bool
  prepareFail, applyFail: bool
  attachPrepareLen, attachApplyLen: int
  windowPrepareLen, windowApplyLen: int
  windowPrepareEmpty, windowApplyEmpty: bool
  windowPrepareFields, windowApplyFields: bool

proc fieldsComplete(issues: seq[CapabilityIssue]): bool =
  result = true
  for issue in issues:
    if issue.nodeId.len == 0 or issue.property.len == 0: return false

proc windowBackend(recorder: WindowRecorder): Backend =
  var caps = fullCapabilities()
  caps.decorations.excl(dfColor)
  result = Backend(capabilities: caps,
    prepare: proc(batch: UpdateBatch) =
      let issues = recorder.observed.capabilityIssues()
      if recorder.active: recorder.windowPrepareLen = issues.len
      else: recorder.attachPrepareLen = issues.len
      if recorder.active:
        recorder.windowPrepareEmpty = issues.len > 0 and issues[^1].nodeId.len == 0
        recorder.windowPrepareFields = fieldsComplete(issues)
      if recorder.prepareFail: fail("window prepare failure"),
    apply: proc(batch: UpdateBatch) =
      let issues = recorder.observed.capabilityIssues()
      if recorder.active: recorder.windowApplyLen = issues.len
      else: recorder.attachApplyLen = issues.len
      if recorder.active:
        recorder.windowApplyEmpty = issues.len > 0 and issues[^1].nodeId.len == 0
        recorder.windowApplyFields = fieldsComplete(issues)
      if recorder.applyFail: fail("window apply failure"),
    discardPrepared: proc() = discard,
    restore: proc(entities: Table[NodeHandle, MountedEntity]) = discard,
    dispose: proc() = discard)

proc attachRecorded(rt: Runtime, recorder: WindowRecorder): BackendSession =
  result = attachBackendObserved(rt, windowBackend(recorder), diagnosticHost(),
    compatible, proc(s: BackendSession) = recorder.observed = s)

suite "accepted diagnostics read view":
  test "accepted view is the previous list in prepare and apply windows":
    let recorder = WindowRecorder()
    let rt = newRuntime(componentApplication(component(Decorator, 0), "view-attach"))
    let session = attachRecorded(rt, recorder)
    # Initial accepted issue count is zero; both observation points see zero.
    check recorder.attachPrepareLen == 0
    check recorder.attachApplyLen == 0
    recorder.active = true
    decorate.set(1)
    check rt.flush()
    # The new issue is not visible during the commit that prepares it.
    check recorder.windowPrepareLen == 0
    check recorder.windowApplyLen == 0
    check recorder.windowPrepareFields
    check recorder.windowApplyFields
    check not recorder.windowPrepareEmpty
    check not recorder.windowApplyEmpty
    var accepted = session.capabilityIssues()
    check accepted.len == 1
    check accepted[0].nodeId.len > 0 and accepted[0].property == "color"
    # A second issue is visible only after its own accept.
    recorder.active = true
    decorate.set(3)
    check rt.flush()
    check recorder.windowPrepareLen == 1
    check recorder.windowApplyLen == 1
    check not recorder.windowPrepareEmpty
    check not recorder.windowApplyEmpty
    accepted = session.capabilityIssues()
    check accepted.len == 2
    check accepted[1].nodeId.len > 0 and accepted[1].property == "color"
    # Duplicate issue repeats neither the count nor a placeholder.
    decorate.set(3)
    check rt.flush()
    check session.capabilityIssues().len == 2
    session.dispose()

  test "non-zero initial accepted view and failure boundaries stay stable":
    let recorder = WindowRecorder()
    let rt = newRuntime(componentApplication(component(Decorator, 0), "view-nonzero"))
    # Accept one issue before the backend attaches.
    decorate.set(1)
    check rt.flush()
    let session = attachRecorded(rt, recorder)
    check recorder.attachPrepareLen == 1
    check recorder.attachApplyLen == 1
    check session.capabilityIssues().len == 1
    # Apply failure: windows see the previous accepted list; rollback returns to
    # the same list and the retry publishes exactly once.
    recorder.active = true
    recorder.applyFail = true
    decorate.set(5)
    expect UiError: discard rt.flush()
    check recorder.windowPrepareLen == 1
    check recorder.windowApplyLen == 1
    check not recorder.windowApplyEmpty
    check session.capabilityIssues().len == 1
    recorder.applyFail = false
    decorate.set(5)
    check rt.flush()
    check recorder.windowApplyLen == 1
    check session.capabilityIssues().len == 2
    # Prepare failure: no apply window, accepted list unchanged.
    recorder.prepareFail = true
    decorate.set(7)
    expect UiError: discard rt.flush()
    check recorder.windowPrepareLen == 2
    check session.capabilityIssues().len == 2
    recorder.prepareFail = false
    decorate.set(7)
    check rt.flush()
    check session.capabilityIssues().len == 3
    session.dispose()

  test "accept window remains allocation free with diagnostics queries elsewhere":
    let recorder = WindowRecorder()
    let rt = newRuntime(componentApplication(component(Decorator, 0), "view-alloc"))
    let session = attachRecorded(rt, recorder)
    recorder.active = true
    when defined(leafProtocolProbes):
      nativeAcceptAllocations = -1
    decorate.set(1)
    check rt.flush()
    check session.capabilityIssues().len == 1
    when defined(leafProtocolProbes) and defined(nimAllocStats):
      checkpoint("diagnostic accept allocations=" & $nativeAcceptAllocations)
      check nativeAcceptAllocations == 0
    session.dispose()

  test "strict rejection leaves the accepted view empty":
    let recorder = WindowRecorder()
    let rt = newRuntime(componentApplication(component(Decorator, 0), "view-strict"))
    let session = attachBackendObserved(rt, windowBackend(recorder), diagnosticHost(),
      strict, proc(s: BackendSession) = recorder.observed = s)
    recorder.active = true
    decorate.set(1)
    expect UiError: discard rt.flush()
    check session.capabilityIssues().len == 0
    session.dispose()
