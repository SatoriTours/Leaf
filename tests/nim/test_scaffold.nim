import ./cleanup_support
import std/[unittest, os, json, monotimes, strutils, tempfiles, tables, strtabs, algorithm, times]
import leaf/[project, package_files, process_io, build, scaffold, scaffold_files, scaffold_types, sqlite]
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
  # A monotonic deadline keeps every compiler child bounded on every platform.
  let deadline = getMonoTime() + initDuration(seconds = 900)
  while not child.poll():
    if getMonoTime() > deadline: return (124, child.output.diagnosticText())
    sleep(10)
  (child.code, child.output.diagnosticText())

proc stamp(path: string): string =
  let value = getLastModificationTime(path)
  $value.toUnix & "." & $value.nanosecond

proc snapshotTree(root: string): Table[string, string] =
  # Directories are compared by presence only: Windows commits a directory's
  # timestamp lazily, so the parent of a file written just before the snapshot
  # may still report its previous stamp even though no further write happened.
  # Files keep their exact stamp and contents.
  result["."] = "dir"
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    let rel = relativePath(path, root)
    if dirExists(path):
      result[rel & "/"] = "dir"
    else:
      result[rel] = "file:" & stamp(path) & ":" & readFile(path)

proc runCliIn(root: string, args: seq[string]): int =
  createDir(root)
  let previous = getCurrentDir()
  setCurrentDir(root)
  try: return leaf_cli.main(args)
  finally: setCurrentDir(previous)

proc writeHeadlessRows(app: string) =
  # Native templates use lazy lists; this fixture supplies their small viewport.
  writeFile(app / "tests/headless_rows.nim", """
import leaf
proc realizeRows*(rt: Runtime) =
  var lists: seq[tuple[key: string, count: int]]
  proc collect(node: MountedNode) =
    if node.node.kind == virtualList:
      lists.add((node.node.key, node.node.listSource.len))
    for child in node.children: collect(child)
  collect(rt.snapshot.root)
  for list in lists:
    discard rt.materialize(list.key, 0, list.count)
proc dispatchFixture*(rt: Runtime, key: string, event: Event): bool =
  result = rt.dispatch(key, event)
  rt.realizeRows()
""")

