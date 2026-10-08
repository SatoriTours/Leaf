import ./cleanup_support
import std/[monotimes, os, osproc, strutils, tempfiles, times, unittest]
import leaf/migrations
import ./migration_compile_support

when defined(posix): import std/posix

let base = createTempDir("leaf-migration-locking-", "")
removeDirectoryOnExit(base)

const holderSource = """
import std/[os, times]
import leaf/migrations

let lock = acquireFileLock(paramStr(1), 2000)
writeFile(paramStr(2), "locked")
sleep(30000)
lock.release()
"""

proc timeoutError(path: string, timeoutMs: int): tuple[code, message: string] =
  try:
    discard acquireFileLock(path, timeoutMs)
    ("", "")
  except MigrationError as error:
    (error.issueCode, error.msg)

suite "migration file locks":
  test "exclusive locks serialize and time out":
    let path = base / "basic.lock"
    let first = acquireFileLock(path, 200)
    let failure = timeoutError(path, 150)
    check failure.code == "concurrent_migration"
    check "timed out" in failure.message
    first.release()
    let second = acquireFileLock(path, 500)
    check second != nil
    second.release()

  test "an existing stale lock file is reusable and release is idempotent":
    let path = base / "stale.lock"
    writeFile(path, "")
    let lock = acquireFileLock(path, 200)
    check lock != nil
    lock.release()
    lock.release()
    let again = acquireFileLock(path, 200)
    again.release()
    check fileExists(path)

  test "lock paths accept Unicode and spaces":
    let path = base / "中文 目录" / "迁移 lock"
    createDir(path.parentDir)
    let lock = acquireFileLock(path, 500)
    check lock != nil
    check fileExists(path)
    lock.release()

  test "locks release on scope exit and after failures":
    let path = base / "scope.lock"
    proc holdAndReturn() =
      let lock = acquireFileLock(path, 200)
      check lock != nil
    holdAndReturn()
    let afterScope = acquireFileLock(path, 500)
    afterScope.release()
    proc guarded() =
      let lock = acquireFileLock(path, 200)
      defer: lock.release()
      raise newException(ValueError, "boom")
    expect ValueError: guarded()
    let afterFailure = acquireFileLock(path, 500)
    afterFailure.release()

  when defined(posix):
    test "killing the owning process releases the lock":
      let tools = base / "holder-tools"
      writeProbeFiles(tools, @[("holder.nim", holderSource)])
      let holder = buildProbe(tools, "holder.nim", base / "holder-cache", "holder")
      check holder.code == 0
      if holder.code != 0:
        checkpoint(holder.output)
      else:
        let path = base / "killed.lock"
        let marker = base / "holder-ready"
        let child = startProcess(holder.binary, args = @[path, marker],
          options = {poStdErrToStdOut})
        var waited = 0
        while not fileExists(marker) and waited < 15000:
          sleep(20)
          waited += 20
        check fileExists(marker)
        if fileExists(marker):
          discard posix.kill(Pid(child.processID), SIGKILL)
          discard child.waitForExit()
          child.close()
          let lock = acquireFileLock(path, 2000)
          check lock != nil
          lock.release()
        else:
          child.close()

when defined(linux):
  proc prctl(option: cint, arg2, arg3, arg4, arg5: culong): cint {.
    importc, header: "<sys/prctl.h>".}
  const PrSetChildSubreaper = 36.cint
  discard prctl(PrSetChildSubreaper, 1, 0, 0, 0)

const execHolderSource = """
import std/[os, times]
import leaf/migrations
when defined(posix):
  import std/posix
  let lock = acquireFileLock(paramStr(1), 2000)
  let child = fork()
  if int(child) == 0:
    discard execl("/bin/sleep", "sleep", "30", cast[cstring](nil))
    quit(1)
  writeFile(paramStr(2), $child)
  sleep(30000)
  lock.release()
"""

suite "migration locking fix round 1":
  test "permanent lock path errors fail promptly and distinctly":
    let started = getMonoTime()
    let missing = timeoutError(base / "absent-parent" / "lock", 2000)
    check missing.code == "lock_path_error"
    check (getMonoTime() - started) < initDuration(milliseconds = 1000)
    check "lock" in missing.message
    let directory = base / "a-directory"
    createDir(directory)
    check timeoutError(directory, 2000).code == "lock_path_error"
    check timeoutError("", 100).code == "invalid_lock_path"
    check timeoutError("bad\0path", 100).code == "invalid_lock_path"

  when defined(linux):
    test "locks do not leak into exec descendants after the owner is killed":
      let tools = base / "exec-holder-tools"
      writeProbeFiles(tools, @[("holder.nim", execHolderSource)])
      let holder = buildProbe(tools, "holder.nim", base / "exec-holder-cache", "holder")
      check holder.code == 0
      if holder.code == 0:
        let path = base / "exec.lock"
        let marker = base / "exec-child.pid"
        removeFile(marker)
        let owner = startProcess(holder.binary, args = @[path, marker],
          options = {poStdErrToStdOut})
        var childPid = 0
        try:
          var waited = 0
          while not fileExists(marker) and waited < 15000:
            sleep(20)
            waited += 20
          check fileExists(marker)
          if fileExists(marker):
            childPid = parseInt(readFile(marker).strip())
            discard posix.kill(Pid(owner.processID), SIGKILL)
            discard owner.waitForExit()
            let lock = acquireFileLock(path, 2000)
            check lock != nil
            lock.release()
        finally:
          if owner.peekExitCode() == -1:
            discard posix.kill(Pid(owner.processID), SIGKILL)
            discard owner.waitForExit()
          owner.close()
          if childPid > 0:
            discard posix.kill(Pid(childPid), SIGKILL)
            var status: cint
            discard posix.waitpid(Pid(childPid), status, 0)
