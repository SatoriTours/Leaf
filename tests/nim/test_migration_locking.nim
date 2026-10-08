import ./cleanup_support
import std/[os, osproc, strutils, tempfiles, unittest]
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
