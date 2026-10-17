## UI-only lifecycle registrations and accepted deferred events. This layer
## knows Runtime/State contracts, never component descriptions or managed trees.
import std/[tables, sets, algorithm, monotimes, times, options]
import ./[core, component_state, task_contracts, task_worker]

const
  LifecycleRecordBytesInternal* = 128
  MaxLifecycleEventsInternal* = 4 * MaxNodes

type
  OwnerStamp* = object
    owner, generation: uint64
  OwnerRegistration* = ref object
    service: TaskService
    stamp: OwnerStamp
    sealed, hasScope, explicitScope, accepted, active: bool
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
  TaskRequest = ref object
    identity, generation: uint64
    scope: TaskScope
    key, input: string
    work: TaskWork
    onResult: TaskResultHandler
    onError: TaskErrorHandler
    maxResultBytes: int
    ticket: WorkerTicket
    current, submitted: bool
  TaskIntent = object
    request: TaskRequest
    cancelId: uint64
  TaskIntentFrame* = ref object
    intents: seq[TaskIntent]
    starts: seq[TaskRequest]
    cancellations: seq[TaskRequest]
    published, rejected: bool
  TaskAttempt* = ref object
    service: TaskService
    frame: TaskIntentFrame
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
    pumping, supported, retired, intentsTouched: bool
    nextIdentity, nextRequestGeneration: uint64
    intents: seq[TaskIntent]
    records: array[64, TaskRequest]
    pool: TaskWorkerPool
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
    supported: true, owners: initTable[uint64, OwnerRegistration](MaxNodes*2))
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

# An explicit thread-local owner pins pools independently of Runtime/service
# cycles. Only finalizeTaskPoolServiceInternal removes a pin, after UI join.
var poolPins {.threadvar.}: seq[TaskWorkerPool]

proc configureTaskServiceInternal*(service: TaskService, supported: bool) =
  service.requireUi()
  if not supported:
    for registration in service.owners.values:
      if registration.hasScope: fail("host does not support task pumping")
  service.supported = supported

proc scopeChargeInternal*(registration: OwnerRegistration): int =
  if registration.explicitScope: fail("duplicate explicit task scope")
  if registration.hasScope: 0 else: LifecycleRecordBytesInternal

proc configureScopeInternal*(registration: OwnerRegistration,
    retention: TaskRetention): TaskScope =
  registration.explicitScope = true
  registration.hasScope = true
  registration.scope = newTaskScopeInternal(registration.service,
    registration.stamp.owner, registration.stamp.generation, retention)
  registration.scope

proc requireTaskAccess*(service: TaskService, scope: TaskScope) =
  service.requireUi()
  if service.retired: fail("task service is retired")
  if executionRuntimeIdentity() != service.runtime.runtimeIdentity or not service.runtime.taskBodyInternal:
    fail("task API requires its Runtime UI task")
  service.states.requireIdle()
  if scope.taskDomainInternal != service: fail("task scope belongs to another Runtime")
  let registration = service.owners.getOrDefault(scope.taskOwnerInternal)
  if registration == nil or registration.stamp.generation != scope.taskGenerationInternal:
    fail("task scope owner is disposed or unaccepted")
  if not registration.active and registration.scope.retention != keepWhileRetained:
    fail("task scope owner is inactive")

proc requireTaskBoundary(service: TaskService) =
  service.requireUi()
  if service.retired: fail("task service is retired")
  if executionRuntimeIdentity() != service.runtime.runtimeIdentity or not service.runtime.taskBodyInternal:
    fail("task API requires its Runtime UI task")
  service.states.requireIdle()

proc hasTaskIntents*(service: TaskService): bool = service.intentsTouched
proc sealTaskIntentsInternal*(service: TaskService): TaskIntentFrame =
  service.requireUi()
  service.intentsTouched = false
  TaskIntentFrame(intents: move(service.intents))

