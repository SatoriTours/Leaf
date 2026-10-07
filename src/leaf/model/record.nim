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
