import ./record as record_state
import ./[metadata]

type
  OperationKind* = enum createOperation, updateOperation, destroyOperation
  CallbackPhase* = enum
    beforeValidationPhase, afterValidationPhase, beforeSavePhase, afterSavePhase,
    beforeCreatePhase, afterCreatePhase, beforeUpdatePhase, afterUpdatePhase,
    beforeDestroyPhase, afterDestroyPhase, afterCommitPhase, afterRollbackPhase
  ModelEvent* = ref object
    eventOperation: OperationKind
    delta: ChangeSet

proc isBefore*(phase: CallbackPhase): bool =
  phase in {beforeValidationPhase, beforeSavePhase, beforeCreatePhase,
    beforeUpdatePhase, beforeDestroyPhase}
proc newModelEvent*(operation: OperationKind, changes: ChangeSet): ModelEvent =
  result = ModelEvent(eventOperation: operation)
  for change in changes: result.delta.add(change)
proc operation*(event: ModelEvent): OperationKind = event.eventOperation
proc eventChanges*(event: ModelEvent): ChangeSet =
  for change in event.delta: result.add(change)

proc runCallbacks*(record: Record, phase: CallbackPhase, event: ModelEvent = nil) = discard

proc invokeCallback*[T: Record](record: T, phase: CallbackPhase,
                               callback: proc(record: T) {.closure.}) =
  if phase.isBefore and record_state.operationAborted(record): return
  record.setCancellationAllowed(phase.isBefore)
  try: callback(record)
  finally: record.setCancellationAllowed(false)

proc invokeEventCallback*[T: Record](record: T, event: ModelEvent,
                                    callback: proc(record: T, event: ModelEvent) {.closure.}) =
  callback(record, event)
