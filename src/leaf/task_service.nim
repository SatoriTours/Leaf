## UI-only lifecycle registrations and accepted deferred events. This layer
## knows Runtime/State contracts, never component descriptions or managed trees.
import std/[tables, sets, algorithm, monotimes, times]
import ./[core, component_state, task_contracts]

const
  LifecycleRecordBytesInternal* = 128
  MaxLifecycleEventsInternal* = 4 * MaxNodes

type
  OwnerStamp* = object
    owner, generation: uint64
  OwnerRegistration* = ref object
    service: TaskService
    stamp: OwnerStamp
    sealed, hasScope, accepted, active: bool
    epoch: uint64
    scope: TaskScope
    hooks: array[LifecyclePhase, LifecycleCallback]
  OwnerTransition* = object
    stamp: OwnerStamp
    kind: LifecyclePhase
    depth: int
    order: uint64
    finalActive: bool
  LifecycleEvent = object
    registration: OwnerRegistration
    kind: LifecyclePhase
    revision, epoch: uint64
    callback: LifecycleCallback
    scope: TaskScope
  EventBatch = ref object
    events: seq[LifecycleEvent]
    cursor: int
    next: EventBatch
  OwnerUpdate = object
    registration: OwnerRegistration
    kind: LifecyclePhase
    epoch: uint64
    active: bool
  TaskAttempt* = ref object
    service: TaskService
    updates: seq[OwnerUpdate]
    batch: EventBatch
    pendingRecords: int
    published, rejected: bool
  TaskService* = ref object of TaskDomain
    runtime: Runtime
    states: StateStore
    owners: Table[uint64, OwnerRegistration]
    first, last: EventBatch
    pendingRecords: int
    nextGeneration: uint64
    pumping: bool
    when compileOption("threads"): threadId: int

proc requireUi(service: TaskService) =
  if service == nil: fail("missing task service")
  when compileOption("threads"):
    if service.threadId != getThreadId(): fail("task service requires its UI thread")
  if executionRuntimeIdentity() != 0 and executionRuntimeIdentity() != service.runtime.runtimeIdentity:
    fail("task service belongs to another executing Runtime")

proc newTaskService*(runtime: Runtime, states: StateStore): TaskService =
  if runtime == nil or states == nil: fail("task service requires Runtime and StateStore")
  result = TaskService(runtime: runtime, states: states,
    owners: initTable[uint64, OwnerRegistration](MaxNodes*2))
  when compileOption("threads"): result.threadId = getThreadId()

proc newOwnerRegistration*(service: TaskService, owner: uint64): OwnerRegistration =
  service.requireUi()
  if owner == 0: fail("lifecycle owner must be nonzero")
  if service.nextGeneration == high(uint64): fail("lifecycle generation exhausted")
  inc service.nextGeneration
  OwnerRegistration(service: service,
    stamp: OwnerStamp(owner: owner, generation: service.nextGeneration))

proc sealOwnerRegistration*(registration: OwnerRegistration) {.raises: [].} =
  if registration != nil: registration.sealed = true

proc requireOwnerRegistrationInternal*(registration: OwnerRegistration,
    states: StateStore, owner: uint64) =
  if registration == nil: fail("mount context has no lifecycle service")
  registration.service.requireUi()
  if registration.service.states != states or registration.stamp.owner != owner:
    fail("lifecycle registration belongs to another owner")
  if registration.sealed: fail("lifecycle registration is already closed")
  states.requireInitializing()

proc lifecycleChargeInternal*(registration: OwnerRegistration,
    kind: LifecyclePhase, callback: LifecycleCallback): int =
  if callback == nil: fail("nil lifecycle callback")
  if registration.hooks[kind] != nil: fail("duplicate lifecycle callback")
  LifecycleRecordBytesInternal * (if registration.hasScope: 1 else: 2)

proc registerLifecycleInternal*(registration: OwnerRegistration,
    kind: LifecyclePhase, callback: LifecycleCallback) =
  if not registration.hasScope:
    registration.scope = newTaskScopeInternal(registration.service,
      registration.stamp.owner, registration.stamp.generation)
    registration.hasScope = true
  registration.hooks[kind] = callback

proc ownerTransitionInternal*(registration: OwnerRegistration,
    kind: LifecyclePhase, depth: int, order: uint64, active: bool): OwnerTransition =
  OwnerTransition(stamp: registration.stamp, kind: kind, depth: depth, order: order, finalActive: active)

proc pendingTaskBytesInternal*(service: TaskService): int =
  service.pendingRecords * LifecycleRecordBytesInternal
proc preparedTaskBytesInternal*(attempt: TaskAttempt): int =
  if attempt == nil: 0 else: attempt.pendingRecords * LifecycleRecordBytesInternal

