## Measures native managed-runtime update cost separately from GPU/layout cost.
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
  let ListRoot = defineComponent[int, int]("RuntimeListRoot",
    proc(ctx: MountContext, p: int): int = p,
    proc(ctx: ComponentContext, p, m: int): UiDescription =
      hostShell(column(@[], key = "list-column"),
        @[componentList("list", keys,
          proc(index: int): UiDescription = host(row(@[text($index), text("A native Nim row")])),
          rowHeight = 32)]))
  let runtime = newRuntime(componentApplication(component(ListRoot, 0), "List", 640, 480))
  var samples: seq[float64]
  for round in 0..<9:
    let start = getMonoTime()
    for page in 0..<1000:
      discard runtime.materialize("list", page * 50, page * 50 + 50)
    samples.add(elapsed(start))
  doAssert runtime.find("list").node.listSource.len == 100_000
  doAssert runtime.stats.mountedNodes < 1000
  report.add(summary("100000_item_scroll_50_visible", samples, 1000, runtime.stats))
block:
  let StaticRoot = defineComponent[int, int]("RuntimeStaticRoot",
    proc(ctx: MountContext, p: int): int = p,
    proc(ctx: ComponentContext, p, m: int): UiDescription =
      var nodes: seq[UiDescription]
      for i in 0..<1000: nodes.add(host(text($i)))
      hostShell(column(@[]), nodes))
  let runtime = newRuntime(componentApplication(component(StaticRoot, 0), "Static", 640, 480))
  var samples: seq[float64]
  for round in 0..<9:
    let start = getMonoTime()
    for i in 0..<1000: discard runtime.refresh()
    samples.add(elapsed(start))
  doAssert runtime.stats.mountedNodes == 1001
  report.add(summary("1000_node_static_subtree", samples, 1000, runtime.stats))
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
  "platform": hostOS, "architecture": hostCPU, "scope": "managed native runtime; excludes layout and GPU",
  "samples": 9, "results": report}))
