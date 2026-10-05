## Measures native update cost separately from future GPU/layout cost.
import std/[monotimes, times, json, algorithm]
import leaf
import ../examples/counter

proc elapsed(start: MonoTime): float64 =
  float64((getMonoTime() - start).inNanoseconds) / 1_000_000.0

proc summary(name: string, samples: seq[float64], operations: int,
             stats: PerformanceStats): JsonNode =
  var sorted = samples
  sorted.sort()
  %*{"scenario": name, "operations_per_sample": operations,
    "median_ms": sorted[sorted.len div 2],
    "max_ms": sorted[^1],
    "median_us_per_operation": sorted[sorted.len div 2] * 1000 / float64(operations),
    "runtime": stats}

var report = newJArray()
block:
  let runtime = newRuntime(counterApp())
  for i in 0..<1000: discard runtime.dispatch("add", Event(kind: click))
  var samples: seq[float64]
  for round in 0..<9:
    let start = getMonoTime()
    for i in 0..<10_000: discard runtime.dispatch("add", Event(kind: click))
    samples.add(elapsed(start))
  doAssert runtime.find("count").node.text == "91000"
  report.add(summary("counter_events", samples, 10_000, runtime.stats))
block:
  var keys: seq[string]
  for i in 0..<100_000: keys.add($i)
  let list = virtualList("list", keys, proc(i: int): Node =
    row(@[text($i), text("A native Nim row")]), rowHeight = 32)
  let runtime = newRuntime(Application(title: "List", width: 640, height: 480,
    render: proc(ctx: BuildContext): Node = list))
  var samples: seq[float64]
  for round in 0..<9:
    let start = getMonoTime()
    for page in 0..<1000:
      discard runtime.materialize("list", page * 50, page * 50 + 50)
    samples.add(elapsed(start))
  doAssert runtime.stats.mountedNodes == 151
  doAssert runtime.stats.cachedItems <= 128
  report.add(summary("100000_item_scroll_50_visible", samples, 1000, runtime.stats))
block:
  var builds = 0
  let runtime = newRuntime(Application(title: "Cache", width: 640, height: 480,
    render: proc(ctx: BuildContext): Node =
      ctx.cached("table", "1", proc(): Node =
        inc builds
        var nodes: seq[Node]
        for i in 0..<1000: nodes.add(text($i))
        column(nodes))))
  var samples: seq[float64]
  for round in 0..<9:
    let start = getMonoTime()
    for i in 0..<1000: discard runtime.refresh()
    samples.add(elapsed(start))
  doAssert builds == 1
  report.add(summary("1000_node_cached_subtree", samples, 1000, runtime.stats))
block:
  var heights = initHeightIndex(100_000, 40)
  var samples: seq[float64]
  var checksum = 0
  for round in 0..<9:
    let start = getMonoTime()
    for i in 0..<100_000:
      heights.measure(i, float64(20 + i mod 60))
      checksum += heights.visible(float64(i * 30), 800).first
    samples.add(elapsed(start))
  doAssert checksum > 0
  report.add(summary("100000_variable_height_updates", samples, 100_000, PerformanceStats()))
stdout.writeLine(pretty(%*{"compiler": NimVersion, "memory_manager": "orc",
  "platform": hostOS, "architecture": hostCPU, "scope": "native runtime; excludes layout and GPU",
  "samples": 9, "results": report}))
