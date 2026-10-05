## Performance command orchestration lives outside the application's event path.
import std/[options, strutils, sets, os, json, monotimes, times, strtabs, algorithm, nativesockets, tempfiles]
import ./[performance_report, performance_protocol, performance_scenarios,
  process_io, checksum, diagnostics]
import ./vendor/checksums/sha2
when defined(posix): import std/posix

const PerformanceHelp* = """Usage: leaf-performance [options]
Build: nim c -d:release --out:target/nim/leaf-performance scripts/performance.nim

  --suite runtime|native|all       Default: runtime; native needs GPUI and graphics
  --iterations N                 Measured operations per round (default 100)
  --warmup N                     Once per retained workload instance (default 100)
  --rounds N                     Rounds per scenario and cycle (default 3)
  --repeat N                     Cycles in the same live process (default 1)
  --interval SECONDS             Delay between cycles (default 0, at most 60)
  --timeout SECONDS              Bounded build/group deadline (default 600)
  --output DIRECTORY             Raw logs, reports and verified build manifest
  --no-build                     Require matching source/compiler/binary hashes
  --cpu N                        Request one CPU; fail if affinity is unavailable
  --baseline FILE                Immutable, compatible schema 2 report
  --max-regression FRACTION       Allowed p95 growth (default 0.25)
  --budget-ms N                  Maximum median of per-round p95 values
  --max-rss-growth-mib N          Whole-group retained RSS growth; needs RSS support
  --help, -h                     Show this help

Comparisons require the same machine, toolchain, parameters and scenarios.
Only matching producer and workload identities can be compared.
Native timings cover synchronous transactions; verification, GC and settling
are outside individual operation timings. Resource windows include that work.
Thread-managed Nim heap and process RSS are separate measurements.
"""

type PerformanceArguments* = object
  config*: PerformanceConfig
  help*: bool

proc reject(message: string) {.noreturn.} =
  raise newException(PerformanceError, message)

proc integer(value, name: string): int =
  try: result = parseInt(value)
  except ValueError: reject("expected integer for --" & name & ": " & value)

proc decimal(value, name: string): float64 =
  try: result = parseFloat(value)
  except ValueError: reject("expected number for --" & name & ": " & value)

proc parsePerformanceArgs*(args: seq[string]): PerformanceArguments =
  result.config = defaultPerformanceConfig()
  var seen = initHashSet[string]()
  var i = 0
  while i < args.len:
    let argument = args[i]
    inc i
    if argument == "-h":
      if "help" in seen: reject("duplicate --help")
      seen.incl("help")
      result.help = true
      continue
    if not argument.startsWith("--"): reject("unexpected positional argument: " & argument)
    let equals = argument.find('=')
    let name = if equals < 0: argument[2..^1] else: argument[2..<equals]
    if name in seen: reject("duplicate --" & name)
    seen.incl(name)
    if name in ["no-build", "help"]:
      if equals >= 0: reject("--" & name & " does not take a value")
      if name == "help": result.help = true
      else: result.config.noBuild = true
      continue
    if name notin ["suite", "iterations", "warmup", "rounds", "repeat", "interval",
        "timeout", "output", "cpu", "baseline", "max-regression", "budget-ms",
        "max-rss-growth-mib"]:
      reject("unknown option: --" & name)
    var value: string
    if equals >= 0: value = argument[equals + 1..^1]
    else:
      if i == args.len or args[i].startsWith("--") or args[i] == "-h":
        reject("missing value for --" & name)
      value = args[i]
      inc i
    if value.len == 0: reject("empty value for --" & name)
    case name
    of "suite":
      case value
      of "runtime": result.config.suite = runtimeSuite
      of "native": result.config.suite = nativeSuite
      of "all": result.config.suite = allSuites
      else: reject("--suite must be runtime, native or all")
    of "iterations": result.config.iterations = integer(value, name)
    of "warmup": result.config.warmup = integer(value, name)
    of "rounds": result.config.rounds = integer(value, name)
    of "repeat": result.config.repeats = integer(value, name)
    of "interval": result.config.intervalSeconds = decimal(value, name)
    of "timeout": result.config.timeoutSeconds = decimal(value, name)
    of "max-regression": result.config.maxRegression = decimal(value, name)
    of "budget-ms": result.config.budgetMs = some(decimal(value, name))
    of "max-rss-growth-mib": result.config.rssLimitMiB = some(decimal(value, name))
    of "cpu": result.config.cpu = some(integer(value, name))
    of "output": result.config.output = value
    of "baseline": result.config.baseline = value
    else: reject("unsupported option: --" & name)
  validateConfig(result.config)

