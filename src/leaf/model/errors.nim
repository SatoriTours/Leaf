## Model failures are distinct from SQLite failures and callback cancellation.
type
  DatabaseContextError* = object of ValueError
  ModelUsageError* = object of ValueError
  RecordNotFound* = object of KeyError
  RecordInvalid* = object of ValueError
  RecordNotSaved* = object of ValueError
  RecordNotDestroyed* = object of ValueError
  PostCommitError* = object of CatchableError
    callbackErrors: seq[string]

proc committed*(error: ref PostCommitError): bool = true
proc details*(error: ref PostCommitError): seq[string] =
  for message in error.callbackErrors: result.add(message)
proc newPostCommitError*(messages: seq[string]): ref PostCommitError =
  result = newException(PostCommitError, "database committed; " & $messages.len & " afterCommit callback(s) failed")
  for message in messages: result.callbackErrors.add(message)
