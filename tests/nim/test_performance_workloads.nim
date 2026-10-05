import std/[unittest, json]
import leaf/performance_report
import ../../benchmarks/[measurement, performance_runtime]

suite "Real persistent runtime performance workloads":
  test "all real scenarios retain valid business state through multiple measured cycles":
    var config = defaultPerformanceConfig()
    config.iterations = 2
    config.warmup = 1
    config.rounds = 2
    config.repeats = 2
    var samples = newJArray()
    runMeasurements(newRuntimeWorkloads(), config, "runtime", newJObject(),
      proc(record: JsonNode) =
        if record["type"].getStr == "sample": samples.add(record))
    validateSamples(samples, config, @RuntimeScenarios)
    for record in samples:
      if record["cycle"].getInt != 2 or record["round"].getInt != 2: continue
      let name = record["scenario"].getStr
      if name in ["counter_events", "stocks_240_candles", "reports_1000_items_10_visible",
          "chat_1000_items_10_visible"]:
        check record["runtime"]["dispatches"].getInt == 9
      if name == "100000_item_scroll_50_visible":
        check record["runtime"]["renders"].getInt == 1
        check record["runtime"]["mountedNodes"].getInt == 151
        check record["runtime"]["cachedItems"].getInt <= 128
      if name == "1000_node_cached_subtree":
        check record["runtime"]["cacheHits"].getInt == 9