var terminationFlag {.volatile.}: cint
var handlingSignals = false
when defined(posix):
  var previousTerminationHandler = SIG_DFL
  proc terminated(signal: cint) {.noconv.} = terminationFlag = 1

proc checkStop() =
  if terminationFlag != 0: raise newException(ProcessInterruptedError, "performance run terminated")
  if wasInterrupted(): raise newException(ProcessInterruptedError, "performance run interrupted")

proc beginSignals() =
  if handlingSignals: reject("performance runner cannot be nested")
  terminationFlag = 0
  when defined(posix):
    previousTerminationHandler = posix.signal(SIGTERM, terminated)
    if previousTerminationHandler == SIG_ERR: reject("could not install termination handler")
  beginInterruptHandling()
  handlingSignals = true

proc endSignals() =
  endInterruptHandling()
  when defined(posix): discard posix.signal(SIGTERM, previousTerminationHandler)
  handlingSignals = false

proc performanceFailureCode*(error: ref CatchableError): int =
  if error of ProcessInterruptedError:
    if terminationFlag != 0: return 143
    return 130
  1

proc performanceExit*(code: int) {.noreturn.} =
  when defined(posix): quit(if code in 128..255: code - 256 else: code)
  else: quit(code)

proc groupNames(config: PerformanceConfig): seq[string] =
  case config.suite
  of runtimeSuite: @["runtime"]
  of nativeSuite: @["native"]
  of allSuites: @["runtime", "native"]

proc scenarioNames(group: string): seq[string] =
  if group == "runtime": @RuntimeScenarios else: @NativeScenarios

proc inheritedEnvironment(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): result[key] = value

proc command(executable: string, args: seq[string], root: string, seconds: float64,
    rawPath = "", env: StringTableRef = nil,
    accept: proc(chunk: string) {.closure.} = nil): string =
  let child = startManaged(executable, args, root, env)
  defer: child.close()
  let deadline = getMonoTime() + initDuration(nanoseconds = int64(seconds * 1_000_000_000))
  var raw: File
  if rawPath.len > 0: raw = open(rawPath, fmWrite)
  defer:
    if raw != nil: raw.close()
  var bytes = 0
  proc consume(chunk: string) =
    let remaining = MaxMeasurementOutput - bytes
    if chunk.len > remaining:
      if raw != nil and remaining > 0: raw.write(chunk[0..<remaining])
      reject("subprocess output exceeds 32 MiB")
    bytes += chunk.len
    if raw != nil and chunk.len > 0:
      raw.write(chunk)
      raw.flushFile()
    if accept != nil and chunk.len > 0: accept(chunk)
  while true:
    checkStop()
    let chunk = child.drain()
    consume(chunk)
    if child.checkExit():
      # The child can exit between the first drain and the exit observation.
      let tail = child.drain()
      consume(tail)
      if chunk.len < 131_072 and tail.len < 131_072:
        if child.code != 0:
          reject(executable.extractFilename & " exited " & $child.code & ": " &
            diagnosticText(child.output[max(0, child.output.len - 4096)..^1]))
        return child.output
    if getMonoTime() >= deadline:
      reject(executable.extractFilename & " exceeded " & $seconds & " seconds")
    sleep(5)

proc executable(name: string): string =
  result = if isAbsolute(name): name else: findExe(name)
  if result.len == 0 or not fileExists(result): reject("executable not found: " & name)
  result = expandFilename(result)

proc sourceIdentity(root: string): JsonNode =
  var files: seq[string]
  var visited = 0
  proc visit(directory: string, depth: int) =
    checkStop()
    if depth > 64: reject("performance source tree exceeds depth 64")
    for kind, path in walkDir(directory):
      inc visited
      if visited > 8192: reject("performance source tree exceeds 8192 entries")
      case kind
      of pcDir: visit(path, depth + 1)
      of pcFile:
        if path.splitFile.ext.toLowerAscii in [".nim", ".nims", ".cfg", ".json", ".rs", ".toml", ".lock"]: files.add(path)
      else: reject("performance source cannot contain symbolic links: " & path)
  for folder in ["src", "crates", "benchmarks", "examples", "example", "scripts"]:
    if dirExists(root / folder): visit(root / folder, 0)
  for name in ["config.nims", "nim.cfg", "leaf.nimble", "Cargo.toml", "Cargo.lock"]:
    if fileExists(root / name): files.add(root / name)
  if files.len == 0: reject("no Nim performance sources found")
  files.sort()
  var state = initSha_256()
  let identities = newJObject()
  for path in files:
    checkStop()
    if getFileSize(path) > 16_777_216: reject("performance source exceeds 16 MiB: " & path)
    let relative = relativePath(path, root).replace('\\', '/')
    let digest = sha256File(path)
    identities[relative] = %digest
    state.update(relative & "\0" & digest & "\n")
  %*{"sha256": $state.digest(), "files": identities}

