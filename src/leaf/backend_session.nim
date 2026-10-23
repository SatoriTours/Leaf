## Backend session: binds a synchronous Backend to a Runtime, owns the native
## event queue, viewport tracking and failure recovery.
##
## The session is the only place that coordinates the Runtime commit gate with
## a backend. It never renders business state, never runs a business callback
## before the backend confirms a batch, and never executes platform lifecycle.
import std/[tables, sets, math, strutils, json, options]
import ./[core, styles, backend, reconcile,managed_runtime,host_session,native_host_adapter,
  native_navigation, navigation_protocol]

const
  MaxPendingRowRequests* = 256
    ## Bound on the total owned viewport facts per session: the next-turn queue
    ## plus the still-live in-flight facts of an active drain. Far above the
    ## number of lists a UI can show at once, while still bounding ownership.

type
  EventSource* = enum
    ## A genuine user input event, or a backend setter notification that must
    ## never be treated as user input.
    sourceUser, sourceSetter

  DeliveryGate* = proc(): bool {.closure, raises: [].}
    ## Optional host lifecycle guard, checked at each business delivery boundary.

  EventEnvelope* = object
    session*: uint64
    mountGeneration*: uint64
    handle*: NodeHandle
    sequence*: uint64
    observedRevision*: uint64
    source*: EventSource
    event*: Event
    bindingGeneration*: uint64

  RowViewportRequest* = object
    ## One owned viewport fact recorded on the UI thread. It carries identity,
    ## the list source token and the row ranges only: no Node, closure or
    ## platform pointer ever crosses this seam, so only the owning session on
    ## the current mount/source can execute it.
    sessionId*: uint64
    mountGeneration*: uint64
    listHandle*: NodeHandle
    sourceGeneration*: uint64
    first*, finish*: int
    protected*: seq[int]

  RowFact = object
    ## Internal recorded fact. `superseded` marks an in-flight fact that a newer
    ## fact for the same list replaced: it keeps its drain slot (so the active
    ## batch's indices stay valid) but is never executed.
    request: RowViewportRequest
    superseded: bool

  ViewportState = object
    keys: seq[string]

  BackendSession* = ref object
    runtime: Runtime
    backend: Backend
    host: HostContext
    mode: CapabilityMode
    reconciler: Reconciler
    committerToken: uint64
    preparerToken: uint64
    backendToken: uint64
    typedHost:HostSession
    pendingPlan: ReconcilePlan
    pendingInstall: bool
    pendingInitial: bool
    sessionId: uint64
    mountGeneration: uint64
    lastQueued: uint64
    lastProcessed: uint64
    queue: seq[EventEnvelope]
    navigation: NativeNavigation
    when compileOption("threads"): uiThreadId: int
    entities: Table[NodeHandle, MountedEntity]
    byNodeId: Table[string, NodeHandle]
    viewports: Table[NodeHandle, ViewportState]
    issues: seq[CapabilityIssue]
    seenIssues: HashSet[string]
    pendingIssueBase: int
    pendingIssueValues: seq[CapabilityIssue]
    pendingIssueKeys: seq[string]
    acceptedIssueCount: int
    metadataPrepared: bool
    disposed: bool
    faulted: bool
    frozen: bool
    closing: bool
    draining: bool
    pendingRows: seq[RowFact]
    claimedRows: seq[RowFact]
    drainingRows: bool

proc resetNavigation(session: BackendSession) =
  session.navigation.close()
  session.navigation = nil

proc runtime*(session: BackendSession): Runtime = session.runtime
proc sessionId*(session: BackendSession): uint64 = session.sessionId
proc mountGeneration*(session: BackendSession): uint64 = session.mountGeneration
proc queuedEvents*(session: BackendSession): int = session.queue.len
proc disposed*(session: BackendSession): bool = session.disposed
proc closing*(session: BackendSession): bool = session.closing
proc faulted*(session: BackendSession): bool = session.faulted
proc frozen*(session: BackendSession): bool = session.frozen
proc capabilityIssues*(session: BackendSession): seq[CapabilityIssue] =
  ## Public read view: only accepted diagnostics. Physical slots reserved by a
  ## pending prepare are hidden until accept advances acceptedIssueCount; a
  ## materialized prefix copy is an explicit read-only query cost.
  if session == nil: return @[]
  if session.acceptedIssueCount == session.issues.len: return session.issues
  result = newSeq[CapabilityIssue](session.acceptedIssueCount)
  for index in 0..<session.acceptedIssueCount:
    result[index] = session.issues[index]

proc prepareAcceptedIssues(session: BackendSession, issues: seq[CapabilityIssue]) =
  ## Prepare-time diagnostic publication. New dedup keys and the reserved
  ## issue slots are owned here; accept only copies the prepared values into
  ## already-sized storage. A rejected prepare/apply rolls both back.
  if session.metadataPrepared or issues.len == 0: return
  var values: seq[CapabilityIssue]
  var keys: seq[string]
  for issue in issues:
    let key = issue.nodeId & "\x1f" & issue.property
    if key in session.seenIssues: continue
    var duplicate = false
    for existing in keys:
      if existing == key: duplicate = true; break
    if duplicate: continue
    keys.add(key)
    values.add(issue)
  if keys.len == 0: return
  let base = session.acceptedIssueCount
  doAssert base == session.issues.len
  session.issues.setLen(base + values.len)
  for key in keys: session.seenIssues.incl(key)
  session.pendingIssueBase = base
  session.pendingIssueValues = move(values)
  session.pendingIssueKeys = move(keys)
  session.metadataPrepared = true

