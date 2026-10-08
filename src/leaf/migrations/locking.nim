## Shared OS file locks for migration generation and (later) the runner.
## POSIX flock / Windows LockFileEx. The lock file's existence never means
## ownership: the OS releases the lock on process exit, and release never
## unlinks the file.
import std/[monotimes, os, times]
import ./types

when defined(windows):
  import std/[widestrs, winlean]
else:
  import std/posix

const
  DefaultLockTimeoutMs* = 5000
  LockPollMs = 10

when defined(posix):
  proc cFlock(fd: cint, operation: cint): cint {.importc: "flock", header: "<sys/file.h>".}
  const
    LockExclusive = 2.cint
    LockNonBlocking = 4.cint
    LockUnlock = 8.cint

when defined(windows):
  type
    Overlapped = object
      internal, internalHigh: uint
      offset, offsetHigh: uint32
      hEvent: Handle
  proc lockFileEx(handle: Handle, flags, reserved: DWORD, low, high: DWORD,
      overlapped: ptr Overlapped): WINBOOL {.
    importc: "LockFileEx", stdcall, dynlib: "kernel32".}
  proc unlockFileEx(handle: Handle, reserved, low, high: DWORD,
      overlapped: ptr Overlapped): WINBOOL {.
    importc: "UnlockFileEx", stdcall, dynlib: "kernel32".}
  const
    LockFileFailImmediately = 0x00000001'i32
    LockFileExclusiveLock = 0x00000002'i32

type
  FileLockState = object
    when defined(windows):
      handle: Handle
    else:
      fd: cint
    acquired: bool
  FileLock* = ref FileLockState

proc closeHandle(state: var FileLockState) =
  if not state.acquired: return
  state.acquired = false
  when defined(windows):
    var overlapped: Overlapped
    discard unlockFileEx(state.handle, 0, 1, 0, addr overlapped)
    discard winlean.closeHandle(state.handle)
  else:
    discard cFlock(state.fd, LockUnlock)
    discard posix.close(state.fd)

proc `=destroy`(state: var FileLockState) =
  state.closeHandle()

proc release*(lock: FileLock) =
  ## Idempotent; safe to call explicitly and again from the destructor.
  if lock == nil: return
  lock[].closeHandle()

proc acquireFileLock*(path: string, timeoutMs = DefaultLockTimeoutMs): FileLock =
  ## Take an exclusive lock, polling until `timeoutMs` elapses. A pre-existing
  ## but unheld lock file is acquired immediately.
  if path.len == 0 or '\0' in path:
    raise migrationError("invalid_lock_path", "lock path is empty or contains NUL")
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    when defined(windows):
      let handle = winlean.createFileW(newWideCString(path),
        DWORD(GENERIC_READ) or DWORD(GENERIC_WRITE),
        DWORD(FILE_SHARE_READ) or DWORD(FILE_SHARE_WRITE), nil,
        DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), Handle(0))
      if handle != INVALID_HANDLE_VALUE:
        var overlapped: Overlapped
        if lockFileEx(handle, LockFileExclusiveLock or LockFileFailImmediately,
            0, 1, 0, addr overlapped) != 0:
          result = FileLock(handle: handle, acquired: true)
          return
        discard winlean.closeHandle(handle)
    else:
      let fd = posix.open(path.cstring, O_RDWR or O_CREAT, 0o644)
      if fd >= 0:
        if cFlock(fd, LockExclusive or LockNonBlocking) == 0:
          result = FileLock(fd: fd, acquired: true)
          return
        discard posix.close(fd)
    if getMonoTime() >= deadline:
      raise migrationError("concurrent_migration",
        "timed out waiting for migration lock: " & path)
    sleep(LockPollMs)
