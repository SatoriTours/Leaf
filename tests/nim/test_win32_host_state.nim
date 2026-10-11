import std/unittest
import leaf/backends/win32/host_state

suite "Win32 close state":
  test "repeated close requests merge into one pending":
    var state = CloseState()
    check not state.pending
    requestClose(state)
    requestClose(state)
    requestClose(state)
    check state.pending
    check not state.complete
    markClosePosted(state)
    markClosePosted(state)
    check state.posted

  test "busy tick neither consumes nor spins":
    var state = CloseState()
    requestClose(state)
    check not closeOnTick(state, busy = true)
    check not closeOnTick(state, busy = true)
    check state.pending
    check not state.complete
    # The outermost idle tick may attempt.
    check closeOnTick(state, busy = false)

  test "a tick only attempts while a request is pending":
    var state = CloseState()
    check not closeOnTick(state, busy = false)
    requestClose(state)
    check closeOnTick(state, busy = false)

  test "failed disposal stays pending and retryable":
    var state = CloseState()
    requestClose(state)
    markClosePosted(state)
    check closeOnTick(state, busy = false)
    closeFailed(state)
    check state.pending
    check not state.posted
    check not state.complete
    check closeOnTick(state, busy = false)
    markClosePosted(state)
    closeSucceeded(state)
    check state.complete
    check not state.pending
    check not state.posted

  test "completion is idempotent and never reopens":
    var state = CloseState()
    requestClose(state)
    closeSucceeded(state)
    check state.complete
    closeSucceeded(state)
    closeFailed(state)
    requestClose(state)
    markClosePosted(state)
    check state.complete
    check not state.pending
    check not state.posted
    check not closeOnTick(state, busy = false)

  test "close request survives busy tick and disposal error":
    var state = CloseState()
    requestClose(state)
    requestClose(state)
    markClosePosted(state)
    # Nested/busy ticks must not consume the request or spin.
    check not closeOnTick(state, busy = true)
    check not closeOnTick(state, busy = true)
    check state.pending
    # The outermost tick attempts once and the disposal fails.
    check closeOnTick(state, busy = false)
    closeFailed(state)
    check state.pending
    # The retry merges the posted notification and succeeds.
    markClosePosted(state)
    check state.posted
    check closeOnTick(state, busy = false)
    closeSucceeded(state)
    check state.complete