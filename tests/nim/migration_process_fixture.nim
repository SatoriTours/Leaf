## Test-only child process fixture for migration runner and lock tests.
## Commands print one JSON object and exit with the result exit code.
import std/[json, os, strutils]
import leaf/sqlite
import leaf/migrations

proc cExit(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}

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

var barrierReady, barrierRelease: string

proc barrierFunction(context: ptr SqlContext, argc: cint, argv: ptr ptr SqlArg) {.cdecl.} =
  writeFile(barrierReady, "ready")
  var waited = 0
  while not fileExists(barrierRelease) and waited < 30000:
    sleep(10)
    waited += 10
  returnInt(context, 1)

proc createTableOp(table: string): SchemaOperation =
  SchemaOperation(kind: moCreateTable,
    tableSpec: TableSpec(name: table, hasId: true), tableDefinitionProvided: true)

proc dropTableOp(table: string): SchemaOperation =
  SchemaOperation(kind: moDropTable,
    tableSpec: TableSpec(name: table, hasId: true), tableDefinitionProvided: true)

const slowSql = """
CREATE TABLE big (n INTEGER);
INSERT INTO big SELECT x FROM (WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 600000) SELECT x FROM c);
"""

proc fastCatalog(): seq[MigrationDefinition] =
  @[
    MigrationDefinition(version: 1, name: "one", sourcePath: "one.nim",
      sourceChecksum: sha256Text("one"), format: mfNimV1,
      upOps: @[createTableOp("one")], downOps: @[dropTableOp("one")], hasDown: true),
    MigrationDefinition(version: 2, name: "two", sourcePath: "two.nim",
      sourceChecksum: sha256Text("two"), format: mfNimV1,
      upOps: @[createTableOp("two")], downOps: @[dropTableOp("two")], hasDown: true)]

proc slowCatalog(): seq[MigrationDefinition] =
  @[
    MigrationDefinition(version: 1, name: "one", sourcePath: "one.nim",
      sourceChecksum: sha256Text("one"), format: mfNimV1,
      upOps: @[createTableOp("one")], downOps: @[dropTableOp("one")], hasDown: true),
    MigrationDefinition(version: 2, name: "002_big", sourcePath: "002_big.up.sql",
      sourceChecksum: sha256Text(slowSql), format: mfSqlV1,
      legacyUp: slowSql, hasDown: false)]

proc barrierCatalog(): seq[MigrationDefinition] =
  @[
    MigrationDefinition(version: 1, name: "001_one", sourcePath: "001_one.up.sql",
      sourceChecksum: sha256Text("CREATE TABLE one(id INTEGER);"), format: mfSqlV1,
      legacyUp: "CREATE TABLE one(id INTEGER);"),
    MigrationDefinition(version: 2, name: "002_two", sourcePath: "002_two.up.sql",
      sourceChecksum: sha256Text("CREATE TABLE two AS SELECT barrier();"), format: mfSqlV1,
      legacyUp: "CREATE TABLE two AS SELECT barrier();", legacyDown: "DROP TABLE two;",
      hasDown: true)]

proc main(): int =
  let command = paramStr(1)
  case command
  of "migrate":
    let db = openDatabase(paramStr(2))
    let outcome = runMigrations(db, fastCatalog(), MigrationRequest(kind: mrMigrate))
    echo $resultJson(outcome)
    result = resultExitCode(outcome)
    db.close()
  of "rollback":
    let db = openDatabase(paramStr(2))
    let outcome = runMigrations(db, fastCatalog(),
      MigrationRequest(kind: mrRollback, steps: parseInt(paramStr(3))))
    echo $resultJson(outcome)
    result = resultExitCode(outcome)
    db.close()
  of "status":
    let db = openDatabaseReadOnly(paramStr(2))
    let outcome = runMigrations(db, fastCatalog(), MigrationRequest(kind: mrStatus))
    echo $resultJson(outcome)
    result = resultExitCode(outcome)
    db.close()
  of "cancel-migrate":
    let db = openDatabase(paramStr(2))
    let limit = parseInt(paramStr(3))
    var calls = 0
    let outcome = runMigrations(db, slowCatalog(), MigrationRequest(kind: mrMigrate),
      proc(): bool =
        inc calls
        calls > limit)
    echo $resultJson(outcome)
    result = resultExitCode(outcome)
    db.close()
  of "hold":
    let db = openDatabase(paramStr(2))
    let lock = acquireFileLock(migrationLockPath(db), 5000)
    writeFile(paramStr(3), "locked")
    sleep(parseInt(paramStr(4)))
    lock.release()
    echo "{}"
    result = 0
    db.close()
  of "migrate-barrier-catalog":
    let db = openDatabase(paramStr(2))
    let outcome = runMigrations(db, barrierCatalog(), MigrationRequest(kind: mrMigrate))
    echo $resultJson(outcome)
    result = resultExitCode(outcome)
    db.close()
  of "rollback-barrier":
    let db = openDatabase(paramStr(2))
    let outcome = runMigrations(db, barrierCatalog(),
      MigrationRequest(kind: mrRollback, steps: parseInt(paramStr(3))))
    echo $resultJson(outcome)
    result = resultExitCode(outcome)
    db.close()
  of "migrate-barrier":
    barrierReady = paramStr(3)
    barrierRelease = paramStr(4)
    let db = openDatabase(paramStr(2))
    if createFunction(db.borrowSqliteHandle(), "barrier", 0, 1, nil, barrierFunction,
        nil, nil, nil) != 0:
      stderr.writeLine("cannot register barrier")
      result = 2
    else:
      let outcome = runMigrations(db, barrierCatalog(), MigrationRequest(kind: mrMigrate))
      echo $resultJson(outcome)
      result = resultExitCode(outcome)
    db.close()
  else:
    stderr.writeLine("unknown command: " & command)
    result = 2

cExit(cint(main()))
