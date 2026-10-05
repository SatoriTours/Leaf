import ./cleanup_support
import std/[unittest, os, osproc, tempfiles, json, strutils, times]
import leaf
import leaf/[diagnostics, build, doctor, project, gpui_build]
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
    let rt = newRuntime(Application(title: "Errors", width: 100, height: 100,
      render: proc(ctx: BuildContext): Node =
        if broken: raise newException(ValueError, "failed render")
        text("retained")), diagnostics = d)
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
    test "Cargo discovery preserves the executable name of a multicall symlink":
      let directory = root / "cargo shim"
      createDir(directory)
      let cargo = findExe("cargo", followSymlinks = false)
      require cargo.len > 0
      let shim = directory / "multicall"
      writeFile(shim, "#!/bin/sh\n" &
        "case \"${0##*/}\" in cargo) ;; *) exit 86 ;; esac\n" &
        "exec " & quoteShell(cargo) & " \"$@\"\n")
      setFilePermissions(shim, {fpUserRead, fpUserWrite, fpUserExec})
      createSymlink(shim, directory / "cargo")
      let previousPath = getEnv("PATH")
      let hadCargo = existsEnv("CARGO")
      let previousCargo = getEnv("CARGO")
      let hadLibrary = existsEnv("LEAF_GPUI_LIBRARY")
      let previousLibrary = getEnv("LEAF_GPUI_LIBRARY")
      putEnv("PATH", directory & PathSep & previousPath)
      delEnv("CARGO")
      delEnv("LEAF_GPUI_LIBRARY")
      defer:
        putEnv("PATH", previousPath)
        if hadCargo: putEnv("CARGO", previousCargo)
        else: delEnv("CARGO")
        if hadLibrary: putEnv("LEAF_GPUI_LIBRARY", previousLibrary)
        else: delEnv("LEAF_GPUI_LIBRARY")
      check fileExists(ensureGpui())
      check "cargo " in doctorReport()["tools"]["cargo"].getStr
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
    let job = startBuild(project)
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
    let job = startBuild(readProject(directory / "main.nim"), output = directory / "candidate")
    defer: job.close()
    job.complete()
    check job.code != 0
    check "Error" in job.output
    check readFile(binary) == "previous executable"
  test "doctor works without display and identifies compiler version":
    let display = getEnv("DISPLAY"); let wayland = getEnv("WAYLAND_DISPLAY")
    delEnv("DISPLAY"); delEnv("WAYLAND_DISPLAY")
    defer: putEnv("DISPLAY", display); putEnv("WAYLAND_DISPLAY", wayland)
    let report = doctorReport()
    check report["implementation"].getStr == "nim"
    check "2.2.6" in report["tools"]["nim"].getStr
    when defined(linux): check not report["graphical_session"].getBool
    check report["desktop_backend"].getStr == "gpui"
    check report["gpui_kit"].getStr == "0.7.0"
