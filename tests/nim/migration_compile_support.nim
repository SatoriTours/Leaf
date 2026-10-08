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

when defined(posix):
  type CliRun* = object
    code*: int
    stdoutText*, stderrText*: string

  proc readAvailable(fd: cint, text: var string) =
    var buffer: array[4096, char]
    while true:
      let count = posix.read(fd, addr buffer[0], buffer.len)
      if count <= 0: break
      let start = text.len
      text.setLen(start + count)
      copyMem(addr text[start], addr buffer[0], count)
      if count < buffer.len: break

  proc runCli*(binary, workingDir: string, args: seq[string],
      env: StringTableRef = nil, seconds = 300, interruptAfterMs = 0): CliRun =
    ## Test-local CLI child: literal argv (never a shell), two real pipes so
    ## stdout and stderr stay separate, a monotonic deadline and a reaped exit.
    var outPipe, errPipe: array[2, cint]
    if pipe(outPipe) != 0 or pipe(errPipe) != 0:
      raise newException(OSError, "pipe failed")
    let pid = fork()
    if pid < 0: raise newException(OSError, "fork failed")
    if pid == 0:
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
      exitnow(127)
    discard close(outPipe[1])
    discard close(errPipe[1])
    if interruptAfterMs > 0:
      sleep(interruptAfterMs)
      discard kill(pid, SIGINT)
    var descriptors = [TPollfd(fd: outPipe[0], events: POLLIN),
      TPollfd(fd: errPipe[0], events: POLLIN)]
    let deadline = getMonoTime() + initDuration(seconds = seconds)
    var status: cint
    var exited = false
    try:
      while true:
        if posix.poll(addr descriptors[0], 2, 50) > 0:
          if (descriptors[0].revents and (POLLIN or POLLHUP)) != 0:
            readAvailable(descriptors[0].fd, result.stdoutText)
          if (descriptors[1].revents and (POLLIN or POLLHUP)) != 0:
            readAvailable(descriptors[1].fd, result.stderrText)
        if waitpid(pid, status, WNOHANG) == pid:
          exited = true
          break
        if getMonoTime() > deadline:
          discard kill(pid, SIGKILL)
          discard waitpid(pid, status, 0)
          exited = true
          result.code = 124
          break
      readAvailable(outPipe[0], result.stdoutText)
      readAvailable(errPipe[0], result.stderrText)
    finally:
      discard close(outPipe[0])
      discard close(errPipe[0])
    if result.code != 124:
      result.code = if (status and 0x7f) == 0: (status shr 8) and 0xff
        else: 128 + (status and 0x7f)