suite "Application and resource scaffolding":
  when defined(macosx):
    test "macOS system directory aliases allow scaffolding":
      for alias in ["/tmp", "/var", "/etc"]:
        if symlinkExists(alias) and expandFilename(alias) == "/private" & alias:
          let root = alias / "leaf-scaffold-path-check"
          check guardedPath(root, "app/pages/home/logic.nim") == root / "app/pages/home/logic.nim"

  test "default SQLite storage survives processes and applies newly generated migrations":
    let app = base / "persistent"
    require runCliIn(app, @["g", "scaffold"]) == 0
    writeHeadlessRows(app)
    writeFile(app / "tests/persistence.nim", """
import std/os
import leaf
import leaf/host_session
import ../app/application
import ./headless_rows
proc click(rt: Runtime, key: string) = doAssert rt.dispatchFixture(key, Event(kind: click))
proc change(rt: Runtime, key, value: string) = doAssert rt.dispatchFixture(key, Event(kind: change, value: value))
let rt = newRuntime(createApplication())
rt.realizeRows()
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
of "reject":
  var reject = false
  let session = attachHostSession(rt, HostConsumer(sessionId: 771,
    prepare: proc(batch: HostBatch) = discard,
    apply: proc() =
      if reject: fail("generated page rejection"),
    accept: proc(revision: uint64) {.raises: [].} = discard,
    discardPrepared: proc() {.raises: [].} = discard))
  defer: session.close()
  # Home draft/action: a rejected input must not be inherited by the next add.
  reject = true
  var rejected = false
  try: rt.change("task_draft", "rejected")
  except UiError: rejected = true
  doAssert rejected
  reject = false
  # The accepted draft is still empty: an accepted add must not inherit "rejected".
  rt.click("task_add")
  var inherited = false
  try: inherited = rt.find("task_title_2").node.text == "rejected"
  except UiError: discard
  doAssert not inherited
  rt.change("task_draft", "clean")
  rt.click("task_add")
  doAssert rt.find("task_title_2").node.text == "clean"
  # Resource draft/panel/error: rejected save keeps editor but not draft/error.
  rt.click("nav_notes")
  rt.click("notes_new")
  reject = true
  rejected = false
  try: rt.change("notes_field_title", "leak")
  except UiError: rejected = true
  doAssert rejected
  doAssert rt.find("notes_field_title") != nil
  reject = false
  # Saving immediately must use the accepted draft, never the rejected "leak".
  rt.click("notes_save")
  var leaked = false
  try: leaked = rt.find("notes_title_2") != nil and rt.find("notes_title_2").node.text == "leak"
  except UiError: discard
  doAssert not leaked
  if rt.find("notes_field_title") == nil: rt.click("notes_new")
  rt.change("notes_field_title", "kept")
  rt.click("notes_save")
  doAssert rt.find("notes_title_2").node.text == "kept"
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
    require runCliIn(app, @["g", "scaffold", "Note", "title:string"]) == 0
    require compileFixture()
    for mode in ["extend", "reject", "read"]:
      let ran = runChild(binary, @[mode], app)
      checkpoint ran.output
      check ran.code == 0
    let inspected = openDatabase(app / "target/testing.sqlite3")
    defer: inspected.close()
    check inspected.query("select title from notes")[0][0].asString == "persistent note"
    check inspected.query("select count(*) from leaf_schema_migrations")[0][0].asInt == 2

  test "CLI generates a portable complete application and dry run writes nothing":
    let preview = base / "preview"
    createDir(preview)
    require runCliIn(preview, @["g", "scaffold", "--dry-run"]) == 0
    check not fileExists(preview / "leaf.json")
    check not dirExists(preview / "db")
    let app = base / "Application with spaces"
    require runCliIn(app, @["generate", "scaffold"]) == 0
    let project = readProject(app)
    check project.entryRelative == "main.nim"
    var included: seq[string]
    for item in collectFiles(project): included.add(item.relative)
    for path in ["app/pages/home/logic.nim", "app/pages/home/views/search.nim",
        "config/routes.nim", "db/catalog.nim", "config/database.nim"]:
      check path in included
    var migrations: seq[string]
    for path in included:
      if path.startsWith("db/migrations/") and path.endsWith("_create_tasks.nim"): migrations.add(path)
    check migrations.len == 1
    check "tests/test_home.nim" notin included
    check ".leaf/scaffold.json" notin included
    let before = files(app)
    check runCliIn(app, @["g", "scaffold"]) == 1
    check files(app) == before

  test "invalid arguments and fields leave applications unchanged":
    let app = base / "validation"
    require runCliIn(app, @["g", "scaffold"]) == 0
    let before = files(app)
    for fields in [@["title:string", "title:int"], @["id:int"], @["createdAt:string"], @["updated_at:float"], @["type:string"],
        @["title:date"], @["foo_bar:string", "foobar:bool"], @["9name:string"],
        @["value:float:extra"], @[]]:
      check runCliIn(app, @["g", "scaffold", "Note"] & fields) == 1
      check files(app) == before
    for args in [@["g"], @["g", "unknown", app],
        @["g", "scaffold", "new", "title:string"],
        @["g", "scaffold", "new", "--unknown"],
        @["g", "scaffold", "Note", "title:string", "--project"],
        @["g", "scaffold", "Note", "title:string", "--project", app, "--project", app]]:
      check leaf_cli.main(args) == 1
    for name in ["../escape", "proc", "9Thing", "Task", "LeafSchemaMigration"]:
      check runCliIn(app, @["g", "scaffold", name, "title:string"]) == 1
      check files(app) == before

  test "resource generation preserves user files and refuses conflicts":
    let app = base / "resources"
    require runCliIn(app, @["g", "scaffold"]) == 0
    writeFile(app / "config/routes.nim", readFile(app / "config/routes.nim") & "\n# user route comment\n")
    let customRoutes = readFile(app / "config/routes.nim")
    let before = files(app)
    require runCliIn(app, @["g", "scaffold", "Note", "title:string", "archived:bool", "--dry-run"]) == 0
    check files(app) == before
    require runCliIn(app, @["g", "scaffold", "Note", "title:string", "archived:bool"]) == 0
    check readFile(app / "config/routes.nim") == customRoutes
    let after = files(app)
    check runCliIn(app, @["g", "scaffold", "Note", "title:string"]) == 1
    check files(app) == after
    writeFile(app / "app/generated/pages.nim", readFile(app / "app/generated/pages.nim") & "# custom edit\n")
    let edited = files(app)
    check runCliIn(app, @["g", "scaffold", "Contact", "name:string"]) == 1
    check files(app) == edited
    let minimal = base / "minimal"
    initProject(minimal)
    let minimalBefore = files(minimal)
    check leaf_cli.main(@["g", "scaffold", "Note", "title:string", "--project", minimal]) == 1
    check files(minimal) == minimalBefore

  test "existing directories, .git and unrelated files survive generation":
    let app = base / "preexisting"
    createDir(app / ".git")
    writeFile(app / ".git" / "config", "[core]\n")
    createDir(app / "src" / "nested")
    writeFile(app / "src" / "notes.txt", "unrelated\n")
    writeFile(app / "keep.me", "keep\n")
    require runCliIn(app, @["g", "scaffold"]) == 0
    check readFile(app / ".git" / "config") == "[core]\n"
    check readFile(app / "src" / "notes.txt") == "unrelated\n"
    check readFile(app / "keep.me") == "keep\n"
    check dirExists(app / "src" / "nested")

  test "a fresh cwd reports every generated target conflict before any write":
    let app = base / "fresh-conflicts"
    createDir(app)
    writeFile(app / "README.md", "user readme\n")
    writeFile(app / "main.nim", "# user entry\n")
    let before = snapshotTree(app)
    var message = ""
    try: discard generateScaffold(ScaffoldOptions(mode: smApplication), app)
    except CatchableError as error: message = error.msg
    check "README.md" in message
    check "main.nim" in message
    check snapshotTree(app) == before
    check readFile(app / "README.md") == "user readme\n"
    check not dirExists(app / "target")
    check not fileExists(app / "target/leaf-migration-generation.lock")
    check not fileExists(app / ".leaf/scaffold.json")

  test "multiple conflicts are reported together before any write":
    let root = base / "conflict-message"
    createDir(root)
    writeFile(root / "a.nim", "a")
    writeFile(root / "b.nim", "b")
    let plan = @[ScaffoldFile(path: "a.nim", content: "x"),
      ScaffoldFile(path: "b.nim", content: "y")]
    var message = ""
    try: writePlan(root, plan, false)
    except CatchableError as error: message = error.msg
    check "a.nim" in message
    check "b.nim" in message
    check readFile(root / "a.nim") == "a"
    check readFile(root / "b.nim") == "b"
    # The same aggregation holds for an application scaffold over edited files.
    let app = base / "two-conflicts"
    createDir(app)
    require runCliIn(app, @["g", "scaffold"]) == 0
    writeFile(app / "config/routes.nim", "# edited routes\n")
    writeFile(app / "db/catalog.nim", "# edited catalog\n")
    let before = files(app)
    check runCliIn(app, @["g", "scaffold"]) == 1
    check files(app) == before

  test "untouched minimal init upgrades in place and mutations are refused":
    let app = base / "minimal-upgrade"
    initProject(app)
    let srcMain = readFile(app / "src/main.nim")
    let srcApp = readFile(app / "src/app.nim")
    require runCliIn(app, @["g", "scaffold"]) == 0
    check readFile(app / "src/main.nim") == srcMain
    check readFile(app / "src/app.nim") == srcApp
    for target in ["leaf.json", "src/main.nim", "src/app.nim", "assets/message.txt"]:
      let root = base / ("minimal-" & target.replace("/", "-"))
      initProject(root)
      writeFile(root / target, readFile(root / target) & "\n# edited\n")
      let before = files(root)
      check runCliIn(root, @["g", "scaffold"]) == 1
      check files(root) == before

  test "failed writes retain pre-existing empty directories":
    let root = base / "retain-dirs"
    createDir(root / "app/pages/notes")
    let plan = @[
      ScaffoldFile(path: "app/pages/notes/page.nim", content: "page"),
      ScaffoldFile(path: "new/" & repeat('y', 300) & ".nim", content: "cannot")]
    expect IOError: writePlan(root, plan, false)
    check dirExists(root / "app/pages/notes")
    check not fileExists(root / "app/pages/notes/page.nim")
    check not dirExists(root / "new")

  test "damaged manifests route edits and unregistered files never get overwritten":
    let app = base / "damaged"
    require runCliIn(app, @["g", "scaffold"]) == 0
    let originalManifest = readFile(app / ".leaf/scaffold.json")
    for damaged in ["not json", "{\"schema\":2,\"resources\":[]}",
        "{\"schema\":1,\"resources\":{}}",
        "{\"schema\":1,\"resources\":[{\"model\":\"../Escape\",\"fields\":[],\"migration\":2}]}"]:
      writeFile(app / ".leaf/scaffold.json", damaged)
      let before = files(app)
      check runCliIn(app, @["g", "scaffold", "Note", "title:string"]) == 1
      check files(app) == before
    writeFile(app / ".leaf/scaffold.json", originalManifest)
    let originalRoutes = readFile(app / "config/generated/routes.nim")
    writeFile(app / "config/generated/routes.nim", originalRoutes & "# custom route\n")
    let edited = files(app)
    check runCliIn(app, @["g", "scaffold", "Note", "title:string"]) == 1
    check files(app) == edited
    writeFile(app / "config/generated/routes.nim", originalRoutes)
    writeFile(app / "app/models/note.nim", "# handwritten model\n")
    let unregistered = files(app)
    check runCliIn(app, @["g", "scaffold", "Note", "title:string"]) == 1
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
    require runCliIn(app, @["g", "scaffold"]) == 0
    let path = app / ".leaf/scaffold.json"
    let permissions = getFilePermissions(path)
    defer: setFilePermissions(path, permissions)
    setFilePermissions(path, {fpUserRead, fpGroupRead, fpOthersRead})
    var before: Table[string, string]
    for key, value in files(app):
      if key != "target/leaf-migration-generation.lock": before[key] = value
    check runCliIn(app, @["g", "scaffold", "Note", "title:string"]) == 1
    # The persistent generation lock is a coordination artifact; no generated
    # product may be left behind.
    var after: Table[string, string]
    for key, value in files(app):
      if key != "target/leaf-migration-generation.lock": after[key] = value
    check after == before
    check not dirExists(app / "app/pages/notes")

  test "separated initials retain their identity across subsequent resource generation":
    let app = base / "initials"
    require runCliIn(app, @["g", "scaffold"]) == 0
    require runCliIn(app, @["g", "scaffold", "A_B", "label:string"]) == 0
    check runCliIn(app, @["g", "scaffold", "Contact", "name:string"]) == 0
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
      expect CatchableError:
        discard generateScaffold(ScaffoldOptions(mode: smApplication), alias / "redirected")
      check not dirExists(real / "redirected")

  test "resource names matching library and page symbols remain independent":
    let app = base / "namespaces"
    require runCliIn(app, @["g", "scaffold"]) == 0
    for name in ["Node", "State", "PageDefinition", "Draft", "Panel", "System", "ValueError", "Database", "SqlValue", "Migration"]:
      require runCliIn(app, @["g", "scaffold", name, "label:string"]) == 0
    require runCliIn(app, @["g", "scaffold", "Issue", "errors:string", "changed:bool"]) == 0
    let binary = app / "target/check".addFileExt(ExeExt)
    createDir(binary.parentDir)
    let compiled = runChild(compiler(), @["c", "--path:" & sourceRoot,
      "--nimcache:" & app / "target/cache", "--out:" & binary, app / "main.nim"], app)
    checkpoint compiled.output
    require compiled.code == 0
    let checked = runChild(binary, @["--check"], app)
    checkpoint checked.output
    check checked.code == 0
    for name in ["databases", "sql_values", "migrations", "issues"]:
      let tested = runChild(compiler(), @["c", "-r", "--path:" & sourceRoot,
        "--nimcache:" & app / "target/test-cache", "--out:" & app / "target" / name,
        app / "tests" / ("test_" & name & ".nim")], app)
      checkpoint tested.output
      check tested.code == 0

  test "generated database configuration can be imported without opening storage":
    let app = base / "configuration"
    require runCliIn(app, @["g", "scaffold"]) == 0
    writeFile(app / "tests/configuration.nim", "import std/[os, strutils]\nimport ../config/database\ndelEnv(\"LEAF_DATABASE_PATH\")\ndoAssert databasePath().isAbsolute\ndoAssert databasePath().endsWith(\"application.sqlite3\")\nlet custom = getCurrentDir() / \"target/config.sqlite3\"\nputEnv(\"LEAF_DATABASE_PATH\", custom)\ndoAssert databasePath() == custom\ndoAssert not fileExists(custom)\n")
    let binary = app / "target/configuration".addFileExt(ExeExt)
    createDir(binary.parentDir)
    let compiled = runChild(compiler(), @["c", "-r", "--path:" & sourceRoot,
      "--nimcache:" & app / "target/cache", "--out:" & binary, app / "tests/configuration.nim"], app)
    checkpoint compiled.output
    check compiled.code == 0

  test "generated application and two resources compile and execute CRUD and navigation":
    let app = base / "integration"
    require runCliIn(app, @["g", "scaffold"]) == 0
    require runCliIn(app, @["g", "scaffold", "Note", "title:string", "archived:bool"]) == 0
    require runCliIn(app, @["generate", "scaffold", "Metric", "count:int", "amount:float"]) == 0
    writeHeadlessRows(app)
    writeFile(app / "tests/integration.nim", """
import std/strutils
import leaf
import ../app/application
import ../config/database
import ./headless_rows
proc click(rt: Runtime, key: string) = doAssert rt.dispatchFixture(key, Event(kind: click))
proc change(rt: Runtime, key, value: string) = doAssert rt.dispatchFixture(key, Event(kind: change, value: value))
proc toggle(rt: Runtime, key: string, checked: bool) = doAssert rt.dispatchFixture(key, Event(kind: change, checked: checked))
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
rt.change("notes_field_title", "中".repeat(201))
rt.click("notes_save")
doAssert rt.find("notes_error").node.text.len > 0
doAssert rt.find("notes_field_title").node.text == "中".repeat(201)
doAssert connection.query("SELECT title FROM notes WHERE id=1")[0][0].asString == "First note"
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
    writeFile(app / "tests/storage.nim", """
import std/options
import leaf/sqlite
import leaf/migrations
import ../config/database
import ../db/catalog

let db = openApplicationDatabase(":memory:")
discard db.execute("INSERT INTO notes (title, archived, created_at, updated_at) VALUES (?, ?, 0, 0)", [dbValue("note"), dbValue(0)])
var checked = false
try:
  discard db.execute("INSERT INTO notes (title, archived, created_at, updated_at) VALUES (?, ?, 0, 0)", [dbValue("bad"), dbValue(2)])
except ConstraintError: checked = true
doAssert checked, "generated storage must enforce the boolean CHECK"
discard db.execute("INSERT INTO metrics (count, amount, created_at, updated_at) VALUES (?, ?, 0, 0)", [dbValue(42), dbValue(1.5)])
let down = runMigrations(db, applicationMigrations(), MigrationRequest(kind: mrMigrate, target: some(0'i64)))
doAssert down.errors.len == 0, $down.errors
let tables = db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name != 'leaf_schema_migrations'")
doAssert tables.len == 0, "user tables remained"
doAssert readMigrationHistory(db).len == 0, "history remained"
db.close()
echo "storage ok"
""")
    let storage = runChild(compiler(), @["c", "-r", "--path:" & sourceRoot,
      "--nimcache:" & app / "target/storage-cache", "--out:" & app / "target/storage".addFileExt(ExeExt),
      app / "tests/storage.nim"], app)
    checkpoint storage.output
    check storage.code == 0
    check "storage ok" in storage.output
    discard collectFiles(readProject(app))

  when defined(posix):
    test "symlinked generation targets preserve external files":
      let app = base / "links"
      createDir(app)
      require generateScaffold(ScaffoldOptions(mode: smApplication), app).len > 0
      let outside = base / "outside"
      createDir(outside)
      writeFile(outside / "sentinel", "untouched")
      createSymlink(outside, app / "app/pages/notes")
      let before = files(app)
      check runCliIn(app, @["g", "scaffold", "Note", "title:string"]) == 1
      check files(app) == before
      check readFile(outside / "sentinel") == "untouched"
      let alias = base / "app-alias"
      createSymlink(outside, alias)
      expect CatchableError:
        discard generateScaffold(ScaffoldOptions(mode: smApplication), alias)
      check readFile(outside / "sentinel") == "untouched"
