## Rails-style model declarations; importing this module never opens a database.
import std/[options, times]
import ./model/[record, context, declarations, changes, validation, callbacks]
import ./model/errors as model_errors
export options, times, model_errors, declarations, changes
export Record, TimestampedRecord, id, isNewRecord, isPersisted, isDestroyed
export withDatabase, currentDatabase
export errors, savedChanges
export valid, abortOperation, ModelEvent, OperationKind
export operation, eventChanges
