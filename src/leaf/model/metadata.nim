## Persistent values and metadata, independent of business object runtime state.
import std/[options, times, strutils]
import ../sqlite
import ./errors

type
  FieldMeta* = object
    name*, sqlType*: string
    nullable*, frameworkManaged*: bool
  FieldValues* = seq[tuple[name: string, value: SqlValue]]

proc quoteIdentifier*(name: string): string =
  if name.len == 0 or '\0' in name:
    raise newException(ModelUsageError, "invalid SQL identifier")
  "\"" & name.replace("\"", "\"\"") & "\""

proc fieldValue*(value: string): SqlValue = dbValue(value)
proc fieldValue*(value: bool): SqlValue = dbValue(value)
proc fieldValue*(value: int): SqlValue = dbValue(value)
proc fieldValue*(value: int64): SqlValue = dbValue(value)
proc fieldValue*(value: float): SqlValue = dbValue(value)
proc fieldValue*(value: DateTime): SqlValue = dbValue(value.toTime.toUnixFloat)
proc fieldValue*[T](value: Option[T]): SqlValue =
  if value.isSome: fieldValue(value.get) else: SqlValue(kind: sqlNull)

proc fieldFromValue*(value: SqlValue, _: typedesc[string]): string = value.asString
proc fieldFromValue*(value: SqlValue, _: typedesc[bool]): bool = value.asBool
proc fieldFromValue*(value: SqlValue, _: typedesc[int]): int = value.asInt
proc fieldFromValue*(value: SqlValue, _: typedesc[int64]): int64 = value.asInt64
proc fieldFromValue*(value: SqlValue, _: typedesc[float]): float = value.asFloat
proc fieldFromValue*(value: SqlValue, _: typedesc[DateTime]): DateTime = value.asFloat.fromUnixFloat.utc
proc fieldFromValue*[T](value: SqlValue, _: typedesc[Option[T]]): Option[T] =
  if value.kind == sqlNull: none(T) else: some(fieldFromValue(value, T))

proc fieldMetadata*[T](_: typedesc[T], name: string, managed = false): FieldMeta =
  result.name = name
  result.frameworkManaged = managed
  when T is Option:
    result = fieldMetadata(typeof(default(T).get), name, managed)
    result.nullable = true
  elif T is string: result.sqlType = "TEXT"
  elif T is bool or T is int or T is int64: result.sqlType = "INTEGER"
  elif T is float or T is DateTime: result.sqlType = "REAL"
  else: {.error: "unsupported persistent model field type".}

proc valueFor*(values: FieldValues, field: string): SqlValue =
  for pair in values:
    if pair.name == field: return pair.value
  raise newException(ModelUsageError, "missing persistent field: " & field)
