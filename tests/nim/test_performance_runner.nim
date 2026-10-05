import std/[unittest, options, strutils, os, json, tempfiles, times, monotimes, osproc]
import leaf/[performance_report, performance_runner, performance_scenarios, process_io]
when defined(posix): import std/posix
when defined(windows): import std/winlean

# Real subprocesses below emit synthetic data to test orchestration; their
# latencies and Release metadata are fixtures, never benchmark evidence.
proc fixtureChild(marker: string) =
  discard startProcess(getAppFilename(), args = @["--fixture-child", marker],
    options = {poParentStreams})
  while not fileExists(marker): sleep(5)
  while true: sleep(25)

let arguments = commandLineParams()
if arguments.len == 2 and arguments[0] == "--fixture-child":
  when defined(posix): discard posix.signal(SIGTERM, SIG_IGN)
  writeFile(arguments[1], $getCurrentProcessId())
  while true: sleep(25)
if arguments.len > 0 and getEnv("LEAF_TEST_PERF_FIXTURE") == "1":
  if arguments[0] == "--version":
    # Cold toolchain setup can exceed the progress test's old observation window.
    if getEnv("LEAF_TEST_PERF_MODE") == "pause": sleep(1500)
    echo "Nim Compiler Version ", NimVersion, " [", hostOS, ": ", hostCPU, "]"
    quit(0)
  if arguments[0] == "c":
    if getEnv("LEAF_TEST_PERF_MODE") == "compile-hang": fixtureChild(getEnv("LEAF_TEST_PERF_MARKER"))
    if getEnv("LEAF_TEST_PERF_MODE") == "compile-fail": quit(7)
    var output: string
    for arg in arguments:
      if arg.startsWith("--out:"): output = arg[6..^1]
    if output.len == 0: quit(8)
    # Real Nim adds the native extension to extensionless Windows outputs.
    when defined(windows):
      if output.splitFile.ext.len == 0: output.add(".exe")
    copyFile(getAppFilename(), output)
    setFilePermissions(output, getFilePermissions(getAppFilename()))
    let trace = open(getCurrentDir() / "trace", fmAppend)
    trace.writeLine("compile:" & output.extractFilename)
    trace.close()
    quit(0)
  if arguments[0] == "--fixture-run":
    try:
      discard runPerformance(parsePerformanceArgs(arguments[2..^1]).config, arguments[1])
      performanceExit(0)
    except CatchableError as error:
      stderr.writeLine(error.msg)
      performanceExit(performanceFailureCode(error))