proc toolchain(root: string, timeout: float64): tuple[identity: JsonNode, nim, version, cc: string] =
  result.nim = executable(getEnv("NIM", "nim"))
  result.cc = executable(getEnv("LEAF_PERF_CC", when defined(macosx): "clang" else: "gcc"))
  let nimVersion = command(result.nim, @["--version"], root, timeout)
  let words = nimVersion.splitWhitespace()
  let versionIndex = words.find("Version")
  if versionIndex < 0 or versionIndex + 1 >= words.len: reject("cannot identify Nim compiler version")
  result.version = words[versionIndex + 1]
  let ccVersion = command(result.cc, @["--version"], root, timeout)
  result.identity = %*{"nim": {"path": result.nim, "version_output": nimVersion,
      "sha256": sha256File(result.nim)},
    "c_compiler": {"path": result.cc, "version_output": ccVersion,
      "sha256": sha256File(result.cc)},
    "options": ["skipCfg", "skipUserCfg", "skipParentCfg", "skipProjCfg",
      "forceBuild:on", "release", "orc", "threads:on", "opt:speed", "assertions:on", "boundChecks:on"]}

proc machineEnvironment(config: PerformanceConfig, compiler: JsonNode): JsonNode =
  var model, affinity: string
  when defined(linux):
    for line in readFile("/proc/cpuinfo").splitLines():
      if line.startsWith("model name") or line.startsWith("Hardware"):
        model = line.split(':', 1)[^1].strip()
        break
    for line in readFile("/proc/self/status").splitLines():
      if line.startsWith("Cpus_allowed_list:"): affinity = line.split(':', 1)[^1].strip()
  let graphics = newJObject()
  for key in ["DISPLAY", "WAYLAND_DISPLAY", "LEAF_GPUI_LIBRARY", "VK_ICD_FILENAMES",
      "LIBGL_ALWAYS_SOFTWARE", "GALLIUM_DRIVER", "MESA_LOADER_DRIVER_OVERRIDE",
      "PATH", "LD_LIBRARY_PATH", "LD_PRELOAD", "DYLD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES",
      "FONTCONFIG_FILE", "FONTCONFIG_PATH", "LANG", "LC_ALL"]:
    graphics[key] = %getEnv(key)
  var fonts = newJNull()
  if fileExists("/etc/fonts/fonts.conf"): fonts = %sha256File("/etc/fonts/fonts.conf")
  %*{"platform": hostOS, "architecture": hostCPU, "hostname": getHostname(),
    "cpu_model": model, "allowed_cpus": affinity,
    "requested_cpu": (if config.cpu.isSome: %config.cpu.get else: newJNull()),
    "graphics_environment": graphics, "fontconfig_sha256": fonts, "toolchain": compiler}

proc loadDocument(path: string): JsonNode =
  if not fileExists(path) or getFileSize(path) > 100_663_296:
    reject("missing or excessive performance JSON: " & path)
  try: result = parseFile(path)
  except JsonParsingError as error: reject("invalid performance JSON: " & error.msg)

proc required(record: JsonNode, key: string, kind: JsonNodeKind): JsonNode =
  if record == nil or record.kind != JObject or not record.hasKey(key) or record[key].kind != kind:
    reject("missing or invalid performance field: " & key)
  record[key]

proc validateBaseline(baseline, report: JsonNode, config: PerformanceConfig) =
  if required(baseline, "schema", JInt).getInt != PerformanceSchema or
      required(baseline, "status", JString).getStr != "passed":
    reject("baseline must be a passed schema 2 report")
  for key in ["suite", "parameters", "environment"]:
    if not baseline.hasKey(key) or baseline[key] != report[key]: reject("baseline " & key & " mismatch")
  let groups = required(baseline, "groups", JObject)
  let names = groupNames(config)
  if groups.len != names.len: reject("baseline groups differ")
  for name in names:
    let group = required(groups, name, JObject)
    if required(group, "status", JString).getStr != "passed" or
        required(group, "scenarios", JArray) != %scenarioNames(name):
      reject("baseline group not complete: " & name)
    let samples = required(group, "samples", JArray)
    validateSamples(samples, config, scenarioNames(name))
    for sample in samples:
      if required(sample, "group", JString).getStr != name: reject("foreign baseline sample")
    discard required(group, "metadata", JObject)
    let cycles = required(group, "cycles", JArray)
    if cycles.len != config.repeats: reject("incomplete baseline cycles")
    for i, cycle in cycles.elems:
      if required(cycle, "cycle", JInt).getInt != i + 1 or
          required(cycle, "summary", JObject) != summarizeCycle(samples, i + 1):
        reject("baseline summary does not match its raw observations")

