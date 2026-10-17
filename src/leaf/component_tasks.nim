## UI task intents. Only TaskWork and copied bytes cross the worker boundary.
import ./[core, component_description, task_service, task_contracts]
export task_contracts.TaskScope, task_contracts.TaskHandle, task_contracts.TaskWork,
  task_contracts.WorkerContext, task_contracts.TaskResultHandler,
  task_contracts.TaskErrorHandler, task_contracts.TaskFailure,
  task_contracts.TaskFailureKind, task_contracts.TaskRetention,
  task_contracts.cancelled, task_contracts.kind, task_contracts.message,
  task_contracts.retention, task_contracts.taskScope

proc taskScope*(ctx: MountContext, retention = cancelOnDeactivate): TaskScope =
  let registration = ctx.lifecycleRegistrationInternal()
  let bytes = registration.scopeChargeInternal()
  ctx.accountOwnedDescriptionBytes(bytes)
  registration.configureScopeInternal(retention)

proc startTask*(scope: TaskScope, key: string, input: string,
    work: TaskWork, onResult: TaskResultHandler,
    onError: TaskErrorHandler = nil, maxResultBytes = 65536): TaskHandle =
  let domain = scope.taskDomainInternal
  if not (domain of TaskService): fail("missing task scope")
  TaskService(domain).startTaskInternal(scope, key, input, work, onResult, onError, maxResultBytes)

proc cancel*(task: TaskHandle) =
  let domain = task.taskDomainInternal
  if domain == nil: return
  if not (domain of TaskService): fail("invalid task handle")
  TaskService(domain).cancelTaskInternal(task)