if getEnv("LEAF_TEST_PERF_FIXTURE") == "1" and arguments.len == 0 and
    getAppFilename().extractFilename.startsWith("performance_"):
  let mode = getEnv("LEAF_TEST_PERF_MODE")
  let group = if getAppFilename().extractFilename.startsWith("performance_native"): "native" else: "runtime"
  let names = if group == "native": @NativeScenarios else: @RuntimeScenarios
  let config = parseJson(getEnv("LEAF_PERF_CONFIG"))
  var observedAffinity = ""
  when defined(linux):
    for statusLine in readFile("/proc/self/status").splitLines():
      if statusLine.startsWith("Cpus_allowed_list:"):
        observedAffinity = statusLine.split(':', 1)[^1].strip()
  let trace = open(getCurrentDir() / "trace", fmAppend)
  trace.writeLine("measure:" & group)
  trace.close()
  if mode == "hang": fixtureChild(getEnv("LEAF_TEST_PERF_MARKER"))
  if mode == "exit7": quit(7)
  if mode == "overflow":
    for i in 0..520: stdout.write(repeat('x', 65535) & "\n")
    stdout.flushFile()
    while true: sleep(25)
  proc emit(record: JsonNode) =
    stdout.writeLine("LEAF_PERF " & $record)
    stdout.flushFile()
  emit(%*{"type": "header", "schema": 2, "group": group, "parameters": config,
    "scenarios": names, "metadata": {"compiler": NimVersion, "platform": hostOS,
      "architecture": hostCPU, "release": true, "memory_manager": "orc",
      "scope": "synthetic process fixture"}})
  if mode == "incomplete": quit(0)
  for cycle in 1..config["repeats"].getInt:
    if cycle == 3 and mode == "drift": writeFile(getCurrentDir() / "unexpected-third-cycle", "started")
    for name in names:
      for round in 1..config["rounds"].getInt:
        var latencies = newJArray()
        let latency = if mode == "drift" and cycle >= 2: 2.0 else: 1.0
        for operation in 0..<config["iterations"].getInt: latencies.add(%latency)
        emit(%*{"type": "sample", "group": group, "scenario": name,
          "cycle": cycle, "round": round, "operations": latencies.len,
          "latency_ms": latencies, "checks_passed": true,
          "resources": {"rss_start_kib": 1024,
            "rss_after_gc_kib": (if mode == "rss" and cycle >= 2: 4096 else: 1024),
            "heap_after_gc_bytes": 64, "cpu_seconds": 0.01},
          "elapsed_wall_ms": 3, "runtime": {"operations": cycle, "cpu_affinity": observedAffinity}})
    emit(%*{"type": "cycle_complete", "group": group, "cycle": cycle,
      "samples": names.len * config["rounds"].getInt, "elapsed_wall_ms": cycle * 10})
    if mode == "drift" and cycle == 2: sleep(500)
    if mode == "pause" and cycle == 1:
      # Keep the producer live until its parent actually observes progress.
      while not fileExists(getEnv("LEAF_TEST_PERF_MARKER")): sleep(5)
  if mode == "source-change": writeFile(getCurrentDir() / "src" / "dummy.nim", "changed while measuring")
  when defined(posix):
    if mode == "binary-change":
      let binary = getAppFilename()
      moveFile(binary, binary & ".old")
      copyFile(getCurrentDir() / "bin" / "nim".addFileExt(ExeExt), binary)
      let file = open(binary, fmAppend)
      file.write("replaced while measuring")
      file.close()
  emit(%*{"type": "complete", "group": group, "cycles": config["repeats"].getInt})
  quit(0)

proc alive(pid: int): bool =
  when defined(linux):
    try:
      let stat = readFile("/proc/" & $pid & "/stat")
      result = stat[stat.rfind(')') + 2] notin {'Z', 'X'}
    except IOError: discard
  elif defined(posix): result = posix.kill(Pid(pid), 0) == 0
  elif defined(windows):
    let handle = openProcess(0x1000, 0, int32(pid))
    if handle != 0:
      result = waitForSingleObject(handle, 0) == WAIT_TIMEOUT
      discard closeHandle(handle)

proc fixtureProject(): string =
  result = createTempDir("leaf-perf-runner-", "")
  for folder in ["src", "benchmarks", "bin"]: createDir(result / folder)
  writeFile(result / "src" / "dummy.nim", "discard\n")
  for group in ["runtime", "native"]:
    writeFile(result / "benchmarks" / ("performance_" & group & ".nim"), "discard\n")
  let compiler = result / "bin" / "nim".addFileExt(ExeExt)
  copyFile(getAppFilename(), compiler)
  setFilePermissions(compiler, getFilePermissions(getAppFilename()))
  putEnv("NIM", compiler)
  putEnv("LEAF_PERF_CC", compiler)
  putEnv("LEAF_TEST_PERF_FIXTURE", "1")
  putEnv("LEAF_TEST_PERF_MODE", "valid")

proc fixtureConfig(): PerformanceConfig =
  result = defaultPerformanceConfig()
  result.iterations = 2
  result.warmup = 1
  result.rounds = 1
  result.repeats = 2
  result.timeoutSeconds = 10

let originalNim = getEnv("NIM")
let originalCc = getEnv("LEAF_PERF_CC")
let originalDisplay = getEnv("DISPLAY")
let originalWayland = getEnv("WAYLAND_DISPLAY")

template ownedFixture(body: untyped) =
  block:
    let root {.inject.} = fixtureProject()
    defer:
      putEnv("NIM", originalNim)
      if originalCc.len > 0: putEnv("LEAF_PERF_CC", originalCc)
      else: delEnv("LEAF_PERF_CC")
      putEnv("DISPLAY", originalDisplay)
      putEnv("WAYLAND_DISPLAY", originalWayland)
      delEnv("LEAF_TEST_PERF_FIXTURE")
      delEnv("LEAF_TEST_PERF_MODE")
      delEnv("LEAF_TEST_PERF_MARKER")
      removeDir(root)
    body

