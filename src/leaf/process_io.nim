## Bounded, nonblocking subprocess output. Arguments never pass through a shell.
import std/[os, osproc, monotimes, times, unicode, strutils, strtabs]
when defined(posix): import std/posix
when defined(windows): import std/winlean
when defined(windows): import ./windows_process

const SplitOutputCap* = 262_144
const SplitDrainBudget* = 65_536

type SplitProcess* = ref object
  ## A two-channel owned child: stdout and stderr stay separate on every
  ## platform, output is capped and drained with a per-iteration budget, and the
  ## owned process group/job is always cleaned even if the leader exits first.
  when defined(windows):
    process: WindowsProcess
  else:
    pid: Pid
    outFd, errFd: cint
    reaped: bool
  stdoutText*, stderrText*: string
  code*: int
  closed: bool

when defined(posix):
  proc splitSetNonBlocking(fd: cint) =
    let flags = fcntl(fd, F_GETFL, 0)
    if flags < 0: raise newException(OSError, "fcntl F_GETFL failed")
    if fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
      raise newException(OSError, "fcntl F_SETFL failed")

  proc drainChannel(fd: cint, text: var string, budget: int) =
    var buffer: array[8192, char]
    var total = 0
    while total < budget:
      let count = posix.read(fd, addr buffer[0], buffer.len)
      if count <= 0: break
      let start = text.len
      text.setLen(start + count)
      copyMem(addr text[start], addr buffer[0], count)
      total += count
    if text.len > SplitOutputCap: text = text[^SplitOutputCap .. ^1]

  proc startSplitManaged*(exe: string, args: seq[string], workingDir: string,
      env: StringTableRef = nil): SplitProcess =
    var outPipe, errPipe: array[2, cint]
    if pipe(outPipe) != 0: raise newException(OSError, "pipe failed")
    if pipe(errPipe) != 0:
      discard close(outPipe[0]); discard close(outPipe[1])
      raise newException(OSError, "pipe failed")
    try:
      splitSetNonBlocking(outPipe[0])
      splitSetNonBlocking(errPipe[0])
    except CatchableError:
      discard close(outPipe[0]); discard close(outPipe[1])
      discard close(errPipe[0]); discard close(errPipe[1])
      raise
    # Stable literal argv storage that lives until the child execs.
    let argv = allocCStringArray(@[exe] & args)
    let pid = fork()
    if pid < 0:
      deallocCStringArray(argv)
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
      if workingDir.len > 0 and chdir(workingDir.cstring) != 0:
        stderr.writeLine("leaf: cannot enter working directory: " & workingDir)
        quit(126)
      discard execvp(exe.cstring, argv)
      quit(127)
    deallocCStringArray(argv)
    discard close(outPipe[1]); discard close(errPipe[1])
    result = SplitProcess(pid: pid, outFd: outPipe[0], errFd: errPipe[0], code: -1)

  proc splitPid*(p: SplitProcess): int =
    if p == nil: 0 else: int(p.pid)

  proc drainSplit*(p: SplitProcess) =
    if p == nil or p.closed: return
    drainChannel(p.outFd, p.stdoutText, SplitDrainBudget)
    drainChannel(p.errFd, p.stderrText, SplitDrainBudget)

  proc pollSplit*(p: SplitProcess): bool =
    if p == nil or p.closed: return true
    p.drainSplit()
    var status: cint
    if waitpid(p.pid, status, WNOHANG) == p.pid:
      p.reaped = true
      # Descendants may outlive the leader; always clean the owned group.
      discard kill(-p.pid, SIGKILL)
      p.code = if (status and 0x7f) == 0: (status shr 8) and 0xff
        else: 128 + (status and 0x7f)
      p.drainSplit()
      return true
    false

  proc closeSplit*(p: SplitProcess) =
    if p == nil or p.closed: return
    if not p.reaped:
      discard kill(-p.pid, SIGKILL)
      discard kill(p.pid, SIGKILL)
      var status: cint
      discard waitpid(p.pid, status, 0)
      p.reaped = true
    else:
      discard kill(-p.pid, SIGKILL)
    discard close(p.outFd)
    discard close(p.errFd)
    p.closed = true
