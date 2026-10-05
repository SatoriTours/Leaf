import ./cleanup_support
import std/[unittest, os, tempfiles, tables, json, times, strutils]
import leaf/[watch_files, watch_ipc, watch, project, process_io, diagnostics]

let root = createTempDir("leaf-watch-", "")
removeDirectoryOnExit(root)

proc waitFor(supervisor: WatchSupervisor, condition: proc(): bool) =
  let deadline = epochTime() + 40
  while not condition():
    supervisor.step()
    if epochTime() > deadline: raise newException(IOError, "watch timed out: " & supervisor.message)
    sleep(10)

proc readyProgram(version: string): string =
  """import std/[os, json]
writeFile(getEnv("LEAF_WATCH_READY"), $(%*{"version": 1, "token": getEnv("LEAF_WATCH_TOKEN"), "pid": getCurrentProcessId()}))
echo "VERSION"
while true: sleep(25)
""".replace("VERSION", version)

suite "Nim development watch":
  test "source and asset changes are detected, build directories and links are excluded":
    let directory = root / "files"
    createDir(directory / "assets")
    createDir(directory / "target")
    writeFile(directory / "main.nim", "discard")
    writeFile(directory / "assets" / "image.dat", "one")
    writeFile(directory / "target" / "ignored.nim", "discard")
    let initial = scanFiles(directory)
    check initial.len == 2
    writeFile(directory / "target" / "ignored.nim", "changed")
    check scanFiles(directory) == initial
    writeFile(directory / "assets" / "image.dat", "longer")
    check scanFiles(directory) != initial
    when defined(posix):
      createSymlink(root, directory / "cycle")
      check scanFiles(directory).len == 2
    removeFile(directory / "main.nim")
    check scanFiles(directory).len == 1
    expect ValueError: discard scanFiles(directory, maxEntries = 1)
  test "ready files require matching protocol token and live process identity":
    let path = root / "ready.json"
    writeFile(path, "{invalid}")
    check not isReady(path, "token", 20)
    writeReady(path, "token", 20)
    check isReady(path, "token", 20)
    check not isReady(path, "another", 20)
    check not isReady(path, "token", 21)
    writeFile(path, $(%*{"version": 2, "token": "token", "pid": 20}))
    check not isReady(path, "token", 20)
  test "real compiled candidates preserve old process across compile and startup failures":
    let directory = root / "app"
    createDir(directory)
    let entry = directory / "main.nim"
    writeFile(entry, readyProgram("first"))
    let supervisor = newWatchSupervisor(readProject(entry), scanIntervalMs = 0, debounceMs = 0, startupTimeoutMs = 500)
    defer: supervisor.close()
    supervisor.waitFor(proc(): bool = supervisor.current != nil)
    let oldPid = supervisor.current.pid
    writeFile(entry, "this is invalid Nim !!!")
    supervisor.waitFor(proc(): bool = supervisor.message.len > 0)
    check supervisor.current.pid == oldPid
    check not supervisor.current.poll()
    writeFile(entry, "quit(9)")
    supervisor.waitFor(proc(): bool = supervisor.message.len == 0)
    supervisor.waitFor(proc(): bool = supervisor.message.len > 0)
    check supervisor.current.pid == oldPid
    check not supervisor.current.poll()
    writeFile(entry, readyProgram("repaired"))
    supervisor.waitFor(proc(): bool = supervisor.current.pid != oldPid)
    check supervisor.message.len == 0
    check supervisor.generation >= 4
    let repairedPid = supervisor.current.pid
    let oldGeneration = supervisor.generation
    writeFile(entry, "import std/os\nstatic: sleep(350)\n" & readyProgram("stale"))
    supervisor.waitFor(proc(): bool = supervisor.buildJob != nil)
    writeFile(entry, readyProgram("latest source"))
    supervisor.waitFor(proc(): bool = supervisor.current.pid != repairedPid)
    check supervisor.generation >= oldGeneration + 2
    let latestPid = supervisor.current.pid
    writeFile(entry, "import std/os\nwhile true: sleep(25)\n")
    supervisor.waitFor(proc(): bool = supervisor.message.len > 0)
    check supervisor.current.pid == latestPid
    check "timeout" in supervisor.message
    writeFile(entry, readyProgram("will be cancelled"))
    supervisor.waitFor(proc(): bool = supervisor.buildJob != nil)
    let newProcess = supervisor.current
    supervisor.close()
    check newProcess.poll()
    check not dirExists(supervisor.sessionDir)

  test "diagnostic dump failures retain output and still retire the old process":
    let directory = root / "dump-error"
    createDir(directory)
    let entry = directory / "main.nim"
    writeFile(entry, readyProgram("old"))
    let dump = directory / "tree.json"
    writeFile(dump, "{\"known\":\"good\"}")
    let d = newDiagnostics(dumpFile = dump)
    defer: d.close()
    let s = newWatchSupervisor(readProject(entry), d, scanIntervalMs = 0, debounceMs = 0)
    defer: s.close()
    s.waitFor(proc(): bool = s.current != nil)
    let old = s.current
    defer: old.close()
    writeFile(entry, readyProgram("new").replace("echo", "writeFile(getEnv(\"LEAF_WATCH_READY\").parentDir / \"tree.json\", \"bad json\")\necho"))
    s.waitFor(proc(): bool = s.current.pid != old.pid)
    check old.poll()
    check readFile(dump) == "{\"known\":\"good\"}"
    check not s.current.poll()

  test "a ready candidate exiting during the final scan cannot retire the old process":
    let directory = root / "exit-during-scan"
    createDir(directory)
    let entry = directory / "main.nim"
    writeFile(entry, readyProgram("old"))
    var slowScan = false
    let scanner: FileScanner = proc(path: string): FileSnapshot =
      if slowScan: sleep(200)
      scanFiles(path)
    let s = newWatchSupervisor(readProject(entry), scanIntervalMs = 1000, debounceMs = 0, scanner = scanner)
    defer: s.close()
    s.waitFor(proc(): bool = s.current != nil)
    let oldPid = s.current.pid
    slowScan = true
    writeFile(entry, readyProgram("ready then exit").replace("while true: sleep(25)", "sleep(100)\nquit(7)"))
    s.waitFor(proc(): bool = s.message.len > 0 or s.finished)
    check not s.finished
    check s.current.pid == oldPid
    check not s.current.poll()
