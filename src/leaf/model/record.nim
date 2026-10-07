import std/[options, times]
import ../sqlite
import ./[metadata, errors]

type
  RecordLifecycle* = enum newRecord, persisted, destroyed
  Record* = ref object of RootObj
    identity: int64
    lifecycle: RecordLifecycle
    database: Database
    baseline: FieldValues
    lastChanges: ChangeSet
    fieldErrors: ModelErrors
    busy, aborted, canCancel: bool
  TimestampedRecord* = ref object of Record
    created_at*, updated_at*: Option[DateTime]
  RecordState* = object
    identity: int64
    lifecycle: RecordLifecycle
    database: Database
    baseline: FieldValues
    lastChanges: ChangeSet
    created, updated: Option[DateTime]

proc requireRecord*(record: Record) =
  if record == nil: raise newException(ModelUsageError, "model record is nil")
proc id*(record: Record): int64 =
  record.requireRecord()
  record.identity
proc isNewRecord*(record: Record): bool =
  record.requireRecord()
  record.lifecycle == newRecord
proc isPersisted*(record: Record): bool =
  record.requireRecord()
  record.lifecycle == persisted
proc isDestroyed*(record: Record): bool =
  record.requireRecord()
  record.lifecycle == destroyed
proc boundDatabase*(record: Record): Database =
  record.requireRecord()
  record.database
proc originalValues*(record: Record): FieldValues =
  record.requireRecord()
  for value in record.baseline: result.add(value)
proc errors*(record: Record): ModelErrors =
  record.requireRecord()
  if record.fieldErrors == nil: record.fieldErrors = ModelErrors()
  record.fieldErrors
proc savedChanges*(record: Record): ChangeSet =
  record.requireRecord()
  for change in record.lastChanges: result.add(change)
proc captureState*(record: Record): RecordState =
  record.requireRecord()
  result = RecordState(identity: record.identity, lifecycle: record.lifecycle,
    database: record.database, baseline: record.originalValues, lastChanges: record.savedChanges)
  if record of TimestampedRecord:
    result.created = TimestampedRecord(record).created_at
    result.updated = TimestampedRecord(record).updated_at
proc restoreState*(record: Record, state: RecordState) =
  record.requireRecord()
  record.identity = state.identity
  record.lifecycle = state.lifecycle
  record.database = state.database
  record.baseline = state.baseline
  record.lastChanges = state.lastChanges
  if record of TimestampedRecord:
    TimestampedRecord(record).created_at = state.created
    TimestampedRecord(record).updated_at = state.updated
proc markLoaded*(record: Record, db: Database, id: int64, values: FieldValues) =
  record.requireRecord()
  record.identity = id
  record.database = db
  record.lifecycle = persisted
  record.baseline = values
  for pair in record.baseline.mitems:
    if pair.name == "id": pair.value = dbValue(id)
  record.lastChanges = @[]

proc acceptPersistedValues*(record: Record, db: Database, id: int64,
                            values: FieldValues, changes: ChangeSet) =
  record.markLoaded(db, id, values)
  for change in changes: record.lastChanges.add(change)
proc markDestroyed*(record: Record) =
  record.requireRecord()
  record.lifecycle = destroyed

proc beginOperation*(record: Record, db: Database) =
  record.requireRecord()
  if record.busy: raise newException(ModelUsageError, "cannot reenter a model operation on the same record")
  if record.database != nil and record.database != db:
    raise newException(ModelUsageError, "record belongs to another database; use dupRecord to copy")
  record.busy = true
  record.aborted = false
  record.canCancel = false
proc endOperation*(record: Record) =
  record.busy = false
  record.canCancel = false
proc operationAborted*(record: Record): bool = record.aborted
proc setCancellationAllowed*(record: Record, allowed: bool) = record.canCancel = allowed
proc abortOperation*(record: Record) =
  record.requireRecord()
  if not record.canCancel:
    raise newException(ModelUsageError, "abortOperation is only allowed in a before callback")
  record.aborted = true
