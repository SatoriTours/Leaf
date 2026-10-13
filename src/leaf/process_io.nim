## Bounded, nonblocking subprocess output. Arguments never pass through a shell.
import std/[os, osproc, monotimes, sets, tables, times, unicode, strutils, strtabs]
when defined(posix): import std/posix
when defined(windows): import std/winlean
when defined(windows): import ./windows_process

const SplitOutputCap* = 262_144
const SplitDrainBudget* = 65_536
const SplitSubreaper = defined(linux) and not defined(leafPortableSplit)

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
    statusBuffer: array[4, char]
    statusRead: int
    reaped: bool
  protocolError*: bool
  cleanupUnconfirmed*: bool
  statusEof*: bool
  statusError*: bool
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
    if flags < 0 or fcntl(fd, F_SETFD, flags or FD_CLOEXEC) < 0:
      raise newException(OSError, "fcntl FD_CLOEXEC failed")

  proc splitCloseUnrelated(keep: openArray[cint]) =
    ## The guardian never execs, so FD_CLOEXEC alone cannot protect it from
    ## inheriting sibling pipes. Close everything except the intentional set.
    template wanted(fd: cint): bool =
      (block:
        var found = false
        for item in keep:
          if item == fd: found = true
        found)
    block:
      try:
        let fdDirectory = when defined(linux): "/proc/self/fd" else: "/dev/fd"
        if not dirExists(fdDirectory):
          raise newException(OSError, "descriptor directory unavailable")
        var unrelated: seq[cint]
        for entry in walkDir(fdDirectory):
          let name = entry.path.extractFilename
          if name.len == 0 or name[0] notin {'0'..'9'}: continue
          var fd = 0
          try: fd = parseInt(name)
          except ValueError: continue
          if fd > 2 and not wanted(cint(fd)): unrelated.add cint(fd)
        # Finish directory iteration before closing its own enumeration fd.
        for fd in unrelated: discard close(fd)
        return
      except CatchableError:
        discard
    var limit: RLimit
    if getrlimit(RLIMIT_NOFILE, limit) != 0 or limit.rlim_max <= 0 or
        limit.rlim_max > int(high(cint)):
      raise newException(OSError, "cannot determine inherited descriptor bounds")
    for fd in 3 ..< max(limit.rlim_cur, limit.rlim_max):
      if not wanted(cint(fd)): discard close(cint(fd))

  proc drainChannel(fd: cint, text: var string, budget: int): bool =
    var buffer: array[8192, char]
    var total = 0
    result = true
    let deadline = getMonoTime() + initDuration(milliseconds = 10)
    while total < budget and getMonoTime() < deadline:
      let count = posix.read(fd, addr buffer[0], buffer.len)
      if count == 0: break
      if count < 0:
        if errno == EINTR: continue
        if errno in [EAGAIN, EWOULDBLOCK]: break
        result = false
        break
      let start = text.len
      text.setLen(start + count)
      copyMem(addr text[start], addr buffer[0], count)
      total += count
    if text.len > SplitOutputCap: text = text[^SplitOutputCap .. ^1]

  proc guardianWriteFrame(fd: cint, value: int32): bool =
    ## Checked and partial-write/EINTR safe; a closed peer (EPIPE) is not fatal
    ## and never prevents cleanup.
    var buffer: array[4, char]
    copyMem(addr buffer[0], unsafeAddr value, 4)
    var written = 0
    while written < 4:
      let count = posix.write(fd, addr buffer[written], 4 - written)
      if count > 0: written += count
      elif count < 0 and errno == EINTR: continue
      else: return false
    true

  proc guardianChildren(self: int): seq[int] =
    ## Read the kernel's direct-child list. Descendants become direct children
    ## after their parents exit. Failure is an ownership error, never an empty
    ## tree. These pids cannot be recycled until this guardian reaps them.
    when SplitSubreaper:
      for raw in strutils.splitWhitespace(readFile("/proc/" & $self &
          "/task/" & $self & "/children")):
        result.add parseInt(raw)

  var waitPidKind {.importc: "P_PID", header: "<sys/wait.h>".}: cint
  var childExited {.importc: "CLD_EXITED", header: "<signal.h>".}: cint

  proc peekCommand(child: Pid): int =
    ## Keep the exited command waitable until group cleanup; its pid pins the
    ## group identity on POSIX systems without Linux's subreaper facility.
    var info: SigInfo
    if waitid(waitPidKind, Id(child), info, WEXITED or WNOHANG or WNOWAIT) != 0:
      if errno == EINTR: return -1
      raise newException(OSError, "cannot inspect the owned command")
    if info.si_pid == 0: return -1
    # Darwin reports the whole 32-bit exit value for CLD_EXITED
    # (WEXITSTATUS(p_xstat) | p_xhighbits << 24), so exitCli's quit(-126)
    # arrives as -126 or 0x00FFFF82. Only the low eight bits are the status;
    # decode exactly like the waitpid path.
    if info.si_code == childExited: int(info.si_status) and 0xff
    else: 128 + int(info.si_status)

  proc guardianExitCode(status: cint): int =
    if (status and 0x7f) == 0: (status shr 8) and 0xff
    else: 128 + (status and 0x7f)

  proc guardianKillTree(self: int) =
    ## Only currently kernel-owned, non-reaped children are signalled. A reaped
    ## command pid is never used as a group id (it may be recycled by a foreign
    ## group by the time a delayed caller closes).
    for pid in guardianChildren(self):
      discard kill(Pid(pid), SIGKILL)

  proc guardianCleanup(self: int, child: int, code: var int, budgetMs = 5000) =
    ## Iterative and non-blocking. Every successful waitpid result is recorded
    ## exactly once; there is no second ECHILD probe that could swallow the
    ## command's final status.
    let deadline = getMonoTime() + initDuration(milliseconds = budgetMs)
    while true:
      var status: cint
      var reapedAny = false
      while getMonoTime() <= deadline:
        let waited = waitpid(-1, status, WNOHANG)
        if waited > 0:
          reapedAny = true
          if waited == child and code < 0: code = guardianExitCode(status)
          continue
        if waited < 0 and errno == EINTR: continue
        if waited < 0 and errno != ECHILD:
          raise newException(OSError, "guardian cleanup waitpid failed")
        break
      let remaining = guardianChildren(self)
      if remaining.len == 0:
        if reapedAny: continue
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
    # The whole lifecycle is one non-returning boundary: no setup, fork, loop or
    # write may ever unwind into caller code or run the caller's atexit hooks.
    var child: Pid = Pid(-1)
    var code = -1
    var reported = false
    var eof = false
    var self = 0
    try:
      discard posix.signal(SIGPIPE, SIG_IGN)
      var failure = int32(0)
      when SplitSubreaper:
        if prctl(PR_SET_CHILD_SUBREAPER, clong(1)) != 0:
          failure = -2'i32
      else:
        # A guardian lives outside its command's group, including when nested.
        # Closing its parent's control pipe still triggers its own cleanup.
        if setpgid(0, 0) != 0: failure = -3'i32
      if failure != 0:
        discard guardianWriteFrame(statusWrite, failure)
        splitExit(125)
      splitCloseUnrelated([outWrite, errWrite, controlRead, statusWrite])
      splitSetNonBlocking(controlRead)
      self = int(getpid())
      child = fork()
      if child < 0:
        discard guardianWriteFrame(statusWrite, -1'i32)
        splitExit(125)
    except CatchableError:
      # Nothing owned exists yet: report and leave without touching any pid.
      discard guardianWriteFrame(statusWrite, -4'i32)
      splitExit(125)
    if child == 0:
      # The forked command is its own non-returning boundary: no pre-exec setup
      # failure may ever unwind into the caller's catch/finally/atexit.
      try:
        discard setpgid(0, 0)
        discard dup2(outWrite, 1)
        discard dup2(errWrite, 2)
        discard close(outWrite); discard close(errWrite); discard close(controlRead)
        discard close(statusWrite)
        if env != nil:
          for key, value in env: putEnv(key, value)
        if workingDir.len > 0 and chdir(workingDir.cstring) != 0:
          try: stderr.writeLine("leaf: cannot enter working directory: " & workingDir)
          except Exception: discard
          splitExit(126)
        let argv = allocCStringArray(@[exe] & args)
        discard execvp(exe.cstring, argv)
      except Exception as error:
        try: stderr.writeLine("leaf: cannot launch the command: " & error.msg)
        except Exception: discard
      splitExit(127)
    # START is published only once the owner is fully ready to supervise.
    try:
      if not guardianWriteFrame(statusWrite, int32(child)):
        raise newException(IOError, "guardian could not publish the command pid")
      while true:
        when SplitSubreaper:
          var status: cint
          let reapDeadline = getMonoTime() + initDuration(milliseconds = 50)
          while getMonoTime() < reapDeadline:
            let waited = waitpid(-1, status, WNOHANG)
            if waited < 0 and errno == EINTR: continue
            if waited < 0 and errno != ECHILD:
              raise newException(OSError, "guardian waitpid failed")
            if waited <= 0: break
            if waited == child and code < 0:
              code = guardianExitCode(status)
        else:
          if code < 0: code = peekCommand(child)
        if code >= 0 and not reported:
          reported = guardianWriteFrame(statusWrite, int32(code))
        if not eof:
          var buffer: array[1, char]
          let count = posix.read(controlRead, addr buffer[0], 1)
          if count == 0: eof = true
          elif count < 0 and errno notin [EAGAIN, EWOULDBLOCK, EINTR]: eof = true
        if eof:
          when SplitSubreaper:
            guardianKillTree(self)
            guardianCleanup(self, int(child), code)
            if guardianChildren(self).len == 0: break
          else:
            # The unreaped leader still pins this process group, even if it
            # exited before close. Never signal the group after reaping it.
            discard kill(Pid(-child), SIGKILL)
            discard kill(child, SIGKILL) # also covers a pre-setpgid child
            var status: cint
            let cleanupDeadline = getMonoTime() + initDuration(seconds = 5)
            while true:
              let waited = waitpid(child, status, WNOHANG)
              if waited == child:
                if code < 0: code = guardianExitCode(status)
                break
              if waited < 0 and errno != EINTR:
                raise newException(OSError, "guardian cleanup waitpid failed")
              if getMonoTime() >= cleanupDeadline:
                raise newException(OSError, "guardian cleanup timed out")
              sleep(5)
            break
        sleep(5)
      if code < 0: code = 0
      if not reported:
        reported = guardianWriteFrame(statusWrite, int32(code))
      splitExit(0)
    except CatchableError:
      # Keep responsibility for all descendants on lifecycle errors as well.
      # A nonzero guardian exit is independently checked by the parent, even
      # when the command's successful status was already published.
      if child > 0:
        when SplitSubreaper:
          var clean = false
          while not clean:
            try:
              guardianKillTree(self)
              guardianCleanup(self, int(child), code)
              clean = guardianChildren(self).len == 0
            except CatchableError:
              sleep(5)
        else:
          discard kill(Pid(-child), SIGKILL)
          discard kill(child, SIGKILL)
          var status: cint
          while true:
            let waited = waitpid(child, status, WNOHANG)
            if waited == child or (waited < 0 and errno == ECHILD): break
            sleep(5)
      if not reported:
        reported = guardianWriteFrame(statusWrite, -4'i32)
      splitExit(125)

  proc splitAbortCleanup(guardian: Pid, outFd, errFd, controlFd, statusFd: cint) =
    ## Exception-safe constructor cleanup: ask the guardian to clean, confirm a
    ## bounded reap, then close every own endpoint.
    if controlFd >= 0: discard close(controlFd)
    let deadline = getMonoTime() + initDuration(seconds = 5)
    var status: cint
    while true:
      let waited = waitpid(guardian, status, WNOHANG)
      if waited == guardian: break
      if getMonoTime() > deadline: break
      if waited < 0 and errno == EINTR: continue
      if waited < 0 and errno == ECHILD: break
      # Closing control requests tree cleanup. Do not kill its lifecycle owner
      # on a handshake error; it must keep responsibility for any descendants.
      sleep(5)
    if outFd >= 0: discard close(outFd)
    if errFd >= 0: discard close(errFd)
    if statusFd >= 0: discard close(statusFd)

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
    # Handshake: the guardian reports the real command pid before the caller can
    # signal it. The wait uses one monotonic budget (EINTR does not reset it),
    # frames are validated, and any missing/error/invalid frame fails fast with
    # owned cleanup instead of returning an unusable handle.
    var owned = SplitProcess(pid: guardian, outFd: outPipe[0], errFd: errPipe[0],
      controlFd: controlPipe[1], statusFd: statusPipe[0], code: -1)
    try:
      let handshakeDeadline = getMonoTime() + initDuration(seconds = 5)
      var frame: array[4, char]
      var pidRead = 0
      while pidRead < 4:
        var descriptor = TPollfd(fd: statusPipe[0], events: POLLIN)
        let remaining = (handshakeDeadline - getMonoTime()).inMilliseconds
        if remaining <= 0:
          raise newException(IOError, "split guardian handshake timed out")
        let ready = posix.poll(addr descriptor, 1, cint(remaining))
        if ready < 0:
          if errno == EINTR: continue
          raise newException(IOError, "split guardian handshake poll failed")
        if ready == 0:
          raise newException(IOError, "split guardian handshake timed out")
        let count = posix.read(statusPipe[0], addr frame[pidRead], 4 - pidRead)
        if count <= 0:
          if count < 0 and errno == EINTR: continue
          raise newException(IOError, "split guardian handshake closed early")
        pidRead += count
      var pidValue: int32
      copyMem(addr pidValue, addr frame[0], 4)
      if pidValue <= 0:
        raise newException(IOError, "split guardian could not acquire ownership (" &
          $pidValue & ")")
      owned.childPid = int(pidValue)
      splitSetNonBlocking(statusPipe[0])
      result = owned
    except CatchableError:
      splitAbortCleanup(guardian, outPipe[0], errPipe[0], controlPipe[1],
        statusPipe[0])
      raise

  proc splitPid*(p: SplitProcess): int =
    ## Only the real command pid; a failed ownership acquisition reports 0 so a
    ## caller can never signal an unrelated process.
    if p == nil: 0 else: p.childPid

  proc drainSplit*(p: SplitProcess) =
    if p == nil or p.closed: return
    if not drainChannel(p.outFd, p.stdoutText, SplitDrainBudget):
      p.protocolError = true
    if not drainChannel(p.errFd, p.stderrText, SplitDrainBudget):
      p.protocolError = true

  proc readChildStatus(p: SplitProcess) =
    ## Buffers the whole status frame across partial reads; a value outside the
    ## exit domain 0..255 is a framework error, never an exit status.
    if p.code >= 0 or p.protocolError or p.statusEof or p.statusError: return
    let deadline = getMonoTime() + initDuration(milliseconds = 10)
    while p.statusRead < 4 and getMonoTime() < deadline:
      let count = posix.read(p.statusFd, addr p.statusBuffer[p.statusRead],
        4 - p.statusRead)
      if count > 0:
        p.statusRead += count
      elif count == 0:
        # EOF is terminal: no more bytes can arrive.
        p.statusEof = true
        break
      elif errno == EINTR:
        continue
      elif errno in [EAGAIN, EWOULDBLOCK]:
        return
      else:
        p.statusError = true
        break
    if p.statusRead == 4:
      var value: int32
      copyMem(addr value, addr p.statusBuffer[0], 4)
      if value in 0'i32 .. 255'i32:
        p.code = int(value)
      else:
        p.protocolError = true
        p.code = 125
    elif p.statusEof or p.statusError:
      # A truncated or unreadable frame is a terminal protocol failure, never a
      # running command and never a fabricated success.
      p.protocolError = true
      p.code = 125

  proc pollSplit*(p: SplitProcess): bool =
    if p == nil or p.closed: return true
    if p.startupFailure != 0:
      p.code = 125
      return true
    p.drainSplit()
    if p.protocolError:
      if p.code < 0: p.code = 125
      return true
    if p.code < 0: p.readChildStatus()
    p.code >= 0

  proc closeSplit*(p: SplitProcess) =
    if p == nil or p.closed: return
    # Closing the control pipe asks the guardian to kill and reap the tree.
    discard close(p.controlFd)
    p.controlFd = -1
    # The guardian cleans the tree then exits. The wait is bounded and never
    # unbounded: if cleanup cannot be confirmed, retain the owner and endpoints
    # for a retry and report that cleanup was NOT confirmed.
    let deadline = getMonoTime() + initDuration(seconds = 15)
    var status: cint
    while true:
      let waited = waitpid(p.pid, status, WNOHANG)
      if waited == p.pid:
        p.reaped = true
        if guardianExitCode(status) != 0: p.cleanupUnconfirmed = true
        break
      if getMonoTime() > deadline:
        p.cleanupUnconfirmed = true
        return # leave the live owner and endpoints available for a later close
      if waited < 0 and errno == EINTR: continue
      if waited < 0:
        p.cleanupUnconfirmed = true
        if errno == ECHILD: break
        # Transient wait failures must not abandon a still-waitable owner.
        sleep(5)
        continue
      p.drainSplit()
      sleep(5)
    if p.code < 0 and not p.protocolError:
      p.readChildStatus()
      if p.code < 0: p.cleanupUnconfirmed = true
    p.readChildStatus()
    # Drain the final buffered tail, even if it spans several fair poll budgets.
    # No producers remain after the guardian exits; each call is nonblocking.
    for _ in 0 .. (SplitOutputCap div SplitDrainBudget + 1):
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
    let code = p.process.close()
    if p.code < 0: p.code = code
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
    p.process.close()
  else:
    # Windows closes the Job Object and waits before querying the final exit.
    p.code = p.process.close()
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
