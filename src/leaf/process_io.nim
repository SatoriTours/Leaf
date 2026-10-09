## Bounded, nonblocking subprocess output. Arguments never pass through a shell.
import std/[os, osproc, monotimes, sets, tables, times, unicode, strutils, strtabs]
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
    pid: Pid          # guardian pid
    childPid: int     # the actual command, reported by the guardian handshake
    outFd, errFd: cint
    controlFd: cint   # parent write end: closing it asks the guardian to clean
    statusFd: cint    # guardian reports the direct child's exit code
    startupFailure: int
    reaped: bool
  stdoutText*, stderrText*: string
  code*: int
  closed: bool

when defined(posix):
  proc splitExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
    ## The guardian is a fork of the caller, so it must not run the caller's
    ## atexit handlers (which would delete caller-owned directories).

  when defined(linux):
    proc prctl(option: cint): cint {.importc, header: "<sys/prctl.h>",
      varargs.}
    const PR_SET_CHILD_SUBREAPER = 36

  proc splitSetNonBlocking(fd: cint) =
    let flags = fcntl(fd, F_GETFL, 0)
    if flags < 0: raise newException(OSError, "fcntl F_GETFL failed")
    if fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
      raise newException(OSError, "fcntl F_SETFL failed")

  proc splitSetCloexec(fd: cint) =
    let flags = fcntl(fd, F_GETFD, 0)
    if flags >= 0: discard fcntl(fd, F_SETFD, flags or FD_CLOEXEC)

  proc splitCloseUnrelated(keep: openArray[cint]) =
    ## The guardian never execs, so FD_CLOEXEC alone cannot protect it from
    ## inheriting sibling pipes. Close everything except the intentional set.
    template wanted(fd: cint): bool =
      (block:
        var found = false
        for item in keep:
          if item == fd: found = true
        found)
    when defined(linux):
      try:
        for entry in walkDir("/proc/self/fd"):
          let name = entry.path.extractFilename
          if name.len == 0 or name[0] notin {'0'..'9'}: continue
          var fd = 0
          try: fd = parseInt(name)
          except ValueError: continue
          if fd > 2 and not wanted(cint(fd)): discard close(cint(fd))
        return
      except CatchableError:
        discard
    for fd in 3 .. 1023:
      if not wanted(cint(fd)): discard close(cint(fd))

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

  proc guardianChildren(self: int): seq[int] =
    ## Every live descendant is a direct child of the subreaper, so one scan is
    ## authoritative; no ancestry guessing and no polling of the original pid.
    result = @[]
    try:
      for entry in walkDir("/proc"):
        let name = entry.path.extractFilename
        if name.len == 0 or name[0] notin {'0'..'9'}: continue
        var pid = 0
        try: pid = parseInt(name)
        except ValueError: continue
        if pid == self: continue
        try:
          let raw = readFile("/proc/" & $pid & "/stat")
          let close = raw.rfind(')')
          if close < 0: continue
          let rest = strutils.splitWhitespace(raw[close + 1 .. ^1].strip())
          if rest.len > 1 and rest[1] == $self: result.add pid
        except CatchableError:
          discard
    except CatchableError:
      discard

  proc guardianExitCode(status: cint): int =
    if (status and 0x7f) == 0: (status shr 8) and 0xff
    else: 128 + (status and 0x7f)

  proc guardianKillTree(self, child: int) =
    ## Kill the command's own process group (the portable fallback where no
    ## subreaper exists) plus every kernel-owned child of the subreaper.
    if child > 0: discard kill(Pid(-child), SIGKILL)
    for pid in guardianChildren(self):
      discard kill(Pid(pid), SIGKILL)

  proc guardianCleanup(self, child: int, code: var int, budgetMs = 5000) =
    ## Iterative and non-blocking: newly adopted grandchildren are killed on the
    ## next scan, never waited on while still unsignalled and alive.
    let deadline = getMonoTime() + initDuration(milliseconds = budgetMs)
    while true:
      var status: cint
      var progressed = false
      while true:
        let waited = waitpid(-1, status, WNOHANG)
        if waited > 0:
          progressed = true
          if waited == child and code < 0: code = guardianExitCode(status)
          continue
        if waited < 0 and errno == EINTR: continue
        break
      if waitpid(-1, status, WNOHANG) < 0 and errno == ECHILD: return
      let remaining = guardianChildren(self)
      if remaining.len == 0:
        if progressed: continue
        return
      for pid in remaining: discard kill(Pid(pid), SIGKILL)
      if getMonoTime() > deadline: return
      sleep(5)

  proc guardianMain(outWrite, errWrite, controlRead, statusWrite: cint,
      env: StringTableRef, exe: string, args: seq[string],
      workingDir: string) {.noreturn.} =
    ## Ownership is acquired at spawn: the guardian becomes the subreaper before
    ## the command starts, so every descendant reparents to it, and it cleans the
    ## whole tree when the parent closes the control pipe (or dies).
    var failure = int32(0)
    when defined(linux):
      if prctl(PR_SET_CHILD_SUBREAPER, clong(1)) != 0:
        failure = -2'i32
    else:
      failure = -3'i32   # no kernel ownership primitive on this platform
    if failure != 0:
      discard write(statusWrite, addr failure, sizeof(failure))
      splitExit(125)
    let self = int(getpid())
    let child = fork()
    if child < 0:
      var forkFailure = -1'i32
      discard write(statusWrite, addr forkFailure, sizeof(forkFailure))
      splitExit(125)
    if child == 0:
      discard setpgid(0, 0)
      discard dup2(outWrite, 1)
      discard dup2(errWrite, 2)
      discard close(outWrite); discard close(errWrite); discard close(controlRead)
      discard close(statusWrite)
      if env != nil:
        for key, value in env: putEnv(key, value)
      if workingDir.len > 0 and chdir(workingDir.cstring) != 0:
        stderr.writeLine("leaf: cannot enter working directory: " & workingDir)
        splitExit(126)
      let argv = allocCStringArray(@[exe] & args)
      discard execvp(exe.cstring, argv)
      splitExit(127)
    # The guardian keeps only the intentional IPC and the standard streams.
    splitCloseUnrelated([outWrite, errWrite, controlRead, statusWrite])
    var pidValue = int32(child)
    discard write(statusWrite, addr pidValue, sizeof(pidValue))
    splitSetNonBlocking(controlRead)
    var code = -1
    var reported = false
    var eof = false
    while true:
      var status: cint
      while true:
        let waited = waitpid(-1, status, WNOHANG)
        if waited <= 0: break
        if waited == child and code < 0:
          code = guardianExitCode(status)
          var value = int32(code)
          discard write(statusWrite, addr value, sizeof(value))
          reported = true
      if not eof:
        var buffer: array[1, char]
        let count = posix.read(controlRead, addr buffer[0], 1)
        if count == 0: eof = true
        elif count < 0 and errno notin [EAGAIN, EWOULDBLOCK, EINTR]: eof = true
      if eof:
        guardianKillTree(self, int(child))
        guardianCleanup(self, int(child), code)
        if guardianChildren(self).len == 0: break
      sleep(5)
    if code < 0: code = 0
    if not reported:
      var value = int32(code)
      discard write(statusWrite, addr value, sizeof(value))
    splitExit(0)

  proc startSplitManaged*(exe: string, args: seq[string], workingDir: string,
      env: StringTableRef = nil): SplitProcess =
    var outPipe = [-1.cint, -1.cint]
    var errPipe = [-1.cint, -1.cint]
    var controlPipe = [-1.cint, -1.cint]
    var statusPipe = [-1.cint, -1.cint]
    template cleanupPipes() =
      for pair in [outPipe, errPipe, controlPipe, statusPipe]:
        if pair[0] >= 0: discard close(pair[0])
        if pair[1] >= 0: discard close(pair[1])
    if pipe(outPipe) != 0: raise newException(OSError, "pipe failed")
    if pipe(errPipe) != 0:
      cleanupPipes()
      raise newException(OSError, "pipe failed")
    if pipe(controlPipe) != 0:
      cleanupPipes()
      raise newException(OSError, "pipe failed")
    if pipe(statusPipe) != 0:
      cleanupPipes()
      raise newException(OSError, "pipe failed")
    try:
      splitSetNonBlocking(outPipe[0])
      splitSetNonBlocking(errPipe[0])
      # The exec'd command must never inherit sibling IPC.
      splitSetCloexec(outPipe[0]); splitSetCloexec(outPipe[1])
      splitSetCloexec(errPipe[0]); splitSetCloexec(errPipe[1])
      splitSetCloexec(controlPipe[0]); splitSetCloexec(controlPipe[1])
      splitSetCloexec(statusPipe[0]); splitSetCloexec(statusPipe[1])
    except CatchableError:
      cleanupPipes()
      raise
    let guardian = fork()
    if guardian < 0:
      cleanupPipes()
      raise newException(OSError, "fork failed")
    if guardian == 0:
      discard close(outPipe[0]); discard close(errPipe[0])
      discard close(controlPipe[1]); discard close(statusPipe[0])
      guardianMain(outPipe[1], errPipe[1], controlPipe[0], statusPipe[1], env,
        exe, args, workingDir)
    discard close(outPipe[1]); discard close(errPipe[1])
    discard close(controlPipe[0]); discard close(statusPipe[1])
    result = SplitProcess(pid: guardian, outFd: outPipe[0], errFd: errPipe[0],
      controlFd: controlPipe[1], statusFd: statusPipe[0], code: -1)
    # Handshake: the guardian reports the real command pid before we can signal
    # it. The read is bounded by poll so a dead guardian cannot hang startup.
    var descriptor = TPollfd(fd: statusPipe[0], events: POLLIN)
    if posix.poll(addr descriptor, 1, 5000) > 0:
      var pidBuffer: array[4, char]
      var pidRead = 0
      while pidRead < 4:
        let count = posix.read(statusPipe[0], addr pidBuffer[pidRead], 4 - pidRead)
        if count <= 0:
          if count < 0 and errno == EINTR: continue
          break
        pidRead += count
      if pidRead == 4:
        var value: int32
        copyMem(addr value, addr pidBuffer[0], 4)
        if value > 0:
          result.childPid = int(value)
        else:
          # The guardian could not acquire ownership: never invent a pid and
          # never fall back to the guardian pid.
          result.startupFailure = int(value)
    splitSetNonBlocking(statusPipe[0])

  proc splitPid*(p: SplitProcess): int =
    ## Only the real command pid; a failed ownership acquisition reports 0 so a
    ## caller can never signal an unrelated process.
    if p == nil: 0 else: p.childPid

  proc drainSplit*(p: SplitProcess) =
    if p == nil or p.closed: return
    drainChannel(p.outFd, p.stdoutText, SplitDrainBudget)
    drainChannel(p.errFd, p.stderrText, SplitDrainBudget)

  proc readChildStatus(p: SplitProcess) =
    if p.code >= 0: return
    var buffer: array[4, char]
    let count = posix.read(p.statusFd, addr buffer[0], 4)
    if count == 4:
      var value: int
      copyMem(addr value, addr buffer[0], 4)
      p.code = value

  proc pollSplit*(p: SplitProcess): bool =
    if p == nil or p.closed: return true
    if p.startupFailure != 0:
      p.code = 125
      return true
    p.drainSplit()
    if p.code < 0: p.readChildStatus()
    p.code >= 0

  proc closeSplit*(p: SplitProcess) =
    if p == nil or p.closed: return
    # Closing the control pipe asks the guardian to kill and reap the tree.
    discard close(p.controlFd)
    p.controlFd = -1
    # The guardian cleans the tree then exits; bound the wait so a wedged
    # guardian cannot hang the caller, and force it afterwards.
    let deadline = getMonoTime() + initDuration(seconds = 15)
    var status: cint
    while true:
      let waited = waitpid(p.pid, status, WNOHANG)
      if waited == p.pid: break
      if waited < 0 and errno == EINTR: continue
      if waited < 0: break
      if getMonoTime() > deadline:
        discard kill(p.pid, SIGKILL)
        discard waitpid(p.pid, status, 0)
        break
      sleep(5)
    p.reaped = true
    p.readChildStatus()
    p.drainSplit()
    discard close(p.outFd)
    discard close(p.errFd)
    discard close(p.statusFd)
    p.outFd = -1; p.errFd = -1; p.statusFd = -1
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
    result = SplitProcess(process: startWindows(exe, args, workingDir, env, false,
      split = true), code: -1)

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
