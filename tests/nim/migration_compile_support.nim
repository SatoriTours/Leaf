## Test-only helper: compile (and optionally run) real Nim migration sources.
## Migration files use numbered names that Nim cannot import as modules, so the
## generated probe programs include them textually, like the real catalog must.
import ./cleanup_support
import leaf/process_io
when defined(posix): import std/posix
import std/[monotimes, os, osproc, streams, strtabs, tempfiles, times]

const leafSourceRoot = currentSourcePath().parentDir.parentDir.parentDir / "src"

let probeCache = createTempDir("leaf-migration-probe-cache-", "")
removeDirectoryOnExit(probeCache)

proc runManagedBounded*(exe: string, args: seq[string], cwd: string,
    seconds = 900): tuple[code: int, output: string] =
  ## Test-local bounded child: literal argv, monotonic deadline, finally reap.
  let child = startManaged(exe, args, cwd)
  try:
    let deadline = getMonoTime() + initDuration(seconds = seconds)
    while not child.poll():
      if getMonoTime() > deadline:
        result.code = 124
        break
      sleep(10)
    if result.code != 124: result.code = child.code
    result.output = child.output.diagnosticText()
  finally:
    child.close()


proc compileProbe*(files: seq[tuple[path, content: string]], mainPath: string,
    run = false): tuple[code: int, output: string] =
  let compiler = getEnv("NIM", findExe("nim"))
  if compiler.len == 0: return (1, "Nim compiler not found")
  let root = createTempDir("leaf-migration-probe-", "")
  removeDirectoryOnExit(root)
  for file in files:
    let target = root / file.path
    createDir(target.parentDir)
    writeFile(target, file.content)
  let binary = root / ("probe" & (when defined(windows): ".exe" else: ""))
  var args = @["c", "--hints:off", "--path:" & leafSourceRoot,
    "--nimcache:" & probeCache, "--out:" & binary]
  if run: args.add "-r"
  args.add mainPath
  let ran = runManagedBounded(compiler, args, root)
  result.code = ran.code
  result.output = ran.output

proc createProbeRoot*(): string =
  ## A probe root the caller owns and removes (unlike compileProbe's temporary).
  createTempDir("leaf-migration-probe-", "")

proc writeProbeFiles*(root: string, files: seq[tuple[path, content: string]]) =
  for file in files:
    let target = root / file.path
    createDir(target.parentDir)
    writeFile(target, file.content)

proc buildProbe*(root, mainPath, nimcache: string, outName = "probe",
    outPath = "", extraArgs: seq[string] = @[]): tuple[code: int, output: string, binary: string] =
  ## Compile an existing root with an explicit nimcache, keeping the binary.
  ## `outPath` keeps `--out` away from fixture paths that contain `$`.
  let compiler = getEnv("NIM", findExe("nim"))
  if compiler.len == 0: return (1, "Nim compiler not found", "")
  result.binary = if outPath.len > 0: outPath
    else: root / (outName & (when defined(windows): ".exe" else: ""))
  var args = @["c", "--hints:off", "--path:" & leafSourceRoot,
    "--nimcache:" & nimcache, "--out:" & result.binary]
  args.add extraArgs
  args.add mainPath
  let ran = runManagedBounded(compiler, args, root)
  result.code = ran.code
  result.output = ran.output

proc runBinary*(binary, workingDir: string): tuple[code: int, output: string] =
  let ran = runManagedBounded(binary, @[], workingDir)
  result.code = ran.code
  result.output = ran.output

proc startBuild*(root, mainPath, nimcache, outName: string): Process =
  ## Start a real compile without waiting, for concurrency tests.
  let compiler = getEnv("NIM", findExe("nim"))
  let binary = root / (outName & (when defined(windows): ".exe" else: ""))
  startProcess(compiler, workingDir = root,
    args = @["c", "--hints:off", "--path:" & leafSourceRoot, "--nimcache:" & nimcache,
      "--out:" & binary, mainPath],
    options = {poUsePath, poStdErrToStdOut})

type CliRun* = object
  code*: int
  stdoutText*, stderrText*: string

