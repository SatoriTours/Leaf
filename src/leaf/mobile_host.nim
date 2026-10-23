## Retained mobile business owner. Views attach/detach; only the retained owner
## closes the managed Runtime. Platform callbacks still enter on the UI thread
## through a guarded ABI. This module owns no Activity/View/JNI reference.
import ./[core, backend, backend_session, managed_runtime, ui_thread]

type
  ApplicationFactory* = proc(): Application {.closure.}
  MobileHostState* = enum
    mobileDetached, mobileAttaching, mobileAttached, mobileDetaching,
    mobileClosing, mobileClosed
  MobileMount* = object
    ## Attachment identity, stable for an Activity/view tree. Session recovery
    ## may independently increase its event mountGeneration within this mount.
    hostIdentity*, generation*: uint64
  MobileHost* = ref object
    runtimeValue: Runtime
    session: BackendSession
    activity: UiScopeActivity
    currentThread: ThreadIdProc
    owner: uint64
    identityValue, lastGeneration: uint64
    mount: MobileMount
    stateValue: MobileHostState
    resumed, ticking, pumpingTasks: bool

proc deliveryReady(host: MobileHost, mount: MobileMount): bool

proc systemThread(): uint64 {.raises: [].} =
  when compileOption("threads"): uint64(getThreadId())
  else: 1'u64

proc requireOwner(host: MobileHost) =
  if host == nil: fail("mobile host is nil")
  if host.currentThread() != host.owner:
    fail("mobile host requires its owning UI thread")

proc runtime*(host: MobileHost): Runtime =
  host.requireOwner()
  host.runtimeValue
proc identity*(host: MobileHost): uint64 =
  host.requireOwner()
  host.identityValue
proc state*(host: MobileHost): MobileHostState =
  host.requireOwner()
  host.stateValue
proc currentMount*(host: MobileHost): MobileMount =
  host.requireOwner()
  host.mount

proc ordinary(host: MobileHost): bool =
  not host.ticking and not host.activity.busy and host.runtimeValue != nil and
    not host.runtimeValue.installingUpdate and not host.runtimeValue.installingHook

proc matches(host: MobileHost, mount: MobileMount): bool =
  mount.hostIdentity != 0 and mount.generation != 0 and mount == host.mount

proc newMobileHost*(factory: ApplicationFactory,
    currentThread: ThreadIdProc = systemThread): MobileHost =
  if factory == nil or currentThread == nil: fail("mobile host requires a factory and UI thread source")
  let owner = currentThread()
  let activity = newUiScopeActivity()
  let host = MobileHost(owner: owner, currentThread: currentThread, activity: activity)
  var app = factory()
  let originalScope = app.executionScope
  app.executionScope = proc(body: proc() {.closure.}) =
    # TaskService preserves an event/result when scope entry is refused. Check
    # each callback, including one after a callback paused/closed the host.
    if host.pumpingTasks and not host.deliveryReady(host.mount):
      fail("mobile task delivery is paused")
    proc allowedBody() =
      if host.pumpingTasks and not host.deliveryReady(host.mount):
        fail("mobile task delivery is paused")
      body()
    if originalScope == nil: allowedBody()
    else: originalScope(allowedBody)
  app = guardUiApplication(app, currentThread, activity)
  # newRuntime's existing RuntimeCleanupError retains its cleanupRuntime if
  # startup cleanup fails. Do not catch/drop that owner or create another one.
  let runtime = newRuntime(app)
  runtime.configureTaskPumpInternal(true)
  host.runtimeValue = runtime
  host.identityValue = runtime.runtimeIdentity
  host

proc backendSession*(host: MobileHost, mount: MobileMount): BackendSession =
  ## Read-only ownership query. A detaching Session can still be inspected for
  ## cleanup diagnostics, but enqueue and safeTurn cannot use it for delivery.
  host.requireOwner()
  if host.matches(mount): host.session else: nil

proc attach*(host: MobileHost, backend: Backend,
    width, height, scale: float64): MobileMount =
  host.requireOwner()
  if host.stateValue != mobileDetached or host.session != nil:
    fail("mobile host must finish detaching before attaching another backend")
  if not host.ordinary: fail("mobile attachment requires an ordinary UI boundary")
  if host.runtimeValue.eventsFrozen or host.runtimeValue.runtimeClosedInternal:
    fail("mobile runtime is closed or frozen")
  if host.lastGeneration == high(uint64): fail("mobile attachment identity exhausted")
  inc host.lastGeneration # A failed attempt must never reuse its identity.
  host.mount = MobileMount(hostIdentity: host.identityValue, generation: host.lastGeneration)
  host.stateValue = mobileAttaching
  host.resumed = false
  let context = HostContext(sessionId: host.identityValue,
    mountGeneration: host.lastGeneration, contentWidth: width,
    contentHeight: height, scale: scale)
  try:
    discard attachBackendObserved(host.runtimeValue, backend, context, compatible,
      proc(session: BackendSession) {.raises: [].} = host.session = session)
    # A protected callback may have requested terminal close and swallowed its
    # deferred-boundary exception. Do not reactivate that attachment afterwards.
    if host.stateValue != mobileAttaching or host.session.closing:
      fail("mobile attachment was cancelled")
    host.stateValue = mobileAttached
    result = host.mount
  except CatchableError:
    if host.session != nil:
      host.session.requestClose()
      if host.stateValue != mobileClosing: host.stateValue = mobileDetaching
    elif host.stateValue != mobileClosing:
      host.mount = MobileMount()
      host.stateValue = mobileDetached
    raise