proc publishAcceptedIssues(session: BackendSession) {.raises:[].} =
  if not session.metadataPrepared: return
  let count = session.pendingIssueValues.len
  for index in 0..<count:
    session.issues[session.pendingIssueBase + index] = move(session.pendingIssueValues[index])
  inc session.acceptedIssueCount, count
  session.pendingIssueValues.setLen(0)
  session.pendingIssueKeys.setLen(0)
  session.metadataPrepared = false

proc discardAcceptedIssues(session: BackendSession) {.raises:[].} =
  if not session.metadataPrepared: return
  session.issues.setLen(session.acceptedIssueCount)
  for key in session.pendingIssueKeys: session.seenIssues.excl(key)
  session.pendingIssueValues.setLen(0)
  session.pendingIssueKeys.setLen(0)
  session.metadataPrepared = false

proc acceptedEntities*(session: BackendSession): Table[NodeHandle, MountedEntity] =
  ## Explicit metadata snapshot. Managed sessions query the consumer's accepted
  ## map; the returned Table is materialized on demand, never per commit.
  if session.typedHost != nil: return session.typedHost.materializeAccepted()
  session.entities

proc hasAcceptedEntity(session: BackendSession, handle: NodeHandle): bool =
  if session.typedHost != nil: session.typedHost.hasAcceptedEntity(handle)
  else: session.entities.hasKey(handle)

proc acceptedEntity(session: BackendSession, handle: NodeHandle): MountedEntity =
  if session.typedHost != nil: session.typedHost.acceptedEntity(handle)
  else: session.entities.getOrDefault(handle)

proc handleFor*(session: BackendSession, nodeId: string): NodeHandle =
  if session.typedHost != nil:
    result = session.typedHost.acceptedHandle(nodeId)
    if result != NoHandle: return
  elif nodeId in session.byNodeId:
    return session.byNodeId[nodeId]
  fail("session has no entity for node: " & nodeId)

proc collectIssues(session: BackendSession, root: MountedNode) =
  ## Structured decoration diagnostics are reported once per node/property for
  ## the lifetime of a session; a new session can report them again.
  for issue in checkCapabilities(root, session.backend.capabilities, session.mode):
    let key = issue.nodeId & "\x1f" & issue.property
    if key notin session.seenIssues:
      session.seenIssues.incl(key)
      session.issues.add(issue)
      inc session.acceptedIssueCount

proc adapterFor(session: BackendSession): PropsAdapter =
  ## Diff capability-filtered effective properties so the accepted entity props
  ## match what the backend actually applied. The raw three-argument
  ## `reconcile.plan` API is unchanged.
  let capabilities = session.backend.capabilities
  result = proc(node: Node): NormalizedProps =
    effectiveProps(capabilities, normalizeProps(node))

proc recover(session: BackendSession,
             previous: Table[NodeHandle, MountedEntity]): string =
  ## Apply failed after touching native state. Restore the old accepted
  ## entities; a successful restore advances the mount generation so old
  ## native notifications are invalidated, then re-arms the backend through
  ## `rebind`. A failed restore or rebind faults the session and permanently
  ## freezes business dispatch on the runtime. Returns "" on success,
  ## otherwise the failure detail.
  session.frozen = true
  # Viewport facts captured against the failed/restored tree are obsolete;
  # never let them reach the replacement mount.
  session.pendingRows.setLen(0)
  session.claimedRows.setLen(0)
  try:
    session.backend.restore(previous)
  except CatchableError as error:
    session.faulted = true
    session.runtime.freezeEvents("backend restore failed: " & error.msg)
    return error.msg
  inc session.mountGeneration
  session.resetNavigation()
  session.queue.setLen(0)
  session.lastQueued = 0
  session.lastProcessed = 0
  if session.backend.rebind != nil:
    try:
      session.backend.rebind(session.sessionId, session.mountGeneration)
    except CatchableError as error:
      session.faulted = true
      session.runtime.freezeEvents("backend rebind failed: " & error.msg)
      return error.msg
  session.frozen = false
  ""

proc safeDiscard(session: BackendSession, cleanup: var seq[string]) =
  ## Cleanup must never mask the primary failure. A missing or throwing
  ## discard hook is recorded, not propagated, so apply-failure recovery still
  ## runs.
  if session.backend.discardPrepared == nil:
    cleanup.add("discardPrepared missing")
    return
  try:
    session.backend.discardPrepared()
  except CatchableError as error:
    cleanup.add("discardPrepared failed: " & error.msg)

proc cleanupSuffix(cleanup: seq[string]): string =
  if cleanup.len == 0: "" else: "; cleanup: " & cleanup.join(", ")

