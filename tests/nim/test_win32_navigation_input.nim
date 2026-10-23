import std/unittest
import leaf/core
import leaf/backends/win32/navigation_input

suite "Win32 navigation input boundary":
  test "Alt Left requires system-key Alt context and distinguishes repeats":
    check navigationInput(0x0104, 0x25, 1 shl 29) == backKey
    check navigationInput(0x0104, 0x25, (1 shl 29) or (1 shl 30)) == repeatedBackKey
    check navigationInput(0x0104, 0x25, 0) == noNavigationInput
    check navigationInput(0x0100, 0x25, 1 shl 29) == noNavigationInput
    check navigationInput(0x0105, 0x25, 1 shl 29) == noNavigationInput
    check navigationInput(0x0104, 0x26, 1 shl 29) == noNavigationInput
  test "browser back masks device bits without treating forward as back":
    check navigationInput(0x0319, 0, 1 shl 16) == backCommand
    check navigationInput(0x0319, 0, 0x8001 shl 16) == backCommand
    check navigationInput(0x0319, 0, 2 shl 16) == noNavigationInput
    check navigationInput(0x0319, 0, 0) == noNavigationInput
  test "ordinary editor keys and commands are not navigation":
    for key in [8, 13, 27, 0x25]:
      check navigationInput(0x0100, uint(key), 0) == noNavigationInput
    check navigationInput(0x0102, 8, 0) == noNavigationInput
    check navigationInput(0x0111, 1, 0) == noNavigationInput
  test "request identity advances across backend-local sequence resets":
    var retained = 0'u64
    check advanceBackRequest(retained) == 1
    var sequence = 17
    sequence = 0 # A rebind resets event sequence, not this UI-owner counter.
    check advanceBackRequest(retained) == 2
    check sequence == 0
    retained = high(uint64)
    expect UiError: discard advanceBackRequest(retained)
    check retained == high(uint64)
