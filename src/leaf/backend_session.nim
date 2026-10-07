## Backend session: binds a synchronous Backend to a Runtime, owns the native
## event queue, viewport tracking and failure recovery.
##
## The session is the only place that coordinates the Runtime commit gate with
## a backend. It never renders business state, never runs a business callback
## before the backend confirms a batch, and never executes platform lifecycle.
import std/[tables, sets, math, strutils]
import ./[core, styles, backend, reconcile]

type
  EventSource* = enum
    ## A genuine user input event, or a backend setter notification that must
    ## never be treated as user input.
    sourceUser, sourceSetter

  EventEnvelope* = object
    session*: uint64
    mountGeneration*: uint64
    handle*: NodeHandle
    sequence*: uint64
    observedRevision*: uint64
    source*: EventSource
    event*: Event

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
    pendingPlan: ReconcilePlan
    pendingInstall: bool
    pendingInitial: bool
    sessionId: uint64
    mountGeneration: uint64
    lastQueued: uint64
    lastProcessed: uint64
    queue: seq[EventEnvelope]
    entities: Table[NodeHandle, MountedEntity]
    byNodeId: Table[string, NodeHandle]
    viewports: Table[NodeHandle, ViewportState]
    issues: seq[CapabilityIssue]
    seenIssues: HashSet[string]
    disposed: bool
    faulted: bool
    frozen: bool
    closing: bool
    draining: bool

proc runtime*(session: BackendSession): Runtime = session.runtime
proc sessionId*(session: BackendSession): uint64 = session.sessionId
proc mountGeneration*(session: BackendSession): uint64 = session.mountGeneration
proc queuedEvents*(session: BackendSession): int = session.queue.len
proc disposed*(session: BackendSession): bool = session.disposed
proc closing*(session: BackendSession): bool = session.closing
proc faulted*(session: BackendSession): bool = session.faulted
proc frozen*(session: BackendSession): bool = session.frozen
proc capabilityIssues*(session: BackendSession): seq[CapabilityIssue] = session.issues

proc acceptedEntities*(session: BackendSession): Table[NodeHandle, MountedEntity] =
  session.entities

proc handleFor*(session: BackendSession, nodeId: string): NodeHandle =
  if nodeId notin session.byNodeId:
    fail("session has no entity for node: " & nodeId)
  session.byNodeId[nodeId]

proc collectIssues(session: BackendSession, root: MountedNode) =
  ## Structured decoration diagnostics are reported once per node/property for
  ## the lifetime of a session; a new session can report them again.
  for issue in checkCapabilities(root, session.backend.capabilities, session.mode):
    let key = issue.nodeId & "\x1f" & issue.property
    if key notin session.seenIssues:
      session.seenIssues.incl(key)
      session.issues.add(issue)

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
  ## native notifications are invalidated. A failed restore faults the session
  ## and permanently freezes business dispatch on the runtime. Returns "" on
  ## success, otherwise the restore failure detail.
  session.frozen = true
  try:
    session.backend.restore(previous)
  except CatchableError as error:
    session.faulted = true
    session.runtime.freezeEvents("backend restore failed: " & error.msg)
    return error.msg
  inc session.mountGeneration
  session.queue.setLen(0)
  session.lastQueued = 0
  session.lastProcessed = 0
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
    if not session.entities.hasKey(handle): continue
    let nodeId = session.entities[handle].nodeId
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

proc attachBackend*(runtime: Runtime, backend: Backend, host: HostContext,
                    mode = compatible): BackendSession =
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
  discard checkCapabilities(runtime.snapshot.root, backend.capabilities, mode)

  var session = BackendSession(runtime: runtime, backend: backend, host: host,
    mode: mode, reconciler: newReconciler(), sessionId: host.sessionId,
    mountGeneration: host.mountGeneration)
  session.collectIssues(runtime.snapshot.root)
  session.backendToken = backend.reserveSession()

  try:
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
  session.closing = true
  session.queue.setLen(0)
  session.lastQueued = 0
  session.lastProcessed = 0
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
  if envelope.source == sourceSetter: return false
  if envelope.session != session.sessionId: return false
  if envelope.mountGeneration != session.mountGeneration: return false
  if envelope.observedRevision > session.runtime.acceptedRevision: return false
  if envelope.sequence <= session.lastQueued: return false
  if not session.entities.hasKey(envelope.handle): return false
  session.lastQueued = envelope.sequence
  session.queue.add(envelope)
  true

proc eventEligible(session: BackendSession): bool =
  ## Single eligibility predicate, re-checked before every queued event. A
  ## teardown that starts mid-drain (even at a safe post-scope boundary) makes
  ## the remaining captured batch ineligible instead of leaking it to business.
  not session.disposed and not session.faulted and not session.frozen and
    not session.closing

proc process(session: BackendSession, envelope: EventEnvelope) =
  ## Revalidate against the live accepted state immediately before running the
  ## callback. A failed dispatch leaves the old accepted tree and never
  ## re-executes the business closure. The eligibility guard runs before any
  ## sequence or Runtime access.
  if not session.eventEligible: return
  if envelope.session != session.sessionId: return
  if envelope.mountGeneration != session.mountGeneration: return
  if envelope.sequence <= session.lastProcessed: return
  session.lastProcessed = envelope.sequence
  if not session.entities.hasKey(envelope.handle): return
  let entity = session.entities[envelope.handle]
  var mounted: MountedNode
  try:
    mounted = session.runtime.find(entity.nodeId)
  except UiError:
    return
  let node = mounted.node
  if node.disabled: return
  if node.handler(envelope.event.kind) == nil: return
  try:
    discard session.runtime.dispatch(entity.nodeId, envelope.event)
  except CatchableError:
    discard

proc drainEvents*(session: BackendSession) =
  ## Explicit host drain. A commit in progress (or a reentrant drain) returns
  ## without touching the queue or its sequence bookkeeping, so genuine user
  ## events queued during apply survive for a drain after publication. The
  ## committer never dispatches queued events before publication.
  if session == nil or not session.eventEligible: return
  if session.draining: return
  if session.runtime != nil and session.runtime.installingUpdate: return
  session.draining = true
  try:
    let pending = session.queue
    session.queue = @[]
    for envelope in pending:
      if not session.eventEligible: return
      session.process(envelope)
  finally:
    session.draining = false

proc requestRows*(session: BackendSession, listHandle: NodeHandle,
                  sourceGeneration: uint64, first, finish: int,
                  protected: seq[int] = @[]): seq[MountedNode] =
  ## Materialize a list viewport. The tracked viewport is replaced only after a
  ## successful commit, so a rejected request cannot corrupt visible tracking.
  if session == nil or session.disposed: fail("session is disposed")
  if session.closing: fail("session is closing")
  if session.faulted: fail("session is faulted")
  if not session.entities.hasKey(listHandle):
    fail("unknown list handle: " & $listHandle)
  let entity = session.entities[listHandle]
  if entity.kind != virtualList:
    fail("handle is not a virtual list: " & entity.nodeId)
  let target = session.runtime.find(entity.nodeId)
  let source = target.node.listSource
  if source == nil: fail("list has no source")
  if source.generation != sourceGeneration:
    fail("obsolete list source generation")
  result = session.runtime.materialize(entity.nodeId, first, finish, protected)
  var keys: seq[string]
  for index in first..<finish: keys.add(source.itemKey(index))
  for index in protected:
    if index >= 0 and index < source.len: keys.add(source.itemKey(index))
  session.viewports[listHandle] = ViewportState(keys: keys)
