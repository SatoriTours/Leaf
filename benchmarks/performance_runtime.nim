## Real Nim runtime workloads. Instances and bounded sources persist across cycles.
import std/json
import leaf
import leaf/performance_report
import leaf/performance_scenarios
export performance_scenarios
import ./measurement
import ../examples/counter
import ../example/[stocks, reports, chat]

proc require(condition: bool, message: string) =
  if not condition: raise newException(PerformanceError, message)

proc counterWorkload(): Workload =
  let runtime = newRuntime(counterApp())
  var performed = 0
  result = Workload(name: RuntimeScenarios[0])
  result.operation = proc() =
    require(runtime.dispatch("add", Event(kind: click)), "counter dispatch failed")
    inc performed
  result.verify = proc() =
    require(runtime.find("count").node.text == $performed, "counter result differs")
    require(runtime.stats.mountedNodes == 7, "counter mounted tree differs")
  result.counters = proc(): JsonNode = %runtime.stats

proc staticWorkload(): Workload =
  var performed = 0
  let StaticRoot = defineComponent[int, int]("PerformanceStaticRoot",
    proc(ctx: MountContext, p: int): int = p,
    proc(ctx: ComponentContext, p, m: int): UiDescription =
      var leaves: seq[UiDescription]
      for i in 0..<1000: leaves.add(host(text($i)))
      hostShell(column(@[]), leaves))
  let runtime = newRuntime(componentApplication(component(StaticRoot, 0), "Static", 640, 480))
  result = Workload(name: RuntimeScenarios[1])
  result.operation = proc() =
    require(runtime.refresh(), "static update failed")
    inc performed
  result.verify = proc() =
    require(runtime.stats.renders > 0 and runtime.stats.mountedNodes == 1001,
      "static subtree node count differs")
  result.counters = proc(): JsonNode = %runtime.stats

proc viewportWorkload(): Workload =
  var keys: seq[string]
  for i in 0..<100000: keys.add($i)
  let list = virtualList("list", keys, proc(i: int): Node =
    row(@[text($i), text("Native Nim row")]), rowHeight = 32)
  let ListRoot = defineComponent[int, int]("PerformanceViewportRoot",
    proc(ctx: MountContext, p: int): int = p,
    proc(ctx: ComponentContext, p, m: int): UiDescription =
      hostShell(column(@[], key = "viewport-column"),
        @[componentList("list", keys,
          proc(index: int): UiDescription = host(row(@[text($index), text("Native Nim row")])),
          rowHeight = 32)]))
  let runtime = newRuntime(componentApplication(component(ListRoot, 0), "Viewport", 640, 480))
  var performed = 0
  result = Workload(name: RuntimeScenarios[2])
  result.operation = proc() =
    let first = (performed mod 2000) * 50
    require(runtime.materialize("list", first, first + 50).len == 50, "virtual viewport failed")
    inc performed
  result.verify = proc() =
    require(runtime.stats.mountedNodes < 1000, "virtual viewport boundary differs")
    require(runtime.find("list").node.listSource.len == 100000, "virtual source changed")
  result.counters = proc(): JsonNode = %runtime.stats

proc heightWorkload(): Workload =
  var index = initHeightIndex(100000, 40)
  var performed, last = 0
  var measured = 40.0
  var visible: VisibleRange
  result = Workload(name: RuntimeScenarios[3])
  result.operation = proc() =
    last = performed mod index.len
    measured = float64(20 + performed mod 60)
    index.measure(last, measured)
    visible = index.visible(float64(last * 30), 800)
    inc performed
  result.verify = proc() =
    require(index.len == 100000 and index.height(last) == measured, "height update differs")
    require(visible.first >= 0 and visible.finish <= index.len and visible.finish > visible.first,
      "height viewport range invalid")
    require(visible.total >= 2000000 and visible.total <= 8000000, "height extent invalid")
  result.counters = proc(): JsonNode = %*{"rows": index.len, "operations": performed,
    "total_height": visible.total, "visible_first": visible.first, "visible_finish": visible.finish}

proc applicationWorkload(name: string, app: Application, event: string,
                         listKey = "", frameKey = ""): Workload =
  let runtime = newRuntime(app)
  var performed = 0
  result = Workload(name: name)
  result.operation = proc() =
    require(runtime.dispatch(event, Event(kind: click)), name & " business dispatch failed")
    if listKey.len > 0:
      require(runtime.materialize(listKey, 0, 10).len == 10, name & " visible rows failed")
    inc performed
  result.verify = proc() =
    require(runtime.stats.dispatches == uint64(performed), name & " event count differs")
    if frameKey.len > 0:
      require(runtime.find(frameKey).node.text == $performed, name & " business frame differs")
    if listKey.len > 0:
      require(runtime.find(listKey).node.listSource.len == 1000, name & " source bound differs")
      require(runtime.stats.mountedNodes < 1000, name & " virtualization bound differs")
  result.counters = proc(): JsonNode = %runtime.stats

proc newRuntimeWorkloads*(): seq[Workload] =
  @[counterWorkload(), staticWorkload(), viewportWorkload(), heightWorkload(),
    applicationWorkload(RuntimeScenarios[4], stocksApp(), "stock_tick", frameKey = "stock_frame"),
    applicationWorkload(RuntimeScenarios[5], reportsApp(), "report_refresh", "report_rows"),
    applicationWorkload(RuntimeScenarios[6], chatApp(), "chat_incoming", "message_list")]

when isMainModule:
  try:
    requireRelease()
    let config = harnessConfig()
    runMeasurements(newRuntimeWorkloads(), config, "runtime",
      %*{"scope": "individual operation callback/render/validation/viewport; excludes native drawing, verification and GC; resource window includes verification and GC"},
      emitStdout)
  except CatchableError as error:
    stderr.writeLine("performance runtime: " & error.msg)
    quit(1)