proc utf8ScalarWidth(message: string, index: int): int =
  let first = ord(message[index])
  var width = 0
  var scalar, minimum: int
  if first <= 0x7F: width = 1; scalar = first
  elif first in 0xC2..0xDF: width = 2; scalar = first and 0x1F; minimum = 0x80
  elif first in 0xE0..0xEF: width = 3; scalar = first and 0x0F; minimum = 0x800
  elif first in 0xF0..0xF4: width = 4; scalar = first and 0x07; minimum = 0x10000
  var valid = width > 0 and width <= message.len - index
  if valid:
    for offset in 1..<width:
      let next = ord(message[index+offset])
      if next notin 0x80..0xBF:
        valid = false
        break
      scalar = (scalar shl 6) or (next and 0x3F)
    valid = valid and scalar >= minimum and scalar <= 0x10FFFF and
      scalar notin 0xD800..0xDFFF
  if valid: width else: 0

proc validTaskKey(key: string): bool =
  if key.len == 0 or key.len > 256: return false
  var index = 0
  while index < key.len:
    let width = utf8ScalarWidth(key, index)
    if width == 0: return false
    index += width
  true

proc startTaskInternal*(service: TaskService, scope: TaskScope, key, input: string,
    work: TaskWork, onResult: TaskResultHandler, onError: TaskErrorHandler,
    maxResultBytes: int): TaskHandle =
  service.requireTaskAccess(scope)
  if not validTaskKey(key): fail("task key must be 1..256 valid UTF-8 bytes")
  if input.len > 1048576: fail("task input exceeds 1 MiB")
  if maxResultBytes notin 1..1048576: fail("task result reservation must be 1..1048576 bytes")
  if work == nil or onResult == nil: fail("task requires work and onResult")
  # Pending replacements retain only their final bytes/closures. Include every
  # still-unsettled worker reservation, even if a cancellation is also pending.
  var inputs = input.len
  var results = maxResultBytes
  var count = 1
  if service.pool != nil:
    let stats = service.pool.workerPoolStats()
    inputs += stats.inputBytes
    results += stats.resultBytes
    count += stats.reservedTasks
  for intent in service.intents:
    let pending = intent.request
    if pending != nil and not (pending.scope.taskOwnerInternal == scope.taskOwnerInternal and pending.key == key):
      inputs += pending.input.len
      results += pending.maxResultBytes
      inc count
  if count > 64 or inputs > 8388608 or results > 8388608:
    fail("task pending reservation capacity exceeded")
  if service.nextIdentity == high(uint64): fail("task identity exhausted")
  inc service.nextIdentity
  for i in countdown(service.intents.high, 0):
    let pending = service.intents[i].request
    if pending != nil and pending.scope.taskOwnerInternal == scope.taskOwnerInternal and pending.key == key:
      service.intents.delete(i)
  let request = TaskRequest(identity: service.nextIdentity, scope: scope,
    key: key, input: input, work: work, onResult: onResult, onError: onError,
    maxResultBytes: maxResultBytes)
  service.intents.add(TaskIntent(request: request))
  service.intentsTouched = true
  newTaskHandleInternal(service, request.identity)

proc cancelTaskInternal*(service: TaskService, handle: TaskHandle) =
  service.requireTaskBoundary()
  if handle.taskDomainInternal != service: fail("task handle belongs to another Runtime")
  var found = false
  for request in service.records:
    if request != nil and request.current and request.identity == handle.taskIdInternal: found = true
  for intent in service.intents:
    if intent.request != nil and intent.request.identity == handle.taskIdInternal: found = true
    if intent.cancelId == handle.taskIdInternal: found = false
  if found:
    service.intentsTouched = true
    var pendingOnly = false
    for i in countdown(service.intents.high, 0):
      if service.intents[i].request != nil and service.intents[i].request.identity == handle.taskIdInternal:
        service.intents.delete(i)
        pendingOnly = true
    if not pendingOnly: service.intents.add(TaskIntent(cancelId: handle.taskIdInternal))

proc taskCurrentInternal*(service: TaskService, handle: TaskHandle): bool =
  service.requireUi()
  if handle.taskDomainInternal != service: return false
  for request in service.records:
    if request != nil and request.identity == handle.taskIdInternal: return request.current

