## Public lifecycle registration on an open component initialization frame.
import ./[component_description, task_service, task_contracts]
export task_contracts.TaskRetention, task_contracts.TaskScope,
  task_contracts.LifecyclePhase, task_contracts.LifecycleContext,
  task_contracts.LifecycleCallback, task_contracts.TaskPumpReport,
  task_contracts.phase, task_contracts.acceptedRevision, task_contracts.taskScope,
  task_contracts.retention, task_contracts.delivered, task_contracts.dropped,
  task_contracts.callbacks, task_contracts.failed, task_contracts.pending

proc register(ctx: MountContext, kind: LifecyclePhase, callback: LifecycleCallback) =
  let registration = ctx.lifecycleRegistrationInternal()
  let bytes = registration.lifecycleChargeInternal(kind, callback)
  ctx.accountOwnedDescriptionBytes(bytes)
  registration.registerLifecycleInternal(kind, callback)

proc onMount*(ctx: MountContext, callback: LifecycleCallback) =
  ctx.register(LifecyclePhase.mount, callback)
proc onActivate*(ctx: MountContext, callback: LifecycleCallback) =
  ctx.register(LifecyclePhase.activate, callback)
proc onDeactivate*(ctx: MountContext, callback: LifecycleCallback) =
  ctx.register(LifecyclePhase.deactivate, callback)
proc onDispose*(ctx: MountContext, callback: LifecycleCallback) =
  ctx.register(LifecyclePhase.dispose, callback)
