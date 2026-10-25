import ./cleanup_support
import std/[unittest, os, osproc, tempfiles, json, strutils, times, options]
import leaf
import ../fixture_app
import leaf/[diagnostics, build, doctor, project, targets]
import ../../examples/counter

let root = createTempDir("leaf-diagnostics-", "")
removeDirectoryOnExit(root)
proc complete(job: BuildJob) =
  let deadline = epochTime() + 30
  while not job.pollBuild():
    if epochTime() > deadline: raise newException(IOError, "test compiler timed out")
    sleep(10)

suite "Nim diagnostics and build pipeline":
  test "structured events and last successful snapshot use real runtime":
    let log = root / "events.jsonl"
    let dump = root / "tree.json"
    let d = newDiagnostics(logFile = log, dumpFile = dump)
    let rt = newRuntime(counterApp(), diagnostics = d)
    discard rt.dispatch("add", Event(kind: click)); discard rt.dispatch("add", Event(kind: click))
    d.close()
    var events, renders = 0
    for line in readFile(log).strip.splitLines:
      let record = parseJson(line)
      check record["time_ms"].getInt > 0
      check record["pid"].getInt > 0
      if record["phase"].getStr == "event" and record["status"].getStr == "ok": inc events
      if record["phase"].getStr == "render" and record["status"].getStr == "ok": inc renders
    check events == 2
    check renders == 3
    check parseFile(dump)["root"]["children"][1]["text"].getStr == "2"
  test "failed render logs error and keeps the successful dump":
    var broken = false
    let dump = root / "retained.json"
    let log = root / "failure.jsonl"
    let d = newDiagnostics(logFile = log, dumpFile = dump)
    defer: d.close()
    let rt = newRuntime(fixtureApplication(proc(): Node =
      if broken: raise newException(ValueError, "failed render")
      text("retained"), "Errors", 100, 100), diagnostics = d)
    let before = readFile(dump)
    broken = true
    expect ValueError: discard rt.refresh()
    check readFile(dump) == before
    check "failed render" in readFile(log)
  test "diagnostic outputs cannot overwrite sources and config":
    let protected = root / "protected"
    createDir(protected)
    for name in ["main.nim", "config.nims", "leaf.json"]:
      let path = protected / name
      writeFile(path, "original")
      expect ValueError: discard newDiagnostics(logFile = path)
      expect ValueError: discard newDiagnostics(dumpFile = path)
      check readFile(path) == "original"
  test "log and snapshot aliases are rejected before creating output":
    let path = root / "same.json"
    expect ValueError: discard newDiagnostics(logFile = path, dumpFile = root / "." / "same.json")
    check not fileExists(path)
  test "watch outputs cannot create a reload loop in assets":
    let assets = root / "assets"
    createDir(assets)
    expect ValueError: discard newDiagnostics(logFile = assets / "trace.jsonl", projectRoot = root, watching = true)
    check not fileExists(assets / "trace.jsonl")
  when defined(posix):
    test "a disguised symlink output still cannot overwrite Nim source":
      let source = root / "protected.nim"
      writeFile(source, "original")
      let alias = root / "alias.log"
      createSymlink(source, alias)
      expect ValueError: discard newDiagnostics(logFile = alias)
      check readFile(source) == "original"
    test "hard linked diagnostic output cannot modify another file":
      let source = root / "hard-source.nim"
      writeFile(source, "original")
      let alias = root / "hard-alias.log"
      createHardlink(source, alias)
      expect ValueError: discard newDiagnostics(logFile = alias)
      check readFile(source) == "original"
  test "real compiler supports space and shell metacharacters in project paths":
    let directory = root / "my app's $(literal)"
    createDir(directory)
    writeFile(directory / "main.nim", "static: echo \"compiler stdout\"\necho \"compiled\"\n")
    let project = readProject(directory / "main.nim")
    let job = startBuild(project, selection=some(resolveBuild(project.backend, headlessOnly=true)))
    defer: job.close()
    job.complete()
    check job.code == 0
    check fileExists(job.binary)
    check "compiler stdout" in job.output
  test "compiler failure is captured without replacing the previous binary":
    let directory = root / "broken"
    createDir(directory)
    writeFile(directory / "main.nim", "this is not valid Nim !!!")
    let binary = directory / "previous"
    writeFile(binary, "previous executable")
    let job = startBuild(readProject(directory / "main.nim"), output = directory / "candidate", selection=some(resolveBuild(backendNative, headlessOnly=true)))
    defer: job.close()
    job.complete()
    check job.code != 0
    check "Error" in job.output
    check "main.nim" in job.output
    check job.pollBuild()
    let failedCode = job.code
    let failedOutput = job.output
    job.close()
    job.close()
    check job.pollBuild()
    check job.code == failedCode
    check job.output == failedOutput
    check readFile(binary) == "previous executable"
    writeFile(directory / "main.nim", "echo \"repaired\"\n")
    let repaired = startBuild(readProject(directory / "main.nim"), output = directory / "candidate", selection=some(resolveBuild(backendNative, headlessOnly=true)))
    defer: repaired.close()
    repaired.complete()
    check repaired.code == 0
    check fileExists(repaired.binary)
    check readFile(binary) == "previous executable"
  test "doctor works without display and identifies compiler version":
    let display = getEnv("DISPLAY"); let wayland = getEnv("WAYLAND_DISPLAY")
    delEnv("DISPLAY"); delEnv("WAYLAND_DISPLAY")
    defer: putEnv("DISPLAY", display); putEnv("WAYLAND_DISPLAY", wayland)
    let report = doctorReport()
    check report["implementation"].getStr == "nim"
    check "2.2.6" in report["tools"]["nim"].getStr
    when not defined(windows): check not report["host_available"].getBool
    check report["desktop_backend"].getStr == "native"
    check not report.hasKey("gpui")
