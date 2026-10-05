import std/[unittest, random, math, sequtils, strutils]
import leaf

proc listRuntime(count: int, build: RowBuilder): Runtime =
  var keys: seq[string]
  for i in 0..<count: keys.add("item/" & $i)
  let list = virtualList("list", keys, build, rowHeight = 32)
  newRuntime(Application(title: "List", width: 640, height: 480,
    render: proc(ctx: BuildContext): Node = column(@[list])))

suite "Virtual list runtime":
  test "100000 items build only requested rows":
    var built = 0
    let runtime = listRuntime(100_000, proc(i: int): Node =
      inc built
      text($i))
    check built == 0
    let rows = runtime.materialize("list", 40_000, 40_020)
    check rows.len == 20
    check rows[0].node.text == "40000"
    check runtime.find("item/40000").node.text == "40000"
    check rows[0].id == "i:0/k:4:list/k:10:item/40000"
    check runtime.stats.mountedNodes == 22
    check built == 20
    discard runtime.materialize("list", 40_010, 40_030)
    check built == 30
    check runtime.stats.rowCacheHits == 10

  test "LRU cache remains bounded during long scrolling":
    let runtime = listRuntime(1000, proc(i: int): Node = text($i))
    for i in countup(0, 980, 20):
      discard runtime.materialize("list", i, i + 20)
      check runtime.stats.cachedItems <= 128
      check runtime.stats.mountedNodes == 22
    let built = runtime.stats.builtItems
    discard runtime.materialize("list", 980, 1000)
    check runtime.stats.builtItems == built
    discard runtime.materialize("list", 0, 20)
    check runtime.stats.builtItems == built + 20

  test "focused rows remain mounted outside the viewport":
    let runtime = listRuntime(500, proc(i: int): Node = input($i, key = "entry"))
    discard runtime.materialize("list", 0, 10)
    let focused = runtime.snapshot.root.children[0].children[0].id
    discard runtime.materialize("list", 200, 210, protected = @[0])
    check runtime.find(focused).node.text == "0"
    check runtime.stats.mountedNodes == 13
    discard runtime.materialize("list", 400, 410)
    expect UiError: discard runtime.find(focused)

  test "offscreen cached callbacks cannot be dispatched":
    var clicked = -1
    let runtime = listRuntime(500, proc(i: int): Node =
      button($i, key = "button", onClick = proc(e: Event) = clicked = i))
    let first = runtime.materialize("list", 0, 1)[0].id
    discard runtime.materialize("list", 100, 101)
    expect UiError: discard runtime.dispatch(first, Event(kind: click))
    check clicked == -1

  test "failed row builder preserves committed tree and cache":
    var broken = false
    let runtime = listRuntime(500, proc(i: int): Node =
      if broken and i == 101: raise newException(ValueError, "bad row")
      text($i))
    discard runtime.materialize("list", 0, 20)
    let old = runtime.snapshot.root
    let stats = runtime.stats
    broken = true
    expect ValueError: discard runtime.materialize("list", 100, 110)
    check runtime.snapshot.root == old
    check runtime.stats.cachedItems == stats.cachedItems
    check runtime.stats.builtItems == stats.builtItems
    broken = false
    discard runtime.materialize("list", 100, 110)
    check runtime.stats.builtItems == stats.builtItems + 10

  test "unchanged sources keep warm rows across state renders":
    let runtime = listRuntime(1000, proc(i: int): Node = text($i))
    discard runtime.materialize("list", 0, 20)
    discard runtime.refresh()
    check runtime.stats.cachedItems == 20
    discard runtime.materialize("list", 0, 20)
    check runtime.stats.builtItems == 20

  test "replaced sources invalidate row cache":
    var version = 1
    let runtime = newRuntime(Application(title: "List", width: 640, height: 480,
      render: proc(ctx: BuildContext): Node =
        virtualList("list", @["a", "b"], proc(i: int): Node = text($version))))
    discard runtime.materialize("list", 0, 2)
    version = 2
    discard runtime.refresh()
    check runtime.stats.cachedItems == 0
    check runtime.materialize("list", 0, 1)[0].node.text == "2"

  test "invalid descriptor, ranges and active row budgets are rejected":
    expect UiError: discard virtualList("bad", @["a", "a"], proc(i: int): Node = text(""))
    expect UiError: discard virtualList("bad", @[], proc(i: int): Node = text(""), rowHeight = NaN)
    expect UiError: discard virtualList("bad", @[], proc(i: int): Node = text(""), estimatedHeight = Inf)
    expect UiError: discard virtualList("bad", @[], proc(i: int): Node = text(""), overscan = 33)
    let runtime = listRuntime(500, proc(i: int): Node = text($i))
    expect UiError: discard runtime.materialize("list", -1, 1)
    expect UiError: discard runtime.materialize("list", 0, 501)
    check runtime.stats.cachedItems == 0

  test "large viewports keep active rows while bounding warm cache":
    let runtime = listRuntime(500, proc(i: int): Node = text($i))
    check runtime.materialize("list", 0, 200).len == 200
    check runtime.stats.cachedItems == 128
    check runtime.stats.mountedNodes == 202
    discard runtime.materialize("list", 0, 200)
    check runtime.stats.builtItems == 200
    discard runtime.materialize("list", 400, 410, protected = @[0])
    check runtime.find("i:0/k:4:list/k:6:item/0").node.text == "0"

  test "row cache byte budget rejects oversized active rows atomically":
    let runtime = listRuntime(50, proc(i: int): Node = text(repeat('x', MaxStringBytes)))
    let old = runtime.snapshot.root
    expect UiError: discard runtime.materialize("list", 0, 17)
    check runtime.snapshot.root == old

  test "lazy rows share the committed UI and subtree description budget":
    let payload = repeat('x', MaxStringBytes)
    let runtime = newRuntime(Application(title: "Combined budget", width: 640, height: 480,
      render: proc(ctx: BuildContext): Node =
        discard ctx.cached("large", "1", proc(): Node =
          var nodes: seq[Node]
          for i in 0..<8: nodes.add(text(payload))
          column(nodes))
        var keys: seq[string]
        for i in 0..<20: keys.add($i)
        virtualList("list", keys, proc(i: int): Node = text(payload))))
    let old = runtime.snapshot.root
    expect UiError: discard runtime.materialize("list", 0, 9)
    check runtime.snapshot.root == old
    check runtime.stats.cachedItems == 0

