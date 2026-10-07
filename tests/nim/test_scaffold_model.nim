import ./cleanup_support
import std/[unittest, os, tempfiles, json, strutils, strtabs]
import leaf/[scaffold, sqlite, model, build, process_io]

let base = createTempDir("leaf-model-scaffold-", "")
removeDirectoryOnExit(base)
let fixture = currentSourcePath().parentDir.parentDir / "fixtures/scaffold_v1"

type LegacyTask = ref object of TimestampedRecord
  title: string
  done: bool
defineModel(LegacyTask, table = "tasks")

suite "model scaffold versions":
  test "new applications use model declarations and no CRUD services":
    let app = base / "modern"
    discard generateScaffold(ScaffoldOptions(target: app))
    let manifest = parseFile(app / ".leaf/scaffold.json")
    check manifest["schema"].getInt == 2
    check manifest["model_api"].getInt == 1
    check manifest["timestamps"].getBool
    check not fileExists(app / "app/services/task_service.nim")
    check "defineAbstractModel" in readFile(app / "app/models/application_record.nim")
    check "defineModel" in readFile(app / "app/models/task.nim")
    check "executionScope" in readFile(app / "app/application.nim")
    discard generateScaffold(ScaffoldOptions(target: "Note", project: app, fields: @["title:string"]))
    check not fileExists(app / "app/services/note_service.nim")
    check "REAL NOT NULL" in readFile(app / "db/migrations/002_create_notes.up.sql")
    check "editingId, selectedId: int64" in readFile(app / "app/pages/notes/logic.nim")
    check "generatedPages*()" in readFile(app / "app/generated/pages.nim")

  test "frozen schema 1 application keeps original files and legacy resource API":
    let app = base / "legacy"
    copyDir(fixture, app)
    let oldMigration = readFile(app / "db/migrations/001_create_tasks.up.sql")
    let oldModel = readFile(app / "app/models/task.nim")
    discard generateScaffold(ScaffoldOptions(target: "Note", project: app, fields: @["title:string"]))
    check parseFile(app / ".leaf/scaffold.json")["schema"].getInt == 1
    check readFile(app / "db/migrations/001_create_tasks.up.sql") == oldMigration
    check readFile(app / "app/models/task.nim") == oldModel
    check fileExists(app / "app/services/note_service.nim")
    check "id*: int" in readFile(app / "app/models/note.nim")
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = app / "target/test.sqlite3"
    let source = currentSourcePath().parentDir.parentDir.parentDir / "src"
    let binary = app / "target/check".addFileExt(ExeExt)
    createDir(binary.parentDir)
    let child = startManaged(compiler(), @["c", "--path:" & source,
      "--nimcache:" & app / "target/cache", "--out:" & binary, app / "main.nim"], app, env)
    while not child.poll(): sleep(10)
    checkpoint child.output.diagnosticText()
    require child.code == 0
    child.close()
    let ran = startManaged(binary, @["--headless", "--change", "task_draft", "legacy task", "--click", "task_add"], app, env)
    while not ran.poll(): sleep(10)
    checkpoint ran.output.diagnosticText()
    check ran.code == 0
    ran.close()
    let db = openDatabase(env["LEAF_DATABASE_PATH"])
    check db.query("SELECT title FROM tasks")[0][0].asString == "legacy task"
    db.close()

  test "timestamps for old data are a new migration, not a rewritten create":
    let db = openDatabase(":memory:")
    defer: db.close()
    let original = readFile(fixture / "db/migrations/001_create_tasks.up.sql")
    db.migrate([Migration(version: 1, name: "create_tasks", sql: original)])
    discard db.execute("INSERT INTO tasks(title,done) VALUES (?,?)", [dbValue("old"), dbValue(false)])
    db.migrate([Migration(version: 1, name: "create_tasks", sql: original), Migration(version: 2, name: "task_timestamps", sql: """
      ALTER TABLE tasks ADD COLUMN created_at REAL;
      ALTER TABLE tasks ADD COLUMN updated_at REAL;
      UPDATE tasks SET created_at = CAST(strftime('%s','now') AS REAL), updated_at = CAST(strftime('%s','now') AS REAL);
    """)])
    withDatabase(db):
      let task = LegacyTask.find(1'i64)
      check task.title == "old"
      check task.created_at.isSome
      check task.updated_at.isSome

  test "unsupported schema and model metadata fail before writing":
    let app = base / "metadata"
    discard generateScaffold(ScaffoldOptions(target: app))
    let path = app / ".leaf/scaffold.json"
    for invalid in ["{\"schema\":3,\"resources\":[]}",
      "{\"schema\":2,\"resources\":[],\"timestamps\":true}",
      "{\"schema\":2,\"resources\":[],\"model_api\":1}",
      "{\"schema\":2,\"resources\":[],\"model_api\":2,\"timestamps\":true}"]:
      writeFile(path, invalid)
      expect CatchableError:
        discard generateScaffold(ScaffoldOptions(target: "Note", project: app, fields: @["title:string"]))
      check not fileExists(app / "app/models/note.nim")

  test "generated resource editor completes committed writes even when notifications fail":
    let app = base / "notifications"
    discard generateScaffold(ScaffoldOptions(target: app))
    discard generateScaffold(ScaffoldOptions(target: "Note", project: app, fields: @["title:string"]))
    let modelPath = app / "app/models/note.nim"
    var declaration = readFile(modelPath)
    declaration = declaration.replace("defineModel(Note,", "proc notify(record: Note, event: ModelEvent) =\n  raise newException(ValueError, \"notification unavailable\")\n\ndefineModel(Note,")
    declaration = declaration.replace("  beforeValidation normalize", "  beforeValidation normalize\n  afterCommit notify")
    writeFile(modelPath, declaration)
    let testPath = app / "tests/notifications.nim"
    writeFile(testPath, """
import std/strutils
import leaf
import ../app/application
import ../config/database
let db = openApplicationDatabase(":memory:")
let rt = newRuntime(createApplication(db))
proc click(key: string) = doAssert rt.dispatch(key, Event(kind: click))
proc change(key, value: string) = doAssert rt.dispatch(key, Event(kind: change, value: value))
click("nav_notes")
click("notes_new")
change("notes_field_title", "Committed note")
click("notes_save")
doAssert db.query("SELECT COUNT(*) FROM notes")[0][0].asInt64 == 1'i64
doAssert rt.find("notes_title_1").node.text == "Committed note"
doAssert "committed" in rt.find("notes_error").node.text
click("notes_edit_1")
change("notes_field_title", "Committed update")
click("notes_save")
doAssert rt.find("notes_title_1").node.text == "Committed update"
doAssert db.query("SELECT COUNT(*) FROM notes")[0][0].asInt64 == 1'i64
click("notes_delete_1")
doAssert db.query("SELECT COUNT(*) FROM notes")[0][0].asInt64 == 0'i64
doAssert rt.find("notes_empty").node.text.len > 0
doAssert "committed" in rt.find("notes_error").node.text
db.close()
""")
    let binary = app / "target/notifications".addFileExt(ExeExt)
    createDir(binary.parentDir)
    let source = currentSourcePath().parentDir.parentDir.parentDir / "src"
    let child = startManaged(compiler(), @["c", "-r", "--path:" & source,
      "--nimcache:" & app / "target/cache", "--out:" & binary, testPath], app)
    while not child.poll(): sleep(10)
    checkpoint child.output.diagnosticText()
    check child.code == 0
    child.close()
