## Shared standalone workload protocol. Instances persist through all cycles.
import std/[json, monotimes, times, os, sets]
import leaf/[performance_report, process_metrics]

const MeasurementPrefix* = "LEAF_PERF "
type
  Workload* = ref object
    name*: string
    operation*, verify*, beforeRound*, afterRound*, dispose*: proc() {.closure.}
    counters*: proc(): JsonNode {.closure.}

proc configDocument*(config: PerformanceConfig): JsonNode =
  measurementParameters(config)

proc harnessConfig*(): PerformanceConfig =
  result = defaultPerformanceConfig()
  let raw = getEnv("LEAF_PERF_CONFIG")
  if raw.len == 0: return
  if raw.len > 16384: raise newException(PerformanceError, "measurement configuration too large")
  try:
    let document = parseJson(raw)
    if document.kind != JObject: raise newException(ValueError, "expected object")
    for key in ["iterations", "warmup", "rounds", "repeats"]:
      if not document.hasKey(key) or document[key].kind != JInt:
        raise newException(ValueError, "missing integer " & key)
    result.iterations = document["iterations"].getInt
    result.warmup = document["warmup"].getInt
    result.rounds = document["rounds"].getInt
    result.repeats = document["repeats"].getInt
    if not document.hasKey("interval_seconds") or document["interval_seconds"].kind notin {JInt, JFloat}:
      raise newException(ValueError, "missing interval")
    result.intervalSeconds = document["interval_seconds"].getFloat
    validateConfig(result)
  except CatchableError as error:
    raise newException(PerformanceError, "invalid measurement configuration: " & error.msg)

proc elapsed(start: MonoTime): float64 =
  float64((getMonoTime() - start).inNanoseconds) / 1_000_000

proc emitStdout*(record: JsonNode) =
  stdout.writeLine(MeasurementPrefix & $record)
  stdout.flushFile()

proc requireRelease*() =
  if not defined(release): raise newException(PerformanceError, "performance harness requires -d:release")
  if not defined(gcOrc): raise newException(PerformanceError, "performance harness requires --mm:orc")
  if paramCount() != 0: raise newException(PerformanceError, "harness takes no arguments; use LEAF_PERF_CONFIG")

proc runMeasurements*(workloads: seq[Workload], config: PerformanceConfig,
                      group: string, extraMetadata: JsonNode,
                      emit: proc(record: JsonNode) {.closure.}) =
  var cleanupErrors: seq[string]
  try:
    validateConfig(config)
    if workloads.len == 0 or workloads.len > 32 or group.len == 0 or emit == nil:
      raise newException(PerformanceError, "measurement needs actual workloads, group and output")
    var names = initHashSet[string]()
    var scenarios: seq[string]
    for workload in workloads:
      if workload == nil or workload.name.len == 0 or workload.name in names or
          workload.operation == nil or workload.verify == nil or workload.counters == nil:
        raise newException(PerformanceError, "invalid or duplicate workload")
      names.incl(workload.name)
      scenarios.add(workload.name)
    if extraMetadata == nil or extraMetadata.kind != JObject:
      raise newException(PerformanceError, "invalid measurement metadata")
    let metadata = extraMetadata.copy()
    metadata["compiler"] = %NimVersion
    metadata["platform"] = %hostOS
    metadata["architecture"] = %hostCPU
    metadata["release"] = %defined(release)
    metadata["memory_manager"] = %(when defined(gcOrc): "orc" else: "other")
    emit(%*{"type": "header", "schema": PerformanceSchema, "group": group,
      "metadata": metadata, "parameters": configDocument(config), "scenarios": scenarios})
    let wholeStart = getMonoTime()
    # Warm every retained instance before recording the initial resource set.
    for workload in workloads:
      if workload.beforeRound != nil: workload.beforeRound()
      for operation in 0..<config.warmup: workload.operation()
      workload.verify()
    for cycle in 1..config.repeats:
      for workload in workloads:
        for round in 1..config.rounds:
          if workload.beforeRound != nil: workload.beforeRound()
          var latencies = newSeqOfCap[float64](config.iterations)
          let before = collectObservation()
          let roundStart = getMonoTime()
          for operation in 0..<config.iterations:
            let start = getMonoTime()
            workload.operation()
            latencies.add(elapsed(start))
            workload.verify() # Outside the individual operation timing.
          if workload.afterRound != nil: workload.afterRound()
          workload.verify()
          let after = collectObservation()
          emit(%*{"type": "sample", "scenario": workload.name, "group": group,
            "round": round, "cycle": cycle, "operations": latencies.len,
            "latency_ms": latencies, "checks_passed": true,
            "resources": resourceRecord(before, after),
            "elapsed_wall_ms": elapsed(roundStart), "runtime": workload.counters()})
      emit(%*{"type": "cycle_complete", "group": group, "cycle": cycle,
        "samples": workloads.len * config.rounds, "elapsed_wall_ms": elapsed(wholeStart)})
      if cycle < config.repeats and config.intervalSeconds > 0:
        sleep(int(config.intervalSeconds * 1000))
  finally:
    # Shared native hosts may have idempotent disposal. Finish all cleanups even
    # when a different workload's cleanup fails; completion follows disposal.
    for i in countdown(workloads.len - 1, 0):
      let workload = workloads[i]
      if workload != nil and workload.dispose != nil:
        try: workload.dispose()
        except CatchableError as error: cleanupErrors.add(workload.name & ": " & error.msg)
    if cleanupErrors.len > 0:
      raise newException(PerformanceError, "workload cleanup failed: " & $cleanupErrors)
  emit(%*{"type": "complete", "group": group, "cycles": config.repeats})
