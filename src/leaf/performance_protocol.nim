## Streaming validation for standalone measurement subprocesses. A successful
## process exit and a complete protocol are both required; neither replaces the other.
import std/[json, strutils, sets, math]
import ./performance_report

const
  MeasurementRecordPrefix = "LEAF_PERF "
  MaxMeasurementLine* = 1_048_576
  MaxMeasurementOutput* = 33_554_432

type
  CycleAccepted* = proc(cycle: int, summary: JsonNode) {.closure.}
  MeasurementProtocol* = ref object
    config: PerformanceConfig
    group, compiler, platform, architecture: string
    scenarios: seq[string]
    pending: string
    outputBytes: int
    complete: bool
    failed: bool
    header*: JsonNode
    samples*: JsonNode
    completedCycles*: int

proc reject(message: string) {.noreturn.} =
  raise newException(PerformanceError, "measurement protocol: " & message)

proc required(record: JsonNode, key: string, kind: JsonNodeKind): JsonNode =
  if record == nil or record.kind != JObject or not record.hasKey(key) or record[key].kind != kind:
    reject("missing or invalid " & key)
  record[key]

proc requireInt(record: JsonNode, key: string, expected: int) =
  if required(record, key, JInt).getBiggestInt != BiggestInt(expected):
    reject("unexpected " & key)

proc requireString(record: JsonNode, key, expected: string) =
  if required(record, key, JString).getStr != expected: reject("unexpected " & key)

proc requireElapsed(record: JsonNode) =
  if record == nil or not record.hasKey("elapsed_wall_ms") or
      record["elapsed_wall_ms"].kind notin {JInt, JFloat}:
    reject("missing elapsed_wall_ms")
  let value = record["elapsed_wall_ms"].getFloat
  if classify(value) in {fcNan, fcInf, fcNegInf} or value < 0:
    reject("invalid elapsed_wall_ms")

proc newMeasurementProtocol*(config: PerformanceConfig, group: string,
    scenarios: seq[string], compiler: string,
    platform = hostOS, architecture = hostCPU): MeasurementProtocol =
  validateConfig(config)
  if group.len == 0 or compiler.len == 0 or platform.len == 0 or architecture.len == 0 or
      scenarios.len == 0 or scenarios.len > 32:
    reject("expected actual group, toolchain and scenarios")
  var seen = initHashSet[string]()
  for scenario in scenarios:
    if scenario.len == 0 or scenario in seen: reject("invalid expected scenarios")
    seen.incl(scenario)
  MeasurementProtocol(config: config, group: group, scenarios: scenarios,
    compiler: compiler, platform: platform, architecture: architecture,
    samples: newJArray())

proc consume(protocol: MeasurementProtocol, record: JsonNode, onCycle: CycleAccepted) =
  if protocol.complete: reject("record after cleanup completion")
  requireString(record, "group", protocol.group)
  let kind = required(record, "type", JString).getStr
  if protocol.header == nil:
    if kind != "header": reject("expected header before measurements")
    requireInt(record, "schema", PerformanceSchema)
    if required(record, "parameters", JObject) != measurementParameters(protocol.config):
      reject("requested parameters differ")
    let names = required(record, "scenarios", JArray)
    if names != %protocol.scenarios: reject("requested scenarios differ")
    let metadata = required(record, "metadata", JObject)
    requireString(metadata, "compiler", protocol.compiler)
    requireString(metadata, "platform", protocol.platform)
    requireString(metadata, "architecture", protocol.architecture)
    requireString(metadata, "memory_manager", "orc")
    if not required(metadata, "release", JBool).getBool: reject("harness is not Release")
    protocol.header = record
    return
  let perCycle = protocol.scenarios.len * protocol.config.rounds
  let nextCycle = protocol.completedCycles + 1
  case kind
  of "sample":
    if nextCycle > protocol.config.repeats: reject("sample after last cycle")
    let currentCount = protocol.samples.len - protocol.completedCycles * perCycle
    if currentCount >= perCycle: reject("missing cycle completion before next sample")
    requireInt(record, "cycle", nextCycle)
    requireInt(record, "round", currentCount mod protocol.config.rounds + 1)
    requireString(record, "scenario", protocol.scenarios[currentCount div protocol.config.rounds])
    requireElapsed(record)
    discard required(record, "runtime", JObject)
    # Apply the full business/count/finite/resource policies immediately, using
    # one normalized observation before admitting it into the retained raw set.
    let single = record.copy()
    single["cycle"] = %1
    single["round"] = %1
    var singleConfig = protocol.config
    singleConfig.repeats = 1
    singleConfig.rounds = 1
    validateSamples(%*[single], singleConfig, @[record["scenario"].getStr])
    protocol.samples.add(record)
  of "cycle_complete":
    if nextCycle > protocol.config.repeats: reject("duplicate cycle completion")
    requireInt(record, "cycle", nextCycle)
    requireInt(record, "samples", perCycle)
    requireElapsed(record)
    var observedConfig = protocol.config
    observedConfig.repeats = nextCycle
    validateSamples(protocol.samples, observedConfig, protocol.scenarios)
    protocol.completedCycles = nextCycle
    if onCycle != nil: onCycle(nextCycle, summarizeCycle(protocol.samples, nextCycle))
  of "complete":
    requireInt(record, "cycles", protocol.config.repeats)
    if protocol.completedCycles != protocol.config.repeats:
      reject("cleanup completed before all requested cycles")
    validateSamples(protocol.samples, protocol.config, protocol.scenarios)
    protocol.complete = true
  else: reject("unknown or repeated record type: " & kind)

proc feed*(protocol: MeasurementProtocol, chunk: string, onCycle: CycleAccepted = nil) =
  if protocol.failed: reject("previous validation failed")
  try:
    if chunk.len > MaxMeasurementOutput - protocol.outputBytes:
      reject("subprocess output exceeds 32 MiB")
    protocol.outputBytes += chunk.len
    # Scan without repeatedly copying the shrinking remainder of a large chunk.
    var start = 0
    while start < chunk.len:
      let newline = chunk.find('\n', start)
      let last = if newline < 0: chunk.len else: newline
      if last - start > MaxMeasurementLine - protocol.pending.len:
        reject("subprocess line exceeds 1 MiB")
      protocol.pending.add(chunk[start..<last])
      if newline < 0: break
      var line = move(protocol.pending)
      protocol.pending = ""
      if line.endsWith("\r"): line.setLen(line.len - 1)
      if line.startsWith(MeasurementRecordPrefix):
        var record: JsonNode
        try: record = parseJson(line[MeasurementRecordPrefix.len..^1])
        except JsonParsingError: reject("invalid JSON record")
        protocol.consume(record, onCycle)
      start = newline + 1
  except CatchableError:
    protocol.failed = true
    raise

proc finish*(protocol: MeasurementProtocol, exitCode: int) =
  if protocol.failed: reject("previous validation failed")
  if exitCode != 0: reject("subprocess exited " & $exitCode)
  if protocol.pending.startsWith(MeasurementRecordPrefix): reject("truncated protocol record")
  if not protocol.complete: reject("missing complete measurements and cleanup")
