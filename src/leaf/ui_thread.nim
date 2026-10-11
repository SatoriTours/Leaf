## UI-thread ownership guard for Application execution scopes.
##
## This module is platform-neutral and deliberately does not import any
## graphics or Win32 API. `guardUiApplication` captures the expected owner
## thread at the call site and returns a value copy of the Application whose
## `executionScope` rejects any action that runs off that thread.
##
## Only synchronous exactly-once execution scopes are supported: the wrapper
## rejects an off-thread invocation, a scope that never runs the body, and a
## scope that runs the body more than once. A per-call atomic latch records an
## off-thread body attempt so that a scope which swallows the worker exception
## still fails on the owner's return.
import std/atomics
import ./core

type
  ThreadIdProc* = proc(): uint64 {.closure, raises: [].}
  UiScopeActivity* = ref object
    depth: int

proc newUiScopeActivity*(): UiScopeActivity = UiScopeActivity()
proc busy*(activity: UiScopeActivity): bool {.raises: [].} =
  ## Read on the owning UI thread; includes original scope entry/post-body/exit.
  activity != nil and activity.depth > 0


proc guardedApplication(app: Application, currentThread: ThreadIdProc,
                        activity: UiScopeActivity): Application =
  ## Capture `currentThread()` as the expected owner now, then return a value
  ## copy of `app` whose execution scope enforces that owner. No render,
  ## handler, row builder, validator or preparer runs here.
  if currentThread == nil: fail("guardUiApplication requires a thread id source")
  let expected = currentThread()
  result = app
  let original = app.executionScope
  result.executionScope = proc(body: proc() {.closure.}) =
    # Owner check before the original scope is entered at all.
    if currentThread() != expected:
      fail("UI action must run on the owning thread")
    var calls: Atomic[int]
    calls.store(0)
    var violation: Atomic[bool]
    violation.store(false)
    var authorized: Atomic[bool]
    authorized.store(true)
    proc guardedBody() =
      # A guard violation revokes this call immediately: a body saved by a
      # failed, finished or already-noncompliant scope can never run later.
      if not authorized.load():
        fail("UI guard: this scope invocation no longer authorizes the body")
      if currentThread() != expected:
        authorized.store(false)
        violation.store(true)
        fail("UI body must run on the owning thread")
      let count = calls.fetchAdd(1) + 1
      if count > 1:
        authorized.store(false)
        violation.store(true)
        fail("UI body must run exactly once")
      body()
    var primary: ref CatchableError
    if activity != nil: inc activity.depth
    try:
      if original != nil:
        original(guardedBody)
      else:
        guardedBody()
    except CatchableError as error:
      primary = error
    finally:
      # The synchronous scope call is over: revoke body authorization on every
      # exit path (normal, primary exception, zero body, worker violation).
      authorized.store(false)
      if activity != nil: dec activity.depth
    # Even if the original scope swallowed a worker exception, the latch makes
    # the owner fail instead of silently accepting an unrendered Runtime.
    var secondary = ""
    if violation.load():
      secondary.add("; UI guard: body ran off the owning thread or more than once")
    let observed = calls.load()
    if observed != 1:
      secondary.add("; UI guard: body invoked " & $observed & " time(s)")
    if primary != nil:
      if secondary.len > 0: primary.msg.add(secondary)
      raise primary
    if secondary.len > 0:
      fail("UI guard violation" & secondary)
proc guardUiApplication*(app: Application, currentThread: ThreadIdProc): Application =
  guardedApplication(app, currentThread, nil)

proc guardUiApplication*(app: Application, currentThread: ThreadIdProc,
                         activity: UiScopeActivity): Application =
  ## Same owner/body guard, with full original Scope activity for safe hosts.
  if activity == nil: fail("UI scope activity must not be nil")
  guardedApplication(app, currentThread, activity)
