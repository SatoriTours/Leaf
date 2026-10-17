## Thread-independent task and lifecycle contracts. UI closures stay in the
## task domain; only TaskWork and byte payloads may enter a worker.
import std/atomics

type
  TaskRetention* = enum cancelOnDeactivate, keepWhileRetained
  TaskFailureKind* = enum workFailed, resultTooLarge
  TaskFailure* = object
    failureKind: TaskFailureKind
    failureMessage: string
  TaskDomain* = ref object of RootObj
    ## Opaque UI service base. This type is never a worker message.
  TaskScope* = object
    domain: TaskDomain
    owner, generation: uint64
    retentionPolicy: TaskRetention
  TaskHandle* = object
    domain: TaskDomain
    identity: uint64
  LifecyclePhase* {.pure.} = enum mount, activate, deactivate, dispose
  LifecycleContext* = object
    eventPhase: LifecyclePhase
    revision: uint64
    scope: TaskScope
  TaskPumpReport* = object
    deliveredCount, droppedCount, callbackCount, failedCount: int
    hasPending: bool
  TaskCancellationSignalInternal* = object
    ## Shared allocation contains no managed memory, only atomic metadata.
    requested: Atomic[bool]
    references: Atomic[int]
  WorkerContext* = object
    ## Borrowed only during TaskWork. Applications must not retain this value.
    signal: ptr TaskCancellationSignalInternal
  TaskWork* = proc(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.}
  TaskResultHandler* = proc(value: string) {.closure.}
  TaskErrorHandler* = proc(error: TaskFailure) {.closure.}
  LifecycleCallback* = proc(ctx: LifecycleContext) {.closure.}

proc kind*(failure: TaskFailure): TaskFailureKind = failure.failureKind
proc message*(failure: TaskFailure): string = failure.failureMessage
proc taskFailureInternal*(kind: TaskFailureKind, message: string): TaskFailure =
  TaskFailure(failureKind: kind, failureMessage: message)

proc newTaskScopeInternal*(domain: TaskDomain, owner, generation: uint64,
    retention = cancelOnDeactivate): TaskScope =
  TaskScope(domain: domain, owner: owner, generation: generation,
    retentionPolicy: retention)
proc taskDomainInternal*(scope: TaskScope): TaskDomain = scope.domain
proc taskOwnerInternal*(scope: TaskScope): uint64 = scope.owner
proc taskGenerationInternal*(scope: TaskScope): uint64 = scope.generation
proc retention*(scope: TaskScope): TaskRetention = scope.retentionPolicy
proc newTaskHandleInternal*(domain: TaskDomain, id: uint64): TaskHandle =
  TaskHandle(domain: domain, identity: id)
proc taskDomainInternal*(handle: TaskHandle): TaskDomain = handle.domain
proc taskIdInternal*(handle: TaskHandle): uint64 = handle.identity
proc newLifecycleContextInternal*(phase: LifecyclePhase, revision: uint64,
    scope: TaskScope): LifecycleContext =
  LifecycleContext(eventPhase: phase, revision: revision, scope: scope)
proc phase*(ctx: LifecycleContext): LifecyclePhase = ctx.eventPhase
proc acceptedRevision*(ctx: LifecycleContext): uint64 = ctx.revision
proc taskScope*(ctx: LifecycleContext): TaskScope = ctx.scope
proc newTaskPumpReportInternal*(delivered, dropped, callbacks, failed: int,
    pending: bool): TaskPumpReport =
  TaskPumpReport(deliveredCount: delivered, droppedCount: dropped,
    callbackCount: callbacks, failedCount: failed, hasPending: pending)
proc delivered*(report: TaskPumpReport): int = report.deliveredCount
proc dropped*(report: TaskPumpReport): int = report.droppedCount
proc callbacks*(report: TaskPumpReport): int = report.callbackCount
proc failed*(report: TaskPumpReport): int = report.failedCount
proc pending*(report: TaskPumpReport): bool = report.hasPending

proc newCancellationSignalInternal*(): ptr TaskCancellationSignalInternal =
  result = createShared(TaskCancellationSignalInternal)
  result.references.store(1)
proc retainCancellationSignalInternal*(signal: ptr TaskCancellationSignalInternal) =
  discard signal.references.fetchAdd(1, moRelaxed)
proc releaseCancellationSignalInternal*(signal: ptr TaskCancellationSignalInternal) =
  if signal != nil and signal.references.fetchSub(1, moAcquireRelease) == 1:
    deallocShared(signal)
proc requestCancellationInternal*(signal: ptr TaskCancellationSignalInternal) {.raises: [].} =
  if signal != nil: signal.requested.store(true, moRelease)
proc workerContextInternal*(signal: ptr TaskCancellationSignalInternal): WorkerContext =
  WorkerContext(signal: signal)
proc cancelled*(ctx: WorkerContext): bool {.raises: [].} =
  ctx.signal != nil and ctx.signal.requested.load(moAcquire)
