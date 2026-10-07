import std/options
import ../sqlite
import ./[record, metadata]
export FieldChange, ChangeSet

proc changes*[T: Record](record: T): ChangeSet =
  mixin modelFields, modelValues
  record.requireRecord()
  let current = modelValues(record)
  let previous = record.originalValues
  for field in modelFields(T):
    if field.frameworkManaged: continue
    let value = current.valueFor(field.name)
    let original = if record.isNewRecord: none(SqlValue)
      else: some(previous.valueFor(field.name))
    if original.isNone or original.get != value:
      result.add(FieldChange(field: field.name, before: original, after: some(value)))

proc changed*[T: Record](record: T): bool = record.changes.len > 0

proc dupRecord*[T: Record](record: T): T =
  mixin modelValues, modelFields, assignModelValues
  record.requireRecord()
  result = T()
  var values = modelValues(record)
  for pair in values.mitems:
    if pair.name in ["created_at", "updated_at"]: pair.value = SqlValue(kind: sqlNull)
    elif pair.name == "id": pair.value = dbValue(0'i64)
  assignModelValues(result, values)