proc migrateViewports(session: BackendSession,
                      previous: Table[NodeHandle, MountedEntity],
                      plan: ReconcilePlan) =
  ## Move accepted viewport tracking to the current handle of the same list
  ## node after an ancestor replacement, and drop tracking for lists that are
  ## gone. Called only after a successful accept.
  var migrated: Table[NodeHandle, ViewportState]
  for handle, viewport in session.viewports:
    if not previous.hasKey(handle): continue
    let nodeId = previous[handle].nodeId
    if nodeId notin plan.byNodeId: continue
    let nextHandle = plan.byNodeId[nodeId]
    if not plan.entities.hasKey(nextHandle): continue
    if plan.entities[nextHandle].kind != virtualList: continue
    migrated[nextHandle] = viewport
  session.viewports = migrated

proc acceptPlan(session: BackendSession, plan: ReconcilePlan) =
  let previous = session.entities
  session.reconciler.accept(plan)
  session.migrateViewports(previous, plan)
  session.entities = plan.entities
  session.byNodeId = plan.byNodeId
  # Pure framework metadata notification: copy the accepted map and revision.
  # Never renders, applies native changes or runs business callbacks.
  if session.backend.accepted != nil:
    session.backend.accepted(session.entities, plan.revision)

proc confirmInstall(session: BackendSession) =
  ## Pure framework publication, after the installation scope has exited.
  if not session.pendingInstall: return
  session.acceptPlan(session.pendingPlan)
  session.pendingInstall = false
  session.pendingPlan = default(ReconcilePlan)

proc abortInstall(session: BackendSession, scoped: bool) =
  if not session.pendingInstall: return
  let initial = session.pendingInitial
  session.pendingInstall = false
  session.pendingPlan = default(ReconcilePlan)
  if not scoped:
    if not initial:
      session.frozen = true
      session.faulted = true
      session.runtime.freezeEvents("backend installation rollback scope refused entry")
    return
  var cleanup: seq[string]
  session.safeDiscard(cleanup)
  if not initial:
    let restoreError = session.recover(session.entities)
    if restoreError.len != 0: cleanup.add("restore failed: " & restoreError)
  # Discard failures must not skip restore or mask the original scope failure.
  if cleanup.len != 0: fail("backend installation abort" & cleanupSuffix(cleanup))

proc commit(session: BackendSession, accepted: Runtime, candidate: Runtime) =
  ## The Runtime committer. Runs after build/validate/prepare and before
  ## publication: prepare and apply the batch. Ordinary commits accept here;
  ## hook installations defer acceptance until the scope's lifecycle confirms.
  ## No event is drained here and no business callback runs.
  session.collectIssues(candidate.snapshot.root)
  let revision = if candidate.proposedRevision != 0: candidate.proposedRevision
                 else: candidate.acceptedRevision
  let plan = session.reconciler.plan(candidate.snapshot, revision,
    session.adapterFor())
  let previous = session.entities

  try:
    session.backend.prepare(plan.batch)
  except CatchableError as error:
    var cleanup: seq[string]
    session.safeDiscard(cleanup)
    raise newException(UiError, "backend prepare failed: " & error.msg &
      cleanupSuffix(cleanup))

  try:
    session.backend.apply(plan.batch)
  except CatchableError as error:
    var cleanup: seq[string]
    session.safeDiscard(cleanup)
    let suffix = cleanupSuffix(cleanup)
    if accepted == nil:
      # Initial mount has no accepted native state to restore. The caller
      # disposes the backend and installs nothing.
      raise newException(UiError, "initial backend apply failed: " &
        error.msg & suffix)
    let restoreError = session.recover(previous)
    if restoreError.len == 0:
      raise newException(UiError, "backend apply failed; restored accepted state: " &
        error.msg & suffix)
    raise newException(UiError, "backend apply failed and restore failed: " &
      error.msg & suffix & "; restore: " & restoreError)

  if candidate.installingHook:
    # Native apply has completed, but scope exit may still fail. Keep accepted
    # identities/viewports unchanged until the owner-bound lifecycle confirms.
    session.pendingPlan = plan
    session.pendingInitial = accepted == nil
    session.pendingInstall = true
  else:
    session.acceptPlan(plan)

proc restoreViewports(session: BackendSession, candidate: Runtime) =
  ## Preparer: after a list source changes, remount the tracked viewport by
  ## stable item key. Old row numbers are never rebound to new items. Only a
  ## list that is no longer mounted in this candidate is skipped; row-build,
  ## validation and materialize errors propagate so the candidate is rejected.
  for handle, viewport in session.viewports:
    if not session.hasAcceptedEntity(handle): continue
    let nodeId = session.acceptedEntity(handle).nodeId
    var target: MountedNode
    try:
      target = candidate.find(nodeId)
    except UiError:
      continue
    let source = target.node.listSource
    if source == nil or source.len == 0: continue
    var indexByKey: Table[string, int]
    for index in 0..<source.len: indexByKey[source.itemKey(index)] = index
    var active: seq[int]
    for key in viewport.keys:
      if key in indexByKey: active.add(indexByKey[key])
    if active.len > 0:
      discard candidate.materialize(nodeId, 0, 0, active)

