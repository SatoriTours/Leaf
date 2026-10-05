import std/[unittest, json, options, math]
import leaf/performance_report

proc sample(scenario: string, round = 1, cycle = 1, latency = 1.0): JsonNode =
  %*{"scenario": scenario, "round": round, "cycle": cycle,
    "operations": 2, "latency_ms": [latency, latency + 1], "checks_passed": true,
    "resources": {"rss_start_kib": 1000, "rss_after_gc_kib": 1100,
      "heap_after_gc_bytes": 512, "cpu_seconds": 0.01}}

proc report(value: float64): JsonNode =
  %*{"schema": PerformanceSchema, "environment": {"machine": "same", "nim": "2.2.6"},
    "parameters": {"iterations": 2, "warmup": 1, "rounds": 1},
    "summary": {"counter": {"median_round_p95_ms": value}}}

suite "Performance report acceptance":
  test "configuration rejects zero counts nonfinite thresholds and excessive raw observations":
    var config = defaultPerformanceConfig()
    validateConfig(config)
    config.iterations = 0
    expect PerformanceError: validateConfig(config)
    config = defaultPerformanceConfig()
    config.maxRegression = Inf
    expect PerformanceError: validateConfig(config)
    config.maxRegression = NaN
    expect PerformanceError: validateConfig(config)
    config = defaultPerformanceConfig()
    config.rssLimitMiB = some(-1.0)
    expect PerformanceError: validateConfig(config)
    config = defaultPerformanceConfig()
    config.iterations = high(int)
    expect PerformanceError: validateConfig(config)

  test "all scenarios rounds and cycles must appear exactly once":
    var config = defaultPerformanceConfig()
    config.iterations = 2
    config.warmup = 1
    config.rounds = 2
    config.repeats = 2
    var samples = newJArray()
    for cycle in 1..2:
      for round in 1..2:
        for scenario in ["counter", "list"]: samples.add(sample(scenario, round, cycle))
    validateSamples(samples, config, @["counter", "list"])
    var missing = samples.copy()
    missing.elems.setLen(7)
    expect PerformanceError: validateSamples(missing, config, @["counter", "list"])
    var duplicate = samples.copy()
    duplicate.elems[7] = duplicate[0]
    expect PerformanceError: validateSamples(duplicate, config, @["counter", "list"])
    expect PerformanceError: validateSamples(newJArray(), config, @[])
    expect PerformanceError: validateSamples(samples, config, @["counter", "counter"])

  test "wrong counts nonfinite latency missing fields and failed business checks are errors":
    var config = defaultPerformanceConfig()
    config.iterations = 2
    config.warmup = 1
    config.rounds = 1
    for field in ["operations", "latency_ms", "resources", "checks_passed"]:
      let record = sample("counter")
      record.delete(field)
      expect PerformanceError: validateSamples(%*[record], config, @["counter"])
    for value in [NaN, Inf, -1.0]:
      expect PerformanceError: validateSamples(%*[sample("counter", latency = value)], config, @["counter"])
    let failed = sample("counter")
    failed["checks_passed"] = %false
    expect PerformanceError: validateSamples(%*[failed], config, @["counter"])
    let wrong = sample("counter")
    wrong["operations"] = %3
    expect PerformanceError: validateSamples(%*[wrong], config, @["counter"])

  test "round distributions retain maxima and use median of round percentiles":
    var config = defaultPerformanceConfig()
    config.iterations = 2
    config.warmup = 1
    config.rounds = 3
    let records = %*[sample("counter", 1, latency = 100),
      sample("counter", 2, latency = 2), sample("counter", 3, latency = 1)]
    validateSamples(records, config, @["counter"])
    let summary = summarizeCycle(records, 1)
    check summary["counter"]["median_round_p95_ms"].getFloat == 3
    check summary["counter"]["max_round_max_ms"].getFloat == 101
    check summary["counter"]["operations"].getInt == 6
    check percentile(@[4.0, 1.0, 3.0, 2.0], 0.5) == 2
    expect PerformanceError: discard percentile(@[], 0.95)

  test "latency thresholds accept equality and reject actual slowdown":
    check compareReports(report(1.25), report(1), 0.25).len == 0
    check compareReports(report(1.26), report(1), 0.25).len == 1
    check compareReports(report(0), report(0), 0.25).len == 0
    check compareReports(report(0.01), report(0), 0.25).len == 1
    let current = report(1)
    check budgetFailures(current["summary"], 1).len == 0
    check budgetFailures(current["summary"], 0.99).len == 1

  test "incompatible machines toolchains parameters schemas and scenario sets cannot compare":
    for field in ["environment", "parameters", "schema"]:
      let current = report(1)
      current[field] = %"different"
      expect PerformanceError: discard compareReports(current, report(1), 0.25)
    let current = report(1)
    current["summary"]["extra"] = %*{"median_round_p95_ms": 1}
    expect PerformanceError: discard compareReports(current, report(1), 0.25)
    current["summary"].delete("extra")
    current["summary"]["counter"].delete("median_round_p95_ms")
    expect PerformanceError: discard compareReports(current, report(1), 0.25)

  test "RSS growth uses the initial post-warmup baseline and missing RSS is not zero":
    let records = %*[sample("counter")]
    check rssFailures(records, 100.0 / 1024).len == 0
    check rssFailures(records, 99.0 / 1024).len == 1
    # A later round's fresh start must not hide cumulative retained growth.
    records[0]["resources"]["rss_start_kib"] = %1100
    check rssFailures(records, 99.0 / 1024, some(1000.0)).len == 1
    records[0]["resources"]["rss_after_gc_kib"] = newJNull()
    expect PerformanceError: discard rssFailures(records, 64)
