## Transactional development supervisor. Build, launch, then replace on readiness.
import std/[os, tables, strtabs, monotimes, times, tempfiles, json]
import ./[project, build, process_io, diagnostics, watch_files, watch_ipc]

type FileScanner* = proc(root: string): FileSnapshot {.closure.}
type WatchSupervisor* = ref object
  project: Project
  diagnostics: Diagnostics
  sessionDir*, message*: string
  current*, candidate*: ManagedProcess
  buildJob*: BuildJob
  generation*, exitCode*: int
  finished*, disposed: bool
  snapshot: FileSnapshot
  dirty: bool
  lastScan, lastChange, launchTime: MonoTime
  scanInterval, debounce, startupTimeout: Duration
  revision: int
  candidateDir, activeDir, token: string
  outputLines: Table[int, string]
  dumpStamp: FileStamp
  scanner: FileScanner

proc scan(s: WatchSupervisor): FileSnapshot =
  if s.scanner == nil: scanFiles(s.project.root) else: s.scanner(s.project.root)

proc status(s: WatchSupervisor, message: string) =
  if s.revision > 0 and s.message == message: return
  s.message = message
  inc s.revision
  writeStatus(s.sessionDir / "status.json", s.revision, message)
  if message.len > 0:
    stderr.writeLine("leaf watch: " & message)
    s.diagnostics.record("watch", "error", %*{"generation": s.generation, "message": message})

proc forward(s: WatchSupervisor, p: ManagedProcess) =
  if p == nil: return
  let chunk = p.drain()
  var buffered = s.outputLines.getOrDefault(p.pid) & chunk
  var start = 0
  for i, c in buffered:
    if c == '\n':
      let line = buffered[start..<i]
      var structured = false
      try:
        let record = parseJson(line)
        if record.kind == JObject and "phase" in record and "status" in record and "details" in record:
          s.diagnostics.forwardRecord(record)
          structured = true
      except CatchableError: discard
      if not structured and line.len > 0: stderr.writeLine(line.diagnosticText())
      start = i + 1
  buffered = buffered[start..^1]
  if buffered.len > MaxProcessOutput: buffered = buffered[^MaxProcessOutput..^1]
  s.outputLines[p.pid] = move(buffered)

proc publishDump(s: WatchSupervisor) =
  if s.diagnostics == nil or s.diagnostics.dumpFile.len == 0 or s.activeDir.len == 0: return
  let path = s.activeDir / "tree.json"
  if not fileExists(path): return
  let info = getFileInfo(path)
  let stamp = FileStamp(size: info.size, modified: info.lastWriteTime)
  if stamp == s.dumpStamp: return
  # Private dumps are written by the runtime with the existing 16 MiB tree bound.
  s.dumpStamp = stamp
  try:
    if info.size > 134_217_728: raise newException(ValueError, "watch tree dump exceeds 128 MiB")
    let tree = parseFile(path)
    s.diagnostics.snapshot(tree)
  except CatchableError as error:
    stderr.writeLine("leaf: watch tree dump failed: " & error.msg)
    s.diagnostics.record("diagnostic", "error", %*{"message": error.msg})

proc newWatchSupervisor*(project: Project, diagnostics: Diagnostics = nil,
                         scanIntervalMs = 500, debounceMs = 200,
                         startupTimeoutMs = 10_000, scanner: FileScanner = nil): WatchSupervisor =
  if scanIntervalMs < 0 or debounceMs < 0 or startupTimeoutMs <= 0:
    raise newException(ValueError, "invalid watch intervals")
  createDir(project.root / "target" / "nim")
  result = WatchSupervisor(project: project, diagnostics: diagnostics,
    scanInterval: initDuration(milliseconds = scanIntervalMs),
    debounce: initDuration(milliseconds = debounceMs),
    startupTimeout: initDuration(milliseconds = startupTimeoutMs), dirty: true,
    scanner: scanner, lastScan: getMonoTime(), lastChange: getMonoTime())
  result.snapshot = result.scan()
  result.sessionDir = createTempDir("watch-", "", project.root / "target" / "nim")
  result.status("")

proc reject(s: WatchSupervisor, message: string) =
  if s.candidate != nil:
    s.outputLines.del(s.candidate.pid)
    s.candidate.close()
    s.candidate = nil
  s.status(message)
  if s.current == nil:
    s.finished = true
    s.exitCode = 1