proc attachBackendImpl(runtime: Runtime, backend: Backend, host: HostContext,
                       mode: CapabilityMode,
                       onReserved: proc(s: BackendSession) {.closure, raises: [].}): BackendSession =
  ## Validate hooks, host and capabilities before any visible backend apply,
  ## then claim resources and install the committer and viewport preparer.
  ## Cleanup only removes this call's hooks and disposes its own Backend;
  ## occupied instances are rejected without touching their resources. If a
  ## scope refuses hook cleanup, retain the Backend referenced by that hook
  ## and report the cleanup failure together with the primary install error.
  if runtime == nil: fail("attachBackend requires a runtime")
  if runtime.committerOwner != 0:
    fail("committer already installed; unload the existing session first")
  if runtime.installingUpdate: fail("cannot attach backend during update")
  if backend == nil or backend.prepare == nil or backend.apply == nil or
      backend.discardPrepared == nil or backend.restore == nil or
      backend.dispose == nil:
    fail("backend contract is incomplete")
  if host.sessionId == 0: fail("host session id must be non-zero")
  if classify(host.scale) in {fcNan, fcInf, fcNegInf} or host.scale <= 0:
    fail("host scale must be finite and positive")
  if classify(host.contentWidth) in {fcNan, fcInf, fcNegInf} or host.contentWidth <= 0 or
      classify(host.contentHeight) in {fcNan, fcInf, fcNegInf} or host.contentHeight <= 0:
    fail("host content size must be finite and positive")
  # Required capabilities are rejected here, before the backend sees a batch.
  if not runtime.managed:discard checkCapabilities(runtime.snapshot.root, backend.capabilities, mode)

  var session = BackendSession(runtime: runtime, backend: backend, host: host,
    mode: mode, reconciler: newReconciler(), sessionId: host.sessionId,
    mountGeneration: host.mountGeneration)
  when compileOption("threads"): session.uiThreadId = getThreadId()
  if runtime.managed:
    session.issues=runtime.useNativePolicy(backend.capabilities,mode)
    for issue in session.issues:session.seenIssues.incl(issue.nodeId & "\x1f" & issue.property)
    session.acceptedIssueCount=session.issues.len
  else:session.collectIssues(runtime.snapshot.root)
  session.backendToken = backend.reserveSession()

  try:
    # Metadata observer only: exact reservation is established and protected by
    # this same installation/cleanup path before any native rebind or prepare.
    if onReserved != nil: onReserved(session)
    # Tell the host its identity before the first prepare, inside this lease.
    if backend.rebind != nil:
      backend.rebind(session.sessionId, session.mountGeneration)
    if runtime.managed:
      let consumer=nativeHostConsumer(backend,session.sessionId,mode=mode,
        onRecover=proc()=
          inc session.mountGeneration
          session.resetNavigation()
          session.queue.setLen(0);session.lastQueued=0;session.lastProcessed=0
          session.pendingRows.setLen(0)
          session.claimedRows.setLen(0)
          if backend.rebind!=nil:backend.rebind(session.sessionId,session.mountGeneration),
        onFault=proc(reason:string) {.raises:[].}=
          session.faulted=true
          session.pendingRows.setLen(0)
          session.claimedRows.setLen(0)
          runtime.freezeEvents("native restore failed: " & reason))
      consumer.prepareAcceptedMetadata=proc(issues:seq[CapabilityIssue])=
        session.prepareAcceptedIssues(issues)
      consumer.acceptAcceptedMetadata=proc() {.raises:[].}=
        session.publishAcceptedIssues()
      consumer.discardAcceptedMetadata=proc() {.raises:[].}=
        session.discardAcceptedIssues()
      session.typedHost=attachHostSession(runtime,consumer)
      session.committerToken=runtime.committerOwner
      return session
    session.committerToken = runtime.installCommitter(
      proc(accepted: Runtime, candidate: Runtime) =
        session.commit(accepted, candidate),
      RuntimeInstallLifecycle(
        confirm: proc() = session.confirmInstall(),
        abort: proc(scoped: bool) = session.abortInstall(scoped)))
    session.preparerToken = runtime.installPreparer(
      proc(candidate: Runtime) = session.restoreViewports(candidate))
  except CatchableError as error:
    var cleanup: seq[string]
    if session.committerToken != 0:
      try:
        runtime.clearCommitter(session.committerToken)
      except CatchableError as secondary:
        cleanup.add("clearCommitter failed: " & secondary.msg)
    if session.preparerToken != 0:
      try:
        runtime.clearPreparer(session.preparerToken)
      except CatchableError as secondary:
        cleanup.add("clearPreparer failed: " & secondary.msg)
    # A clear may throw after its body has removed the hook, or before its
    # body has run at all. Inspect exact ownership rather than the return path.
    let liveCommitter = session.committerToken != 0 and
      runtime.committerOwner == session.committerToken
    let livePreparer = session.preparerToken != 0 and
      runtime.preparerOwner == session.preparerToken
    if liveCommitter or livePreparer:
      cleanup.add("backend retained: session hook is still installed")
    elif backend.ownsSession(session.backendToken):
      try:
        backend.dispose()
        backend.releaseSession(session.backendToken)
      except CatchableError as secondary:
        cleanup.add("backend dispose failed: " & secondary.msg)
    # Preserve the primary exception (including its type/chain) while making
    # every secondary failure visible to the caller.
    error.msg.add(cleanupSuffix(cleanup))
    raise error
  session