proc taskWorkerStatsInternal*(service: TaskService): WorkerPoolStats =
  service.requireUi()
  if service.pool != nil: service.pool.workerPoolStats() else: default(WorkerPoolStats)

proc clearPrepared(service: TaskService, frame: TaskIntentFrame) {.raises: [].} =
  if frame == nil or frame.published: return
  for request in frame.starts:
    if service.pool != nil:
      try: service.pool.ackCompletion(request.ticket)
      except ValueError as error: raiseAssert(error.msg)
    request.ticket = default(WorkerTicket)
  frame.starts.setLen(0)
  frame.cancellations.setLen(0)

proc rejectTaskIntentsInternal*(service: TaskService, frame: TaskIntentFrame) {.raises: [].} =
  service.clearPrepared(frame)
  if frame != nil and not frame.published:
    frame.rejected = true
    frame.intents.setLen(0)
  service.intents.setLen(0)
  service.intentsTouched = false

proc finalOwner(service: TaskService, request: TaskRequest,
    updates: seq[OwnerUpdate]): bool =
  let owner = request.scope.taskOwnerInternal
  var registration = service.owners.getOrDefault(owner)
  var active = registration != nil and registration.active
  for update in updates:
    if update.registration.stamp.owner == owner:
      registration = if update.kind == LifecyclePhase.dispose: nil else: update.registration
      active = update.active
  registration != nil and registration.stamp.generation == request.scope.taskGenerationInternal and
    (active or registration.scope.retention == keepWhileRetained)

proc prepareIntents(service: TaskService, frame: TaskIntentFrame, updates: seq[OwnerUpdate]) =
  if frame == nil: return
  service.clearPrepared(frame)
  var latest: seq[TaskRequest]
  for intent in frame.intents:
    if intent.request != nil:
      let request = intent.request
      for i in countdown(latest.high, 0):
        if latest[i].scope.taskOwnerInternal == request.scope.taskOwnerInternal and latest[i].key == request.key:
          latest.delete(i)
      latest.add(request)
    else:
      for i in countdown(latest.high, 0):
        if latest[i].identity == intent.cancelId: latest.delete(i)
      for old in service.records:
        if old != nil and old.current and old.identity == intent.cancelId:
          frame.cancellations.add(old)
  for old in service.records:
    if old == nil or not old.current: continue
    if not service.finalOwner(old, updates): frame.cancellations.add(old)
  for request in latest:
    if not service.finalOwner(request, updates): continue
    for old in service.records:
      if old != nil and old.current and old.scope.taskOwnerInternal == request.scope.taskOwnerInternal and old.key == request.key:
        frame.cancellations.add(old)
    frame.starts.add(request)
  if frame.starts.len == 0: return
  if service.pool == nil:
    try: service.pool = newTaskWorkerPool()
    except CatchableError as error: fail("task worker startup failed: " & error.msg)
    poolPins.add(service.pool)
  try:
    for request in frame.starts:
      request.ticket = service.pool.reserveWork(request.identity, request.input, request.work, request.maxResultBytes)
    if uint64(frame.starts.len) > high(uint64)-service.nextRequestGeneration:
      fail("task request generation exhausted")
  except CatchableError as error:
    service.clearPrepared(frame)
    fail("task reservation failed: " & error.msg)

proc retireTaskPoolServiceInternal*(service: TaskService) =
  service.requireUi()
  service.retired = true
  if service.pool != nil: service.pool.retirePool()

proc finalizeTaskPoolServiceInternal*(service: TaskService) =
  service.requireUi()
  if service.runtime.installingUpdate or service.runtime.installingHook or service.pumping or
      executionRuntimeIdentity() != 0:
    fail("task pool cleanup requires an ordinary noncallback UI finally")
  service.retireTaskPoolServiceInternal()
  service.intents.setLen(0)
  service.intentsTouched = false
  if service.pool != nil:
    service.pool.joinPool()
    for request in service.records.mitems: request = nil
    for i in countdown(poolPins.high, 0):
      if poolPins[i] == service.pool: poolPins.delete(i)
    service.pool = nil