proc stepImpl(s: WatchSupervisor) =
  if s.disposed or s.finished: return
  let now = getMonoTime()
  s.forward(s.current)
  if s.current != nil and s.current.checkExit():
    s.forward(s.current)
    s.finished = true
    s.exitCode = s.current.code
    return
  if now - s.lastScan >= s.scanInterval:
    let next = s.scan()
    s.lastScan = now
    if next != s.snapshot:
      s.snapshot = next
      s.dirty = true
      s.lastChange = now
  if s.buildJob != nil and s.buildJob.pollBuild():
    let job = s.buildJob
    s.buildJob = nil
    defer: job.close()
    if s.dirty:
      # This compile consumed a superseded file set; never launch its output.
      if fileExists(job.binary): removeFile(job.binary)
    elif job.code != 0: s.reject(job.output)
    else:
      var env = newStringTable(modeCaseSensitive)
      for key, value in envPairs(): env[key] = value
      env["LEAF_PROJECT_ROOT"] = s.project.root
      env["LEAF_WATCH_STATUS"] = s.sessionDir / "status.json"
      env["LEAF_WATCH_READY"] = s.candidateDir / "ready.json"
      env["LEAF_WATCH_TOKEN"] = s.token
      var args = @["--trace"]
      if s.diagnostics != nil and s.diagnostics.dumpFile.len > 0:
        args.add(@["--dump-tree", s.candidateDir / "tree.json"])
      s.launchTime = now
      s.candidate = startManaged(job.binary, args, s.project.root, env)
  if s.candidate != nil:
    s.forward(s.candidate)
    if s.candidate.checkExit():
      s.forward(s.candidate)
      s.reject("candidate exited before readiness (exit " & $s.candidate.code & ")\n" & s.candidate.output.diagnosticText())
    elif s.dirty:
      s.outputLines.del(s.candidate.pid)
      s.candidate.close()
      s.candidate = nil
    elif isReady(s.candidateDir / "ready.json", s.token, s.candidate.pid):
      # Rescan immediately before retirement; periodic scans can miss a late edit.
      let next = s.scan()
      if next != s.snapshot:
        s.snapshot = next
        s.dirty = true
        s.lastChange = now
      elif s.candidate.checkExit():
        s.reject("candidate exited during readiness validation (exit " & $s.candidate.code & ")")
      else:
        # Validate status publication before transferring process ownership.
        s.status("")
        let previous = s.current
        let previousDir = s.activeDir
        s.current = s.candidate
        s.candidate = nil
        defer:
          if previous != nil:
            s.outputLines.del(previous.pid)
            previous.close()
          if previousDir.len > 0 and dirExists(previousDir): removeDir(previousDir)
        s.activeDir = s.candidateDir
        s.dumpStamp = default(FileStamp)
        s.publishDump()
        s.diagnostics.record("watch", "ready", %*{"generation": s.generation, "pid": s.current.pid})
    elif now - s.launchTime > s.startupTimeout: s.reject("candidate did not open a window before startup timeout")
  s.publishDump()
  if s.finished: return
  if s.dirty and s.buildJob == nil and s.candidate == nil and now - s.lastChange >= s.debounce:
    s.dirty = false
    s.project = readProject(if s.project.configFile.len > 0: s.project.configFile else: s.project.entry)
    inc s.generation
    if s.candidateDir.len > 0 and s.candidateDir != s.activeDir and dirExists(s.candidateDir): removeDir(s.candidateDir)
    s.candidateDir = s.sessionDir / $s.generation
    createDir(s.candidateDir)
    s.token = s.sessionDir.extractFilename & "-" & $s.generation
    s.status("")
    s.dirty = false
    s.buildJob = startBuild(s.project, s.candidateDir / "app".addFileExt(ExeExt))
    s.diagnostics.record("build", "start", %*{"generation": s.generation})

proc step*(s: WatchSupervisor) =
  try: s.stepImpl()
  except CatchableError as error:
    s.lastScan = getMonoTime()
    s.reject(error.msg)

proc close*(s: WatchSupervisor) =
  if s == nil or s.disposed: return
  s.buildJob.close()
  s.candidate.close()
  s.current.close()
  s.disposed = true
  if dirExists(s.sessionDir): removeDir(s.sessionDir)

var interrupted = false
proc interrupt() {.noconv.} = interrupted = true

proc runWatch*(project: Project, diagnostics: Diagnostics): int =
  let supervisor = newWatchSupervisor(project, diagnostics)
  defer: supervisor.close()
  interrupted = false
  setControlCHook(interrupt)
  defer: unsetControlCHook()
  while not supervisor.finished and not interrupted:
    supervisor.step()
    sleep(10)
  if interrupted: 130 else: supervisor.exitCode
