import std/[options, unicode, math, tables]
import ./[record, context, errors, callbacks]

proc runValidations*(record: Record) = discard

proc validatePresence*[T](record: Record, field: string, value: T) =
  when T is Option:
    if value.isNone:
      record.errors.add(field, "blank", "is required")
    elif typeof(value.get) is string: validatePresence(record, field, value.get)
  elif T is string:
    if value.strip.len == 0: record.errors.add(field, "blank", "is required")
  else: {.error: "presence validation requires string or Option".}

proc validateMaxLength*[T](record: Record, field: string, value: T, maximum: int) =
  when T is Option:
    if value.isSome: validateMaxLength(record, field, value.get, maximum)
  elif T is string:
    if value.runeLen > maximum:
      record.errors.add(field, "too_long", "must be at most " & $maximum & " characters",
        {"maximum": $maximum}.toTable)
  else: {.error: "maxLength validation requires string or Option[string]".}

proc validateFinite*[T](record: Record, field: string, value: T) =
  when T is Option:
    if value.isSome: validateFinite(record, field, value.get)
  elif T is float:
    if value.classify in {fcNan, fcInf, fcNegInf}:
      record.errors.add(field, "not_finite", "must be finite")
  else: {.error: "finite validation requires float or Option[float]".}

proc validateInOperation*[T: Record](record: T): bool =
  mixin runCallbacks, runValidations
  record.errors.clear()
  runCallbacks(record, beforeValidationPhase)
  if record.operationAborted: return false
  runValidations(record)
  runCallbacks(record, afterValidationPhase)
  not record.errors.hasErrors

proc valid*[T: Record](record: T): bool =
  let db = currentDatabase()
  record.beginOperation(db)
  try: result = validateInOperation(record)
  finally: record.endOperation()