proc comparable(summary, metadata, report: JsonNode): JsonNode =
  %*{"schema": PerformanceSchema, "summary": summary,
    "environment": {"machine": report["environment"], "workload": metadata},
    "parameters": report["parameters"]}

proc runPerformance*(config: PerformanceConfig,
    projectRoot = currentSourcePath().parentDir.parentDir.parentDir): JsonNode =
  validateConfig(config)
  let root = expandFilename(absolutePath(projectRoot))
  let output = normalizedPath(absolutePath(config.output, root))
  # A baseline is immutable even when the requested output directory is reused.
  let baselinePath = if config.baseline.len > 0: normalizedPath(absolutePath(config.baseline, root)) else: ""
  if baselinePath.len > 0:
    let latest = output / "latest.json"
    if baselinePath == latest or (fileExists(baselinePath) and fileExists(latest) and
        expandFilename(baselinePath) == expandFilename(latest)):
      reject("baseline cannot be the report output latest.json; copy it to an immutable file")
  createDir(output / "runs")
  let runDirectory = createTempDir("run-", "", output / "runs")
  let wholeStart = getMonoTime()
  result = %*{"schema": PerformanceSchema, "status": "running",
    "suite": $config.suite, "parameters": measurementParameters(config),
    "gates": {"max_regression": config.maxRegression,
      "budget_ms": (if config.budgetMs.isSome: %config.budgetMs.get else: newJNull()),
      "rss_growth_mib": (if config.rssLimitMiB.isSome: %config.rssLimitMiB.get else: newJNull())},
    "environment": {}, "provenance": {}, "groups": {}, "failures": [],
    "started_utc": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "run_directory": runDirectory,
    "comparison_mode": (if baselinePath.len > 0: "external_baseline" else: "first_cycle")}
  let report = result
  proc saveReport() =
    report["elapsed_seconds"] = %((getMonoTime() - wholeStart).inNanoseconds.float64 / 1_000_000_000)
    let document = report.pretty() & "\n"
    atomicWrite(runDirectory / "report.json", document)
    atomicWrite(output / "latest.json", document)
  beginSignals()
  defer: endSignals()
  try:
    let names = groupNames(config)
    if "native" in names:
      when defined(linux):
        if getEnv("DISPLAY").len == 0 and getEnv("WAYLAND_DISPLAY").len == 0:
          reject("native suite requires a graphical session (DISPLAY or WAYLAND_DISPLAY)")
    var affinityTool: string
    if config.cpu.isSome:
      when defined(linux): affinityTool = executable("taskset")
      else: reject("--cpu affinity is currently supported only on Linux")
    let tools = toolchain(root, config.timeoutSeconds)
    let sources = sourceIdentity(root)
    report["environment"] = machineEnvironment(config, tools.identity)
    let measurementSources = newJObject()
    var measurementPaths = @["benchmarks/measurement.nim",
      "src/leaf/performance_scenarios.nim", "src/leaf/process_metrics.nim"]
    for name in names: measurementPaths.add("benchmarks/performance_" & name & ".nim")
    for path in measurementPaths:
      if sources["files"].hasKey(path): measurementSources[path] = sources["files"][path]
    report["environment"]["measurement_sources"] = measurementSources
    report["provenance"] = %*{"source": sources, "root": root, "binaries": {}}
    var baseline: JsonNode
    if baselinePath.len > 0:
      baseline = loadDocument(baselinePath)
      validateBaseline(baseline, report, config)
    let buildDirectory = output / "build"
    createDir(buildDirectory)
    let manifestPath = buildDirectory / "manifest.json"
    let buildIdentity = %*{"schema": PerformanceSchema, "source": sources, "toolchain": tools.identity}
    var manifest: JsonNode
    if config.noBuild:
      manifest = loadDocument(manifestPath)
      for key in ["schema", "source", "toolchain"]:
        if not manifest.hasKey(key) or manifest[key] != buildIdentity[key]:
          reject("--no-build " & key & " mismatch; rebuild required")
      discard required(manifest, "binaries", JObject)
    else:
      manifest = buildIdentity.copy()
      manifest["binaries"] = newJObject()
    # Complete every compilation before any timed harness starts.
    for name in names:
      checkStop()
      let binary = buildDirectory / ("performance_" & name).addFileExt(ExeExt)
      if not config.noBuild:
        let ccKind = when defined(macosx): "clang" else: "gcc"
        let args = @["c", "--skipCfg:on", "--skipUserCfg:on", "--skipParentCfg:on",
          "--skipProjCfg:on", "--forceBuild:on", "-d:release", "--mm:orc", "--threads:on", "--opt:speed",
          "--assertions:on", "--boundChecks:on", "--hints:off", "--cc:" & ccKind,
          "--" & ccKind & ".exe:" & tools.cc, "--" & ccKind & ".linkerexe:" & tools.cc,
          "--path:" & root / "src", "--nimcache:" & buildDirectory / ("cache-" & name),
          "--out:" & binary, root / "benchmarks" / ("performance_" & name & ".nim")]
        discard command(tools.nim, args, root, config.timeoutSeconds, runDirectory / (name & ".build.log"))
        if not fileExists(binary): reject("compiler did not produce " & binary)
        manifest["binaries"][name] = %sha256File(binary)
      if not fileExists(binary) or not manifest["binaries"].hasKey(name) or
          manifest["binaries"][name] != %sha256File(binary):
        reject("--no-build binary mismatch: " & name)
      report["provenance"]["binaries"][name] = manifest["binaries"][name]
    if sourceIdentity(root) != sources: reject("sources changed during compilation; rebuild required")
    if not config.noBuild: atomicWrite(manifestPath, manifest.pretty() & "\n")
    for groupName in names:
      checkStop()
      let name = groupName
      let protocol = newMeasurementProtocol(config, name, scenarioNames(name), tools.version)
      let group = %*{"status": "running", "scenarios": scenarioNames(name),
        "samples": protocol.samples, "cycles": []}
      report["groups"][name] = group
      var firstCycle: JsonNode
      proc accepted(cycle: int, summary: JsonNode) =
        let metadata = protocol.header["metadata"]
        let current = comparable(summary, metadata, report)
        var failures: seq[string]
        if baseline != nil:
          let old = baseline["groups"][name]
          failures.add(compareReports(current,
            comparable(old["cycles"][cycle - 1]["summary"], old["metadata"], baseline), config.maxRegression))
        elif firstCycle != nil:
          failures.add(compareReports(current, firstCycle, config.maxRegression))
        else: firstCycle = current
        if config.budgetMs.isSome: failures.add(budgetFailures(summary, config.budgetMs.get))
        if config.rssLimitMiB.isSome: failures.add(rssFailures(protocol.samples, config.rssLimitMiB.get))
        group["cycles"].add(%*{"cycle": cycle, "summary": summary, "failures": failures})
        stdout.writeLine(name & " cycle " & $cycle & "/" & $config.repeats &
          (if failures.len == 0: " passed" else: " failed"))
        stdout.flushFile()
        if failures.len > 0: reject(failures.join("; "))
      let env = inheritedEnvironment()
      env["LEAF_PERF_CONFIG"] = $measurementParameters(config)
      let binary = buildDirectory / ("performance_" & name).addFileExt(ExeExt)
      let exe = if affinityTool.len > 0: affinityTool else: binary
      let args = if affinityTool.len > 0: @["-c", $config.cpu.get, binary] else: @[]
      try:
        discard command(exe, args, root, config.timeoutSeconds, runDirectory / (name & ".raw.log"), env,
          proc(chunk: string) = protocol.feed(chunk, accepted))
        protocol.finish(0)
        group["status"] = %"passed"
      except CatchableError:
        group["status"] = %"failed"
        raise
      finally:
        if protocol.header != nil: group["metadata"] = protocol.header["metadata"]
    for name in names:
      checkStop()
      if sha256File(buildDirectory / ("performance_" & name).addFileExt(ExeExt)) !=
          report["provenance"]["binaries"][name].getStr:
        reject("binary changed during measurement: " & name)
    if sourceIdentity(root) != sources: reject("sources changed during measurement; report is invalid")
    report["status"] = %"passed"
    saveReport()
  except CatchableError as error:
    report["status"] = %"failed"
    report["failures"].add(%error.msg)
    try: saveReport()
    except CatchableError as writeError:
      stderr.writeLine("could not save failed performance report: " & writeError.msg)
    raise
