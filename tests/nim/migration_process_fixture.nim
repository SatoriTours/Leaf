## Test-only child process fixture for migration runner and lock tests.
## Commands print one JSON object and exit with the result exit code.
import std/[json, os, strutils]
import leaf/sqlite
import leaf/migrations

proc cExit(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}

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
  else:
    stderr.writeLine("unknown command: " & command)
    result = 2

cExit(cint(main()))