suite "Variable height indexing":
  test "exact edges and viewport clamping":
    var heights = initHeightIndex(1000, 40)
    check heights.rowAt(0) == 0
    check heights.rowAt(40) == 1
    check heights.rowAt(39.5) == 0
    check heights.rowAt(40_000) == 1000
    check heights.visible(0, 400, 0).first == 0
    check heights.visible(0, 400, 0).finish == 10
    check heights.visible(0, 400, 2).finish == 12
    check heights.visible(100_000, 400, 0).first == 990
    heights.measure(0, 80)
    check heights.total == 40_040
    check heights.rowAt(79) == 0
    check heights.rowAt(80) == 1

  test "random measurements and lookups agree with a linear oracle":
    var rng = initRand(42)
    var index = initHeightIndex(1000, 40)
    var heights = newSeqWith(1000, 40.0)
    for update in 0..<2000:
      let row = rng.rand(999)
      let height = float64(rng.rand(1..500))
      heights[row] = height
      index.measure(row, height)
      let offset = rng.rand(index.total)
      var expected = 0
      var sum = 0.0
      while expected < heights.len and sum + heights[expected] <= offset:
        sum += heights[expected]
        inc expected
      check index.rowAt(offset) == expected
      check abs(index.prefix(expected) - sum) < 0.00001

  test "empty and invalid viewports and measurements":
    let empty = initHeightIndex(0, 40)
    check empty.visible(100, 500).finish == 0
    check empty.rowAt(1) == 0
    var index = initHeightIndex(10, 40)
    expect UiError: index.measure(0, 0)
    expect UiError: index.measure(0, NaN)
    expect UiError: index.measure(10, 40)
    expect UiError: discard index.visible(NaN, 100)
    expect UiError: discard index.visible(0, Inf)
    expect UiError: discard index.visible(0, -1)
