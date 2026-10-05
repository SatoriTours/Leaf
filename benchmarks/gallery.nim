## Release runtime evidence for the migrated real application workloads.
## Includes events, render, validation and visible-row construction; excludes GPUI.
import std/[monotimes, times, json, algorithm]
import leaf
import ../example/[stocks, reports, chat]

proc operation(runtime: Runtime, event, listKey: string) =
  discard runtime.dispatch(event, Event(kind: click))
  if listKey.len > 0: discard runtime.materialize(listKey, 0, 10)

var results = newJArray()
for scenario in [("stocks_240_candles", stocksApp(), "stock_tick", ""),
  ("reports_1000_items_10_visible", reportsApp(), "report_refresh", "report_rows"),
  ("chat_1000_items_10_visible", chatApp(), "chat_incoming", "message_list")]:
  let runtime = newRuntime(scenario[1])
  for i in 0..<100: runtime.operation(scenario[2], scenario[3])
  var samples: seq[float64]
  for round in 0..<9:
    let start = getMonoTime()
    for i in 0..<100: runtime.operation(scenario[2], scenario[3])
    samples.add(float64((getMonoTime() - start).inNanoseconds) / 1_000_000.0)
  let rawSamples = samples
  samples.sort()
  if scenario[3].len == 0:
    doAssert runtime.find("stock_frame").node.text == "1000"
  else:
    doAssert runtime.find(scenario[3]).node.listSource.len == 1000
    doAssert runtime.stats.mountedNodes < 1000
    doAssert runtime.stats.cachedItems <= 128
  results.add(%*{"scenario": scenario[0], "warmup_operations": 100,
    "operations_per_sample": 100, "samples_ms": rawSamples,
    "median_us_per_operation": samples[4] * 10, "max_us_per_operation": samples[^1] * 10,
    "runtime": runtime.stats})
stdout.writeLine(pretty(%*{"implementation": "nim", "compiler": NimVersion,
  "platform": hostOS, "architecture": hostCPU, "mode": "release_orc",
  "scope": "runtime events/render/validation/10 visible rows; excludes GPUI layout and drawing",
  "results": results}))