proc prepareTasks*(service: TaskService, revision: uint64,
    transitions: seq[OwnerTransition], registrations: seq[OwnerRegistration]): TaskAttempt =
  service.requireUi()
  result = TaskAttempt(service: service, pendingRecords: service.pendingRecords)
  var fresh: Table[uint64, OwnerRegistration]
  for registration in registrations:
    if registration == nil or registration.service != service or not registration.sealed:
      fail("invalid candidate lifecycle registration")
    fresh[registration.stamp.owner] = registration
  var ordered = transitions
  ordered.sort(proc(a, b: OwnerTransition): int =
    let aEnter = a.kind in {LifecyclePhase.mount, LifecyclePhase.activate}
    let bEnter = b.kind in {LifecyclePhase.mount, LifecyclePhase.activate}
    result = cmp(aEnter, bEnter)
    if result == 0: result = (if aEnter: cmp(a.depth, b.depth) else: cmp(b.depth, a.depth))
    if result == 0: result = cmp(a.order, b.order))
  var seen: HashSet[uint64]
  var events: seq[LifecycleEvent]
  for transition in ordered:
    let owner = transition.stamp.owner
    if owner in seen: fail("duplicate candidate lifecycle owner transition")
    seen.incl(owner)
    let registration = if transition.kind == LifecyclePhase.mount:
        fresh.getOrDefault(owner) else: service.owners.getOrDefault(owner)
    if registration == nil or registration.stamp != transition.stamp:
      fail("lifecycle transition has a stale owner stamp")
    if registration.epoch == high(uint64): fail("lifecycle activity epoch exhausted")
    let epoch = registration.epoch + 1
    result.updates.add(OwnerUpdate(registration: registration, kind: transition.kind,
      epoch: epoch, active: transition.finalActive))
    let callback = registration.hooks[transition.kind]
    # A candidate may prewarm a new owner and accept it already inactive.
    # Register its State/scope identity, but only accepted active enters notify.
    if callback != nil and (transition.kind notin {LifecyclePhase.mount, LifecyclePhase.activate} or transition.finalActive):
      if result.pendingRecords >= MaxLifecycleEventsInternal:
        fail("pending lifecycle events exceed 40000 records")
      inc result.pendingRecords
      events.add LifecycleEvent(registration: registration, kind: transition.kind,
        revision: revision, epoch: epoch, callback: callback, scope: registration.scope)
  if events.len > 0: result.batch = EventBatch(events: move(events))

proc publishTasks*(service: TaskService, attempt: TaskAttempt) {.raises: [].} =
  if attempt == nil or attempt.service != service or attempt.published or attempt.rejected: return
  for update in attempt.updates:
    let registration = update.registration
    registration.epoch = update.epoch
    registration.active = update.active
    registration.accepted = update.kind != LifecyclePhase.dispose
    if registration.accepted: service.owners[registration.stamp.owner] = registration
    else: service.owners.del(registration.stamp.owner)
  if attempt.batch != nil:
    if service.last == nil: service.first = attempt.batch
    else: service.last.next = attempt.batch
    service.last = attempt.batch
  service.pendingRecords = attempt.pendingRecords
  attempt.published = true

proc rejectTasks*(service: TaskService, attempt: TaskAttempt) {.raises: [].} =
  if attempt == nil or attempt.service != service or attempt.published: return
  attempt.rejected = true
  attempt.batch = nil
  attempt.updates.setLen(0)

proc popEvent(service: TaskService) =
  let batch = service.first
  batch.events[batch.cursor] = default(LifecycleEvent)
  inc batch.cursor
  dec service.pendingRecords
  if batch.cursor == batch.events.len:
    service.first = batch.next
    if service.first == nil: service.last = nil

proc logFailure(event: LifecycleEvent, error: ref CatchableError) =
  try:
    stderr.writeLine("leaf: lifecycle owner=" & $event.registration.stamp.owner &
      " revision=" & $event.revision & " phase=" & $event.kind & ": " &
      error.msg[0..<min(error.msg.len, 4096)])
  except IOError: discard

proc currentEntry(service: TaskService, event: LifecycleEvent): bool =
  if event.kind notin {LifecyclePhase.mount, LifecyclePhase.activate}: return true
  let registration = service.owners.getOrDefault(event.registration.stamp.owner)
  registration == event.registration and registration.active and registration.epoch == event.epoch

proc pumpTaskService*(service: TaskService): TaskPumpReport =
  service.requireUi()
  if service.runtime.installingUpdate or service.runtime.installingHook or service.pumping:
    fail("lifecycle pump requires an ordinary UI safe point")
  service.pumping = true
  var callbacks, dropped, failed, processed: int
  let deadline = getMonoTime() + initDuration(milliseconds = 4)
  try:
    while service.first != nil and processed < 64 and
        (processed == 0 or getMonoTime() < deadline):
      let event = service.first.events[service.first.cursor]
      if not service.currentEntry(event):
        service.popEvent()
        inc dropped
        inc processed
        continue
      var entered = false
      try:
        service.runtime.uiTask(proc() =
          # Scope refusal before this body leaves the record and its charge
          # intact. Once entered, callback/flush/scope-exit failures never replay.
          entered = true
          service.popEvent()
          # executionScope is application code too: it may accept a different
          # owner/activity before invoking this body. Check again at delivery.
          if service.currentEntry(event):
            inc callbacks
            event.callback(newLifecycleContextInternal(event.kind, event.revision, event.scope))
          else: inc dropped)
      except CatchableError as error:
        inc failed
        event.logFailure(error)
      if not entered: break
      inc processed
  finally: service.pumping = false
  newTaskPumpReportInternal(0, dropped, callbacks, failed, service.pendingRecords > 0)