proc resume*(host: MobileHost, mount: MobileMount): bool =
  host.requireOwner()
  if not host.matches(mount) or host.stateValue != mobileAttached: return false
  host.resumed = true
  true

proc pause*(host: MobileHost, mount: MobileMount): bool =
  ## Stop platform delivery without deactivating business components. Existing
  ## queued events/task results keep their existing owners and wait for resume;
  ## detach instead invalidates the old Session's event queue. TaskService's
  ## budgets remain in force; this layer adds no separate native event budget.
  host.requireOwner()
  if not host.matches(mount) or host.stateValue != mobileAttached: return false
  host.resumed = false
  true

proc deliveryReady(host: MobileHost, mount: MobileMount): bool =
  host.matches(mount) and host.stateValue == mobileAttached and host.resumed and
    host.session != nil and not host.session.closing and not host.session.disposed and
    not host.session.faulted and not host.session.frozen and
    not host.runtimeValue.eventsFrozen and not host.runtimeValue.runtimeClosedInternal

proc enqueue*(host: MobileHost, mount: MobileMount, event: EventEnvelope): bool =
  host.requireOwner()
  if not host.deliveryReady(mount): return false
  host.session.enqueue(event)

proc queueNavigation*(host: MobileHost, mount: MobileMount, fact: NavigationBackFact): bool =
  ## Platform callbacks record facts only while their current Activity delivers.
  ## The ordinary Session queue later revalidates and runs the business handler.
  host.requireOwner()
  if not host.deliveryReady(mount): return false
  host.session.queueNavigation(fact)

proc safeTurn*(host: MobileHost, mount: MobileMount): bool =
  ## One explicit platform turn. No loop, no timer and no hidden retry of native
  ## teardown failures. A platform scheduler must arrange later ordinary turns.
  ## True means the turn ran, not that every event committed: BackendSession
  ## retains its existing per-event error/accepted-state handling policy.
  host.requireOwner()
  if not host.deliveryReady(mount) or not host.ordinary: return false
  host.ticking = true
  try:
    # Session revalidates its fault/close/identity facts itself between entries.
    # This nonthrowing gate adds the platform lifecycle state to that check.
    let canDeliver = proc(): bool {.raises: [].} =
      host.matches(mount) and host.stateValue == mobileAttached and host.resumed
    host.session.drainEvents(canDeliver)
    if host.deliveryReady(mount): discard host.session.drainRowRequests(canDeliver)
    if host.deliveryReady(mount):
      host.pumpingTasks = true
      try: discard host.runtimeValue.pumpTasks()
      finally: host.pumpingTasks = false
    result = true
  finally:
    host.ticking = false

proc releaseViews(host: MobileHost) =
  if host.session != nil:
    # Backend restore can advance event mountGeneration beyond the original
    # Activity token. New views must not reuse any of those event generations.
    host.lastGeneration = max(host.lastGeneration, host.session.mountGeneration)
    host.session.dispose() # Failure keeps the authoritative owner for retry.
    host.session = nil
  host.mount = MobileMount()

proc detach*(host: MobileHost, mount: MobileMount): bool =
  host.requireOwner()
  if not host.matches(mount) or host.stateValue notin
      {mobileAttaching, mobileAttached, mobileDetaching}: return false
  host.resumed = false
  host.stateValue = mobileDetaching
  if host.session != nil: host.session.requestClose()
  if not host.ordinary: fail("mobile detach deferred; retry at an ordinary UI boundary")
  host.releaseViews()
  host.stateValue = mobileDetached
  true

proc close*(host: MobileHost) =
  ## Retained-owner terminal operation (e.g. ViewModel.onCleared), never a
  ## substitute for Activity detach. Native resources must finish first.
  host.requireOwner()
  if host.stateValue == mobileClosed: return
  host.resumed = false
  host.stateValue = mobileClosing
  if host.session != nil: host.session.requestClose()
  if not host.ordinary: fail("mobile close deferred; retry at an ordinary UI boundary")
  host.releaseViews()
  host.runtimeValue.closeRuntime()
  host.runtimeValue = nil
  host.stateValue = mobileClosed
