## Acceptance policies for independent performance tools, not the UI event path.
import std/[json, options, math, algorithm, tables, sets]

const PerformanceSchema* = 2
type
  PerformanceError* = object of CatchableError
  PerformanceSuite* = enum runtimeSuite, nativeSuite, allSuites
  PerformanceConfig* = object
    iterations*, warmup*, rounds*, repeats*: int
    intervalSeconds*, timeoutSeconds*, maxRegression*: float64
    budgetMs*, rssLimitMiB*: Option[float64]
    cpu*: Option[int]
    suite*: PerformanceSuite
    output*, baseline*: string
    noBuild*: bool

proc reject(message: string) {.noreturn.} =
  raise newException(PerformanceError, message)

proc finite(value: float64): bool = classify(value) notin {fcNan, fcInf, fcNegInf}

proc defaultPerformanceConfig*(): PerformanceConfig =
  PerformanceConfig(iterations: 100, warmup: 100, rounds: 3, repeats: 1,
    timeoutSeconds: 600, maxRegression: 0.25, suite: runtimeSuite,
    output: "artifacts/performance")

proc measurementParameters*(config: PerformanceConfig): JsonNode =
  %*{"iterations": config.iterations, "warmup": config.warmup,
    "rounds": config.rounds, "repeats": config.repeats,
    "interval_seconds": config.intervalSeconds}

proc validateConfig*(config: PerformanceConfig) =
  for pair in [("iterations", config.iterations, 10_000),
      ("warmup", config.warmup, 100_000), ("rounds", config.rounds, 100),
      ("repeat", config.repeats, 100)]:
    if pair[1] < 1 or pair[1] > pair[2]: reject(pair[0] & " outside supported bounds 1.." & $pair[2])
  # Bound before multiplication, including platforms with a 32-bit int.
  if config.rounds * config.repeats > 1000 or
      config.iterations > 100_000 div (config.rounds * config.repeats):
    reject("at most 100000 raw observations and 1000 rounds per scenario")
  if not finite(config.timeoutSeconds) or config.timeoutSeconds <= 0 or config.timeoutSeconds > 3600:
    reject("timeout must be finite and in (0, 3600] seconds")
  if not finite(config.intervalSeconds) or config.intervalSeconds < 0 or config.intervalSeconds > 60:
    reject("interval must be finite and in [0, 60] seconds")
  if not finite(config.maxRegression) or config.maxRegression < 0:
    reject("max-regression must be finite and nonnegative")
  for pair in [("budget-ms", config.budgetMs), ("max-rss-growth-mib", config.rssLimitMiB)]:
    if pair[1].isSome and (not finite(pair[1].get) or pair[1].get < 0):
      reject(pair[0] & " must be finite and nonnegative")
  if config.cpu.isSome and config.cpu.get < 0: reject("cpu must be nonnegative")
  if config.output.len == 0 or '\0' in config.output or '\0' in config.baseline:
    reject("invalid performance output or baseline path")

proc required(record: JsonNode, key: string): JsonNode =
  if record == nil or record.kind != JObject or not record.hasKey(key):
    reject("missing performance field: " & key)
  record[key]

proc integer(record: JsonNode, key: string): int =
  let field = required(record, key)
  if field.kind != JInt: reject("expected integer: " & key)
  let value = field.getBiggestInt
  if value < BiggestInt(low(int)) or value > BiggestInt(high(int)):
    reject("integer exceeds platform bounds: " & key)
  int(value)

proc number(field: JsonNode, context: string): float64 =
  if field == nil or field.kind notin {JInt, JFloat}: reject("expected number: " & context)
  result = field.getFloat
  if not finite(result) or result < 0: reject("expected finite nonnegative number: " & context)

proc latencyValues(record: JsonNode): seq[float64] =
  let values = required(record, "latency_ms")
  if values.kind != JArray or values.len == 0: reject("empty or invalid latency observations")
  for value in values:
    let milliseconds = number(value, "latency_ms")
    if milliseconds > 3_600_000: reject("latency exceeds maximum supervised timeout")
    result.add(milliseconds)

proc percentile*(values: seq[float64], fraction: float64): float64 =
  if values.len == 0 or not finite(fraction) or fraction < 0 or fraction > 1:
    reject("invalid percentile input")
  var sorted = values
  for value in sorted:
    if not finite(value) or value < 0: reject("invalid percentile observation")
  sorted.sort()
  sorted[max(0, int(ceil(fraction * float64(sorted.len))) - 1)]

proc median(values: seq[float64]): float64 =
  if values.len == 0: reject("empty median input")
  var sorted = values
  sorted.sort()
  let middle = sorted.len div 2
  if sorted.len mod 2 == 1: sorted[middle]
  else: sorted[middle - 1] / 2 + sorted[middle] / 2

