## Bounded, nonblocking subprocess output. Arguments never pass through a shell.
import std/[os, osproc, monotimes, times, unicode, strutils, strtabs]
when defined(posix): import std/posix
when defined(windows): import std/winlean
when defined(windows): import ./windows_process

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
