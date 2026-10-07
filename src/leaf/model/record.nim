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
  TimestampedRecord* = ref object of Record
    created_at*, updated_at*: Option[DateTime]

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
proc markLoaded*(record: Record, db: Database, id: int64, values: FieldValues) =
  record.requireRecord()
  record.identity = id
  record.database = db
  record.lifecycle = persisted
  record.baseline = values
  for pair in record.baseline.mitems:
    if pair.name == "id": pair.value = dbValue(id)