when defined(posix):
  proc setNonBlocking(fd: cint) =
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0: discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

  proc capText(text: var string) =
    if text.len > 262_144: text = text[^262_144 .. ^1]

  proc drainFd(fd: cint, text: var string) =
    ## Non-blocking, capped and bounded: an exact pipe-buffer write followed by
    ## a long sleep can never make the helper block.
    var buffer: array[8192, char]
    while true:
      let count = posix.read(fd, addr buffer[0], buffer.len)
      if count > 0:
        let start = text.len
        text.setLen(start + count)
        copyMem(addr text[start], addr buffer[0], count)
        capText(text)
      elif count == 0:
        break
      else:
        if errno in [EAGAIN, EWOULDBLOCK, EINTR]: break
        break

  proc decodeStatus(status: cint): int =
    if (status and 0x7f) == 0: (status shr 8) and 0xff
    else: 128 + (status and 0x7f)

  proc runCli*(binary, workingDir: string, args: seq[string],
      env: StringTableRef = nil, seconds = 300, interruptAfterMs = 0,
      ready: proc(): bool {.closure.} = nil): CliRun =
    ## Test-local CLI child: literal argv (never a shell), two real non-blocking
    ## pipes, a monotonic deadline from launch, an owned process group that is
    ## always killed and reaped, and capped output.
    var outPipe, errPipe: array[2, cint]
    if pipe(outPipe) != 0 or pipe(errPipe) != 0:
      raise newException(OSError, "pipe failed")
    let pid = fork()
    if pid < 0:
      discard close(outPipe[0]); discard close(outPipe[1])
      discard close(errPipe[0]); discard close(errPipe[1])
      raise newException(OSError, "fork failed")
    if pid == 0:
      discard setpgid(0, 0)
      discard dup2(outPipe[1], 1)
      discard dup2(errPipe[1], 2)
      discard close(outPipe[0]); discard close(outPipe[1])
      discard close(errPipe[0]); discard close(errPipe[1])
      if env != nil:
        for key, value in env: putEnv(key, value)
      if workingDir.len > 0: discard chdir(workingDir.cstring)
      var argv = newSeq[cstring](args.len + 2)
      argv[0] = binary.cstring
      for index, argument in args: argv[index + 1] = argument.cstring
      argv[^1] = nil
      discard execvp(binary.cstring, cast[cstringArray](addr argv[0]))
      quit(127)
    discard close(outPipe[1])
    discard close(errPipe[1])
    setNonBlocking(outPipe[0])
    setNonBlocking(errPipe[0])
    let launch = getMonoTime()
    let deadline = launch + initDuration(seconds = seconds)
    var interruptAt = launch
    if interruptAfterMs > 0:
      interruptAt = launch + initDuration(milliseconds = interruptAfterMs)
    var signalled = interruptAfterMs <= 0 and ready == nil
    var reaped = false
    var status: cint
    try:
      while true:
        drainFd(outPipe[0], result.stdoutText)
        drainFd(errPipe[0], result.stderrText)
        if interruptAfterMs > 0 and not signalled and getMonoTime() >= interruptAt:
          discard kill(pid, SIGINT)
          signalled = true
        if not signalled and ready != nil and ready():
          discard kill(pid, SIGINT)
          signalled = true
        if waitpid(pid, status, WNOHANG) == pid:
          reaped = true
          result.code = decodeStatus(status)
          break
        if getMonoTime() > deadline:
          discard kill(-pid, SIGKILL)
          discard kill(pid, SIGKILL)
          if waitpid(pid, status, 0) == pid: reaped = true
          result.code = 124
          break
        var descriptors = [TPollfd(fd: outPipe[0], events: POLLIN),
          TPollfd(fd: errPipe[0], events: POLLIN)]
        discard posix.poll(addr descriptors[0], 2, 20)
      drainFd(outPipe[0], result.stdoutText)
      drainFd(errPipe[0], result.stderrText)
    finally:
      if not reaped:
        discard kill(-pid, SIGKILL)
        discard kill(pid, SIGKILL)
        var finalStatus: cint
        discard waitpid(pid, finalStatus, 0)
      discard close(outPipe[0])
      discard close(errPipe[0])
else:
  proc runCli*(binary, workingDir: string, args: seq[string],
      env: StringTableRef = nil, seconds = 300, interruptAfterMs = 0): CliRun =
    ## Windows semantic path: the accepted managed process merges the channels,
    ## so only `stdoutText` is populated. Not a claim of split-channel support.
    let child = startManaged(binary, args, workingDir, env)
    try:
      let deadline = getMonoTime() + initDuration(seconds = seconds)
      while not child.poll():
        if getMonoTime() > deadline:
          result.code = 124
          break
        sleep(10)
      if result.code != 124: result.code = child.code
      result.stdoutText = child.output.diagnosticText()
    finally:
      child.close()
