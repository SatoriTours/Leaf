## Pure clone-isolation test for the variable-row first slice. No platform, no
## Runtime: it only checks that cloneHeightIndex copies both private sequences and
## that measuring either side never touches the other.
import std/[unittest, math]
import leaf/height_index

suite "cloneHeightIndex":
  test "measure on the copy leaves the original prefix/height/total untouched":
    var original = initHeightIndex(5, 24.0)
    original.measure(1, 48.0)
    let before0 = original.height(0)
    let before1 = original.height(1)
    let beforeTotal = original.total
    let beforePrefix2 = original.prefix(2)
    var copy = cloneHeightIndex(original)
    copy.measure(0, 96.0)
    copy.measure(3, 12.5)
    check original.height(0) == before0
    check original.height(1) == before1
    check original.total == beforeTotal
    check original.prefix(2) == beforePrefix2
    check copy.height(0) == 96.0
    check copy.height(3) == 12.5
    check copy.total != original.total

  test "measure on the original leaves the copy untouched":
    var original = initHeightIndex(4, 10.0)
    var copy = cloneHeightIndex(original)
    original.measure(2, 40.0)
    check copy.height(2) == 10.0
    check copy.total == 40.0
    check original.total == 70.0
    check copy.prefix(4) == 40.0
    check original.prefix(4) == 70.0

  test "empty and single-row clones stay legal and independent":
    let empty = cloneHeightIndex(HeightIndex())
    check empty.len == 0
    check empty.total == 0.0
    var one = initHeightIndex(1, 24.0)
    var copy = cloneHeightIndex(one)
    check copy.len == 1
    one.measure(0, 48.0)
    check copy.height(0) == 24.0
    copy.measure(0, 7.0)
    check one.height(0) == 48.0
    check copy.total == 7.0
