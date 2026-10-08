import ./cleanup_support
import std/[json, monotimes, os, osproc, sequtils, streams, strutils, tempfiles, times, unittest]
import leaf/sqlite
import leaf/migrations
import ./migration_compile_support

when defined(posix): import std/posix

let base = createTempDir("leaf-migration-locking-", "")
removeDirectoryOnExit(base)

proc killAndClose(child: Process) =
  ## Bounded best-effort kill/reap/close; never masks the caller's error.
  if child == nil: return
  try:
    if child.peekExitCode() == -1:
      when defined(posix):
        discard posix.kill(Pid(child.processID), SIGKILL)
      else:
        child.terminate()
      discard child.waitForExit()
  except CatchableError:
    discard
  try:
    child.close()
  except CatchableError:
    discard

type
  FixtureChild = ref object
    process: Process
    finished: bool

proc startChild(binary: string, args: seq[string]): FixtureChild =
  FixtureChild(process: startProcess(binary, args = args, options = {poStdErrToStdOut}))

proc stopChild(child: FixtureChild) =
  ## Exactly-once kill/reap/close on every path.
  if child == nil or child.process == nil or child.finished: return
  child.finished = true
  killAndClose(child.process)

proc finishChild(child: FixtureChild,
    timeoutMs = 30000): tuple[code: int, data: JsonNode] =
  ## Bounded wait; parse before marking finished so a failure still cleans up.
  if child == nil or child.process == nil: return (1, newJNull())
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while child.process.peekExitCode() == -1 and getMonoTime() < deadline:
    sleep(20)
  if child.process.peekExitCode() == -1:
    stopChild(child)
    raise newException(IOError, "fixture process did not exit within the deadline")
  result.code = child.process.waitForExit()
  let output = child.process.outputStream.readAll()
  child.finished = true
  try: child.process.close()
  except CatchableError: discard
  result.data = newJNull()
  for line in output.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("{"): result.data = parseJson(trimmed)

proc runChild(binary: string, args: seq[string],
    timeoutMs = 30000): tuple[code: int, data: JsonNode] =
  let child = startChild(binary, args)
  try:
    result = finishChild(child, timeoutMs)
  finally:
    stopChild(child)

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
        try:
          var waited = 0
          while not fileExists(marker) and waited < 15000:
            sleep(20)
            waited += 20
          check fileExists(marker)
          if fileExists(marker):
            discard posix.kill(Pid(child.processID), SIGKILL)
            discard child.waitForExit()
            let lock = acquireFileLock(path, 2000)
            check lock != nil
            lock.release()
        finally:
          killAndClose(child)

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

let fixtureBuild = block:
  let tools = base / "migration-tools"
  writeProbeFiles(tools, @[("fixture.nim",
    readFile(currentSourcePath().parentDir / "migration_process_fixture.nim"))])
  buildProbe(tools, "fixture.nim", base / "migration-tools-cache", "fixture")

proc fastV1(): MigrationDefinition =
  let up = SchemaOperation(kind: moCreateTable,
    tableSpec: TableSpec(name: "one", hasId: true), tableDefinitionProvided: true)
  let down = SchemaOperation(kind: moDropTable,
    tableSpec: TableSpec(name: "one", hasId: true), tableDefinitionProvided: true)
  MigrationDefinition(version: 1, name: "one", sourcePath: "one.nim",
    sourceChecksum: sha256Text("one"), format: mfNimV1,
    upOps: @[up], downOps: @[down], hasDown: true)

proc waitForMarker(marker: string): bool =
  var waited = 0
  while not fileExists(marker) and waited < 15000:
    sleep(20)
    waited += 20
  fileExists(marker)

