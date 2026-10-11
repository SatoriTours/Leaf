## Pure close-request state for a native host.
##
## A close request is merged with any pending request, is never consumed by a
## busy tick, and only completes after a real dispose success. A failed dispose
## keeps the request pending so a later safe tick can retry, and completion is
## idempotent. This module has no platform dependency.
##
## `posted` records that the WM_APP/timer safe tick is already scheduled, so
## repeated requests merge into a single posted notification.

type
  CloseState* = object
    ## `pending` - a close request is outstanding (not yet completed).
    ## `posted`  - a safe tick is already scheduled for the pending request.
    ## `complete`- the host finished disposing the window/session.
    pending*: bool
    posted*: bool
    complete*: bool

proc requestClose*(s: var CloseState) =
  ## Merge a close request. Repeating while pending changes nothing, and a
  ## completed close never reopens.
  if s.complete: return
  s.pending = true

proc markClosePosted*(s: var CloseState) =
  ## Merge the WM_APP/timer scheduling into one posted notification.
  if s.complete: return
  if s.pending: s.posted = true

proc closeOnTick*(s: var CloseState, busy: bool): bool =
  ## True when this tick may attempt disposal. The pending request is not
  ## consumed here: a busy tick must neither consume nor spin. The caller runs
  ## the real dispose attempt and then calls `closeSucceeded`/`closeFailed`.
  if s.complete: return false
  if not s.pending: return false
  if busy: return false
  return true

proc closeSucceeded*(s: var CloseState) =
  ## Complete only after a real dispose success; idempotent.
  if s.complete: return
  s.complete = true
  s.pending = false
  s.posted = false

proc closeFailed*(s: var CloseState) =
  ## A failed dispose leaves the request pending for a later safe tick and
  ## clears `posted` so the retry can schedule a new notification.
  if s.complete: return
  s.pending = true
  s.posted = false