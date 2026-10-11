import std/unittest
import leaf/core
import leaf/backends/win32/control_ids
suite "host lifetime control IDs":
  test "all command IDs are issued exactly once and exhaustion never wraps":
    var pool: ControlIdPool
    for expected in 1..int(high(uint16)):
      check pool.allocate() == uint16(expected)
    expect UiError: discard pool.allocate()
    expect UiError: discard pool.allocate()