proc ownsBackend*(session: BackendSession, backend: Backend): bool {.raises: [].} =
  session != nil and backend != nil and not session.disposed and
    session.backend == backend and backend.ownsSession(session.backendToken)

proc attachBackend*(runtime: Runtime, backend: Backend, host: HostContext,
                    mode = compatible): BackendSession =
  attachBackendImpl(runtime, backend, host, mode, nil)

proc attachBackendObserved*(runtime: Runtime, backend: Backend, host: HostContext,
                            mode: CapabilityMode,
                            onReserved: proc(s: BackendSession) {.closure, raises: [].}): BackendSession =
  attachBackendImpl(runtime, backend, host, mode, onReserved)

proc requestClose*(session: BackendSession) =
  ## Intent only: invalidate queued/captured event eligibility immediately.
  ## In-flight candidate acceptance/abort and actual lease disposal remain
  ## with their existing coordinators; no business or native callback runs.
  if session == nil or session.disposed: return
  session.closing = true
  session.resetNavigation()
  session.queue.setLen(0)
  session.lastQueued = 0
  session.lastProcessed = 0
  session.pendingRows.setLen(0)
  session.claimedRows.setLen(0)

proc dispose*(session: BackendSession) =
  ## Teardown. A request made while a Runtime update/commit is in progress is
  ## rejected with a catchable `UiError`, so the host can retry on a safe tick
  ## instead of losing the close request silently. Once teardown starts the
  ## session is event-ineligible: the queue is invalidated and
  ## enqueue/drain/requestRows stop touching business state. Only hooks this
  ## session installed are removed, and a throwing backend dispose leaves the
  ## session retryable (it is not marked disposed).
  if session == nil or session.disposed: return
  if session.runtime != nil and session.runtime.installingUpdate:
    fail("cannot dispose backend session during a runtime update; retry on a safe tick")
  session.requestClose()
  if session.typedHost!=nil:session.typedHost.close()
  if session.runtime != nil:
    if session.committerToken != 0:
      session.runtime.clearCommitter(session.committerToken)
      session.committerToken = 0
    if session.preparerToken != 0:
      session.runtime.clearPreparer(session.preparerToken)
      session.preparerToken = 0
  if session.backend != nil and session.backend.dispose != nil and
      session.backend.ownsSession(session.backendToken):
    session.backend.dispose()
    session.backend.releaseSession(session.backendToken)
  session.viewports.clear()
  session.disposed = true

proc enqueue*(session: BackendSession, envelope: EventEnvelope): bool =
  ## Queue a genuine user event. Backend setter notifications are suppressed at
  ## the source. Wrong session/generation, dead handles, future revisions and
  ## non-monotonic or already processed sequences are rejected; an old observed
  ## revision alone is not a reason to reject.
  if session == nil or session.disposed or session.faulted or session.closing:
    return false
  if envelope.source == sourceSetter or envelope.event.kind == EventKind.back: return false
  if envelope.session != session.sessionId: return false
  if envelope.mountGeneration != session.mountGeneration: return false
  if envelope.observedRevision > session.runtime.acceptedRevision: return false
  if envelope.sequence <= session.lastQueued: return false
  if not session.hasAcceptedEntity(envelope.handle): return false
  if session.backend.bindingValid != nil and
      not session.backend.bindingValid(envelope.handle, envelope.bindingGeneration):
    return false
  session.lastQueued = envelope.sequence
  session.queue.add(envelope)
  true

proc faultBackendEffects*(session: BackendSession, backend: Backend, reason: string) =
  ## Ordinary Nim boundary for an owned backend's asynchronous native failure.
  if session == nil or not session.ownsBackend(backend): fail("foreign backend effect failure")
  session.faulted = true
  session.pendingRows.setLen(0)
  session.claimedRows.setLen(0)
  session.runtime.freezeEvents(reason)

proc eventEligible(session: BackendSession): bool =
  ## Single eligibility predicate, re-checked before every queued event. A
  ## teardown that starts mid-drain (even at a safe post-scope boundary) makes
  ## the remaining captured batch ineligible instead of leaking it to business.
  not session.disposed and not session.faulted and not session.frozen and
    not session.closing

proc navigationContext(session: BackendSession, handle: NodeHandle,
    binding: uint64): Option[NavigationContext] =
  if not session.hasAcceptedEntity(handle): return
  let entity = session.acceptedEntity(handle)
  if entity.kind != NodeKind.navigation or entity.navigation.isNone: return
  # Navigation has no unbound legacy delivery mode. A backend that implements
  # it must attest the current native binding, including before each callback.
  if session.backend.bindingValid == nil or
      not session.backend.bindingValid(handle, binding): return
  result = some(NavigationContext(sessionId: session.sessionId,
    mountGeneration: session.mountGeneration, handle: uint64(handle),
    bindingGeneration: binding, acceptedRevision: session.runtime.acceptedRevision,
    navigation: entity.navigation.get))