else:
  proc drainWindowsChannel(handle: Handle, text: var string, budget: int) =
    if handle == 0: return
    var buffer: array[8192, char]
    var total = 0
    while total < budget:
      var available, received: int32
      if not peekNamedPipe(handle, lpTotalBytesAvail = addr available) or available == 0: break
      let want = min(available, int32(buffer.len))
      if winlean.readFile(handle, addr buffer[0], want, addr received, nil) == 0: break
      if received <= 0: break
      let start = text.len
      text.setLen(start + int(received))
      copyMem(addr text[start], addr buffer[0], int(received))
      total += int(received)
    if text.len > SplitOutputCap: text = text[^SplitOutputCap .. ^1]

  proc startSplitManaged*(exe: string, args: seq[string], workingDir: string,
      env: StringTableRef = nil): SplitProcess =
    result = SplitProcess(process: startWindows(exe, args, workingDir, env, false),
      code: -1)

  proc splitPid*(p: SplitProcess): int =
    if p == nil: 0 else: p.process.pid

  proc drainSplit*(p: SplitProcess) =
    if p == nil or p.closed: return
    drainWindowsChannel(p.process.outputHandle, p.stdoutText, SplitDrainBudget)
    drainWindowsChannel(p.process.errorHandle, p.stderrText, SplitDrainBudget)

  proc pollSplit*(p: SplitProcess): bool =
    if p == nil or p.closed: return true
    p.drainSplit()
    p.code = p.process.peekExit()
    p.code != -1

  proc closeSplit*(p: SplitProcess) =
    if p == nil or p.closed: return
    p.process.close()
    p.closed = true

const MaxProcessOutput* = 262_144
type ManagedProcess* = ref object
  when defined(windows): process: WindowsProcess
  else: process: Process
  output*: string
  code*: int
  closed: bool
  parentStreams: bool

proc startManaged*(exe: string, args: seq[string], workingDir: string,
                   env: StringTableRef = nil, parentStreams = false): ManagedProcess =
  result = ManagedProcess(code: -1, parentStreams: parentStreams)
  when defined(windows):
    let command = if isAbsolute(exe): exe else: findExe(exe)
    if command.len == 0: raise newException(IOError, "executable not found: " & exe)
    result.process = startWindows(command, args, workingDir, env, parentStreams)
  else:
    let options = if parentStreams: {poUsePath, poParentStreams, poDaemon}
      else: {poUsePath, poStdErrToStdOut, poDaemon}
    result.process = startProcess(exe, args = args, workingDir = workingDir, env = env, options = options)

proc pid*(p: ManagedProcess): int =
  when defined(windows): p.process.pid
  else: p.process.processID

proc exitCode(p: ManagedProcess): int =
  when defined(windows): p.process.peekExit()
  else: p.process.peekExitCode()

proc drain*(p: ManagedProcess): string =
  if p.closed or p.parentStreams: return
  var buffer: array[4096, char]
  while result.len < 131_072:
    var count: int
    when defined(posix):
      var fd = TPollfd(fd: cint(p.process.outputHandle), events: POLLIN)
      if posix.poll(addr fd, 1, 0) <= 0 or (fd.revents and (POLLIN or POLLHUP)) == 0: break
      count = int(posix.read(fd.fd, addr buffer[0], buffer.len))
    elif defined(windows):
      var available, received: int32
      let handle = Handle(p.process.outputHandle)
      if not peekNamedPipe(handle, lpTotalBytesAvail = addr available) or available == 0: break
      if winlean.readFile(handle, addr buffer[0], min(available, int32(buffer.len)), addr received, nil) == 0: break
      count = int(received)
    else:
      {.error: "process output requires POSIX or Windows".}
    if count <= 0: break
    let start = result.len
    result.setLen(start + count)
    copyMem(addr result[start], addr buffer[0], count)
  p.output.add(result)
  if p.output.len > MaxProcessOutput:
    p.output = p.output[^MaxProcessOutput..^1]
    # A tail may start inside a UTF-8 character.
    while p.output.len > 0 and (ord(p.output[0]) and 0xc0) == 0x80:
      p.output.delete(0..0)

proc poll*(p: ManagedProcess): bool =
  if p.closed: return true
  let chunk = p.drain()
  p.code = p.exitCode()
  if p.code != -1:
    # Defer a large remaining tail to the next bounded polling step.
    return chunk.len < 131_072

proc checkExit*(p: ManagedProcess): bool =
  ## A supervisor that forwards output drains it itself, without losing chunks.
  if p.closed: return true
  p.code = p.exitCode()
  p.code != -1

proc close*(p: ManagedProcess) =
  if p == nil or p.closed: return
  when defined(posix):
    # The process group can outlive its original leader (Nim → cc → linker).
    discard posix.kill(Pid(-p.pid), SIGTERM)
    let deadline = getMonoTime() + initDuration(milliseconds = 500)
    while getMonoTime() < deadline:
      p.code = p.exitCode()
      if posix.kill(Pid(-p.pid), 0) != 0: break
      discard p.drain()
      sleep(5)
    discard posix.kill(Pid(-p.pid), SIGKILL)
    p.code = p.process.waitForExit()
  else: p.code = p.exitCode()
  p.process.close()
  p.closed = true

var interrupted = false
proc interrupt() {.noconv.} = interrupted = true
proc beginInterruptHandling*() =
  interrupted = false
  setControlCHook(interrupt)
proc endInterruptHandling*() = unsetControlCHook()
proc wasInterrupted*(): bool = interrupted
type ProcessInterruptedError* = object of CatchableError

proc diagnosticText*(s: string): string =
  result = if validateUtf8(s) == -1: s else: s.escape()
  result = result.replace("\0", "\\0")
