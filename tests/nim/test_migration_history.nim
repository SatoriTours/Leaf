import ./cleanup_support
import std/[options, os, sequtils, strutils, tempfiles, unittest]
import leaf/sqlite
import leaf/migrations

let base = createTempDir("leaf-migration-history-", "")
removeDirectoryOnExit(base)

proc tableColumns(db: Database, table: string): seq[string] =
  for row in db.query("PRAGMA table_info(" & table & ")"):
    result.add row[1].asString

proc createLegacyHistory(db: Database) =
  db.executeScript("""CREATE TABLE leaf_schema_migrations (
    version INTEGER PRIMARY KEY, name TEXT NOT NULL, sql TEXT NOT NULL);""")

proc createExtendedHistory(db: Database) =
  db.executeScript("""CREATE TABLE leaf_schema_migrations (
    version INTEGER PRIMARY KEY, name TEXT NOT NULL, sql TEXT NOT NULL,
    format TEXT NOT NULL DEFAULT 'sql-v1', source_sha256 TEXT,
    operations_sha256 TEXT, down_sha256 TEXT);""")

proc sqlDefinition(version: int64, basename, up, down: string): MigrationDefinition =
  MigrationDefinition(version: version, name: basename, sourcePath: basename & ".up.sql",
    sourceChecksum: "sql-source-" & basename, format: mfSqlV1,
    legacyUp: up, legacyDown: down, hasDown: down.len > 0)

proc createTableOp(table: string): SchemaOperation =
  SchemaOperation(kind: moCreateTable,
    tableSpec: TableSpec(name: table, hasId: true), tableDefinitionProvided: true)

proc dropTableOp(table: string): SchemaOperation =
  SchemaOperation(kind: moDropTable,
    tableSpec: TableSpec(name: table, hasId: true), tableDefinitionProvided: true)

proc nimDefinition(version: int64, name: string): MigrationDefinition =
  MigrationDefinition(version: version, name: name,
    sourcePath: "db/migrations/" & name & ".nim",
    sourceChecksum: "source-" & name, format: mfNimV1,
    upOps: @[createTableOp(name)], downOps: @[dropTableOp(name)], hasDown: true)

proc nimRecord(definition: MigrationDefinition): MigrationRecord =
  MigrationRecord(version: definition.version, name: definition.name,
    sql: forwardSql(definition), format: "nim-v1", sourceChecksum: definition.sourceChecksum,
    operationsChecksum: operationsFingerprint(definition),
    downChecksum: downFingerprint(definition))

const upSql = "CREATE TABLE tasks (id INTEGER PRIMARY KEY, title TEXT);\n"
const downSql = "DROP TABLE tasks;\n"

