import ./cleanup_support
import std/[json, monotimes, options, os, sequtils, strutils, tempfiles, times, unittest]
import leaf/sqlite
import leaf/migrations

proc createTableOp(table: string): SchemaOperation =
  SchemaOperation(kind: moCreateTable,
    tableSpec: TableSpec(name: table, hasId: true), tableDefinitionProvided: true)

proc dropTableOp(table: string): SchemaOperation =
  SchemaOperation(kind: moDropTable,
    tableSpec: TableSpec(name: table, hasId: true), tableDefinitionProvided: true)

proc nimDefinition(version: int64, name: string, pending = false,
    hasDown = true): MigrationDefinition =
  if pending:
    MigrationDefinition(version: version, name: name, sourcePath: name & ".nim",
      sourceChecksum: sha256Text(name), format: mfNimV1, hasDown: false, pending: true)
  elif hasDown:
    MigrationDefinition(version: version, name: name, sourcePath: name & ".nim",
      sourceChecksum: sha256Text(name), format: mfNimV1,
      upOps: @[createTableOp(name)], downOps: @[dropTableOp(name)], hasDown: true)
  else:
    MigrationDefinition(version: version, name: name, sourcePath: name & ".nim",
      sourceChecksum: sha256Text(name), format: mfNimV1,
      upOps: @[createTableOp(name)], hasDown: false)

proc sqlDefinition(version: int64, basename, up: string, down = ""): MigrationDefinition =
  MigrationDefinition(version: version, name: basename, sourcePath: basename & ".up.sql",
    sourceChecksum: sha256Text(up), format: mfSqlV1,
    legacyUp: up, legacyDown: down, hasDown: down.len > 0)

let busyRoot = createTempDir("leaf-runner-fix2-", "")
removeDirectoryOnExit(busyRoot)

proc tableExists(db: Database, name: string): bool =
  db.query("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
    @[dbValue(name)])[0][0].asInt == 1

const longSql = """
CREATE TABLE big (n INTEGER);
INSERT INTO big SELECT x FROM (WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 400000) SELECT x FROM c);
"""

let one = nimDefinition(1, "one")
let two = nimDefinition(2, "two")
let three = nimDefinition(3, "three")
let catalog = @[one, two, three]

