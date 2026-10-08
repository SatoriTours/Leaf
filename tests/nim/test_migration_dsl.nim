import std/[unittest, os, options, strutils]
import leaf/[core, sqlite]
import leaf/migrations
import ./migration_compile_support

include "../fixtures/migrations/001_create_tasks.nim"

suite "declarative migration DSL":
  test "bare field tokens compile without variables":
    let definition = migrationDefinition
    check definition.version == 1'i64
    check definition.name == "create_tasks"
    check definition.format == mfNimV1
    check not definition.pending
    check definition.hasDown
    check definition.upOps.len == 2
    check definition.upOps[0].kind == moCreateTable
    let table = definition.upOps[0].tableSpec
    check table.name == "tasks"
    check table.hasId
    check not table.autoIncrement
    check table.columns.len == 4
    check table.columns[0].name == "title"
    check table.columns[0].kind == ckText
    check not table.columns[0].nullable
    check table.columns[0].defaultValue.isNone
    check table.columns[1].name == "done"
    check table.columns[1].kind == ckBoolean
    check table.columns[1].nullable
    check table.columns[1].defaultValue.get() == dbValue(false)
    check table.columns[2].name == "created_at"
    check table.columns[2].kind == ckDateTime
    check not table.columns[2].nullable
    check table.columns[2].defaultValue.isNone
    check table.columns[3].name == "updated_at"
    check table.columns[3].kind == ckDateTime
    check definition.upOps[1].kind == moAddIndex
    check definition.upOps[1].indexSpec.table == "tasks"
    check definition.upOps[1].indexSpec.name == "index_tasks_on_title"
    check definition.upOps[1].indexSpec.columns == @["title"]
    check not definition.upOps[1].indexSpec.unique
    check definition.downOps.len == 2
    check definition.downOps[0].kind == moRemoveIndex
    check definition.downOps[0].indexSpec.name == "index_tasks_on_title"
    check definition.downOps[1].kind == moDropTable
    check definition.downOps[1].tableSpec.columns.len == 4

  test "source checksum hashes the migration file bytes":
    let fixture = currentSourcePath().parentDir / ".." / "fixtures" /
      "migrations" / "001_create_tasks.nim"
    check migrationDefinition.sourcePath.endsWith("001_create_tasks.nim")
    check migrationDefinition.sourceChecksum.len == 64
    check migrationDefinition.sourceChecksum == sha256Text(readFile(fixture))

  test "migration identity parses versions and snake_case names":
    check parseMigrationIdentity("001_create_tasks.nim").version == 1'i64
    check parseMigrationIdentity("001_create_tasks.nim").name == "create_tasks"
    check parseMigrationIdentity("/tmp/db/20261008120000123_add_priority.nim").version ==
      20261008120000123'i64
    check parseMigrationIdentity("/tmp/db/20261008120000123_add_priority.nim").name ==
      "add_priority"
    check parseMigrationIdentity("007_notes.up.sql").version == 7'i64
    check parseMigrationIdentity("007_notes.up.sql").name == "notes"
    expect UiError: discard parseMigrationIdentity("create_tasks.nim")
    expect UiError: discard parseMigrationIdentity("000_create_tasks.nim")
    expect UiError: discard parseMigrationIdentity("001_CreateTasks.nim")
    expect UiError: discard parseMigrationIdentity("001_create__tasks.nim")
    expect UiError: discard parseMigrationIdentity("001_create_tasks.txt")
    expect UiError: discard parseMigrationIdentity("99999999999999999999_overflow.nim")

  test "sha256Text matches standard SHA-256 vectors":
    check sha256Text("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Text("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Text("中文") ==
      "72726d8818f693066ceb69afa364218b692e62ea92b385782363780f47529c21"

  test "fingerprints are deterministic and ignore diagnostic source paths":
    let original = migrationDefinition
    var relocated = original
    relocated.sourcePath = "/relocated/sdk/db/migrations/001_create_tasks.nim"
    relocated.sourceChecksum = "0".repeat(64)
    check operationsFingerprint(relocated) == operationsFingerprint(original)
    check downFingerprint(relocated) == downFingerprint(original)
    check operationsFingerprint(original).len == 64
    check downFingerprint(original).len == 64
    var changedUp = original
    changedUp.upOps[1].indexSpec.columns = @["done"]
    check operationsFingerprint(changedUp) != operationsFingerprint(original)
    var changedDown = original
    changedDown.downOps[0] = SchemaOperation(kind: moRemoveIndex,
      indexSpec: IndexSpec(table: "tasks", name: "index_other",
        columns: @["title"], unique: false))
    check downFingerprint(changedDown) != downFingerprint(original)
    check operationsFingerprint(changedDown) != operationsFingerprint(original)
    var absent = original
    absent.upOps[0].tableSpec.columns[0].defaultValue = none(SqlValue)
    var explicitNull = original
    explicitNull.upOps[0].tableSpec.columns[0].defaultValue =
      some(SqlValue(kind: sqlNull))
    check operationsFingerprint(absent) != operationsFingerprint(explicitNull)

  test "SQL-format fingerprints cover raw legacy up and down bytes":
    let original = MigrationDefinition(version: 1'i64, name: "001_legacy",
      format: mfSqlV1, hasDown: true,
      legacyUp: "CREATE TABLE x (id INTEGER)", legacyDown: "DROP TABLE x")
    check operationsFingerprint(original).len == 64
    check downFingerprint(original).len == 64
    var changedDown = original
    changedDown.legacyDown = "DELETE FROM x"
    check downFingerprint(changedDown) != downFingerprint(original)
    check operationsFingerprint(changedDown) != operationsFingerprint(original)
    var changedUp = original
    changedUp.legacyUp = "CREATE TABLE y (id INTEGER)"
    check operationsFingerprint(changedUp) != operationsFingerprint(original)
    check downFingerprint(changedUp) == downFingerprint(original)
    var upOnly = original
    upOnly.hasDown = false
    upOnly.legacyDown = ""
    check downFingerprint(upOnly) == ""

  test "invertOperations reverses order and swaps directions":
    let operations = @[
      SchemaOperation(kind: moCreateTable,
        tableSpec: TableSpec(name: "tasks", columns: @[], hasId: true),
        tableDefinitionProvided: true),
      SchemaOperation(kind: moAddColumn, tableName: "tasks",
        columnSpec: ColumnSpec(name: "priority", kind: ckInteger,
          nullable: false, defaultValue: some(SqlValue(kind: sqlInteger, integer: 0))),
        columnDefinitionProvided: true)]
    let inverted = invertOperations(operations)
    check inverted.len == 2
    check inverted[0].kind == moRemoveColumn
    check inverted[0].columnSpec.name == "priority"
    check inverted[0].columnSpec.defaultValue.get() == dbValue(0)
    check inverted[0].columnDefinitionProvided
    check inverted[1].kind == moDropTable
    check inverted[1].tableSpec.hasId
    let restored = invertOperations(inverted)
    check restored.len == 2
    check restored[0].kind == moCreateTable
    check restored[1].kind == moAddColumn
    expect MigrationError:
      discard invertOperations(@[SchemaOperation(kind: moDropTable,
        tableSpec: TableSpec(name: "tasks"), tableDefinitionProvided: false)])
    expect MigrationError:
      discard invertOperations(@[SchemaOperation(kind: moRemoveColumn,
        tableName: "tasks", columnSpec: ColumnSpec(name: "x", kind: ckText),
        columnDefinitionProvided: false)])

  test "renderStatements emits SQLite DDL for the fixture":
    check renderStatements(migrationDefinition.upOps) == @[
      "CREATE TABLE \"tasks\" (\"id\" INTEGER PRIMARY KEY, \"title\" TEXT NOT NULL, " &
        "\"done\" INTEGER DEFAULT 0 CHECK (\"done\" IN (0, 1)), " &
        "\"created_at\" REAL NOT NULL, \"updated_at\" REAL NOT NULL)",
      "CREATE INDEX \"index_tasks_on_title\" ON \"tasks\" (\"title\")"]
    check renderStatements(migrationDefinition.downOps) == @[
      "DROP INDEX \"index_tasks_on_title\"",
      "DROP TABLE \"tasks\""]

  test "generated DDL executes and the inverse restores the schema":
    let db = openDatabase(":memory:")
    defer: db.close()
    for statement in renderStatements(migrationDefinition.upOps):
      db.executeScript(statement)
    let columns = db.query("PRAGMA table_info(tasks)")
    check columns.len == 5
    check columns[0][1].asString == "id"
    check columns[1][1].asString == "title"
    check columns[1][2].asString == "TEXT"
    check columns[1][3].asInt == 1
    check columns[1][4].kind == sqlNull
    check columns[2][1].asString == "done"
    check columns[2][2].asString == "INTEGER"
    check columns[2][4].asString == "0"
    check columns[3][1].asString == "created_at"
    check columns[3][2].asString == "REAL"
    check columns[4][1].asString == "updated_at"
    check db.query("SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
      @[dbValue("index_tasks_on_title")]).len == 1
    expect ConstraintError:
      discard db.execute(
        "INSERT INTO tasks (title, done, created_at, updated_at) VALUES (?, ?, ?, ?)",
        @[dbValue("a"), dbValue(5), dbValue(0.0), dbValue(0.0)])
    for statement in renderStatements(migrationDefinition.downOps):
      db.executeScript(statement)
    check db.query("SELECT name FROM sqlite_master WHERE name IN (?, ?)",
      @[dbValue("tasks"), dbValue("index_tasks_on_title")]).len == 0

  test "backend capabilities gate renameColumn and removeColumn":
    let rename = SchemaOperation(kind: moRenameColumn, columnTableName: "tasks",
      oldColumnName: "title", newColumnName: "name")
    let remove = SchemaOperation(kind: moRemoveColumn, tableName: "tasks",
      columnSpec: ColumnSpec(name: "priority", kind: ckInteger, nullable: true,
        defaultValue: none(SqlValue)), columnDefinitionProvided: true)
    let add = SchemaOperation(kind: moAddColumn, tableName: "tasks",
      columnSpec: ColumnSpec(name: "priority", kind: ckInteger, nullable: true,
        defaultValue: none(SqlValue)), columnDefinitionProvided: true)
    checkCapabilities(@[add], (3, 24, 0))
    checkCapabilities(@[rename], (3, 25, 0))
    checkCapabilities(@[remove], (3, 35, 0))
    checkCapabilities(@[add, remove], (3, 35, 0))
    expect MigrationError: checkCapabilities(@[rename], (3, 24, 0))
    expect MigrationError: checkCapabilities(@[remove], (3, 34, 0))
    expect MigrationError: checkCapabilities(@[add, remove], (3, 34, 0))
    try:
      checkCapabilities(@[rename], (3, 24, 0))
      check false
    except MigrationError as error:
      check error.issueCode == "unsupported_sqlite"
      check "renameColumn" in error.msg
      check "3.25" in error.msg

  test "adapter rejects structurally impossible tables":
    expect MigrationError:
      discard renderStatements(@[SchemaOperation(kind: moCreateTable,
        tableSpec: TableSpec(name: "samples", hasId: false),
        tableDefinitionProvided: true)])
    check renderStatements(@[SchemaOperation(kind: moCreateTable,
      tableSpec: TableSpec(name: "samples", hasId: true),
      tableDefinitionProvided: true)]) ==
      @["CREATE TABLE \"samples\" (\"id\" INTEGER PRIMARY KEY)"]

  test "every first version operation compiles":
    let probe = compileProbe(@[
      ("db/migrations/023_schema_ops.nim", """
import leaf/migrations

migration schema_ops:
  change:
    createTable tasks:
      string title, nullable = false
      boolean done, default = false
      timestamps()
    addIndex tasks, [title]
    addColumn tasks, priority, integer, default = 0
    renameColumn tasks, title, name
    renameTable tasks, archived_tasks
    addTimestamps archived_tasks, nullable = true
    removeColumn archived_tasks, priority, integer, default = 0
    removeIndex archived_tasks, [title], name = index_tasks_on_title
    dropTable archived_tasks, autoIncrement = true:
      string name, nullable = false
      timestamps()
"""),
      ("main.nim", """
import std/os
doAssert not fileExists("application.sqlite3")
include "db/migrations/023_schema_ops.nim"
doAssert not fileExists("application.sqlite3")
doAssert migrationDefinition.upOps.len == 10
doAssert migrationDefinition.downOps.len == 10
doAssert migrationDefinition.upOps[0].kind == moCreateTable
doAssert migrationDefinition.upOps[5].kind == moAddColumn
doAssert migrationDefinition.upOps[5].columnSpec.name == "created_at"
doAssert migrationDefinition.downOps[0].kind == moCreateTable
doAssert migrationDefinition.downOps[0].tableSpec.autoIncrement
doAssert migrationDefinition.downOps[^1].kind == moDropTable
doAssert renderStatements(migrationDefinition.upOps).len == 10
doAssert renderStatements(migrationDefinition.downOps).len == 10
echo "ok"
""")], "main.nim", run = true)
    check probe.code == 0
    check "ok" in probe.output

  test "declared operations run against real in-memory SQLite":
    let probe = compileProbe(@[
      ("db/migrations/024_apply_ops.nim", """
import leaf/migrations

migration apply_ops:
  change:
    createTable tasks:
      string title, nullable = false
      boolean done, default = false
      timestamps()
    addIndex tasks, [title]
    addColumn tasks, priority, integer, default = 0
    renameColumn tasks, priority, rank
    removeColumn tasks, rank, integer, default = 0
"""),
      ("main.nim", """
import leaf/sqlite
include "db/migrations/024_apply_ops.nim"
let db = openDatabase(":memory:")
for statement in renderStatements(migrationDefinition.upOps):
  db.executeScript(statement)
doAssert db.query("PRAGMA table_info(tasks)").len == 5
doAssert db.query("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'index_tasks_on_title'").len == 1
discard db.execute("INSERT INTO tasks (title, done, created_at, updated_at) VALUES (?, ?, ?, ?)",
  @[dbValue("first"), dbValue(true), dbValue(0.0), dbValue(0.0)])
for statement in renderStatements(migrationDefinition.downOps):
  db.executeScript(statement)
doAssert db.query("SELECT name FROM sqlite_master WHERE name IN ('tasks', 'index_tasks_on_title')").len == 0
echo "ok"
db.close()
""")], "main.nim", run = true)
    check probe.code == 0
    check "ok" in probe.output

  test "explicit up and down keep the declared directions":
    let probe = compileProbe(@[
      ("db/migrations/021_explicit_index.nim", """
import leaf/migrations

migration explicit_index:
  up:
    removeIndex tasks, [title], name = index_tasks_on_title
    addIndex tasks, [title, done], name = index_tasks_on_title_and_done
  down:
    removeIndex tasks, [title, done], name = index_tasks_on_title_and_done
    addIndex tasks, [title], name = index_tasks_on_title
    removeColumn tasks, priority
"""),
      ("main.nim", """
include "db/migrations/021_explicit_index.nim"
doAssert migrationDefinition.hasDown
doAssert migrationDefinition.upOps.len == 2
doAssert migrationDefinition.downOps.len == 3
doAssert migrationDefinition.upOps[0].kind == moRemoveIndex
doAssert migrationDefinition.upOps[1].indexSpec.name == "index_tasks_on_title_and_done"
doAssert migrationDefinition.downOps[0].kind == moRemoveIndex
doAssert migrationDefinition.downOps[1].indexSpec.name == "index_tasks_on_title"
doAssert migrationDefinition.downOps[2].kind == moRemoveColumn
doAssert not migrationDefinition.downOps[2].columnDefinitionProvided
echo "ok"
""")], "main.nim", run = true)
    check probe.code == 0
    check "ok" in probe.output

  test "pending template compiles without applying anything":
    let probe = compileProbe(@[
      ("db/migrations/022_pending.nim", """
import leaf/migrations

migration pending:
  change:
    pending()
"""),
      ("main.nim", """
include "db/migrations/022_pending.nim"
doAssert migrationDefinition.pending
doAssert not migrationDefinition.hasDown
doAssert migrationDefinition.upOps.len == 0
doAssert migrationDefinition.downOps.len == 0
doAssert downFingerprint(migrationDefinition) == ""
checkCapabilities(migrationDefinition.upOps, (3, 24, 0))
echo "ok"
""")], "main.nim", run = true)
    check probe.code == 0
    check "ok" in probe.output

  test "index names default deterministically and autoIncrement is preserved":
    let probe = compileProbe(@[
      ("db/migrations/025_index_names.nim", """
import leaf/migrations

migration index_names:
  change:
    createTable tasks, autoIncrement = true:
      string title
      text body, nullable = true
    addIndex tasks, [title, done]
    addIndex tasks, [title], unique = true
"""),
      ("main.nim", """
include "db/migrations/025_index_names.nim"
doAssert migrationDefinition.upOps[0].tableSpec.hasId
doAssert migrationDefinition.upOps[0].tableSpec.autoIncrement
doAssert migrationDefinition.upOps[1].indexSpec.name == "index_tasks_on_title_and_done"
doAssert not migrationDefinition.upOps[1].indexSpec.unique
doAssert migrationDefinition.upOps[2].indexSpec.name == "index_tasks_on_title"
doAssert migrationDefinition.upOps[2].indexSpec.unique
doAssert renderStatements(migrationDefinition.upOps)[0] ==
  "CREATE TABLE \"tasks\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"title\" TEXT, \"body\" TEXT)"
doAssert renderStatements(migrationDefinition.upOps)[2] ==
  "CREATE UNIQUE INDEX \"index_tasks_on_title\" ON \"tasks\" (\"title\")"
echo "ok"
""")], "main.nim", run = true)
    check probe.code == 0
    check "ok" in probe.output

  test "literal defaults keep their type and spelling":
    let probe = compileProbe(@[
      ("db/migrations/020_literal_defaults.nim", """
import leaf/migrations

migration literal_defaults:
  change:
    createTable samples:
      integer count, default = -7
      float amount, default = 1.5
      string label, default = "中文 'quoted'"
      boolean flag, default = true
      datetime at, default = 0
      string note, default = nil
"""),
      ("main.nim", """
import std/strutils
import leaf/sqlite
include "db/migrations/020_literal_defaults.nim"
let columns = migrationDefinition.upOps[0].tableSpec.columns
doAssert columns[0].defaultValue.get() == SqlValue(kind: sqlInteger, integer: -7)
doAssert columns[1].defaultValue.get() == SqlValue(kind: sqlFloat, number: 1.5)
doAssert columns[2].defaultValue.get() == SqlValue(kind: sqlText, text: "中文 'quoted'")
doAssert columns[3].defaultValue.get() == SqlValue(kind: sqlInteger, integer: 1)
doAssert columns[4].defaultValue.get() == SqlValue(kind: sqlFloat, number: 0.0)
doAssert columns[5].defaultValue.get() == SqlValue(kind: sqlNull)
let sql = renderStatements(migrationDefinition.upOps)[0]
doAssert "DEFAULT -7" in sql
doAssert "DEFAULT 1.5" in sql
doAssert "DEFAULT '中文 ''quoted'''" in sql
doAssert "DEFAULT NULL" in sql
let db = openDatabase(":memory:")
db.executeScript(sql)
doAssert db.query("PRAGMA table_info(samples)").len == 7
echo "ok"
db.close()
""")], "main.nim", run = true)
    check probe.code == 0
    check "ok" in probe.output

  test "Unicode database names compile and execute":
    let probe = compileProbe(@[
      ("db/migrations/030_unicode_names.nim", """
import leaf/migrations

migration unicode_names:
  change:
    createTable 用户:
      string 名称, nullable = false
    addIndex 用户, [名称]
"""),
      ("main.nim", """
import leaf/sqlite
include "db/migrations/030_unicode_names.nim"
doAssert migrationDefinition.upOps[0].tableSpec.name == "用户"
doAssert migrationDefinition.upOps[0].tableSpec.columns[0].name == "名称"
doAssert migrationDefinition.upOps[1].indexSpec.name == "index_用户_on_名称"
let db = openDatabase(":memory:")
for statement in renderStatements(migrationDefinition.upOps):
  db.executeScript(statement)
doAssert db.query("SELECT count(*) FROM \"用户\"").len == 1
for statement in renderStatements(migrationDefinition.downOps):
  db.executeScript(statement)
doAssert db.query("SELECT name FROM sqlite_master WHERE name = '用户'").len == 0
echo "ok"
db.close()
""")], "main.nim", run = true)
    check probe.code == 0
    check "ok" in probe.output

  test "explicitly typed signed and finite float literals are accepted":
    let probe = compileProbe(@[
      ("db/migrations/031_typed_literals.nim", """
import leaf/migrations

migration typed_literals:
  change:
    createTable samples:
      integer low_value, default = -9223372036854775808'i64
      integer high_value, default = 9223372036854775807'i64
      integer typed, default = 7'i64
      integer spaced, default = - 7
      float f32, default = 1.5'f32
      float f64, default = 2.5'f64
      float huge, default = 1.0e300'f64
      datetime at, default = 3.0'f32
"""),
      ("main.nim", """
import std/strutils
include "db/migrations/031_typed_literals.nim"
let columns = migrationDefinition.upOps[0].tableSpec.columns
doAssert columns[0].defaultValue.get().integer == low(int64)
doAssert columns[1].defaultValue.get().integer == high(int64)
doAssert columns[2].defaultValue.get().integer == 7
doAssert columns[3].defaultValue.get().integer == -7
doAssert columns[4].defaultValue.get().number == 1.5
doAssert columns[5].defaultValue.get().number == 2.5
doAssert columns[6].defaultValue.get().number == 1.0e300
doAssert columns[7].defaultValue.get().number == 3.0
let sql = renderStatements(migrationDefinition.upOps)[0]
doAssert "DEFAULT -9223372036854775808" in sql
doAssert "DEFAULT 9223372036854775807" in sql
echo "ok"
""")], "main.nim", run = true)
    check probe.code == 0
    check "ok" in probe.output

  test "invalid declarations fail with located DSL errors":
    let cases = @[
      (file: "001_bad_string_name.nim", source: """
import leaf/migrations

migration "bad_string_name":
  change:
    createTable tasks:
      string title
""", expected: "migration name must be a bare identifier"),
      (file: "002_unknown_option.nim", source: """
import leaf/migrations

migration unknown_option:
  change:
    createTable tasks:
      string title, bogus = 1
""", expected: "unknown option: bogus"),
      (file: "003_duplicate_option.nim", source: """
import leaf/migrations

migration duplicate_option:
  change:
    createTable tasks:
      string title, nullable = false, nullable = true
""", expected: "duplicate option: nullable"),
      (file: "004_duplicate_column.nim", source: """
import leaf/migrations

migration duplicate_column:
  change:
    createTable tasks:
      string title
      string title
""", expected: "duplicate column: title"),
      (file: "005_invalid_default.nim", source: """
import leaf/migrations

migration invalid_default:
  change:
    createTable tasks:
      integer priority, default = "high"
""", expected: "invalid default for column: priority"),
      (file: "006_nil_default.nim", source: """
import leaf/migrations

migration nil_default:
  change:
    createTable tasks:
      string title, nullable = false, default = nil
""", expected: "cannot default to nil"),
      (file: "007_nul_default.nim", source: """
import leaf/migrations

migration nul_default:
  change:
    createTable tasks:
      string title, default = "a\0b"
""", expected: "NUL"),
      (file: "008_two_migrations.nim", source: """
import leaf/migrations

migration two_migrations:
  change:
    createTable tasks:
      string title

migration two_migrations:
  change:
    createTable notes:
      string body
""", expected: "redefinition"),
      (file: "009_bare_drop.nim", source: """
import leaf/migrations

migration bare_drop:
  change:
    dropTable tasks
""", expected: "dropTable in change requires the original table structure"),
      (file: "010_pending_mixed.nim", source: """
import leaf/migrations

migration pending_mixed:
  change:
    pending()
    createTable tasks:
      string title
""", expected: "pending() must be the only statement in change"),
      (file: "011_unknown_operation.nim", source: """
import leaf/migrations

migration unknown_operation:
  change:
    truncateTable tasks
""", expected: "unsupported operation: truncateTable"),
      (file: "012_change_and_up.nim", source: """
import leaf/migrations

migration change_and_up:
  change:
    createTable tasks:
      string title
  up:
    createTable notes:
      string body
""", expected: "change and up/down are mutually exclusive"),
      (file: "013_reserved_table.nim", source: """
import leaf/migrations

migration reserved_table:
  change:
    createTable leaf_schema_migrations:
      string title
""", expected: "reserved"),
      (file: "014_auto_increment_without_id.nim", source: """
import leaf/migrations

migration auto_increment_without_id:
  change:
    createTable tasks, id = false, autoIncrement = true:
      string title
""", expected: "autoIncrement requires the automatic id column"),
      (file: "015_missing_down.nim", source: """
import leaf/migrations

migration missing_down:
  up:
    createTable tasks:
      string title
""", expected: "up and down must both be provided"),
      (file: "016_bare_remove_column.nim", source: """
import leaf/migrations

migration bare_remove_column:
  change:
    removeColumn tasks, priority
""", expected: "removeColumn in change requires the original column type"),
      (file: "017_mismatched_name.nim", source: """
import leaf/migrations

migration other_name:
  change:
    createTable tasks:
      string title
""", expected: "does not match file name"),
      (file: "018_negative_text_default.nim", source: """
import leaf/migrations

migration negative_text_default:
  change:
    createTable samples:
      string label, default = -"abc"
""", expected: "invalid default for column: label"),
      (file: "019_section_arguments.nim", source: """
import leaf/migrations

migration section_arguments:
  change ignored:
    createTable samples:
      string label
""", expected: "take only an indented block"),
      (file: "027_section_arguments_up.nim", source: """
import leaf/migrations

migration section_arguments_up:
  up ignored:
    createTable tasks:
      string title
  down:
    dropTable tasks:
      string title
""", expected: "take only an indented block"),
      (file: "028_empty_id_less_table.nim", source: """
import leaf/migrations

migration empty_id_less_table:
  change:
    createTable samples, id = false
""", expected: "must declare at least one column when id = false"),
      (file: "029_out_of_range_int.nim", source: """
import leaf/migrations

migration out_of_range_int:
  change:
    createTable samples:
      integer count, default = 9223372036854775808
""", expected: "number out of range"),
      (file: "032_infinite_float.nim", source: """
import leaf/migrations

migration infinite_float:
  change:
    createTable samples:
      float amount, default = 1e400
""", expected: "invalid default for column: amount")]
    for item in cases:
      let probe = compileProbe(@[
        ("db/migrations/" & item.file, item.source),
        ("main.nim", "include \"db/migrations/" & item.file & "\"\n")], "main.nim")
      check probe.code != 0
      check item.expected in probe.output
      check item.file in probe.output
