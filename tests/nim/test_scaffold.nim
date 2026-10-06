import ./cleanup_support
import std/[unittest, os, json, strutils, tempfiles, tables, strtabs]
import leaf/[project, package_files, process_io, build, scaffold_files, scaffold_types]
import leaf_cli

let base = createTempDir("leaf-scaffold-", "")
removeDirectoryOnExit(base)
let sourceRoot = currentSourcePath().parentDir.parentDir.parentDir / "src"

proc files(root: string): Table[string, string] =
  for path in walkDirRec(root):
    if fileExists(path): result[relativePath(path, root)] = readFile(path)

proc runChild(exe: string, args: seq[string], cwd: string): tuple[code: int, output: string] =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  env["LEAF_DATABASE_PATH"] = cwd / "target/testing.sqlite3"
  let child = startManaged(exe, args, cwd, env)
  defer: child.close()
  while not child.poll(): sleep(10)
  (child.code, child.output.diagnosticText())

suite "Application and resource scaffolding":
  test "default SQLite storage survives processes and applies newly generated migrations":
    let app = base / "persistent"
    require leaf_cli.main(@["g", "scaffold", app]) == 0
    writeFile(app / "tests/persistence.nim", """
import std/os
import leaf
import ../app/application
proc click(rt: Runtime, key: string) = doAssert rt.dispatch(key, Event(kind: click))
proc change(rt: Runtime, key, value: string) = doAssert rt.dispatch(key, Event(kind: change, value: value))
let rt = newRuntime(createApplication())
let title = "中文 '); DROP TABLE tasks; --"
case paramStr(1)
of "write":
  rt.change("task_draft", title)
  rt.click("task_add")
  doAssert rt.find("task_title_1").node.text == title
of "extend":
  doAssert rt.find("task_title_1").node.text == title
  rt.click("nav_notes")
  rt.click("notes_new")
  rt.change("notes_field_title", "persistent note")
  rt.click("notes_save")
  doAssert rt.find("notes_title_1").node.text == "persistent note"
of "read":
  doAssert rt.find("task_title_1").node.text == title
  rt.click("nav_notes")
  doAssert rt.find("notes_title_1").node.text == "persistent note"
else: doAssert false
""")
    let binary = app / "target/persistence".addFileExt(ExeExt)
    createDir(binary.parentDir)
    proc compileFixture(): bool =
      let compiled = runChild(compiler(), @["c", "--path:" & sourceRoot,
        "--nimcache:" & app / "target/cache", "--out:" & binary, app / "tests/persistence.nim"], app)
      checkpoint compiled.output
      compiled.code == 0
    require compileFixture()
    check runChild(binary, @["write"], app).code == 0
    check fileExists(app / "target/testing.sqlite3")
    require leaf_cli.main(@["g", "scaffold", "Note", "title:string", "--project", app]) == 0
    require compileFixture()
    for mode in ["extend", "read", "read"]:
      let ran = runChild(binary, @[mode], app)
      checkpoint ran.output
      check ran.code == 0
    let inspected = runChild(findExe("python3"), @["-c",
      "import sqlite3,sys; db=sqlite3.connect(sys.argv[1]); assert db.execute('select title from notes').fetchone()[0]=='persistent note'; assert db.execute('select count(*) from leaf_schema_migrations').fetchone()[0]==2",
      app / "target/testing.sqlite3"], app)
    checkpoint inspected.output
    check inspected.code == 0

  test "CLI generates a portable complete application and dry run writes nothing":
    let preview = base / "preview"
    require leaf_cli.main(@["g", "scaffold", preview, "--dry-run"]) == 0
    check not dirExists(preview)
    let app = base / "Application with spaces"
    require leaf_cli.main(@["generate", "scaffold", app]) == 0
    let project = readProject(app)
    check project.entryRelative == "main.nim"
    var included: seq[string]
    for item in collectFiles(project): included.add(item.relative)
    for path in ["app/pages/home/logic.nim", "app/pages/home/views/search.nim",
        "config/routes.nim", "db/migrations/001_create_tasks.up.sql"]:
      check path in included
    check "tests/test_home.nim" notin included
    check ".leaf/scaffold.json" notin included
    let before = files(app)
    check leaf_cli.main(@["g", "scaffold", app]) == 1
    check files(app) == before

  test "invalid arguments and fields leave applications unchanged":
    let app = base / "validation"
    require leaf_cli.main(@["g", "scaffold", app]) == 0
    let before = files(app)
    for fields in [@["title:string", "title:int"], @["id:int"], @["type:string"],
        @["title:date"], @["foo_bar:string", "foobar:bool"], @["9name:string"],
        @["value:float:extra"], @[]]:
      check leaf_cli.main(@["g", "scaffold", "Note"] & fields & @["--project", app]) == 1
      check files(app) == before
    for args in [@["g"], @["g", "scaffold"], @["g", "unknown", app],
        @["g", "scaffold", "new", "title:string"],
        @["g", "scaffold", "new", "--unknown"],
        @["g", "scaffold", "Note", "title:string", "--project"],
        @["g", "scaffold", "Note", "title:string", "--project", app, "--project", app]]:
      check leaf_cli.main(args) == 1
    for name in ["../escape", "proc", "9Thing", "Task", "LeafSchemaMigration"]:
      check leaf_cli.main(@["g", "scaffold", name, "title:string", "--project", app]) == 1
      check files(app) == before

  test "resource generation preserves user files and refuses conflicts":
    let app = base / "resources"
    require leaf_cli.main(@["g", "scaffold", app]) == 0
    writeFile(app / "config/routes.nim", readFile(app / "config/routes.nim") & "\n# user route comment\n")
    let customRoutes = readFile(app / "config/routes.nim")
    let before = files(app)
    require leaf_cli.main(@["g", "scaffold", "Note", "title:string", "archived:bool", "--project", app, "--dry-run"]) == 0
    check files(app) == before
    require leaf_cli.main(@["g", "scaffold", "Note", "title:string", "archived:bool", "--project", app]) == 0
    check readFile(app / "config/routes.nim") == customRoutes
    let after = files(app)
    check leaf_cli.main(@["g", "scaffold", "Note", "title:string", "--project", app]) == 1
    check files(app) == after
    writeFile(app / "app/generated/pages.nim", readFile(app / "app/generated/pages.nim") & "# custom edit\n")
    let edited = files(app)
    check leaf_cli.main(@["g", "scaffold", "Contact", "name:string", "--project", app]) == 1
    check files(app) == edited
    let minimal = base / "minimal"
    initProject(minimal)
    let minimalBefore = files(minimal)
    check leaf_cli.main(@["g", "scaffold", "Note", "title:string", "--project", minimal]) == 1
    check files(minimal) == minimalBefore

  test "damaged manifests route edits and unregistered files never get overwritten":
    let app = base / "damaged"
    require leaf_cli.main(@["g", "scaffold", app]) == 0
    let originalManifest = readFile(app / ".leaf/scaffold.json")
    for damaged in ["not json", "{\"schema\":2,\"resources\":[]}",
        "{\"schema\":1,\"resources\":{}}",
        "{\"schema\":1,\"resources\":[{\"model\":\"../Escape\",\"fields\":[],\"migration\":2}]}"]:
      writeFile(app / ".leaf/scaffold.json", damaged)
      let before = files(app)
      check leaf_cli.main(@["g", "scaffold", "Note", "title:string", "--project", app]) == 1
      check files(app) == before
    writeFile(app / ".leaf/scaffold.json", originalManifest)
    let originalRoutes = readFile(app / "config/generated/routes.nim")
    writeFile(app / "config/generated/routes.nim", originalRoutes & "# custom route\n")
    let edited = files(app)
    check leaf_cli.main(@["g", "scaffold", "Note", "title:string", "--project", app]) == 1
    check files(app) == edited
    writeFile(app / "config/generated/routes.nim", originalRoutes)
    writeFile(app / "app/models/note.nim", "# handwritten model\n")
    let unregistered = files(app)
    check leaf_cli.main(@["g", "scaffold", "Note", "title:string", "--project", app]) == 1
    check files(app) == unregistered

  test "ordinary write failure restores registration and removes only created files":
    let root = base / "rollback"
    createDir(root)
    writeFile(root / "registration.nim", "original")
    let before = files(root)
    let plan = @[
      ScaffoldFile(path: "new/first.nim", content: "new file"),
      ScaffoldFile(path: "registration.nim", content: "updated", update: true, previous: "original"),
      ScaffoldFile(path: "new/" & repeat('x', 300) & ".nim", content: "cannot be written")]
    expect IOError: writePlan(root, plan, false)
    check files(root) == before
    check not dirExists(root / "new")

  test "unwritable unchanged manifest does not prevent earlier writes from rolling back":
    let app = base / "readonly-manifest"
    require leaf_cli.main(@["g", "scaffold", app]) == 0
    let path = app / ".leaf/scaffold.json"
    let permissions = getFilePermissions(path)
    defer: setFilePermissions(path, permissions)
    setFilePermissions(path, {fpUserRead, fpGroupRead, fpOthersRead})
    let before = files(app)
    check leaf_cli.main(@["g", "scaffold", "Note", "title:string", "--project", app]) == 1
    check files(app) == before
    check not dirExists(app / "app/pages/notes")

  test "separated initials retain their identity across subsequent resource generation":
    let app = base / "initials"
    require leaf_cli.main(@["g", "scaffold", app]) == 0
    require leaf_cli.main(@["g", "scaffold", "A_B", "label:string", "--project", app]) == 0
    check leaf_cli.main(@["g", "scaffold", "Contact", "name:string", "--project", app]) == 0
    check "../pages/a_bs/page" in readFile(app / "app/generated/pages.nim")
    check "\"/a_bs\"" in readFile(app / "config/generated/routes.nim")
    let binary = app / "target/check".addFileExt(ExeExt)
    createDir(binary.parentDir)
    let compiled = runChild(compiler(), @["c", "--path:" & sourceRoot,
      "--nimcache:" & app / "target/cache", "--out:" & binary, app / "main.nim"], app)
    checkpoint compiled.output
    require compiled.code == 0
    check runChild(binary, @["--check"], app).code == 0

  when defined(posix):
    test "symbolic link ancestors cannot redirect a new application's writes":
      let real = base / "real"
      let alias = base / "alias"
      createDir(real)
      createSymlink(real, alias)
      check leaf_cli.main(@["g", "scaffold", alias / "redirected"]) == 1
      check not dirExists(real / "redirected")

  test "resource names matching library and page symbols remain independent":
    let app = base / "namespaces"
    require leaf_cli.main(@["g", "scaffold", app]) == 0
    for name in ["Node", "State", "PageDefinition", "Draft", "Panel", "System", "ValueError", "Database", "SqlValue", "Migration"]:
      require leaf_cli.main(@["g", "scaffold", name, "label:string", "--project", app]) == 0
    let binary = app / "target/check".addFileExt(ExeExt)
    createDir(binary.parentDir)
    let compiled = runChild(compiler(), @["c", "--path:" & sourceRoot,
      "--nimcache:" & app / "target/cache", "--out:" & binary, app / "main.nim"], app)
    checkpoint compiled.output
    require compiled.code == 0
    let checked = runChild(binary, @["--check"], app)
    checkpoint checked.output
    check checked.code == 0
    for name in ["databases", "sql_values", "migrations"]:
      let tested = runChild(compiler(), @["c", "-r", "--path:" & sourceRoot,
        "--nimcache:" & app / "target/test-cache", "--out:" & app / "target" / name,
        app / "tests" / ("test_" & name & ".nim")], app)
      checkpoint tested.output
      check tested.code == 0

  test "generated database configuration can be imported without opening storage":
    let app = base / "configuration"
    require leaf_cli.main(@["g", "scaffold", app]) == 0
    writeFile(app / "tests/configuration.nim", "import std/[os, strutils]\nimport ../config/database\ndelEnv(\"LEAF_DATABASE_PATH\")\ndoAssert databasePath().isAbsolute\ndoAssert databasePath().endsWith(\"application.sqlite3\")\nlet custom = getCurrentDir() / \"target/config.sqlite3\"\nputEnv(\"LEAF_DATABASE_PATH\", custom)\ndoAssert databasePath() == custom\ndoAssert not fileExists(custom)\n")
    let binary = app / "target/configuration".addFileExt(ExeExt)
    createDir(binary.parentDir)
    let compiled = runChild(compiler(), @["c", "-r", "--path:" & sourceRoot,
      "--nimcache:" & app / "target/cache", "--out:" & binary, app / "tests/configuration.nim"], app)
    checkpoint compiled.output
    check compiled.code == 0

  test "generated application and two resources compile and execute CRUD and navigation":
    let app = base / "integration"
    require leaf_cli.main(@["g", "scaffold", app]) == 0
    require leaf_cli.main(@["g", "scaffold", "Note", "title:string", "archived:bool", "--project", app]) == 0
    require leaf_cli.main(@["generate", "scaffold", "Metric", "count:int", "amount:float", "--project", app]) == 0
    writeFile(app / "tests/integration.nim", """
import leaf
import ../app/application
import ../config/database
proc click(rt: Runtime, key: string) = doAssert rt.dispatch(key, Event(kind: click))
proc change(rt: Runtime, key, value: string) = doAssert rt.dispatch(key, Event(kind: change, value: value))
proc toggle(rt: Runtime, key: string, checked: bool) = doAssert rt.dispatch(key, Event(kind: change, checked: checked))
let connection = openApplicationDatabase(":memory:")
let rt = newRuntime(createApplication(connection))
rt.change("task_draft", "  first task  ")
rt.click("task_add")
doAssert rt.find("task_title_1").node.text == "first task"
connection.executeScript("PRAGMA query_only = ON")
rt.change("task_draft", "keep failed draft")
rt.click("task_add")
doAssert rt.find("task_error").node.text.len > 0
doAssert rt.find("task_draft").node.text == "keep failed draft"
rt.toggle("task_done_1", true)
doAssert connection.query("SELECT done FROM tasks WHERE id = 1")[0][0].asInt == 0
rt.click("task_delete_1")
doAssert rt.find("task_title_1").node.text == "first task"
connection.executeScript("PRAGMA query_only = OFF")
rt.change("task_draft", "keep draft")
rt.click("nav_search")
rt.change("search_query", "missing")
doAssert rt.find("home_empty").node.text.len > 0
rt.click("nav_home")
doAssert rt.find("task_draft").node.text == "keep draft"
rt.toggle("task_done_1", true)
rt.click("nav_settings")
rt.toggle("hide_completed", true)
rt.click("nav_home")
doAssert rt.find("home_empty").node.text.len > 0
rt.click("nav_settings")
rt.toggle("hide_completed", false)
rt.click("nav_home")
doAssert rt.find("task_title_1").node.text == "first task"
rt.click("nav_notes")
rt.click("notes_new")
rt.change("notes_field_title", "First note")
rt.click("notes_save")
doAssert rt.find("notes_title_1").node.text == "First note"
rt.click("notes_show_1")
doAssert rt.find("notes_detail_title").node.text == "First note"
rt.click("notes_back")
rt.click("notes_edit_1")
rt.change("notes_field_title", "Discard this")
rt.click("notes_cancel")
doAssert rt.find("notes_title_1").node.text == "First note"
rt.click("notes_edit_1")
rt.change("notes_field_title", "Updated note")
rt.click("notes_save")
connection.executeScript("PRAGMA query_only = ON")
rt.click("notes_delete_1")
doAssert rt.find("notes_error").node.text.len > 0
doAssert rt.find("notes_title_1").node.text == "Updated note"
connection.executeScript("PRAGMA query_only = OFF")
rt.click("nav_metrics")
rt.click("metrics_new")
rt.change("metrics_field_count", "bad integer")
rt.change("metrics_field_amount", "1.5")
rt.click("metrics_save")
doAssert rt.find("metrics_error").node.text.len > 0
doAssert rt.find("metrics_field_count").node.text == "bad integer"
rt.change("metrics_field_count", "42")
rt.change("metrics_field_amount", "NaN")
rt.click("metrics_save")
doAssert rt.find("metrics_error").node.text.len > 0
rt.change("metrics_field_amount", "1.5")
rt.click("metrics_save")
doAssert rt.find("metrics_count_1").node.text == "42"
rt.click("nav_notes")
doAssert rt.find("notes_title_1").node.text == "Updated note"
rt.click("notes_delete_1")
doAssert rt.find("notes_empty").node.text.len > 0
rt.click("nav_home")
doAssert rt.find("task_draft").node.text == "keep draft"
echo "generated application ready"
""")
    let binary = app / "target/integration".addFileExt(ExeExt)
    createDir(binary.parentDir)
    let compiled = runChild(compiler(), @["c", "--path:" & sourceRoot,
      "--nimcache:" & app / "target/cache", "--out:" & binary, app / "tests/integration.nim"], app)
    checkpoint compiled.output
    require compiled.code == 0
    let ran = runChild(binary, @[], app)
    checkpoint ran.output
    check ran.code == 0
    check "generated application ready" in ran.output
    for test in ["test_home.nim", "test_notes.nim", "test_metrics.nim"]:
      let tested = runChild(compiler(), @["c", "-r", "--path:" & sourceRoot,
        "--nimcache:" & app / "target/test-cache", "--out:" & app / "target" / test.changeFileExt(ExeExt),
        app / "tests" / test], app)
      checkpoint tested.output
      check tested.code == 0
    let sql = """
import pathlib, sqlite3, sys
root = pathlib.Path(sys.argv[1])
db = sqlite3.connect(':memory:')
for file in sorted((root / 'db/migrations').glob('*.up.sql')):
    db.executescript(file.read_text())
db.execute('INSERT INTO notes (title, archived) VALUES (?, ?)', ('note', 0))
try:
    db.execute('INSERT INTO notes (title, archived) VALUES (?, ?)', ('bad', 2))
except sqlite3.IntegrityError:
    pass
else:
    raise AssertionError('bool constraint missing')
db.execute('INSERT INTO metrics (count, amount) VALUES (?, ?)', (42, 1.5))
for file in sorted((root / 'db/migrations').glob('*.down.sql'), reverse=True):
    db.executescript(file.read_text())
assert not db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").fetchall()
"""
    let migrated = runChild(findExe("python3"), @["-c", sql, app], app)
    checkpoint migrated.output
    check migrated.code == 0
    discard collectFiles(readProject(app))

  when defined(posix):
    test "symlinked generation targets preserve external files":
      let app = base / "links"
      require leaf_cli.main(@["g", "scaffold", app]) == 0
      let outside = base / "outside"
      createDir(outside)
      writeFile(outside / "sentinel", "untouched")
      createSymlink(outside, app / "app/pages/notes")
      let before = files(app)
      check leaf_cli.main(@["g", "scaffold", "Note", "title:string", "--project", app]) == 1
      check files(app) == before
      check readFile(outside / "sentinel") == "untouched"
      let alias = base / "app-alias"
      createSymlink(outside, alias)
      check leaf_cli.main(@["g", "scaffold", alias]) == 1
      check readFile(outside / "sentinel") == "untouched"