suite "transactional migration runner":
  test "migrate, repeat and rollback on a memory database":
    let db = openDatabase(":memory:")
    defer: db.close()
    let result = runMigrations(db, catalog, MigrationRequest(kind: mrMigrate))
    check resultExitCode(result) == 0
    check result.executed.mapIt(it.version) == @[1'i64, 2'i64, 3'i64]
    check result.currentVersion == some(3'i64)
    check result.pendingVersions.len == 0
    check tableExists(db, "one") and tableExists(db, "two") and tableExists(db, "three")
    let repeat = runMigrations(db, catalog, MigrationRequest(kind: mrMigrate))
    check repeat.executed.len == 0
    check repeat.currentVersion == some(3'i64)
    check readMigrationHistory(db).len == 3
    let down = runMigrations(db, catalog, MigrationRequest(kind: mrRollback))
    check down.executed.mapIt((it.version, it.direction)) == @[(3'i64, mdDown)]
    check not tableExists(db, "three")
    check down.currentVersion == some(2'i64)
    check readMigrationHistory(db).len == 2

  test "lower holes are filled and up/down no-ops are explicit":
    let db = openDatabase(":memory:")
    defer: db.close()
    discard runMigrations(db, catalog, MigrationRequest(kind: mrUp, target: some(1'i64)))
    discard runMigrations(db, catalog, MigrationRequest(kind: mrUp, target: some(3'i64)))
    let result = runMigrations(db, catalog, MigrationRequest(kind: mrMigrate))
    check result.executed.mapIt(it.version) == @[2'i64]
    let noopUp = runMigrations(db, catalog, MigrationRequest(kind: mrUp, target: some(1'i64)))
    check noopUp.executed.len == 0
    check noopUp.skipped == @[1'i64]
    let noopDown = runMigrations(db, catalog, MigrationRequest(kind: mrDown, target: some(4'i64)))
    check noopDown.errors.len == 1

  test "a failing second migration preserves only the first commit":
    let db = openDatabase(":memory:")
    defer: db.close()
    let broken = sqlDefinition(2, "002_broken",
      "CREATE TABLE partial (id INTEGER); INSERT INTO missing VALUES (1);")
    let result = runMigrations(db, @[one, broken], MigrationRequest(kind: mrMigrate))
    check resultExitCode(result) == 1
    check result.executed.mapIt(it.version) == @[1'i64]
    check result.errors.len == 1
    check result.errors[0].code == "migration_sql_failed"
    check result.errors[0].version == some(2'i64)
    check result.errors[0].file == broken.sourcePath
    check tableExists(db, "one")
    check not tableExists(db, "partial")
    check readMigrationHistory(db).mapIt(it.version) == @[1'i64]
    # repairing the still-unapplied migration succeeds
    let repaired = sqlDefinition(2, "002_broken", "CREATE TABLE partial (id INTEGER);")
    let retry = runMigrations(db, @[one, repaired], MigrationRequest(kind: mrMigrate))
    check resultExitCode(retry) == 0
    check retry.executed.mapIt(it.version) == @[2'i64]
    check tableExists(db, "partial")

  test "static preflight rejects before any history or DDL mutation":
    let db = openDatabase(":memory:")
    defer: db.close()
    let pending = nimDefinition(2, "two", pending = true)
    let result = runMigrations(db, @[one, pending], MigrationRequest(kind: mrMigrate))
    check result.errors.len == 1
    check result.errors[0].code == "pending_migration"
    check not tableExists(db, "one")
    check not tableExists(db, "leaf_schema_migrations")

    let db2 = openDatabase(":memory:")
    defer: db2.close()
    let upOnly = sqlDefinition(2, "002_up_only", "CREATE TABLE two (id INTEGER);")
    discard runMigrations(db2, @[one, upOnly], MigrationRequest(kind: mrMigrate))
    let irreversible = runMigrations(db2, @[one, upOnly], MigrationRequest(kind: mrMigrate, target: some(0'i64)))
    check irreversible.errors.len == 1
    check irreversible.errors[0].code == "missing_migration_down"
    check readMigrationHistory(db2).len == 2
    check tableExists(db2, "one") and tableExists(db2, "two")

  test "immutable, missing and unknown applied history reject with no mutation":
    let db = openDatabase(":memory:")
    defer: db.close()
    discard runMigrations(db, @[one], MigrationRequest(kind: mrMigrate))
    discard db.execute("UPDATE leaf_schema_migrations SET sql = ? WHERE version = ?",
      @[dbValue("DROP TABLE one;"), dbValue(1'i64)])
    let tampered = runMigrations(db, catalog, MigrationRequest(kind: mrMigrate))
    check tampered.errors.len == 1
    check tampered.errors[0].code == "history_sql_modified"
    check tampered.errors[0].file == one.sourcePath
    check not tableExists(db, "two")
    discard db.execute("UPDATE leaf_schema_migrations SET sql = ? WHERE version = ?",
      @[dbValue(forwardSql(one)), dbValue(1'i64)])

    let unknown = runMigrations(db, catalog, MigrationRequest(kind: mrUp, target: some(1'i64)))
    check unknown.executed.len == 0
    check unknown.skipped == @[1'i64]
    var missingCatalog = @[two, three]
    let missing = runMigrations(db, missingCatalog, MigrationRequest(kind: mrMigrate))
    check missing.errors.len == 1
    check missing.errors[0].code == "history_missing_file"

  test "history rows store frozen forwardSql and fingerprints":
    let db = openDatabase(":memory:")
    defer: db.close()
    discard runMigrations(db, @[one], MigrationRequest(kind: mrMigrate))
    let nimRecord = readMigrationHistory(db)[0]
    check nimRecord.format == "nim-v1"
    check nimRecord.sql == forwardSql(one)
    check nimRecord.sourceChecksum == one.sourceChecksum
    check nimRecord.operationsChecksum == operationsFingerprint(one)
    check nimRecord.downChecksum == downFingerprint(one)

    let db2 = openDatabase(":memory:")
    defer: db2.close()
    let descriptor = sqlDefinition(1, "001_create_tasks", "CREATE TABLE tasks (id INTEGER);",
      "DROP TABLE tasks;")
    discard runMigrations(db2, @[descriptor], MigrationRequest(kind: mrMigrate))
    let sqlRecord = readMigrationHistory(db2)[0]
    check sqlRecord.name == "001_create_tasks"
    check sqlRecord.format == "sql-v1"
    check sqlRecord.sql == descriptor.legacyUp
    check sqlRecord.downChecksum == downFingerprint(descriptor)

  test "the runner upgrades a legacy three-column history in its own transaction":
    let db = openDatabase(":memory:")
    defer: db.close()
    db.executeScript("CREATE TABLE leaf_schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, sql TEXT NOT NULL);")
    let legacyUp = "CREATE TABLE tasks (id INTEGER);"
    discard db.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?)",
      @[dbValue(1'i64), dbValue("001_create_tasks"), dbValue(legacyUp)])
    let descriptor = sqlDefinition(1, "001_create_tasks", legacyUp, "DROP TABLE tasks;")
    let result = runMigrations(db, @[descriptor, two], MigrationRequest(kind: mrMigrate))
    check resultExitCode(result) == 0
    check result.executed.mapIt(it.version) == @[2'i64]
    let history = readMigrationHistory(db)
    check history.len == 2
    check history[0].name == "001_create_tasks"
    check history[0].sql == legacyUp
    check history[0].sourceChecksum == descriptor.sourceChecksum
    check history[0].downChecksum == downFingerprint(descriptor)

  test "status inspects a supplied handle without locking or writing":
    let path = busyRoot / "status.sqlite3"
    removeFile(path)
    removeFile(path & ".leaf-migrate.lock")
    let db = openDatabase(path)
    defer:
      db.close()
      removeFile(path)
      removeFile(path & ".leaf-migrate.lock")
    discard runMigrations(db, @[one], MigrationRequest(kind: mrMigrate))
    removeFile(path & ".leaf-migrate.lock")
    let columns = db.query("PRAGMA table_info(leaf_schema_migrations)").len
    let status = runMigrations(db, catalog, MigrationRequest(kind: mrStatus))
    check resultExitCode(status) == 0
    check status.statuses.mapIt(it.state) == @["up", "down", "down"]
    check status.currentVersion == some(1'i64)
    check status.pendingVersions == @[2'i64, 3'i64]
    check not fileExists(path & ".leaf-migrate.lock")
    check db.query("PRAGMA table_info(leaf_schema_migrations)").len == columns

  test "an active business transaction is rejected":
    let db = openDatabase(":memory:")
    defer: db.close()
    db.executeScript("BEGIN")
    let result = runMigrations(db, catalog, MigrationRequest(kind: mrMigrate))
    check result.errors.len == 1
    check result.errors[0].code == "active_transaction"
    discard db.execute("ROLLBACK")
    check db.isAutocommit

  test "the startup migrate overload raises on failure":
    let db = openDatabase(":memory:")
    defer: db.close()
    let broken = sqlDefinition(1, "001_broken", "INSERT INTO missing VALUES (1);")
    expect MigrationError: migrate(db, @[broken])
    check db.isAutocommit

suite "migration script guard":
  test "transaction, attach and history control are denied":
    let db = openDatabase(":memory:")
    defer: db.close()
    discard db.execute("BEGIN")
    discard createMigrationHistory(db)
    discard db.execute("COMMIT")
    expect DatabaseError: executeMigrationScript(db, "BEGIN")
    check db.isAutocommit
    expect DatabaseError: executeMigrationScript(db, "COMMIT")
    expect DatabaseError: executeMigrationScript(db, "ROLLBACK")
    expect DatabaseError: executeMigrationScript(db, "SAVEPOINT s")
    expect DatabaseError: executeMigrationScript(db, "ATTACH DATABASE 'x' AS y")
    expect DatabaseError: executeMigrationScript(db, "PRAGMA writable_schema = ON")
    expect DatabaseError: executeMigrationScript(db,
      "INSERT INTO leaf_schema_migrations (version, name, sql) VALUES (9, 'x', 'y')")
    expect DatabaseError: executeMigrationScript(db,
      "insert into LEAF_SCHEMA_MIGRATIONS (version, name, sql) VALUES (9, 'x', 'y')")
    expect DatabaseError: executeMigrationScript(db, "DROP TABLE leaf_schema_migrations")
    expect DatabaseError: executeMigrationScript(db,
      "CREATE TRIGGER guard AFTER INSERT ON leaf_schema_migrations BEGIN SELECT 1; END")
    # normal SQL and CRUD still work after every denial
    executeMigrationScript(db, "CREATE TABLE normal (id INTEGER)")
    discard db.execute("INSERT INTO normal (id) VALUES (1)")
    check db.query("SELECT count(*) FROM normal")[0][0].asInt == 1
    check db.isAutocommit
    check not db.isScriptGuardActive and not db.isProgressActive

  test "reentrant framework scopes are rejected":
    let db = openDatabase(":memory:")
    defer: db.close()
    db.beginScriptGuard()
    expect ScopeError: db.beginScriptGuard()
    expect ScopeError: db.beginMigrationRunner()
    db.endScriptGuard()
    db.beginMigrationRunner()
    expect ScopeError: db.beginMigrationRunner()
    db.endMigrationRunner()
    db.installProgress(1000, nil, nil)
    expect ScopeError: db.installProgress(1000, nil, nil)
    db.clearProgress()
    check db.isAutocommit

  test "a throwing cancel hook cannot cross the C boundary":
    let db = openDatabase(":memory:")
    defer: db.close()
    var calls = 0
    proc throwing(): bool =
      inc calls
      raise newException(ValueError, "cancel hook failed")
    expect MigrationError:
      executeMigrationScript(db, longSql, throwing)
    check calls > 0
    check not db.isScriptGuardActive and not db.isProgressActive
    check db.isAutocommit
    executeMigrationScript(db, "CREATE TABLE after (id INTEGER)")

suite "migration cancellation":
  test "cancellation during expensive SQL keeps earlier commits":
    let db = openDatabase(":memory:")
    defer: db.close()
    let slow = sqlDefinition(2, "002_big", longSql)
    var calls = 0
    proc cancelDuringSql(): bool =
      inc calls
      calls > 20
    let result = runMigrations(db, @[one, slow], MigrationRequest(kind: mrMigrate),
      cancelDuringSql)
    check resultExitCode(result) == 130
    check result.executionConfirmed
    check result.executed.mapIt(it.version) == @[1'i64]
    check result.errors.len == 1
    check result.errors[0].code == "migration_cancelled"
    check result.errors[0].version == some(2'i64)
    check tableExists(db, "one")
    check not tableExists(db, "big")
    check readMigrationHistory(db).mapIt(it.version) == @[1'i64]
    check db.isAutocommit
    # the lock is reusable and a later run completes the migration
    let retry = runMigrations(db, @[one, slow], MigrationRequest(kind: mrMigrate))
    check resultExitCode(retry) == 0
    check retry.executed.mapIt(it.version) == @[2'i64]

  test "cancellation at a step boundary commits nothing new":
    let db = openDatabase(":memory:")
    defer: db.close()
    proc alwaysCancel(): bool = true
    let result = runMigrations(db, catalog, MigrationRequest(kind: mrMigrate), alwaysCancel)
    check resultExitCode(result) == 130
    check result.executed.len == 0
    check result.errors[0].code == "migration_cancelled"
    check not tableExists(db, "one")

suite "migration result serialization":
  test "JSON is one truthful object with decimal version strings":
    let step = MigrationStep(version: 1, direction: mdUp, statements: @["CREATE TABLE one (id INTEGER)"],
      name: "one", sourcePath: "one.nim")
    var migration = MigrationResult(command: "migrate", database: ":memory:",
      executionConfirmed: true, planned: @[step], executed: @[step], skipped: @[2'i64],
      currentVersion: some(1'i64), pendingVersions: @[2'i64],
      errors: @[MigrationIssue(code: "sample", message: "m", version: some(3'i64),
        file: "f", direction: some(mdDown))])
    let node = resultJson(migration)
    check node.kind == JObject
    check node["executed"].kind == JArray
    check node["executed"][0]["version"].getStr == "1"
    check node["executed"][0]["direction"].getStr == "up"
    check node["current_version"].getStr == "1"
    check node["skipped"][0].getStr == "2"
    check node["pending_versions"][0].getStr == "2"
    check node["errors"][0]["version"].getStr == "3"
    check node["errors"][0]["direction"].getStr == "down"
    check resultExitCode(migration) == 1

    var terminated = migration
    terminated.executionConfirmed = false
    let terminatedNode = resultJson(terminated)
    check terminatedNode["executed"].kind == JNull
    check terminatedNode["current_version"].kind == JNull
    check terminatedNode["pending_versions"].kind == JNull
    check resultExitCode(terminated) == 130

    var unknown = migration
    unknown.currentVersion = none(int64)
    unknown.pendingVersions = @[]
    let unknownNode = resultJson(unknown)
    check unknownNode["current_version"].kind == JNull
    check unknownNode["pending_versions"].kind == JNull

    var empty = migration
    empty.executed = @[]
    empty.currentVersion = some(0'i64)
    empty.pendingVersions = @[1'i64, 2'i64]
    let emptyNode = resultJson(empty)
    check emptyNode["current_version"].getStr == "0"
    check emptyNode["pending_versions"].len == 2

    var cancelled = migration
    cancelled.errors = @[MigrationIssue(code: "migration_cancelled", message: "cancelled")]
    check resultExitCode(cancelled) == 130

    var rollback = migration
    rollback.planned = @[MigrationStep(version: 2, direction: mdDown, name: "two",
      sourcePath: "two.nim")]
    check "not restored" in resultText(rollback)

when defined(windows):
  const SQLiteLib = "winsqlite3.dll"
elif defined(macosx):
  const SQLiteLib = "libsqlite3.dylib"
else:
  const SQLiteLib = "libsqlite3.so(|.0)"

type
  SqlContext {.pure, inheritable.} = object
  SqlArg {.pure, inheritable.} = object
  ScalarFn = proc(context: ptr SqlContext, argc: cint, argv: ptr ptr SqlArg) {.cdecl.}

proc createFunction(db: pointer, name: cstring, nArg, coding: cint, data: pointer,
    scalar: ScalarFn, step, final, destroy: pointer): cint {.
  cdecl, importc: "sqlite3_create_function_v2", dynlib: SQLiteLib.}
proc returnInt(context: ptr SqlContext, value: cint) {.
  cdecl, importc: "sqlite3_result_int", dynlib: SQLiteLib.}

var shortCancelFlag = false
proc signalCancel(context: ptr SqlContext, argc: cint, argv: ptr ptr SqlArg) {.cdecl.} =
  shortCancelFlag = true
  returnInt(context, 1)

suite "migration runner fix round 1":
  test "busy database returns a report instead of escaping":
    let path = busyRoot / "busy.sqlite3"
    for candidate in [path, path & "-wal", path & "-shm", path & ".leaf-migrate.lock"]:
      removeFile(candidate)
    let db = openDatabase(path)
    let blocker = openDatabase(path)
    defer:
      db.close()
      blocker.close()
      for candidate in [path, path & "-wal", path & "-shm", path & ".leaf-migrate.lock"]:
        removeFile(candidate)
    db.executeScript("PRAGMA busy_timeout = 10")
    discard blocker.execute("BEGIN IMMEDIATE")
    let result = runMigrations(db, @[one], MigrationRequest(kind: mrMigrate))
    check result.errors.len == 1
    check resultExitCode(result) == 1
    check not db.isMigrationRunnerActive
    check db.isAutocommit
    discard blocker.execute("ROLLBACK")

  test "a busy second step preserves the first commit":
    let path = busyRoot / "busy2.sqlite3"
    for candidate in [path, path & "-wal", path & "-shm", path & ".leaf-migrate.lock"]:
      removeFile(candidate)
    let db = openDatabase(path)
    let blocker = openDatabase(path)
    defer:
      db.close()
      blocker.close()
      for candidate in [path, path & "-wal", path & "-shm", path & ".leaf-migrate.lock"]:
        removeFile(candidate)
    db.executeScript("PRAGMA busy_timeout = 10")
    proc blockBeforeSecond(): bool =
      # Block at the step-2 boundary (autocommit, step 1 already committed),
      # not during the intra-transaction post-SQL cancellation check.
      if db.isAutocommit and tableExists(db, "one"):
        discard blocker.execute("BEGIN IMMEDIATE")
      false
    let result = runMigrations(db, @[one, two], MigrationRequest(kind: mrMigrate),
      blockBeforeSecond)
    check result.errors.len == 1
    check result.executed.mapIt(it.version) == @[1'i64]
    check result.errors[0].version == some(2'i64)
    check result.currentVersion == some(1'i64)
    check readMigrationHistory(db).mapIt(it.version) == @[1'i64]
    check not db.isMigrationRunnerActive
    discard blocker.execute("ROLLBACK")

  test "a blob in stored history is reported, not raised":
    let db = openDatabase(":memory:")
    defer: db.close()
    discard runMigrations(db, @[one], MigrationRequest(kind: mrMigrate))
    discard db.execute("UPDATE main.leaf_schema_migrations SET sql = X'0102'")
    let result = runMigrations(db, @[one], MigrationRequest(kind: mrStatus))
    check result.errors.len == 1
    check resultExitCode(result) == 1
    check result.currentVersion.isNone

  test "status promotes fatal history issues and discloses warnings":
    let db = openDatabase(":memory:")
    defer: db.close()
    discard runMigrations(db, @[one], MigrationRequest(kind: mrMigrate))
    discard db.execute("UPDATE main.leaf_schema_migrations SET sql = 'changed'")
    let result = runMigrations(db, @[one], MigrationRequest(kind: mrStatus))
    check result.statuses.len == 1
    check result.statuses[0].state == "modified"
    check resultExitCode(result) == 1
    check result.errors.len >= 1
    let text = resultText(result)
    check "status 1 modified" in text
    check "history_sql_modified" in text
    check one.sourcePath in text

  test "short SQL cancellation is honored before commit":
    shortCancelFlag = false
    let db = openDatabase(":memory:")
    defer: db.close()
    check createFunction(db.borrowSqliteHandle(), "signal_cancel", 0, 1, nil, signalCancel,
      nil, nil, nil) == 0
    let short = sqlDefinition(1, "001_short", "CREATE TABLE short AS SELECT signal_cancel();")
    proc isCancelled(): bool = shortCancelFlag
    let result = runMigrations(db, @[short], MigrationRequest(kind: mrMigrate), isCancelled)
    check shortCancelFlag
    check resultExitCode(result) == 130
    check result.executed.len == 0
    check result.errors[0].code == "migration_cancelled"
    check result.errors[0].version == some(1'i64)
    check readMigrationHistory(db).len == 0
    check not tableExists(db, "short")

  test "known state and step identity survive failures":
    let db = openDatabase(":memory:")
    defer: db.close()
    discard runMigrations(db, @[one], MigrationRequest(kind: mrMigrate))
    let invalid = runMigrations(db, @[one], MigrationRequest(kind: mrUp, target: some(9'i64)))
    check invalid.errors[0].code == "invalid_migration_target"
    check invalid.currentVersion == some(1'i64)
    check invalid.pendingVersions.len == 0
    let db2 = openDatabase(":memory:")
    defer: db2.close()
    proc failing(): bool = raise newException(ValueError, "boundary callback throws")
    let callback = runMigrations(db2, @[one], MigrationRequest(kind: mrMigrate), failing)
    check callback.errors[0].code == "migration_callback_failed"
    check callback.errors[0].version == some(1'i64)
    check callback.errors[0].file == one.sourcePath
    check callback.errors[0].direction == some(mdUp)

  test "ordinary columns named like the history table are allowed":
    let db = openDatabase(":memory:")
    defer: db.close()
    let legitimate = sqlDefinition(1, "001_column",
      "CREATE TABLE normal (leaf_schema_migrations TEXT); " &
      "INSERT INTO normal VALUES ('a'); " &
      "UPDATE normal SET leaf_schema_migrations='b';")
    let result = runMigrations(db, @[legitimate], MigrationRequest(kind: mrMigrate))
    check resultExitCode(result) == 0
    check result.executed.len == 1
    check db.query("SELECT leaf_schema_migrations FROM normal")[0][0].asString == "b"

suite "migration script guard fix round 2":
  test "qualified and case-variant history mutations are denied":
    let db = openDatabase(":memory:")
    defer: db.close()
    discard db.execute("BEGIN")
    discard createMigrationHistory(db)
    discard db.execute("COMMIT")
    expect DatabaseError:
      executeMigrationScript(db, "ALTER TABLE main.leaf_schema_migrations ADD COLUMN corrupt TEXT")
    expect DatabaseError:
      executeMigrationScript(db, "ALTER TABLE leaf_schema_migrations RENAME TO renamed_history")
    expect DatabaseError:
      executeMigrationScript(db, "ALTER TABLE MAIN.LEAF_SCHEMA_MIGRATIONS ADD COLUMN corrupt TEXT")
    expect DatabaseError:
      executeMigrationScript(db,
        "CREATE TEMP TRIGGER erase AFTER INSERT ON main.leaf_schema_migrations BEGIN DELETE FROM leaf_schema_migrations; END")
    expect DatabaseError:
      executeMigrationScript(db,
        "CREATE TRIGGER keep AFTER INSERT ON leaf_schema_migrations BEGIN SELECT 1; END")
    expect DatabaseError:
      executeMigrationScript(db, "CREATE INDEX hidx ON leaf_schema_migrations (version)")
    expect DatabaseError:
      executeMigrationScript(db, "CREATE TEMP TABLE leaf_schema_migrations (version INTEGER)")
    check db.query("PRAGMA main.table_info(leaf_schema_migrations)").len == 7
    check not db.isScriptGuardActive and not db.isProgressActive
    executeMigrationScript(db, "CREATE TABLE normal (leaf_schema_migrations TEXT)")
    executeMigrationScript(db, "UPDATE normal SET leaf_schema_migrations = 'b'")

suite "migration runner fix round 2":
  test "a history trigger migration is rejected before any mutation":
    let db = openDatabase(":memory:")
    defer: db.close()
    let trigger = sqlDefinition(1, "001_trigger",
      "CREATE TABLE work(id INTEGER); CREATE TEMP TRIGGER erase_history AFTER INSERT ON " &
      "main.leaf_schema_migrations BEGIN DELETE FROM leaf_schema_migrations; END;")
    let result = runMigrations(db, @[trigger], MigrationRequest(kind: mrMigrate))
    check resultExitCode(result) == 1
    check result.executed.len == 0
    check not tableExists(db, "work")
    check readMigrationHistory(db).len == 0

    let db2 = openDatabase(":memory:")
    defer: db2.close()
    discard runMigrations(db2, @[one], MigrationRequest(kind: mrMigrate))
    let alter = sqlDefinition(2, "002_alter",
      "ALTER TABLE main.leaf_schema_migrations ADD COLUMN corrupt TEXT;")
    let altered = runMigrations(db2, @[one, alter], MigrationRequest(kind: mrMigrate))
    check altered.executed.len == 0
    check altered.errors.len == 1
    check readMigrationHistory(db2).mapIt(it.version) == @[1'i64]
    check db2.query("PRAGMA main.table_info(leaf_schema_migrations)").len == 7

  test "pending preflight happens before the lock":
    let path = busyRoot / "pending-lock.sqlite3"
    removeFile(path & ".leaf-migrate.lock")
    let db = openDatabase(path)
    defer:
      db.close()
      removeFile(path)
      removeFile(path & ".leaf-migrate.lock")
    let owner = acquireFileLock(migrationLockPath(db))
    var pending = sqlDefinition(2, "002_pending", "")
    pending.pending = true
    let started = getMonoTime()
    let result = runMigrations(db, @[one, pending], MigrationRequest(kind: mrMigrate))
    let elapsed = (getMonoTime() - started).inMilliseconds
    check result.errors[0].code == "pending_migration"
    check elapsed < 2000
    owner.release()

  test "an unlinked database returns a controlled lock-path report":
    let path = busyRoot / "unlinked.sqlite3"
    let db = openDatabase(path)
    defer: db.close()
    removeFile(path)
    let result = runMigrations(db, @[one], MigrationRequest(kind: mrMigrate))
    check result.errors.len == 1
    check result.errors[0].code == "migration_lock_path_failed"
    check result.executed.len == 0
    check not db.isMigrationRunnerActive

  test "unconfirmed reports never claim committed executions":
    let arbitrary = MigrationStep(version: 77, direction: mdUp, name: "not_confirmed",
      sourcePath: "unknown.nim")
    let terminated = MigrationResult(command: "migrate", executionConfirmed: false,
      planned: @[arbitrary], executed: @[arbitrary], currentVersion: some(77'i64),
      pendingVersions: @[78'i64])
    let node = resultJson(terminated)
    check node["executed"].kind == JNull
    check node["current_version"].kind == JNull
    check node["pending_versions"].kind == JNull
    let text = resultText(terminated)
    check "not confirmed" in text
    check "status" in text
    check "executed up 77" notin text
    check "current version: 77" notin text
    check "pending versions" notin text
    check resultExitCode(terminated) == 130
