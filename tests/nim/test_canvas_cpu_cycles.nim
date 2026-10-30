import std/unittest
import leaf/backends/win32/canvas_cpu_probe

suite "bounded Canvas diagnostic CPU cycle accounting":
  test "counter deltas preserve full width and reject backwards observations":
    check cycleDelta(900'u64,100'u64)==800'u64
    check cycleDelta(high(uint64),high(uint64)-9)==9'u64
    expect ValueError: discard cycleDelta(10'u64,11'u64)

  test "framework attribution removes only the two enclosed native stages":
    check frameworkCycles(1000'u64,200'u64,300'u64)==500'u64
    check frameworkCycles(0'u64,0'u64,0'u64)==0'u64
    check frameworkCycles(high(uint64),1'u64,high(uint64)-1)==0'u64

  test "invalid overlap is rejected without unsigned overflow or clipping":
    expect ValueError: discard frameworkCycles(100'u64,101'u64,0'u64)
    expect ValueError: discard frameworkCycles(100'u64,80'u64,21'u64)
    expect ValueError: discard frameworkCycles(high(uint64),high(uint64),1'u64)
