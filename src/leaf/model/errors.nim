## Model failures are distinct from SQLite failures and callback cancellation.
import std/tables
type
  DatabaseContextError* = object of ValueError
  ModelUsageError* = object of ValueError
  RecordNotFound* = object of KeyError
  RecordInvalid* = object of ValueError
  RecordNotSaved* = object of ValueError
  RecordNotDestroyed* = object of ValueError
  PostCommitError* = object of CatchableError
    callbackErrors: seq[string]
  ModelError* = object
    field*, code*, message*: string
    params*: Table[string, string]
  ModelErrors* = ref object
    entries: seq[ModelError]

proc add*(errors: ModelErrors, field, code, message: string,
          params: Table[string, string] = initTable[string, string]()) =
  errors.entries.add(ModelError(field: field, code: code, message: message, params: params))
proc forField*(errors: ModelErrors, field: string): seq[ModelError] =
  for entry in errors.entries:
    if entry.field == field: result.add(entry)
proc fullMessages*(errors: ModelErrors): seq[string] =
  for entry in errors.entries:
    result.add(if entry.field.len == 0: entry.message else: entry.field & " " & entry.message)
proc clear*(errors: ModelErrors) = errors.entries.setLen(0)
proc hasErrors*(errors: ModelErrors): bool = errors.entries.len > 0

proc committed*(error: ref PostCommitError): bool = true
proc details*(error: ref PostCommitError): seq[string] =
  for message in error.callbackErrors: result.add(message)
proc newPostCommitError*(messages: seq[string]): ref PostCommitError =
  result = newException(PostCommitError, "database committed; " & $messages.len & " afterCommit callback(s) failed")
  for message in messages: result.callbackErrors.add(message)