suite "Nim performance command options":
  test "default runtime measurement works without requesting a graphical session":
    let parsed = parsePerformanceArgs(@[])
    check parsed.config.suite == runtimeSuite
    check parsed.config.iterations == 100
    check parsed.config.timeoutSeconds == 600
    check not parsed.config.noBuild
    check not parsed.help

  test "separate and equals syntax preserve all requested measurement and gate settings":
    let config = parsePerformanceArgs(@["--suite=all", "--iterations", "20",
      "--warmup=32", "--rounds", "3", "--repeat=4", "--interval=0.25",
      "--timeout", "90", "--output", "测量 输出", "--no-build",
      "--cpu=2", "--baseline", "baseline.json", "--max-regression=0.1",
      "--budget-ms", "8", "--max-rss-growth-mib=64"]).config
    check config.suite == allSuites
    check config.iterations == 20
    check config.warmup == 32
    check config.rounds == 3
    check config.repeats == 4
    check config.intervalSeconds == 0.25
    check config.timeoutSeconds == 90
    check config.output == "测量 输出"
    check config.baseline == "baseline.json"
    check config.noBuild
    check config.cpu == some(2)
    check config.maxRegression == 0.1
    check config.budgetMs == some(8.0)
    check config.rssLimitMiB == some(64.0)
    check parsePerformanceArgs(@["--suite", "native"]).config.suite == nativeSuite

  test "typos duplicated flags missing values and positional arguments cannot silently change a run":
    for args in [@["--round", "3"], @["--suite", "rust"], @["--rounds"],
        @["--output", "--no-build"], @["--rounds=1", "--rounds", "2"],
        @["--no-build=false"], @["--no-build", "--no-build"],
        @["--baseline="], @["file.nim"], @["--help=true"]]:
      expect PerformanceError: discard parsePerformanceArgs(args)

  test "numbers remain subject to finite resource work and deadline bounds":
    for args in [@["--iterations=0"], @["--iterations=one"], @["--cpu=-1"],
        @["--budget-ms=NaN"], @["--max-regression=Inf"], @["--timeout=3601"],
        @["--interval=-1"], @["--rounds=100", "--repeat=100"],
        @["--iterations=10000", "--rounds=100", "--repeat=2"]]:
      expect PerformanceError: discard parsePerformanceArgs(args)

  test "help explains the measurement and comparison limits":
    check parsePerformanceArgs(@["-h"]).help
    check parsePerformanceArgs(@["--help"]).help
    check "schema 2" in PerformanceHelp
    check "same machine" in PerformanceHelp
    check "RSS" in PerformanceHelp
    check "synchronous" in PerformanceHelp