proc prepareTasks*(service: TaskService, revision: uint64,
    transitions: seq[OwnerTransition], registrations: seq[OwnerRegistration], frame: TaskIntentFrame = nil): TaskAttempt =
  service.requireUi()
  result = TaskAttempt(service: service, frame: frame, pendingRecords: service.pendingRecords)
  var fresh: Table[uint64, OwnerRegistration]
  for registration in registrations:
    if registration == nil or registration.service != service or not registration.sealed:
      fail("invalid candidate lifecycle registration")
    fresh[registration.stamp.owner] = registration
  if service.retired: fail("task service is retired")
  if not service.supported:
    for registration in service.owners.values:
      if registration.hasScope: fail("host does not support task pumping")
    for registration in registrations:
      if registration.hasScope: fail("host does not support task pumping")
    if frame != nil and frame.intents.len > 0: fail("host does not support task pumping")
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
  service.prepareIntents(frame, result.updates)
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
  let frame = attempt.frame
  if frame != nil and not frame.published:
    for request in frame.cancellations:
      request.current = false
      request.ticket.requestCancel()
    for request in frame.starts:
      inc service.nextRequestGeneration
      request.generation = service.nextRequestGeneration
      request.current = true
      request.input = ""
      for slot in service.records.mitems:
        if slot == nil:
          slot = request
          break
    frame.published = true
    frame.intents.setLen(0)
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

proc boundedErrorMessage(message: string): string =
  # Strict Unicode scalar decoding: invalid bytes become U+FFFD. Apply the
  # byte limit after normalization, never retaining only part of a scalar.
  var index = 0
  while index < message.len:
    let width = utf8ScalarWidth(message, index)
    let valid = width > 0
    let encoded = if valid: message[index..<index+width] else: "\xEF\xBF\xBD"
    if result.len + encoded.len > 4096: break
    result.add(encoded)
    index += (if valid: width else: 1)

proc logFailure(event: LifecycleEvent, error: ref CatchableError) =
  try:
    stderr.writeLine("leaf: lifecycle owner=" & $event.registration.stamp.owner &
      " revision=" & $event.revision & " phase=" & $event.kind & ": " &
      boundedErrorMessage(error.msg))
  except IOError: discard

proc currentEntry(service: TaskService, event: LifecycleEvent): bool =
  if event.kind notin {LifecyclePhase.mount, LifecyclePhase.activate}: return true
  let registration = service.owners.getOrDefault(event.registration.stamp.owner)
  registration == event.registration and registration.active and registration.epoch == event.epoch

proc pumpTaskService*(service: TaskService): TaskPumpReport =
  service.requireUi()
  if service.runtime.installingUpdate or service.runtime.installingHook or service.pumping:
    fail("lifecycle pump requires an ordinary UI safe point")
  if not service.supported or service.retired: fail("task service cannot pump")
  service.pumping = true
  var callbacks, dropped, failed, processed: int
  let deadline = getMonoTime() + initDuration(milliseconds = 4)
  try:
    if service.pool != nil:
      for request in service.records.mitems:
        if request == nil: continue
        if not request.current:
          request.ticket.requestCancel()
          if not request.submitted:
            service.pool.ackCompletion(request.ticket)
            request = nil
        elif not request.submitted:
          if service.pool.submitReserved(request.ticket): request.submitted = true
      while processed < 64 and (processed == 0 or getMonoTime() < deadline):
        let completion = service.pool.peekCompletion()
        if completion.isNone: break
        var index = -1
        for i, request in service.records:
          if request != nil and request.identity == completion.get.id: index = i
        if index < 0 or service.records[index].current: break
        service.pool.ackCompletion(service.records[index].ticket)
        service.records[index] = nil
        inc dropped
        inc processed
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
  newTaskPumpReportInternal(0, dropped, callbacks, failed, service.pendingRecords > 0 or (service.pool != nil and service.pool.workerPoolStats.reservedTasks > 0))