suite "database migration locks":
  test "canonical database aliases share one lock path":
    let real = base / "alias-real.sqlite3"
    let db = openDatabase(real)
    defer: db.close()
    when defined(posix):
      createSymlink(real, base / "alias-link.sqlite3")
      let aliased = openDatabase(base / "alias-link.sqlite3")
      defer: aliased.close()
      check migrationLockPath(db) == migrationLockPath(aliased)
    check migrationLockPath(db).endsWith("alias-real.sqlite3.leaf-migrate.lock")

  when defined(posix):
    test "a hostile lock file symlink is refused":
      let real = base / "hostile-real.sqlite3"
      let db = openDatabase(real)
      defer: db.close()
      let lockPath = migrationLockPath(db)
      createSymlink(base / "elsewhere", lockPath)
      let failure = timeoutError(lockPath, 500)
      check failure.code == "lock_path_error"

  test "real migration processes serialize, replan and recover":
    let fixture = fixtureBuild
    check fixture.code == 0
    if fixture.code != 0:
      checkpoint(fixture.output)
    else:
      let dbPath = base / "process.sqlite3"
      let first = runChild(fixture.binary, @["migrate", dbPath])
      check first.code == 0
      check first.data["executed"].len == 2
      let second = runChild(fixture.binary, @["migrate", dbPath])
      check second.code == 0
      check second.data["executed"].len == 0
      check second.data["current_version"].getStr == "2"
      let rolled = runChild(fixture.binary, @["rollback", dbPath, "1"])
      check rolled.code == 0
      check rolled.data["executed"][0]["direction"].getStr == "down"
      check rolled.data["current_version"].getStr == "1"

      let timeoutDb = base / "timeout.sqlite3"
      removeFile(timeoutDb & ".leaf-migrate.lock")
      let timeoutMarker = base / "timeout-marker"
      removeFile(timeoutMarker)
      let holder = startChild(fixture.binary, @["hold", timeoutDb, timeoutMarker, "8000"])
      try:
        check waitForMarker(timeoutMarker)
        let started = getMonoTime()
        let blocked = runChild(fixture.binary, @["migrate", timeoutDb])
        let elapsed = (getMonoTime() - started).inMilliseconds
        check blocked.code == 1
        check blocked.data["errors"][0]["code"].getStr == "concurrent_migration"
        check elapsed >= 4500
        check elapsed < 9500
      finally:
        stopChild(holder)

      let killDb = base / "kill.sqlite3"
      removeFile(killDb & ".leaf-migrate.lock")
      let killMarker = base / "kill-marker"
      removeFile(killMarker)
      let killed = startChild(fixture.binary, @["hold", killDb, killMarker, "30000"])
      try:
        check waitForMarker(killMarker)
        when defined(posix):
          discard posix.kill(Pid(killed.process.processID), SIGKILL)
        else:
          killed.process.terminate()
        discard killed.process.waitForExit()
      finally:
        stopChild(killed)
      let afterKill = runChild(fixture.binary, @["migrate", killDb])
      check afterKill.code == 0
      check afterKill.data["executed"].len == 2

      let cancelDb = base / "cancel.sqlite3"
      let cancelled = runChild(fixture.binary, @["cancel-migrate", cancelDb, "20"])
      check cancelled.code == 130
      check cancelled.data["execution_confirmed"].getBool
      check cancelled.data["executed"].len == 1
      check cancelled.data["executed"][0]["version"].getStr == "1"
      check cancelled.data["errors"][0]["code"].getStr == "migration_cancelled"
      let cancelReader = openDatabaseReadOnly(cancelDb)
      check readMigrationHistory(cancelReader).mapIt(it.version) == @[1'i64]
      check cancelReader.query("SELECT count(*) FROM sqlite_master WHERE name = 'big'")[0][0].asInt == 0
      cancelReader.close()
      let cancelRetry = runChild(fixture.binary, @["migrate", cancelDb])
      check cancelRetry.code == 0
      check cancelRetry.data["executed"].len == 1

      let replanDb = base / "replan.sqlite3"
      removeFile(replanDb & ".leaf-migrate.lock")
      let replanMarker = base / "replan-marker"
      removeFile(replanMarker)
      let replanHolder = startChild(fixture.binary, @["hold", replanDb, replanMarker, "2500"])
      try:
        check waitForMarker(replanMarker)
        let writer = openDatabase(replanDb)
        discard writer.execute("BEGIN IMMEDIATE")
        discard createMigrationHistory(writer)
        let v1 = fastV1()
        discard writer.execute("INSERT INTO leaf_schema_migrations " &
          "(version, name, sql, format, source_sha256, operations_sha256, down_sha256) " &
          "VALUES (?, ?, ?, ?, ?, ?, ?)",
          @[dbValue(1'i64), dbValue("one"), dbValue(forwardSql(v1)), dbValue("nim-v1"),
            dbValue(v1.sourceChecksum), dbValue(operationsFingerprint(v1)),
            dbValue(downFingerprint(v1))])
        discard writer.execute("COMMIT")
        writer.close()
        let waiter = runChild(fixture.binary, @["migrate", replanDb])
        check waiter.code == 0
        check waiter.data["executed"].len == 1
        check waiter.data["executed"][0]["version"].getStr == "2"
      finally:
        stopChild(replanHolder)

      when defined(posix):
        let realAlias = base / "alias-shared.sqlite3"
        let aliasPath = base / "alias-shared-link.sqlite3"
        removeFile(realAlias)
        removeFile(realAlias & ".leaf-migrate.lock")
        let seed = openDatabase(realAlias)
        seed.close()
        createSymlink(realAlias, aliasPath)
        let aliasMarker = base / "alias-marker"
        removeFile(aliasMarker)
        let aliasHolder = startChild(fixture.binary, @["hold", realAlias, aliasMarker, "7000"])
        try:
          check waitForMarker(aliasMarker)
          let aliased = runChild(fixture.binary, @["migrate", aliasPath])
          check aliased.code == 1
          check aliased.data["errors"][0]["code"].getStr == "concurrent_migration"
        finally:
          stopChild(aliasHolder)

when compileOption("threads"):
  proc threadWorker(arg: tuple[db: pointer, flag: ptr int]) {.thread.} =
    # Controlled negative test: the owner's ref stays alive through join, so
    # requireUsable must reject before any SQL or callback runs.
    {.cast(gcsafe).}:
      let outcome = runMigrations(cast[Database](arg.db), newSeq[MigrationDefinition](),
        MigrationRequest(kind: mrMigrate))
      if outcome.errors.len == 1 and outcome.errors[0].code == "database_unusable":
        arg.flag[] = 1

suite "simultaneous migration runners":
  test "overlapping batches wait, then replan after the active runner commits":
    let fixture = fixtureBuild
    check fixture.code == 0
    if fixture.code == 0:
      for rollbackMode in [false, true]:
        let dbPath = base / (if rollbackMode: "sim-rollback.sqlite3" else: "sim-migrate.sqlite3")
        let ready = base / "sim-ready"
        let release = base / "sim-release"
        for path in [dbPath, dbPath & "-wal", dbPath & "-shm",
            dbPath & ".leaf-migrate.lock", ready, release]:
          removeFile(path)
        let first = startChild(fixture.binary,
          @["migrate-barrier", dbPath, ready, release])
        var second: FixtureChild
        try:
          check waitForMarker(ready)
          second = startChild(fixture.binary,
            (if rollbackMode: @["rollback-barrier", dbPath, "1"]
             else: @["migrate-barrier-catalog", dbPath]))
          sleep(250)
          # The second batch waits; no step-2 DDL/history exists mid-batch.
          check second.process.peekExitCode() == -1
          let observer = openDatabase(dbPath)
          check readMigrationHistory(observer).mapIt(it.version) == @[1'i64]
          check observer.query(
            "SELECT count(*) FROM sqlite_master WHERE name = 'two'")[0][0].asInt == 0
          observer.close()
          writeFile(release, "go")
          let firstOutcome = finishChild(first)
          let secondOutcome = finishChild(second)
          check firstOutcome.code == 0
          check firstOutcome.data["executed"].len == 2
          check secondOutcome.code == 0
          if rollbackMode:
            check secondOutcome.data["executed"].len == 1
            check secondOutcome.data["executed"][0]["version"].getStr == "2"
            check secondOutcome.data["executed"][0]["direction"].getStr == "down"
          else:
            check secondOutcome.data["executed"].len == 0
            check secondOutcome.data["current_version"].getStr == "2"
        finally:
          stopChild(first)
          stopChild(second)

  when defined(posix):
    test "the lock deadline holds under a signal storm":
      let fixture = fixtureBuild
      check fixture.code == 0
      if fixture.code == 0:
        let dbPath = base / "storm.sqlite3"
        let marker = base / "storm-marker"
        removeFile(dbPath & ".leaf-migrate.lock")
        removeFile(marker)
        let holder = startChild(fixture.binary, @["hold", dbPath, marker, "8000"])
        var waiter: FixtureChild
        try:
          check waitForMarker(marker)
          waiter = startChild(fixture.binary, @["migrate", dbPath])
          let started = getMonoTime()
          while waiter.process.peekExitCode() == -1 and
              (getMonoTime() - started).inMilliseconds < 9000:
            discard posix.kill(Pid(waiter.process.processID), SIGCHLD)
            sleep(20)
          let outcome = finishChild(waiter)
          check outcome.code == 1
          check outcome.data["errors"][0]["code"].getStr == "concurrent_migration"
          check (getMonoTime() - started).inMilliseconds < 9500
        finally:
          stopChild(waiter)
          stopChild(holder)

  when compileOption("threads"):
    test "a database owned by another thread is rejected":
      let db = openDatabase(":memory:")
      var flag = 0
      var thread: Thread[tuple[db: pointer, flag: ptr int]]
      createThread(thread, threadWorker, (cast[pointer](db), addr flag))
      joinThread(thread)
      check flag == 1
      check not db.isMigrationRunnerActive
      check db.query("SELECT count(*) FROM sqlite_master")[0][0].asInt == 0
      db.close()

suite "fixture child cleanup":
  test "child helpers are bounded and clean up on failure paths":
    let invalid = runChild(fixtureBuild.binary, @["bad-json"])
    check invalid.code == 0
    check invalid.data.kind == JNull
    let never = startChild(fixtureBuild.binary, @["never-exit"])
    try:
      expect IOError: discard finishChild(never, 500)
    finally:
      stopChild(never)
    check never.finished
