import std/unittest
import ../../scripts/test_win32

suite "Windows native suite instrumentation selection":
  test "ordinary native suites retain protocol probes without CPU instrumentation":
    for name in ["test_canvas.nim", "test_animation.nim", "test_win32_host.nim"]:
      check windowsSuiteDefinesInternal(name) == @["-d:leafProtocolProbes"]

  test "CPU instrumentation suite explicitly enables its required clocks":
    check windowsSuiteDefinesInternal("test_canvas_performance.nim") ==
      @["-d:leafProtocolProbes", "-d:leafCanvasMeasure"]
