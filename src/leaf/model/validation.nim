import ./record as record_state
import std/[options, unicode, math, tables]
import ./[context, errors, callbacks]

proc runValidations*(record: Record) = discard

proc validatePresence*[T](record: Record, field: string, value: T) =
  when T is Option:
    if value.isNone:
      record_state.errors(record).add(field, "blank", "is required")
    elif typeof(value.get) is string: validatePresence(record, field, value.get)
  elif T is string:
    if value.strip.len == 0: record_state.errors(record).add(field, "blank", "is required")
  else: {.error: "presence validation requires string or Option".}

proc validateMaxLength*[T](record: Record, field: string, value: T, maximum: int) =
  when T is Option:
    if value.isSome: validateMaxLength(record, field, value.get, maximum)
  elif T is string:
    if value.runeLen > maximum:
      record_state.errors(record).add(field, "too_long", "must be at most " & $maximum & " characters",
        {"maximum": $maximum}.toTable)
  else: {.error: "maxLength validation requires string or Option[string]".}

proc validateFinite*[T](record: Record, field: string, value: T) =
  when T is Option:
    if value.isSome: validateFinite(record, field, value.get)
  elif T is float:
    if value.classify in {fcNan, fcInf, fcNegInf}:
      record_state.errors(record).add(field, "not_finite", "must be finite")
  else: {.error: "finite validation requires float or Option[float]".}

proc validateInOperation*[T: Record](record: T): bool =
  mixin runCallbacks, runValidations
  record_state.errors(record).clear()
  runCallbacks(record, beforeValidationPhase)
  if record_state.operationAborted(record): return false
  runValidations(record)
  runCallbacks(record, afterValidationPhase)
  not record_state.errors(record).hasErrors

proc valid*[T: Record](record: T): bool =
  let db = currentDatabase()
  record.beginOperation(db)
  try: result = validateInOperation(record)
  finally: record.endOperation()