suite "Owned performance builds and measurements":
  test "reports record the configured gate policy independently of workload identity":
    ownedFixture:
      var config = fixtureConfig()
      config.maxRegression = 0.5
      config.budgetMs = some(2.0)
      config.rssLimitMiB = some(1.0)
      let report = runPerformance(config, root)
      check report.hasKey("gates")
      if report.hasKey("gates"):
        check report["gates"] == %*{"max_regression": 0.5, "budget_ms": 2.0, "rss_growth_mib": 1.0}
        check parseFile(root / config.output / "latest.json")["gates"] == report["gates"]

  test "progress is observable before the live subprocess completes":
    ownedFixture:
      putEnv("LEAF_TEST_PERF_MODE", "pause")
      let release = root / "release-after-observed-progress"
      putEnv("LEAF_TEST_PERF_MARKER", release)
      let child = startManaged(getAppFilename(), @["--fixture-run", root,
        "--iterations=2", "--warmup=1", "--rounds=1", "--repeat=2", "--timeout=10"], root)
      defer: child.close()
      let deadline = getMonoTime() + initDuration(seconds = 20)
      var observed = false
      while getMonoTime() < deadline:
        let finished = child.poll()
        if "runtime cycle 1/2 passed" in child.output:
          observed = true
          check not finished
          break
        if finished: break
        sleep(5)
      check observed
      writeFile(release, "parent observed progress")
      while not child.poll() and getMonoTime() < deadline: sleep(5)
      check child.checkExit()
      check child.code == 0

  test "all selected Release builds precede sequential groups and complete raw reports":
    ownedFixture:
      putEnv("DISPLAY", ":synthetic")
      var config = fixtureConfig()
      config.suite = allSuites
      config.output = "输出 测量"
      let report = runPerformance(config, root)
      check report["status"].getStr == "passed"
      check report["groups"].len == 2
      check report["groups"]["runtime"]["samples"].len == 14
      check report["groups"]["native"]["samples"].len == 6
      let trace = readFile(root / "trace").splitLines()
      check trace[0].startsWith("compile:performance_runtime")
      check trace[1].startsWith("compile:performance_native")
      check trace[2] == "measure:runtime"
      check trace[3] == "measure:native"
      check fileExists(report["run_directory"].getStr / "runtime.raw.log")
      check parseFile(root / config.output / "latest.json")["status"].getStr == "passed"

  test "no-build accepts an exact manifest and rejects changed source or binary":
    ownedFixture:
      createDir(root / "crates/leaf-gpui/src")
      writeFile(root / "crates/leaf-gpui/src/lib.rs", "// GPUI source\n")
      writeFile(root / "Cargo.lock", "# locked dependencies\n")
      var config = fixtureConfig()
      discard runPerformance(config, root)
      config.noBuild = true
      discard runPerformance(config, root)
      for source in ["crates/leaf-gpui/src/lib.rs", "Cargo.lock"]:
        let path=root / source
        let previous=readFile(path)
        writeFile(path,previous & "changed\n")
        expect PerformanceError:discard runPerformance(config,root)
        writeFile(path,previous)
      writeFile(root / "src" / "dummy.nim", "source changed\n")
      expect PerformanceError: discard runPerformance(config, root)
      check parseFile(root / config.output / "latest.json")["status"].getStr == "failed"
      writeFile(root / "src" / "dummy.nim", "discard\n")
      let binary = root / config.output / "build" / "performance_runtime".addFileExt(ExeExt)
      let file = open(binary, fmAppend)
      file.write("changed binary")
      file.close()
      expect PerformanceError: discard runPerformance(config, root)

  test "zero incomplete and nonzero child exits preserve failed evidence":
    for mode in ["incomplete", "exit7", "compile-fail"]:
      ownedFixture:
        putEnv("LEAF_TEST_PERF_MODE", mode)
        let config = fixtureConfig()
        expect PerformanceError: discard runPerformance(config, root)
        let report = parseFile(root / config.output / "latest.json")
        check report["status"].getStr == "failed"
        check report["failures"].len > 0
        check fileExists(report["run_directory"].getStr / "report.json")

  test "no-build rejects a changed compiler even when its version text is unchanged":
    ownedFixture:
      var config = fixtureConfig()
      discard runPerformance(config, root)
      let compiler = getEnv("NIM")
      let file = open(compiler, fmAppend)
      file.write("changed compiler overlay")
      file.close()
      config.noBuild = true
      expect PerformanceError: discard runPerformance(config, root)

  when defined(posix):
    test "rebuilding after same-path C compiler replacement uses the new compiler":
      ownedFixture:
        # A real Nim/C compilation is essential: the copied fixture compiler
        # cannot expose Nim's reuse of cached C objects. These sample values
        # identify the compiled macro; they are not measured latency evidence.
        delEnv("LEAF_TEST_PERF_FIXTURE")
        let nim = if originalNim.len > 0: originalNim else: findExe("nim")
        let cc = findExe(when defined(macosx): "clang" else: "gcc")
        require nim.len > 0 and cc.len > 0
        putEnv("NIM", nim)
        let wrapper = root / "bin" / "real-cc"
        putEnv("LEAF_PERF_CC", wrapper)
        proc replaceCompiler(value: int) =
          writeFile(wrapper, "#!/bin/sh\nexec " & quoteShell(cc) &
            " -DLEAF_COMPILER_VARIANT=" & $value & " \"$@\"\n")
          setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
        writeFile(root / "benchmarks" / "performance_runtime.nim", """
import std/[os, json]
{.emit: "int leaf_compiler_variant(void) { return LEAF_COMPILER_VARIANT; }".}
proc variant(): cint {.importc: "leaf_compiler_variant", nodecl.}
let config = parseJson(getEnv("LEAF_PERF_CONFIG"))
""" & "let names = " & $(@RuntimeScenarios) & "\n" & """
proc emit(record: JsonNode) =
  stdout.writeLine("LEAF_PERF " & $record)
emit(%*{"type": "header", "schema": 2, "group": "runtime", "parameters": config,
  "scenarios": names, "metadata": {"compiler": NimVersion, "platform": hostOS,
    "architecture": hostCPU, "release": true, "memory_manager": "orc",
    "scope": "synthetic compiler identity fixture"}})
for name in names:
  emit(%*{"type": "sample", "group": "runtime", "scenario": name,
    "cycle": 1, "round": 1, "operations": 1, "latency_ms": [variant()],
    "checks_passed": true, "runtime": {}, "elapsed_wall_ms": 1,
    "resources": {"rss_start_kib": 1, "rss_after_gc_kib": 1,
      "heap_start_bytes": 1, "heap_after_gc_bytes": 1,
      "reserved_heap_after_gc_bytes": 1, "peak_rss_kib": 1, "cpu_seconds": 0}})
emit(%*{"type": "cycle_complete", "group": "runtime", "cycle": 1,
  "samples": names.len, "elapsed_wall_ms": 1})
emit(%*{"type": "complete", "group": "runtime", "cycles": 1})
""")
        var config = fixtureConfig()
        config.iterations = 1
        config.repeats = 1
        replaceCompiler(1)
        let before = runPerformance(config, root)
        replaceCompiler(2)
        let after = runPerformance(config, root)
        check before["groups"]["runtime"]["samples"][0]["latency_ms"][0].getInt == 1
        check after["groups"]["runtime"]["samples"][0]["latency_ms"][0].getInt == 2
        check before["environment"]["toolchain"]["c_compiler"]["sha256"] !=
          after["environment"]["toolchain"]["c_compiler"]["sha256"]
        config.noBuild = true
        let reused = runPerformance(config, root)
        check reused["groups"]["runtime"]["samples"][0]["latency_ms"][0].getInt == 2

  test "regression stops at cycle two and retains the two completed cycles":
    ownedFixture:
      var config = fixtureConfig()
      config.repeats = 3
      putEnv("LEAF_TEST_PERF_MODE", "drift")
      expect PerformanceError: discard runPerformance(config, root)
      let report = parseFile(root / config.output / "latest.json")
      check report["groups"]["runtime"]["cycles"].len == 2
      check report["groups"]["runtime"]["samples"].len == 14
      check not fileExists(root / "unexpected-third-cycle")

  test "latency and cumulative RSS limits fail with a saved report":
    for mode in ["budget", "rss"]:
      ownedFixture:
        var config = fixtureConfig()
        if mode == "budget": config.budgetMs = some(0.5)
        else:
          config.rssLimitMiB = some(1.0)
          putEnv("LEAF_TEST_PERF_MODE", "rss")
        expect PerformanceError: discard runPerformance(config, root)
        check parseFile(root / config.output / "latest.json")["status"].getStr == "failed"

  test "external baseline is immutable complete and compatible before comparison":
    ownedFixture:
      var config = fixtureConfig()
      let baseline = runPerformance(config, root)
      config.baseline = root / "baseline.json"
      writeFile(config.baseline, $baseline)
      let original = readFile(config.baseline)
      config.noBuild = true
      discard runPerformance(config, root)
      check readFile(config.baseline) == original
      let originalDriver = getEnv("VK_ICD_FILENAMES")
      putEnv("VK_ICD_FILENAMES", if originalDriver == "driver-a": "driver-b" else: "driver-a")
      try:
        expect PerformanceError: discard runPerformance(config, root)
      finally:
        if originalDriver.len > 0: putEnv("VK_ICD_FILENAMES", originalDriver)
        else: delEnv("VK_ICD_FILENAMES")
      for mismatch in ["status", "environment", "parameters", "groups", "summary", "workload"]:
        let changed = baseline.copy()
        case mismatch
        of "status": changed["status"] = %"failed"
        of "environment": changed["environment"]["hostname"] = %"other-machine"
        of "parameters": changed["parameters"]["iterations"] = %20
        of "groups": changed["groups"] = newJObject()
        of "workload": changed["environment"]["measurement_sources"] = newJObject()
        else: changed["groups"]["runtime"]["cycles"][0]["summary"] = newJObject()
        writeFile(config.baseline, $changed)
        expect PerformanceError: discard runPerformance(config, root)
      config.baseline = root / config.output / "latest.json"
      let before = readFile(config.baseline)
      expect PerformanceError: discard runPerformance(config, root)
      check readFile(config.baseline) == before

  test "source edits during execution cannot produce a successful report":
    ownedFixture:
      putEnv("LEAF_TEST_PERF_MODE", "source-change")
      let config = fixtureConfig()
      expect PerformanceError: discard runPerformance(config, root)
      check parseFile(root / config.output / "latest.json")["status"].getStr == "failed"

  when defined(posix):
    test "binary replacement during execution invalidates its declared provenance":
      ownedFixture:
        putEnv("LEAF_TEST_PERF_MODE", "binary-change")
        let config = fixtureConfig()
        expect PerformanceError: discard runPerformance(config, root)
        check parseFile(root / config.output / "latest.json")["status"].getStr == "failed"

  when defined(linux):
    test "native without graphics fails explicitly and saves its report":
      ownedFixture:
        delEnv("DISPLAY")
        delEnv("WAYLAND_DISPLAY")
        var config = fixtureConfig()
        config.suite = nativeSuite
        expect PerformanceError: discard runPerformance(config, root)
        let report = parseFile(root / config.output / "latest.json")
        check "graphical session" in report["failures"][0].getStr
        check not fileExists(root / "trace")

    test "CPU request actually constrains the measurement child's affinity":
      ownedFixture:
        var cpu: int
        for statusLine in readFile("/proc/self/status").splitLines():
          if statusLine.startsWith("Cpus_allowed_list:"):
            cpu = parseInt(statusLine.split(':', 1)[^1].strip().split({',', '-'})[0])
        var config = fixtureConfig()
        config.cpu = some(cpu)
        let report = runPerformance(config, root)
        check report["groups"]["runtime"]["samples"][0]["runtime"]["cpu_affinity"].getStr == $cpu

  test "output overflow is bounded and still leaves a failure report":
    ownedFixture:
      putEnv("LEAF_TEST_PERF_MODE", "overflow")
      let config = fixtureConfig()
      expect PerformanceError: discard runPerformance(config, root)
      let report = parseFile(root / config.output / "latest.json")
      check report["status"].getStr == "failed"
      check getFileSize(report["run_directory"].getStr / "runtime.raw.log") <= 33_554_432

  test "deadline closes the resistant descendant of a hanging harness":
    ownedFixture:
      var config = fixtureConfig()
      config.timeoutSeconds = when defined(windows): 2.0 else: 0.5
      let marker = root / "child-pid"
      putEnv("LEAF_TEST_PERF_MODE", "hang")
      putEnv("LEAF_TEST_PERF_MARKER", marker)
      expect PerformanceError: discard runPerformance(config, root)
      check fileExists(marker)
      if fileExists(marker): check not alive(parseInt(readFile(marker)))
      check parseFile(root / config.output / "latest.json")["status"].getStr == "failed"

  when defined(posix):
    for signal in [SIGINT, SIGTERM]:
      test "signal " & $signal & " closes a compiler tree and records the interrupted run":
        ownedFixture:
          let marker = root / "child-pid"
          putEnv("LEAF_TEST_PERF_MODE", "compile-hang")
          putEnv("LEAF_TEST_PERF_MARKER", marker)
          let child = startManaged(getAppFilename(), @["--fixture-run", root,
            "--iterations=2", "--warmup=1", "--rounds=1", "--timeout=10"], root)
          defer: child.close()
          let deadline = epochTime() + 15
          while not fileExists(marker):
            if epochTime() > deadline or child.poll():
              raise newException(IOError, "fixture compiler startup failed: " & child.output)
            sleep(5)
          let resistant = parseInt(readFile(marker))
          discard posix.kill(Pid(child.pid), signal)
          while not child.poll():
            if epochTime() > deadline: raise newException(IOError, "fixture interruption deadline")
            sleep(5)
          check child.code == (if signal == SIGINT: 130 else: 143)
          check not alive(resistant)
          check parseFile(root / "artifacts" / "performance" / "latest.json")["status"].getStr == "failed"
