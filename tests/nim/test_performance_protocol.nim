import std/[unittest, json, strutils]
import leaf/[performance_report, performance_protocol]

# Synthetic protocol fixtures exercise validation, never performance evidence.
proc fixtureConfig(): PerformanceConfig =
  result = defaultPerformanceConfig()
  result.iterations = 2
  result.warmup = 1
  result.rounds = 2
  result.repeats = 2

proc header(config: PerformanceConfig): JsonNode =
  %*{"type": "header", "schema": 2, "group": "runtime",
    "metadata": {"compiler": NimVersion, "platform": hostOS,
      "architecture": hostCPU, "release": true, "memory_manager": "orc",
      "scope": "synthetic protocol fixture"},
    "parameters": {"iterations": config.iterations, "warmup": config.warmup,
      "rounds": config.rounds, "repeats": config.repeats,
      "interval_seconds": config.intervalSeconds}, "scenarios": ["counter"]}

proc sample(cycle, round: int): JsonNode =
  %*{"type": "sample", "group": "runtime", "scenario": "counter",
    "cycle": cycle, "round": round, "operations": 2,
    "latency_ms": [1.0, 2.0], "checks_passed": true,
    "resources": {"rss_start_kib": 1024, "rss_after_gc_kib": 1024,
      "heap_after_gc_bytes": 64, "cpu_seconds": 0.01},
    "elapsed_wall_ms": 3, "runtime": {"operations": cycle * 4 + round * 2}}

proc cycleEnd(cycle: int): JsonNode =
  %*{"type": "cycle_complete", "group": "runtime", "cycle": cycle,
    "samples": 2, "elapsed_wall_ms": cycle * 10}

proc complete(): JsonNode =
  %*{"type": "complete", "group": "runtime", "cycles": 2}

proc line(record: JsonNode): string = "LEAF_PERF " & $record & "\n"

proc validRecords(config: PerformanceConfig): seq[JsonNode] =
  result.add(header(config))
  for cycle in 1..2:
    for round in 1..2: result.add(sample(cycle, round))
    result.add(cycleEnd(cycle))
  result.add(complete())

proc newFixture(): MeasurementProtocol =
  newMeasurementProtocol(fixtureConfig(), "runtime", @["counter"], NimVersion)

suite "Bounded performance subprocess protocol":
  test "fragmented output retains complete raw observations and emits each validated cycle":
    let protocol = newFixture()
    var raw = "GPUI diagnostic: 你好\n"
    for record in validRecords(fixtureConfig()): raw.add(line(record))
    var cycles: seq[int]
    let accept = proc(cycle: int, summary: JsonNode) =
      cycles.add(cycle)
      check summary["counter"]["operations"].getInt == 4
      check summary["counter"]["median_round_p95_ms"].getFloat == 2.0
    for i in countup(0, raw.len - 1, 7):
      protocol.feed(raw[i..<min(i + 7, raw.len)], accept)
    protocol.finish(0)
    check cycles == @[1, 2]
    check protocol.samples.len == 4
    check protocol.header["metadata"]["scope"].getStr == "synthetic protocol fixture"

  test "header identifies exact requested workload Release ORC and compiler":
    for field in ["schema", "group", "scenarios", "parameters", "metadata"]:
      let changed = header(fixtureConfig())
      case field
      of "schema": changed[field] = %1
      of "group": changed[field] = %"native"
      of "scenarios": changed[field] = %*["other"]
      of "parameters": changed[field]["iterations"] = %3
      else: changed[field]["release"] = %false
      expect PerformanceError: newFixture().feed(line(changed))
    for (field, value) in [("compiler", "old"), ("platform", "other"),
        ("architecture", "other"), ("memory_manager", "refc")]:
      let changed = header(fixtureConfig())
      changed["metadata"][field] = %value
      expect PerformanceError: newFixture().feed(line(changed))
    expect PerformanceError: newFixture().feed(line(sample(1, 1)))
    let duplicate = newFixture()
    duplicate.feed(line(header(fixtureConfig())))
    expect PerformanceError: duplicate.feed(line(header(fixtureConfig())))

  test "exit zero cannot substitute for missing samples cycles cleanup or newline":
    let records = validRecords(fixtureConfig())
    for omitted in [1, 3, records.len - 1]:
      let protocol = newFixture()
      expect PerformanceError:
        for i, record in records:
          if i != omitted: protocol.feed(line(record))
        protocol.finish(0)
    let truncated = newFixture()
    for i in 0..<records.len - 1: truncated.feed(line(records[i]))
    truncated.feed(line(records[^1]).strip())
    expect PerformanceError: truncated.finish(0)
    let failed = newFixture()
    for record in records: failed.feed(line(record))
    expect PerformanceError: failed.finish(7)

  test "malformed repeated reordered or foreign observations fail before cycle acceptance":
    for alteration in ["count", "checks", "resources", "round", "cycle", "group", "scenario"]:
      let changed = sample(1, 1)
      case alteration
      of "count": changed["operations"] = %0
      of "checks": changed["checks_passed"] = %false
      of "resources": changed["resources"]["heap_after_gc_bytes"] = %(-1)
      of "round": changed["round"] = %2
      of "cycle": changed["cycle"] = %2
      of "group": changed["group"] = %"native"
      else: changed["scenario"] = %"other"
      let protocol = newFixture()
      protocol.feed(line(header(fixtureConfig())))
      expect PerformanceError: protocol.feed(line(changed))
    let duplicate = newFixture()
    duplicate.feed(line(header(fixtureConfig())) & line(sample(1, 1)))
    expect PerformanceError: duplicate.feed(line(sample(1, 1)))
    expect PerformanceError: newFixture().feed("LEAF_PERF {invalid}\n")

  test "cycle callback can reject immediately while partial evidence remains available":
    let protocol = newFixture()
    var accepted = 0
    let rejectCycle = proc(cycle: int, summary: JsonNode) =
      inc accepted
      raise newException(PerformanceError, "synthetic regression gate")
    var raw = ""
    for record in validRecords(fixtureConfig()): raw.add(line(record))
    expect PerformanceError: protocol.feed(raw, rejectCycle)
    check accepted == 1
    check protocol.samples.len == 2
    check protocol.completedCycles == 1
    expect PerformanceError: protocol.finish(0)

  test "output and line limits also bound unstructured child diagnostics":
    let protocol = newFixture()
    expect PerformanceError: protocol.feed(repeat('x', MaxMeasurementLine + 1))
    let noisy = newFixture()
    let chunk = repeat('x', 65535) & "\n"
    expect PerformanceError:
      for i in 0..MaxMeasurementOutput div chunk.len: noisy.feed(chunk)