proc validateSamples*(samples: JsonNode, config: PerformanceConfig, expected: seq[string]) =
  validateConfig(config)
  if samples == nil or samples.kind != JArray or expected.len == 0:
    reject("performance suite must contain actual scenarios and samples")
  var scenarios = initHashSet[string]()
  for scenario in expected:
    if scenario.len == 0 or scenario in scenarios: reject("empty or duplicate expected scenario")
    scenarios.incl(scenario)
  if expected.len > 32: reject("too many performance scenarios")
  if samples.len != expected.len * config.rounds * config.repeats:
    reject("incomplete performance scenario/round/cycle results")
  var seen = initHashSet[(string, int, int)]()
  for record in samples:
    let field = required(record, "scenario")
    if field.kind != JString or field.getStr notin scenarios: reject("unknown performance scenario")
    let scenario = field.getStr
    let round = integer(record, "round")
    let cycle = integer(record, "cycle")
    if round notin 1..config.rounds or cycle notin 1..config.repeats:
      reject("performance round or cycle outside requested range")
    let identity = (scenario, round, cycle)
    if identity in seen: reject("duplicate performance sample")
    seen.incl(identity)
    let values = latencyValues(record)
    if integer(record, "operations") != config.iterations or values.len != config.iterations:
      reject("performance operation count mismatch")
    let checked = required(record, "checks_passed")
    if checked.kind != JBool or not checked.getBool: reject("performance business checks failed")
    let resources = required(record, "resources")
    for key in ["rss_start_kib", "rss_after_gc_kib"]:
      let value = required(resources, key)
      if value.kind != JNull: discard number(value, key)
    for key in ["heap_after_gc_bytes", "cpu_seconds"]:
      discard number(required(resources, key), key)

proc summarizeCycle*(samples: JsonNode, cycle: int): JsonNode =
  if samples == nil or samples.kind != JArray or cycle < 1: reject("invalid cycle input")
  var groups = initTable[string, seq[JsonNode]]()
  for record in samples:
    if integer(record, "cycle") == cycle:
      let name = required(record, "scenario")
      if name.kind != JString: reject("invalid scenario name")
      groups.mgetOrPut(name.getStr, @[]).add(record)
  if groups.len == 0: reject("no actual observations for requested cycle")
  result = newJObject()
  for scenario, records in groups:
    var p50, p95, p99: seq[float64]
    var maximum = 0.0
    var operations = 0
    for record in records:
      let values = latencyValues(record)
      p50.add(percentile(values, 0.50))
      p95.add(percentile(values, 0.95))
      p99.add(percentile(values, 0.99))
      maximum = max(maximum, percentile(values, 1))
      operations += values.len
    result[scenario] = %*{"median_round_p50_ms": median(p50),
      "median_round_p95_ms": median(p95), "median_round_p99_ms": median(p99),
      "max_round_max_ms": maximum, "rounds": records.len, "operations": operations}

proc scenarioNames(summary: JsonNode): seq[string] =
  if summary == nil or summary.kind != JObject or summary.len == 0: reject("empty performance summary")
  for key, value in summary: result.add(key)
  result.sort()

proc compareReports*(current, baseline: JsonNode, fraction: float64): seq[string] =
  if not finite(fraction) or fraction < 0: reject("invalid regression threshold")
  for report in [current, baseline]:
    if integer(report, "schema") != PerformanceSchema: reject("performance baseline schema mismatch")
  for key in ["environment", "parameters"]:
    let actual = required(current, key)
    let old = required(baseline, key)
    if actual.kind != JObject or old.kind != JObject or actual != old:
      reject("performance baseline " & key & " mismatch")
  let actual = required(current, "summary")
  let old = required(baseline, "summary")
  if scenarioNames(actual) != scenarioNames(old): reject("performance baseline scenarios differ")
  for scenario, metrics in actual:
    let value = number(required(metrics, "median_round_p95_ms"), scenario)
    let previous = number(required(old[scenario], "median_round_p95_ms"), scenario)
    if value > previous * (1 + fraction):
      result.add(scenario & " p95 " & $value & "ms exceeds baseline " & $previous &
        "ms + " & $(fraction * 100) & "%")

proc budgetFailures*(summary: JsonNode, limitMs: float64): seq[string] =
  if not finite(limitMs) or limitMs < 0: reject("invalid latency budget")
  discard scenarioNames(summary)
  for scenario, metrics in summary:
    let value = number(required(metrics, "median_round_p95_ms"), scenario)
    if value > limitMs: result.add(scenario & " p95 exceeds " & $limitMs & "ms budget")

proc rssFailures*(samples: JsonNode, limitMiB: float64,
                  initialKiB = none(float64)): seq[string] =
  if not finite(limitMiB) or limitMiB < 0: reject("invalid RSS growth budget")
  if samples == nil or samples.kind != JArray or samples.len == 0: reject("no resource samples")
  let first = required(required(samples[0], "resources"), "rss_start_kib")
  let initial = if initialKiB.isSome: initialKiB.get else: number(first, "initial RSS unavailable")
  if not finite(initial) or initial < 0: reject("invalid initial RSS")
  for record in samples:
    let current = number(required(required(record, "resources"), "rss_after_gc_kib"),
      "post-GC RSS unavailable")
    if (current - initial) / 1024 > limitMiB:
      result.add(required(record, "scenario").getStr & " retained RSS exceeds " & $limitMiB & "MiB budget")
