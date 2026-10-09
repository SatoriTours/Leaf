## Task 7 Milestone B throwaway feasibility prototype (test-only, Linux POSIX).
## It proves the ruling's primitives: a parked guardian leases its own private
## command group while staying outside it, children register over anonymous
## descriptor IPC and cannot run before the ACK launch gate, and an inner close
## only ends its own descendants. This is NOT a production backend.
import std/[os, posix, strtabs, strutils, monotimes, times]

type
  Scope = object
    guardian: Pid
    group: Pid
    registration: cint      # guardian's end of the anonymous socketpair
    child: Pid
    childMarker: string

proc alive(pid: int): bool =
  if not fileExists("/proc/" & $pid & "/stat"): return false
  let stat = readFile("/proc/" & $pid & "/stat")
  stat[stat.rfind(')') + 2] notin {'Z', 'X'}

proc pgidOf(pid: int): int =
  try:
    let raw = readFile("/proc/" & $pid & "/stat")
    let close = raw.rfind(')')
    let rest = strutils.splitWhitespace(raw[close + 1 .. ^1].strip())
    parseInt(rest[2])
  except CatchableError:
    -1

proc spawnScope(marker: string, parentRegistration: cint): Scope =
  ## Fork a guardian that leases group = its own pid, forks the command into that
  ## group, parks itself outside it, and gates the command on registration+ACK.
  let parking = getpgid(0)
  var gate: array[2, cint]
  var link: array[2, cint]
  if pipe(gate) != 0: raise newException(OSError, "gate pipe failed")
  if socketpair(AF_UNIX, SOCK_STREAM, 0, link) != 0:
    raise newException(OSError, "socketpair failed")
  let guardian = fork()
  if guardian < 0: raise newException(OSError, "fork failed")
  if guardian == 0:
    discard setpgid(0, 0)
    let group = getpid()
    let command = fork()
    if command == 0:
      discard close(link[0])
      # Register with our own guardian over the anonymous descriptor pair.
      let registration = "REGISTER " & $getpid()
      discard write(link[1], unsafeAddr registration[0], registration.len)
      var ack: array[1, char]
      if read(link[1], addr ack[0], 1) != 1: quit(126)
      # Also register the whole ancestor graph with the root context when one
      # was inherited, before running any user code.
      if parentRegistration >= 0:
        discard write(parentRegistration, unsafeAddr registration[0], registration.len)
        var parentAck: array[1, char]
        if read(parentRegistration, addr parentAck[0], 1) != 1: quit(126)
      writeFile(marker, $getpid())
      sleep(60_000)
      quit(0)
    discard close(link[1])
    # Park outside the command group; the command stays in group = guardian pid.
    discard setpgid(0, parking)
    discard write(gate[1], addr group, sizeof(group))
    discard close(gate[1])
    var status: cint
    var registration = ""
    while true:
      var ready = TPollfd(fd: link[0], events: POLLIN)
      if poll(addr ready, 1, 50) > 0:
        var buffer: array[64, char]
        let count = read(link[0], addr buffer[0], buffer.len)
        if count > 0:
          for index in 0 ..< count: registration.add buffer[index]
          if registration.len > 0:
            var ack: array[1, char]
            ack[0] = 'K'
            # The child owns the parent-context reply channel: the guardian must
            # never read it or it would steal the ancestor's ACK.
            discard write(link[0], addr ack[0], 1)
      let waited = waitpid(command, status, WNOHANG)
      if waited == command: break
      if waited < 0 and errno == ECHILD: break
      if getpgid(0) == group: quit(125)   # parking must have succeeded
      sleep(10)
    discard close(link[0])
    quit(0)
  discard close(link[1])
  discard close(gate[1])
  var group: Pid
  discard read(gate[0], addr group, sizeof(group))
  discard close(gate[0])
  result = Scope(guardian: guardian, group: group, registration: link[0],
    childMarker: marker)

proc awaitMarker(marker: string, timeoutMs = 5000): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    if fileExists(marker): return true
    sleep(10)
  false

proc closeScope(scope: Scope) =
  ## A scope close kills only its leased group (never the parking group) and
  ## waits for the parked guardian to retire.
  discard close(scope.registration)
  discard kill(Pid(-int(scope.group)), SIGKILL)  # leased group, never the parking group
  var status: cint
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    let waited = waitpid(scope.guardian, status, WNOHANG)
    if waited == scope.guardian: return
    if waited < 0 and errno != EINTR: return
    sleep(5)

let base = "/tmp/leaf-ownership-prototype"
removeDir(base)
createDir(base)
var passed = 0
var failed = 0
proc check(condition: bool, label: string) =
  if condition: inc passed; echo "OK   ", label
  else: inc failed; echo "FAIL ", label

# 1. Parked group: the command is in group == guardian pid, the guardian is not.
let root = spawnScope(base / "root.marker", -1)
check root.group > 0, "guardian leased a command group"
check awaitMarker(base / "root.marker"), "command ran only after the ACK gate"
let rootChild = parseInt(readFile(base / "root.marker"))
check pgidOf(rootChild) == int(root.group), "command pgid equals the leased group"
check pgidOf(int(root.guardian)) != int(root.group), "guardian parked outside the group"
check alive(int(root.guardian)), "guardian alive while leased"

# 2. Nested scope registered with an ancestor context registry (test-owned, so
#    no guardian competes for the reply channel), then selectively closed.
var registry: array[2, cint]
if socketpair(AF_UNIX, SOCK_STREAM, 0, registry) != 0:
  raise newException(OSError, "registry socketpair failed")
let inner = spawnScope(base / "inner.marker", registry[1])
discard close(registry[1])
var registered = false
let registryDeadline = getMonoTime() + initDuration(seconds = 5)
while getMonoTime() < registryDeadline:
  var ready = TPollfd(fd: registry[0], events: POLLIN)
  if poll(addr ready, 1, 50) > 0:
    var buffer: array[64, char]
    let count = read(registry[0], addr buffer[0], buffer.len)
    if count > 0:
      registered = true
      var ack: array[1, char]
      ack[0] = 'K'
      discard write(registry[0], addr ack[0], 1)
      break
check registered, "nested scope registered with the ancestor graph before launch"
check awaitMarker(base / "inner.marker"), "nested command ran only after the ancestor ACK"
let innerChild = parseInt(readFile(base / "inner.marker"))
check pgidOf(innerChild) == int(inner.group), "nested command owns its own group"
closeScope(inner)
sleep(200)
check not alive(innerChild), "inner close killed the nested command"
check alive(rootChild), "inner close left the root command active"
check alive(int(root.guardian)), "inner close left the root guardian active"

# 3. Group kill leaves the guardian alive to reap; no root filesystem writes.
check not fileExists(base / "lease.sock"), "no lease socket/file was created"
closeScope(root)
sleep(200)
check not alive(rootChild), "root close killed the root command"
check not alive(int(root.guardian)), "root guardian retired after cleanup"

echo "passed=", passed, " failed=", failed
quit(if failed == 0: 0 else: 1)
