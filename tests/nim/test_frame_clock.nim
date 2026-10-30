import std/unittest
import leaf/frame_clock

suite "bounded120Hz frame deadlines":
 test "first deadline is one120Hz interval ahead":
  check nextFrameDeadline(0,1_000_000_000)==1_008_333_333
 test "early messages do not move a pending deadline":
  check nextFrameDeadline(1_008_333_333,1_004_000_000)==1_008_333_333
 test "late frame advances on the original grid without catch-up":
  check nextFrameDeadline(1_008_333_333,1_030_000_000)==1_033_333_332
 test "exact due deadline advances once":
  check nextFrameDeadline(1_008_333_333,1_008_333_333)==1_016_666_666
 test "waitable100ns interval rounds up and never arms zero":
  check frameDue100ns(1_008_333_333,1_000_000_000)== -83_334
  check frameDue100ns(1_000,1_000)== -1
  check frameDue100ns(1_000,1_001)== -1
 test "invalid clock values and overflow fail closed":
  expect ValueError:discard nextFrameDeadline(0,-1)
  expect ValueError:discard nextFrameDeadline(-1,1)
  expect ValueError:discard nextFrameDeadline(0,high(int64))
  expect ValueError:discard frameDue100ns(-1,1)