proc dropNavigationEvents(session: BackendSession, handle: uint64,
    requestId = 0'u64) =
  var index = session.queue.len
  while index > 0:
    dec index
    let envelope = session.queue[index]
    if envelope.event.kind == EventKind.back and uint64(envelope.handle) == handle and
        (requestId == 0 or envelope.event.navigationRequestId == requestId):
      session.queue.delete(index)

proc pruneNavigation(session: BackendSession) =
  # Ordinary boundary only: no callbacks or allocations during publication.
  for fact in session.navigation.facts():
    let context = session.navigationContext(NodeHandle(fact.handle), fact.bindingGeneration)
    if context.isNone or fact.backFactReason(context.get, MaxNodes).len != 0:
      session.navigation.retire(fact.handle)
      session.dropNavigationEvents(fact.handle)

proc pendingNavigation*(session: BackendSession): int =
  if session == nil: 0 else: session.navigation.pending

proc queueNavigation*(session: BackendSession, fact: NavigationBackFact): bool =
  ## Capture only; confirm is appended to the same ordered event stream as
  ## clicks/input. A successful capture is not accepted navigation or a pop.
  if session == nil or not session.eventEligible: return false
  when compileOption("threads"):
    if session.uiThreadId != getThreadId(): return false
  if executionRuntimeIdentity() != 0 and
      executionRuntimeIdentity() != session.runtime.runtimeIdentity: return false
  if session.runtime.eventsFrozen: return false
  if fact.sequence <= session.lastQueued: return false
  let context = session.navigationContext(NodeHandle(fact.handle), fact.bindingGeneration)
  if context.isNone or fact.backFactReason(context.get, MaxNodes).len != 0: return false
  session.pruneNavigation()
  if session.navigation == nil:
    session.navigation = newNativeNavigation(session.sessionId, session.mountGeneration)
  if not session.navigation.record(context.get, fact): return false
  session.lastQueued = fact.sequence
  if fact.phase == NavigationBackPhase.cancel:
    # Cancelled ready requests must release their queued envelopes too. Without
    # this, repeated confirm/cancel bypasses the bounded pending-fact ledger.
    session.dropNavigationEvents(fact.handle, fact.requestId)
  if fact.phase == NavigationBackPhase.confirm:
    session.queue.add(EventEnvelope(session: fact.sessionId,
      mountGeneration: fact.mountGeneration, handle: NodeHandle(fact.handle),
      sequence: fact.sequence, observedRevision: fact.observedRevision,
      bindingGeneration: fact.bindingGeneration, source: sourceUser,
      event: Event(kind: EventKind.back, navigationRequestId: fact.requestId)))
  true

proc settleEvent(session: BackendSession, envelope: EventEnvelope) =
  ## UI metadata effect: settle the latest accepted props for a live entity
  ## after the Runtime scope has fully returned. Never reads business/DB,
  ## renders or installs hooks. A settlement failure faults and freezes.
  if session.backend.settle == nil: return
  if not session.eventEligible: return
  if envelope.mountGeneration != session.mountGeneration: return
  if not session.hasAcceptedEntity(envelope.handle): return
  if session.backend.bindingValid != nil and
      not session.backend.bindingValid(envelope.handle, envelope.bindingGeneration):
    return
  let settlement = EventSettlement(
    sessionId: session.sessionId,
    mountGeneration: session.mountGeneration,
    bindingGeneration: envelope.bindingGeneration,
    sequence: envelope.sequence,
    revision: session.runtime.acceptedRevision,
    handle: envelope.handle,
    props: session.acceptedEntity(envelope.handle).props)
  try:
    session.backend.settle(settlement)
  except CatchableError as error:
    session.faulted = true
    session.runtime.freezeEvents("backend settle failed: " & error.msg)
    session.runtime.diagnostic("settle", "error",
      %*{"handle": $envelope.handle, "message": error.msg})

proc process(session: BackendSession, envelope: EventEnvelope) =
  ## Revalidate against the live accepted state immediately before running the
  ## callback. A failed dispatch leaves the old accepted tree and never
  ## re-executes the business closure. The eligibility guard runs before any
  ## sequence or Runtime access. Every handled event on a live entity settles
  ## the latest accepted props, including disabled/no-handler/no-op cases.
  if not session.eventEligible: return
  if envelope.session != session.sessionId: return
  if envelope.mountGeneration != session.mountGeneration: return
  if envelope.sequence <= session.lastProcessed: return
  session.lastProcessed = envelope.sequence
  if not session.hasAcceptedEntity(envelope.handle): return
  let entity = session.acceptedEntity(envelope.handle)
  if session.backend.bindingValid != nil and
      not session.backend.bindingValid(envelope.handle, envelope.bindingGeneration):
    return
  if envelope.event.kind == EventKind.back:
    # Claim by exact request id preserves ordering with ordinary events. A
    # cancelled, stale or consumed fact cannot dispatch the business callback.
    let fact = session.navigation.claim(envelope.event.navigationRequestId)
    if fact.isNone: return
    let context = session.navigationContext(envelope.handle, envelope.bindingGeneration)
    if context.isNone or fact.get.backFactReason(context.get, MaxNodes).len != 0: return
  var mounted: MountedNode
  try:
    mounted = session.runtime.find(entity.nodeId)
  except UiError:
    return
  let node = mounted.node
  if not node.disabled and node.handler(envelope.event.kind) != nil:
    try:
      discard session.runtime.dispatch(entity.nodeId, envelope.event)
    except CatchableError:
      discard
  session.settleEvent(envelope)

proc drainEvents*(session: BackendSession, canDeliver: DeliveryGate = nil) =
  ## Explicit host drain. A commit in progress (or a reentrant drain) returns
  ## without touching the queue or its sequence bookkeeping, so genuine user
  ## events queued during apply survive for a drain after publication. The
  ## committer never dispatches queued events before publication.
  if session == nil or not session.eventEligible: return
  if session.draining: return
  if session.runtime != nil and session.runtime.installingUpdate: return
  session.pruneNavigation()
  session.draining = true
  try:
    let pending = session.queue
    session.queue = @[]
    for index, envelope in pending:
      if not session.eventEligible: return
      if canDeliver != nil and not canDeliver():
        # Preserve order ahead of events captured during this drain. Closing
        # still invalidates the batch through eventEligible above.
        session.queue = pending[index .. ^1] & session.queue
        return
      session.process(envelope)
      session.pruneNavigation()
  finally:
    session.draining = false

proc applyRowViewport(session: BackendSession, entity: MountedEntity,
                      source: ListSource, first, finish: int,
                      protected: seq[int]): seq[MountedNode] =
  ## Single materialization seam: stage the viewport through the Runtime commit
  ## gate, then replace the tracked viewport only after the candidate published.
  result = session.runtime.materialize(entity.nodeId, first, finish, protected)
  var keys: seq[string]
  for index in first..<finish: keys.add(source.itemKey(index))
  for index in protected:
    if index >= 0 and index < source.len: keys.add(source.itemKey(index))
  session.viewports[entity.handle] = ViewportState(keys: keys)

proc liveRowSource(session: BackendSession, listHandle: NodeHandle,
                   entity: var MountedEntity): ListSource =
  ## Accepted-only list lookup. Returns nil when the handle is gone, is no
  ## longer a virtual list, or its node has disappeared from the accepted tree.
  ## Never materializes rows and never consults a candidate.
  if not session.hasAcceptedEntity(listHandle): return nil
  entity = session.acceptedEntity(listHandle)
  if entity.kind != virtualList: return nil
  try:
    result = session.runtime.find(entity.nodeId).node.listSource
  except CatchableError:
    return nil

proc rangeValid(source: ListSource, first, finish: int,
                protected: seq[int]): bool =
  if source == nil: return false
  if first < 0 or finish < first or finish > source.len: return false
  for index in protected:
    if index < 0 or index >= source.len: return false
  true

proc liveRowFacts(session: BackendSession): int =
  ## Total owned facts: the next-turn queue plus the still-live in-flight facts
  ## of an active drain. This is the quantity `MaxPendingRowRequests` bounds.
  result = session.pendingRows.len
  for fact in session.claimedRows:
    if not fact.superseded: inc result

proc offerRowRequest(session: BackendSession, request: RowViewportRequest): bool =
  ## Bounded insertion with in-flight reservations. A newer fact for a list
  ## replaces its queued fact, or retires its in-flight fact: either way the
  ## total live fact count does not grow, so newest-wins never costs capacity.
  ## A new list is refused with `false` once the total would pass
  ## `MaxPendingRowRequests`; an already accepted fact is never evicted later
  ## for capacity reasons.
  let owned = RowViewportRequest(sessionId: request.sessionId,
    mountGeneration: request.mountGeneration, listHandle: request.listHandle,
    sourceGeneration: request.sourceGeneration, first: request.first,
    finish: request.finish, protected: @(request.protected))
  for index in 0 ..< session.pendingRows.len:
    if session.pendingRows[index].request.listHandle == request.listHandle:
      session.pendingRows[index] = RowFact(request: owned)
      return true
  for index in 0 ..< session.claimedRows.len:
    if not session.claimedRows[index].superseded and
        session.claimedRows[index].request.listHandle == request.listHandle:
      session.claimedRows[index].superseded = true
      session.pendingRows.add(RowFact(request: owned))
      return true
  if session.liveRowFacts() >= MaxPendingRowRequests: return false
  session.pendingRows.add(RowFact(request: owned))
  true

proc requestRows*(session: BackendSession, listHandle: NodeHandle,
                  sourceGeneration: uint64, first, finish: int,
                  protected: seq[int] = @[]): seq[MountedNode] =
  ## Explicit synchronous viewport request. Unchanged contract: it materializes
  ## immediately and the tracked viewport is replaced only after a successful
  ## commit, so a rejected request cannot corrupt visible tracking. New platform
  ## factories use `queueRows`/`drainRowRequests` instead.
  if session == nil or session.disposed: fail("session is disposed")
  if session.closing: fail("session is closing")
  if session.faulted: fail("session is faulted")
  var entity: MountedEntity
  let source = session.liveRowSource(listHandle, entity)
  if entity.handle == NoHandle:
    fail("unknown list handle: " & $listHandle)
  if entity.kind != virtualList:
    fail("handle is not a virtual list: " & entity.nodeId)
  if source == nil: fail("list has no source")
  if source.generation != sourceGeneration:
    fail("obsolete list source generation")
  result = session.applyRowViewport(entity, source, first, finish, protected)

proc queueRows*(session: BackendSession, request: RowViewportRequest): bool =
  ## UI-thread fact recording for the next safe turn. Never renders, materializes
  ## or commits. Wrong session/mount, dead or non-list handles, obsolete sources
  ## and out-of-range viewports are refused synchronously so nothing invalid is
  ## ever retained. The newest request per list replaces the older viewport.
  ## A `false` result is observable backpressure: the caller may re-queue the
  ## same fact on a later turn. A `true` result is never revoked while the
  ## session is usable: the fact is executed, replaced by a newer fact for that
  ## same list, or dropped together with the whole queue when an unrecoverable
  ## `Defect` escapes a row build and faults the session (see
  ## `drainRowRequests`).
  if session == nil or not session.eventEligible: return false
  if request.sessionId != session.sessionId: return false
  if request.mountGeneration != session.mountGeneration: return false
  var entity: MountedEntity
  let source = session.liveRowSource(request.listHandle, entity)
  if source == nil: return false
  if source.generation != request.sourceGeneration: return false
  if not rangeValid(source, request.first, request.finish, request.protected):
    return false
  session.offerRowRequest(request)

proc pendingRowRequests*(session: BackendSession): int =
  ## Recorded but not yet executed facts, including the in-flight facts of an
  ## active drain (so a reentrant read during a drain sees the reservations).
  if session == nil: 0 else: session.liveRowFacts()

proc rowRequestLive(session: BackendSession, request: RowViewportRequest,
                    entity: var MountedEntity, source: var ListSource): bool =
  ## Re-validate every temporal fact immediately before executing a recorded
  ## fact: eligibility, owning session, mount, accepted list survival, source
  ## token and ranges. A stale request is dropped, never executed.
  if not session.eventEligible: return false
  if request.sessionId != session.sessionId: return false
  if request.mountGeneration != session.mountGeneration: return false
  source = session.liveRowSource(request.listHandle, entity)
  if source == nil: return false
  if source.generation != request.sourceGeneration: return false
  rangeValid(source, request.first, request.finish, request.protected)

proc drainRowRequests*(session: BackendSession, canDeliver: DeliveryGate = nil): int =
  ## Execute recorded viewports on an ordinary safe UI turn and return how many
  ## were consumed. A commit/install in progress or a reentrant drain executes
  ## nothing and keeps every request for a later turn; requests queued while the
  ## batch is being processed are left to the next turn instead of spinning.
  ##
  ## The whole batch stays owned by the session while it runs (`claimedRows`),
  ## so it still counts against the `MaxPendingRowRequests` bound and a newer
  ## fact for a list can retire its in-flight fact instead of racing it. A
  ## rejected row build propagates as `UiError` (accepted state and tracked
  ## viewport stay as they were); the failed fact is dropped and never retried,
  ## and every unattempted fact returns to the queue for a later turn. Returning
  ## a fact therefore never loses it: no capacity is reclaimed during the drain,
  ## so re-queueing cannot overflow.
  ##
  ## A non-catchable `Defect` from a row build is different: it leaves the
  ## Runtime's attempt scope unusable, so no recorded fact could ever execute
  ## again. The session is then marked `faulted` and its recorded facts are
  ## dropped instead of being retained as dead reservations. That path is kept
  ## allocation-free on purpose: growing a queue while a Defect unwinds crashes
  ## the Windows debug build (D-W1, 0xC0000005 in `newSeqPayloadUninit`).
  if session == nil or not session.eventEligible: return 0
  if session.drainingRows: return 0
  if session.runtime != nil and session.runtime.installingUpdate: return 0
  if session.pendingRows.len == 0: return 0
  session.claimedRows = session.pendingRows
  session.pendingRows = @[]
  session.drainingRows = true
  var claimedIndex = 0
  try:
    while claimedIndex < session.claimedRows.len:
      if canDeliver != nil and not canDeliver():
        for remaining in claimedIndex ..< session.claimedRows.len:
          let kept = session.claimedRows[remaining]
          if not kept.superseded: session.pendingRows.add(kept)
        session.claimedRows.setLen(0)
        return
      let fact = session.claimedRows[claimedIndex]
      inc claimedIndex
      # A newer fact for this list arrived during the drain; its slot is retired
      # and the newer fact runs on the next turn.
      if fact.superseded: continue
      var entity: MountedEntity
      var source: ListSource
      if not session.rowRequestLive(fact.request, entity, source): continue
      try:
        discard session.applyRowViewport(entity, source, fact.request.first,
          fact.request.finish, fact.request.protected)
        inc result
      except CatchableError:
        # Keep every unattempted fact (superseded ones already have a newer
        # replacement queued) and surface the failure; the failed fact itself is
        # dropped so it is never retried in a loop.
        for remaining in claimedIndex ..< session.claimedRows.len:
          let kept = session.claimedRows[remaining]
          if not kept.superseded: session.pendingRows.add(kept)
        session.claimedRows.setLen(0)
        raise
    session.claimedRows.setLen(0)
  except Defect:
    # Unrecoverable attempt scope: drop the facts, do not allocate, and let the
    # Defect surface unchanged to the caller.
    session.faulted = true
    session.pendingRows.setLen(0)
    session.claimedRows.setLen(0)
    raise
  finally:
    session.drainingRows = false