suite "migration history reads and legacy compatibility":
  test "legacy three-column history reads without upgrading":
    let db = openDatabase(":memory:")
    defer: db.close()
    createLegacyHistory(db)
    discard db.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?)",
      @[dbValue(1'i64), dbValue("001_create_tasks"), dbValue(upSql)])
    let history = readMigrationHistory(db)
    check history.len == 1
    check history[0].version == 1'i64
    check history[0].name == "001_create_tasks"
    check history[0].sql == upSql
    check history[0].format == "sql-v1"
    check history[0].sourceChecksum == ""
    check history[0].operationsChecksum == ""
    check history[0].downChecksum == ""
    check tableColumns(db, "leaf_schema_migrations") == @["version", "name", "sql"]

  test "inspect exposes legacy-unverified-down before the baseline":
    let db = openDatabase(":memory:")
    defer: db.close()
    createLegacyHistory(db)
    discard db.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?)",
      @[dbValue(1'i64), dbValue("001_create_tasks"), dbValue(upSql)])
    let catalog = @[sqlDefinition(1, "001_create_tasks", upSql, downSql)]
    let statuses = inspectMigrationHistory(catalog, readMigrationHistory(db))
    check statuses.len == 1
    check statuses[0].state == "legacy-unverified-down"
    check "legacy_unverified_down" in statuses[0].issues.mapIt(it.code)
    check statuses[0].issues[0].version == some(1'i64)

  test "upgrade adds metadata, preserves rows and is idempotent":
    let db = openDatabase(":memory:")
    defer: db.close()
    createLegacyHistory(db)
    discard db.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?)",
      @[dbValue(1'i64), dbValue("001_create_tasks"), dbValue(upSql)])
    let catalog = @[sqlDefinition(1, "001_create_tasks", upSql, downSql)]
    discard db.execute("BEGIN")
    upgradeMigrationHistory(db, catalog)
    discard db.execute("COMMIT")
    let upgraded = readMigrationHistory(db)
    check upgraded.len == 1
    check upgraded[0].name == "001_create_tasks"
    check upgraded[0].sql == upSql
    check upgraded[0].format == "sql-v1"
    check upgraded[0].sourceChecksum == catalog[0].sourceChecksum
    check upgraded[0].operationsChecksum == operationsFingerprint(catalog[0])
    check upgraded[0].downChecksum == downFingerprint(catalog[0])
    check tableColumns(db, "leaf_schema_migrations") ==
      @["version", "name", "sql", "format", "source_sha256", "operations_sha256", "down_sha256"]
    discard db.execute("BEGIN")
    upgradeMigrationHistory(db, catalog)
    discard db.execute("COMMIT")
    check readMigrationHistory(db).len == 1

  test "upgrade rolls back with the caller transaction":
    let db = openDatabase(":memory:")
    defer: db.close()
    createLegacyHistory(db)
    discard db.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?)",
      @[dbValue(1'i64), dbValue("001_create_tasks"), dbValue(upSql)])
    let catalog = @[sqlDefinition(1, "001_create_tasks", upSql, downSql)]
    discard db.execute("BEGIN")
    upgradeMigrationHistory(db, catalog)
    discard db.execute("ROLLBACK")
    check tableColumns(db, "leaf_schema_migrations") == @["version", "name", "sql"]
    let history = readMigrationHistory(db)
    check history.len == 1
    check history[0].sourceChecksum == ""
    check history[0].sql == upSql

  test "upgrade does not register unapplied migrations":
    let db = openDatabase(":memory:")
    defer: db.close()
    createLegacyHistory(db)
    discard db.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?)",
      @[dbValue(1'i64), dbValue("001_create_tasks"), dbValue(upSql)])
    let catalog = @[sqlDefinition(1, "001_create_tasks", upSql, downSql),
      sqlDefinition(2, "002_notes", "CREATE TABLE notes (id INTEGER);", "DROP TABLE notes;")]
    discard db.execute("BEGIN")
    upgradeMigrationHistory(db, catalog)
    discard db.execute("COMMIT")
    check readMigrationHistory(db).len == 1

  test "upgrade refuses modified, missing and unknown history":
    let db = openDatabase(":memory:")
    defer: db.close()
    createLegacyHistory(db)
    discard db.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?)",
      @[dbValue(1'i64), dbValue("001_create_tasks"), dbValue(upSql)])
    let catalog = @[sqlDefinition(1, "001_create_tasks", upSql, downSql)]
    discard db.execute("UPDATE leaf_schema_migrations SET sql = ? WHERE version = ?",
      @[dbValue("CREATE TABLE other (id INTEGER);"), dbValue(1'i64)])
    expect MigrationError: upgradeMigrationHistory(db, catalog)
    check tableColumns(db, "leaf_schema_migrations") == @["version", "name", "sql"]

    let missingDb = openDatabase(":memory:")
    defer: missingDb.close()
    createLegacyHistory(missingDb)
    discard missingDb.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?)",
      @[dbValue(9'i64), dbValue("009_absent"), dbValue("SELECT 1;")])
    expect MigrationError: upgradeMigrationHistory(missingDb, catalog)

    let unknownDb = openDatabase(":memory:")
    defer: unknownDb.close()
    createExtendedHistory(unknownDb)
    discard unknownDb.execute(
      "INSERT INTO leaf_schema_migrations VALUES (?, ?, ?, ?, NULL, NULL, NULL)",
      @[dbValue(1'i64), dbValue("001_create_tasks"), dbValue(upSql), dbValue("future-v9")])
    expect MigrationError: upgradeMigrationHistory(unknownDb, catalog)

  test "Nim history detects source, operations and down changes":
    let db = openDatabase(":memory:")
    defer: db.close()
    createExtendedHistory(db)
    let definition = nimDefinition(1, "one")
    let record = nimRecord(definition)
    discard db.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?, ?, ?, ?, ?)",
      @[dbValue(record.version), dbValue(record.name), dbValue(record.sql),
        dbValue(record.format), dbValue(record.sourceChecksum),
        dbValue(record.operationsChecksum), dbValue(record.downChecksum)])
    check inspectMigrationHistory(@[definition], readMigrationHistory(db))[0].state == "up"

    var changedSource = definition
    changedSource.sourceChecksum = "source-changed"
    check inspectMigrationHistory(@[changedSource], readMigrationHistory(db))[0].state == "modified"

    var changedDown = definition
    changedDown.downOps = @[dropTableOp("other")]
    check inspectMigrationHistory(@[changedDown], readMigrationHistory(db))[0].state == "modified"

    var changedUp = definition
    changedUp.upOps.add createTableOp("extra")
    check inspectMigrationHistory(@[changedUp], readMigrationHistory(db))[0].state == "modified"

  test "unknown format, missing file and corrupt schema are explicit":
    let db = openDatabase(":memory:")
    defer: db.close()
    createExtendedHistory(db)
    discard db.execute(
      "INSERT INTO leaf_schema_migrations VALUES (?, ?, ?, ?, NULL, NULL, NULL)",
      @[dbValue(1'i64), dbValue("001_create_tasks"), dbValue(upSql), dbValue("future-v9")])
    let catalog = @[sqlDefinition(1, "001_create_tasks", upSql, downSql)]
    check inspectMigrationHistory(catalog, readMigrationHistory(db))[0].state == "unknown-format"

    let missingDb = openDatabase(":memory:")
    defer: missingDb.close()
    createExtendedHistory(missingDb)
    discard missingDb.execute(
      "INSERT INTO leaf_schema_migrations VALUES (?, ?, ?, ?, NULL, NULL, NULL)",
      @[dbValue(9'i64), dbValue("009_absent"), dbValue("SELECT 1;"), dbValue("sql-v1")])
    let missingStatus = inspectMigrationHistory(catalog, readMigrationHistory(missingDb))
    let missingEntry = missingStatus.filterIt(it.version == 9'i64)
    check missingEntry.len == 1
    check missingEntry[0].state == "missing"

    let corruptDb = openDatabase(":memory:")
    defer: corruptDb.close()
    corruptDb.executeScript("CREATE TABLE leaf_schema_migrations (version INTEGER PRIMARY KEY, name TEXT);")
    expect MigrationError: discard readMigrationHistory(corruptDb)

    let viewDb = openDatabase(":memory:")
    defer: viewDb.close()
    viewDb.executeScript("CREATE VIEW leaf_schema_migrations AS SELECT 1 AS version;")
    expect MigrationError: discard readMigrationHistory(viewDb)

    let nullFormatDb = openDatabase(":memory:")
    defer: nullFormatDb.close()
    nullFormatDb.executeScript("""CREATE TABLE leaf_schema_migrations (
      version INTEGER PRIMARY KEY, name TEXT NOT NULL, sql TEXT NOT NULL,
      format TEXT, source_sha256 TEXT, operations_sha256 TEXT, down_sha256 TEXT);""")
    discard nullFormatDb.execute(
      "INSERT INTO leaf_schema_migrations VALUES (?, ?, ?, NULL, NULL, NULL, NULL)",
      @[dbValue(1'i64), dbValue("001_create_tasks"), dbValue(upSql)])
    expect MigrationError: discard readMigrationHistory(nullFormatDb)

    let badTypeDb = openDatabase(":memory:")
    defer: badTypeDb.close()
    badTypeDb.executeScript("CREATE TABLE leaf_schema_migrations (version, name TEXT, sql TEXT);")
    discard badTypeDb.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?)",
      @[dbValue("not-a-number"), dbValue("001_create_tasks"), dbValue(upSql)])
    expect MigrationError: discard readMigrationHistory(badTypeDb)

  test "inspect reports discovered and pending-template states":
    let db = openDatabase(":memory:")
    defer: db.close()
    createLegacyHistory(db)
    discard db.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?)",
      @[dbValue(1'i64), dbValue("001_create_tasks"), dbValue(upSql)])
    let pending = MigrationDefinition(version: 3, name: "three", sourcePath: "three.nim",
      format: mfNimV1, pending: true, hasDown: false)
    let catalog = @[sqlDefinition(1, "001_create_tasks", upSql, downSql),
      sqlDefinition(2, "002_notes", "CREATE TABLE notes (id INTEGER);", "DROP TABLE notes;"),
      pending]
    let statuses = inspectMigrationHistory(catalog, readMigrationHistory(db))
    check statuses.len == 3
    check statuses[0].state == "legacy-unverified-down"
    check statuses[1].state == "down"
    check statuses[2].state == "pending-template"
    check "pending_template" in statuses[2].issues.mapIt(it.code)

suite "read-only SQLite connections":
  test "absent database and parent are never created":
    let missing = base / "absent.sqlite3"
    expect DatabaseError: discard openDatabaseReadOnly(missing)
    check not fileExists(missing)
    let nested = base / "absent-parent" / "nested.sqlite3"
    expect DatabaseError: discard openDatabaseReadOnly(nested)
    check not dirExists(base / "absent-parent")

  test "read-only connections reject writes and preserve bytes and mtime":
    let path = base / "readonly.sqlite3"
    var writer = openDatabase(path)
    writer.executeScript("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);")
    discard writer.execute("INSERT INTO t (v) VALUES (?)", @[dbValue("one")])
    writer.close()
    let before = readFile(path)
    let mtime = getLastModificationTime(path)
    let db = openDatabaseReadOnly(path)
    check db.query("SELECT v FROM t")[0][0].asString == "one"
    expect DatabaseError: discard db.execute("INSERT INTO t (v) VALUES (?)", @[dbValue("two")])
    expect DatabaseError: db.executeScript("CREATE TABLE u (id INTEGER);")
    db.close()
    check readFile(path) == before
    check getLastModificationTime(path) == mtime

  test "read-only connections see committed uncheckpointed WAL data":
    let path = base / "wal.sqlite3"
    var writer = openDatabase(path)
    writer.executeScript("PRAGMA journal_mode = WAL;")
    writer.executeScript("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);")
    discard writer.execute("INSERT INTO t (v) VALUES (?)", @[dbValue("committed")])
    check fileExists(path & "-wal")
    check getFileSize(path & "-wal") > 0
    let reader = openDatabaseReadOnly(path)
    check reader.query("SELECT v FROM t")[0][0].asString == "committed"
    reader.close()
    writer.close()

  test "connection state helpers report version, file and autocommit":
    check sqliteRuntimeVersion().major >= 3
    let memory = openDatabase(":memory:")
    check memory.isAutocommit
    check memory.databaseFile == ""
    memory.executeScript("BEGIN")
    check not memory.isAutocommit
    discard memory.execute("ROLLBACK")
    check memory.isAutocommit
    memory.close()
    let path = base / "state.sqlite3"
    let file = openDatabase(path)
    check file.databaseFile.endsWith("state.sqlite3")
    file.close()
    expect DatabaseError: discard databaseFile(nil)
    expect DatabaseError: discard isAutocommit(nil)
    let closed = openDatabase(":memory:")
    closed.close()
    expect DatabaseError: discard databaseFile(closed)
    expect DatabaseError: discard isAutocommit(closed)

suite "migration history fix round 1":
  test "malformed shapes are refused before any upgrade":
    let noPk = openDatabase(":memory:")
    defer: noPk.close()
    noPk.executeScript("CREATE TABLE leaf_schema_migrations (version INTEGER, name TEXT, sql TEXT);")
    expect MigrationError: discard readMigrationHistory(noPk)
    expect MigrationError: upgradeMigrationHistory(noPk, @[])
    check tableColumns(noPk, "leaf_schema_migrations") == @["version", "name", "sql"]

    let wrongVersionType = openDatabase(":memory:")
    defer: wrongVersionType.close()
    wrongVersionType.executeScript(
      "CREATE TABLE leaf_schema_migrations (version TEXT PRIMARY KEY, name TEXT, sql TEXT);")
    expect MigrationError: discard readMigrationHistory(wrongVersionType)

    let wrongNameType = openDatabase(":memory:")
    defer: wrongNameType.close()
    wrongNameType.executeScript(
      "CREATE TABLE leaf_schema_migrations (version INTEGER PRIMARY KEY, name INTEGER, sql TEXT);")
    expect MigrationError: discard readMigrationHistory(wrongNameType)

    let partial = openDatabase(":memory:")
    defer: partial.close()
    partial.executeScript("""CREATE TABLE leaf_schema_migrations (
      version INTEGER PRIMARY KEY, name TEXT NOT NULL, sql TEXT NOT NULL,
      source_sha256 TEXT);""")
    expect MigrationError: discard readMigrationHistory(partial)
    expect MigrationError: upgradeMigrationHistory(partial, @[])
    check tableColumns(partial, "leaf_schema_migrations") ==
      @["version", "name", "sql", "source_sha256"]

    let extra = openDatabase(":memory:")
    defer: extra.close()
    extra.executeScript("""CREATE TABLE leaf_schema_migrations (
      version INTEGER PRIMARY KEY, name TEXT NOT NULL, sql TEXT NOT NULL, extra TEXT);""")
    expect MigrationError: discard readMigrationHistory(extra)

  test "history table names resolve case-insensitively from main":
    let db = openDatabase(":memory:")
    defer: db.close()
    db.executeScript("CREATE TABLE LEAF_SCHEMA_MIGRATIONS (version INTEGER PRIMARY KEY, name TEXT NOT NULL, sql TEXT NOT NULL);")
    discard db.execute("INSERT INTO LEAF_SCHEMA_MIGRATIONS VALUES (?, ?, ?)",
      @[dbValue(1'i64), dbValue("001_create_tasks"), dbValue(upSql)])
    let history = readMigrationHistory(db)
    check history.len == 1
    check history[0].name == "001_create_tasks"
    let catalog = @[sqlDefinition(1, "001_create_tasks", upSql, downSql)]
    discard db.execute("BEGIN")
    upgradeMigrationHistory(db, catalog)
    discard db.execute("COMMIT")
    check readMigrationHistory(db)[0].sourceChecksum == catalog[0].sourceChecksum
    # A TEMP object shadows unqualified SQL but must not hide the main history.
    db.executeScript("CREATE TEMP TABLE leaf_schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, sql TEXT NOT NULL);")
    discard db.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?)",
      @[dbValue(7'i64), dbValue("007_temp"), dbValue("SELECT 7;")])
    let mainHistory = readMigrationHistory(db)
    check mainHistory.len == 1
    check mainHistory[0].name == "001_create_tasks"

  test "status and issues keep the real source path and version":
    let db = openDatabase(":memory:")
    defer: db.close()
    createExtendedHistory(db)
    let definition = nimDefinition(1, "one")
    let record = nimRecord(definition)
    discard db.execute("INSERT INTO leaf_schema_migrations VALUES (?, ?, ?, ?, ?, ?, ?)",
      @[dbValue(record.version), dbValue(record.name), dbValue(record.sql),
        dbValue(record.format), dbValue(record.sourceChecksum),
        dbValue(record.operationsChecksum), dbValue(record.downChecksum)])
    let applied = inspectMigrationHistory(@[definition], readMigrationHistory(db))[0]
    check applied.state == "up"
    check applied.file == definition.sourcePath
    var changed = definition
    changed.sourceChecksum = "changed"
    let modified = inspectMigrationHistory(@[changed], readMigrationHistory(db))[0]
    check modified.state == "modified"
    check modified.file == changed.sourcePath
    check modified.issues[0].file == changed.sourcePath
    check modified.issues[0].version == some(1'i64)
    # A missing definition has no actual source path to fabricate.
    var absent = record
    absent.version = 9
    absent.name = "009_absent"
    let missingEntry = inspectMigrationHistory(@[definition], @[absent]).filterIt(
      it.version == 9'i64)
    check missingEntry.len == 1
    check missingEntry[0].state == "missing"
    check missingEntry[0].file == ""
    check missingEntry[0].issues[0].file == ""
