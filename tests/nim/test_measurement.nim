import std/[unittest, json]
import leaf/performance_report
import ../../benchmarks/measurement

suite "Persistent workload measurement protocol":
  test "warmup runs once and live workload instances survive all cycles":
    var operations, checks, closed = 0
    let workload = Workload(name: "counter",
      operation: (proc() = inc operations),
      verify: (proc() = inc checks),
      counters: (proc(): JsonNode = %*{"operations": operations}),
      dispose: proc() = inc closed)
    var config = defaultPerformanceConfig()
    config.iterations = 2
    config.warmup = 1
    config.rounds = 2
    config.repeats = 2
    var records: seq[JsonNode]
    runMeasurements(@[workload], config, "runtime", %*{"scope": "fixture"},
      proc(record: JsonNode) = records.add(record))
    check operations == 9
    check checks >= 5
    check closed == 1
    check records[0]["type"].getStr == "header"
    check records[^1]["type"].getStr == "complete"
    var samples = newJArray()
    var cycles = 0
    for record in records:
      if record["type"].getStr == "sample": samples.add(record)
      if record["type"].getStr == "cycle_complete": inc cycles
    check cycles == 2
    validateSamples(samples, config, @["counter"])

  test "failed real operation releases all workloads and never reports completion":
    var closed = 0
    let broken = Workload(name: "broken",
      operation: (proc() = raise newException(IOError, "operation failed")),
      verify: (proc() = discard),
      counters: (proc(): JsonNode = newJObject()), dispose: proc() = inc closed)
    let survivor = Workload(name: "survivor", operation: (proc() = discard),
      verify: (proc() = discard), counters: (proc(): JsonNode = newJObject()),
      dispose: proc() = inc closed)
    var records: seq[JsonNode]
    expect IOError:
      runMeasurements(@[broken, survivor], defaultPerformanceConfig(), "runtime", newJObject(),
        proc(record: JsonNode) = records.add(record))
    check closed == 2
    for record in records: check record["type"].getStr != "complete"

  test "empty duplicate and incomplete workloads cannot produce successful evidence":
    var records: seq[JsonNode]
    let emit = proc(record: JsonNode) = records.add(record)
    let empty = Workload(name: "empty")
    expect PerformanceError:
      runMeasurements(@[], defaultPerformanceConfig(), "runtime", newJObject(), emit)
    expect PerformanceError:
      runMeasurements(@[empty], defaultPerformanceConfig(), "runtime", newJObject(), emit)
    let valid = Workload(name: "same", operation: (proc() = discard),
      verify: (proc() = discard), counters: proc(): JsonNode = newJObject())
    expect PerformanceError:
      runMeasurements(@[valid, valid], defaultPerformanceConfig(), "runtime", newJObject(), emit)
    check records.len == 0
