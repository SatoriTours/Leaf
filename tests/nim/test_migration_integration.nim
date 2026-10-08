import ./cleanup_support
import std/[algorithm, json, os, osproc, sequtils, strutils, streams, tables, tempfiles, unittest]
import leaf/[project, package_files, build, scaffold, scaffold_types, sqlite, migrations]
import leaf/migrations/initialization
import ./migration_compile_support
when defined(posix): import std/posix

let base = createTempDir("leaf-migration-integration-", "")
removeDirectoryOnExit(base)
let fixture = currentSourcePath().parentDir.parentDir / "fixtures" / "scaffold_v1"

proc stopChild(child: Process) =
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
  try: child.close()
  except CatchableError: discard

suite "database initialization":
  test "an existing project gains config and catalog without opening storage":
    let minimal = base / "minimal"
    initProject(minimal)
    discard initializeDatabaseProject(readProject(minimal))
    check fileExists(minimal / "config/database.nim")
    check fileExists(minimal / "db/catalog.nim")
    check not fileExists(minimal / "application.sqlite3")
    let config = parseFile(minimal / "leaf.json")
    check %"config" in config["include"]
    check %"db" in config["include"]
    # Idempotent: a fully matching project reports initialized and writes nothing.
    let settled = walkDirRec(minimal).toSeq()
    check initializeDatabaseProject(readProject(minimal)) == @["initialized " & realPath(minimal)]
    check walkDirRec(minimal).toSeq() == settled
    # Dry run never changes the filesystem.
    let dry = base / "dry-init"
    initProject(dry)
    let dryBefore = walkDirRec(dry).toSeq()
    check initializeDatabaseProject(readProject(dry), dryRun = true).len > 0
    check walkDirRec(dry).toSeq() == dryBefore
    # A customized config refuses automatic overwrite.
    writeFile(minimal / "config/database.nim", "# handwritten\n")
    expect CatchableError:
      discard initializeDatabaseProject(readProject(minimal))
    check readFile(minimal / "config/database.nim") == "# handwritten\n"

  test "generated configuration and catalog compile and import without opening storage":
    let app = base / "staged"
    initProject(app)
    discard generateScaffold(ScaffoldOptions(mode: smApplication), app)
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
      fields: @["title:string"]), app)
    var included: seq[string]
    for item in collectFiles(readProject(app)): included.add(item.relative)
    check "config/database.nim" in included
    check "db/catalog.nim" in included
    let source = currentSourcePath().parentDir.parentDir.parentDir / "src"
    let binary = app / "target/catalog-check"
    createDir(binary.parentDir)
    writeFile(app / "tests/staged_check.nim",
      "import std/os\nimport ../db/catalog\nimport ../config/database\ndoAssert applicationMigrations().len == 2\n" &
      "doAssert not fileExists(\"target/staged.sqlite3\")\necho \"catalog ok\"\n")
    let child = startProcess(compiler(), workingDir = app,
      args = @["c", "-r", "--hints:off", "--path:" & source,
        "--nimcache:" & app / "target/cache", "--out:" & binary, app / "tests/staged_check.nim"],
      options = {poUsePath, poStdErrToStdOut})
    let output = child.outputStream.readAll()
    let code = child.waitForExit()
    child.close()
    check code == 0
    check "catalog ok" in output
    check not fileExists(app / "target/staged.sqlite3")

suite "legacy project integration":
  test "frozen v1 fixtures upgrade without rewriting SQL or history":
    let app = base / "legacy-integration"
    copyDir(fixture, app)
    let oldUp = readFile(app / "db/migrations/001_create_tasks.up.sql")
    let oldDown = readFile(app / "db/migrations/001_create_tasks.down.sql")
    let seeded = app / "target/legacy.sqlite3"
    createDir(seeded.parentDir)
    block:
      let db = openDatabase(seeded)
      db.migrate(@[Migration(version: 1, name: "001_create_tasks", sql: oldUp)])
      discard db.execute("INSERT INTO tasks(title,done) VALUES (?,?)",
        @[dbValue("original"), dbValue(false)])
      db.close()
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
      fields: @["title:string"]), app)
    check readFile(app / "db/migrations/001_create_tasks.up.sql") == oldUp
    check readFile(app / "db/migrations/001_create_tasks.down.sql") == oldDown
    let manifest = parseFile(app / ".leaf/scaffold.json")
    check manifest["schema"].getInt == 3
    check manifest["model_schema"].getInt == 1
    check manifest["resources"][0]["migration"].kind == JString
    # Explicit startup (real generated catalog) migrates the seeded database:
    # the original row and its exact SQL survive and the new Nim migration runs.
    writeFile(app / "tests/legacy_check.nim", """
import std/os
import leaf/sqlite
import leaf/migrations
import ../config/database

let db = openApplicationDatabase("target/legacy.sqlite3")
let history = readMigrationHistory(db)
doAssert history.len == 2
doAssert history[0].name == "001_create_tasks"
doAssert history[0].sql == readFile("db/migrations/001_create_tasks.up.sql")
doAssert db.query("SELECT title FROM tasks")[0][0].asString == "original"
doAssert db.query("SELECT count(*) FROM notes")[0][0].asInt == 0
db.close()
echo "legacy ok"
""")
    let source = currentSourcePath().parentDir.parentDir.parentDir / "src"
    let binary = app / "target/legacy-check"
    createDir(binary.parentDir)
    let child = startProcess(compiler(), workingDir = app,
      args = @["c", "-r", "--hints:off", "--path:" & source,
        "--nimcache:" & app / "target/lc-cache", "--out:" & binary,
        app / "tests/legacy_check.nim"], options = {poUsePath, poStdErrToStdOut})
    let output = child.outputStream.readAll()
    let code = child.waitForExit()
    child.close()
    checkpoint output
    check code == 0
    check "legacy ok" in output

suite "concurrent resource generation":
  test "two processes share one generation lock and keep both resources":
    let tools = base / "tools"
    writeProbeFiles(tools, @[("worker.nim", """
import std/os
import leaf/scaffold

discard generateScaffold(ScaffoldOptions(mode: smResource, target: paramStr(2),
  fields: @["title:string"]), paramStr(1))
echo "ok"
""")])
    let worker = buildProbe(tools, "worker.nim", base / "tools-cache", "worker")
    check worker.code == 0
    if worker.code == 0:
      let app = base / "concurrent"
      createDir(app)
      discard generateScaffold(ScaffoldOptions(mode: smApplication), app)
      let first = startProcess(worker.binary, args = @[app, "Alpha"],
        options = {poStdErrToStdOut})
      let second = startProcess(worker.binary, args = @[app, "Beta"],
        options = {poStdErrToStdOut})
      try:
        check first.waitForExit() == 0
        check second.waitForExit() == 0
      finally:
        stopChild(first)
        stopChild(second)
      let manifest = parseFile(app / ".leaf/scaffold.json")
      var names: seq[string]
      for entry in manifest["resources"]: names.add(entry["model"].getStr)
      names.sort()
      check names == @["Alpha", "Beta"]
      let files = scanMigrationFiles(app / "db/migrations")
      check files.len == 3
      var versions: seq[int64]
      for file in files: versions.add(file.version)
      check versions.len == versions.deduplicate().len

suite "scaffold hardening (fix round 1)":
  test "customized config and catalog are never overwritten":
    let custom = base / "custom-config"
    copyDir(fixture, custom)
    let path = custom / "config/database.nim"
    writeFile(path, readFile(path).replace(
      "getDataDir() / \"scaffold_v1\" / \"application.sqlite3\"",
      "getCurrentDir() / \"KEEP_MY_PRIVATE_DATABASE.sqlite3\""))
    let customBytes = readFile(path)
    expect CatchableError: discard initializeDatabaseProject(readProject(custom))
    check readFile(path) == customBytes
    let cat = base / "custom-catalog"
    initProject(cat)
    discard initializeDatabaseProject(readProject(cat))
    let catPath = cat / "db/catalog.nim"
    writeFile(catPath, readFile(catPath) & "\n# user comment\n")
    let catBytes = readFile(catPath)
    expect CatchableError: discard initializeDatabaseProject(readProject(cat))
    check readFile(catPath) == catBytes

  test "existing migration names and forged manifest versions are rejected":
    let coll = base / "collision"
    createDir(coll)
    discard generateScaffold(ScaffoldOptions(mode: smApplication), coll)
    createDir(coll / "db/migrations")
    writeFile(coll / "db/migrations/001_create_notes.nim",
      "import leaf/migrations\n\nmigration create_notes:\n  change:\n    createTable custom_notes:\n      string title\n")
    expect CatchableError:
      discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
        fields: @["title:string"]), coll)
    let appColl = base / "app-collision"
    createDir(appColl / "db/migrations")
    writeFile(appColl / "db/migrations/001_create_tasks.nim",
      "import leaf/migrations\n\nmigration create_tasks:\n  change:\n    createTable custom_tasks:\n      string title\n")
    expect CatchableError:
      discard generateScaffold(ScaffoldOptions(mode: smApplication), appColl)
    let forged = base / "forged"
    createDir(forged)
    discard generateScaffold(ScaffoldOptions(mode: smApplication), forged)
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
      fields: @["title:string"]), forged)
    let manifestPath = forged / ".leaf/scaffold.json"
    var value = parseFile(manifestPath)
    value["resources"][0]["migration"] = %"1"
    writeFile(manifestPath, pretty(value) & "\n")
    expect CatchableError:
      discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Metric",
        fields: @["count:int"]), forged)

  when defined(posix):
    test "reads and retained artifacts go through the path guard":
      let sym = base / "symlink"
      initProject(sym)
      discard initializeDatabaseProject(readProject(sym))
      let outside = base / "outside-config.nim"
      writeFile(outside, readFile(sym / "config/database.nim"))
      removeFile(sym / "config/database.nim")
      createSymlink(outside, sym / "config/database.nim")
      expect CatchableError: discard initializeDatabaseProject(readProject(sym))
      check symlinkExists(sym / "config/database.nim")
      let minimal = base / "minimal-symlink"
      initProject(minimal)
      writeFile(base / "outside-main.nim", readFile(minimal / "src/main.nim"))
      removeFile(minimal / "src/main.nim")
      createSymlink(base / "outside-main.nim", minimal / "src/main.nim")
      expect CatchableError:
        discard generateScaffold(ScaffoldOptions(mode: smApplication), minimal)

  when defined(posix):
    test "leaf.json, migrations readme and caller-root symlinks are guarded":
      let lj = base / "leafjson-symlink"
      initProject(lj)
      writeFile(base / "outside-leaf.json", readFile(lj / "leaf.json"))
      removeFile(lj / "leaf.json")
      createSymlink(base / "outside-leaf.json", lj / "leaf.json")
      expect CatchableError: discard initializeDatabaseProject(readProject(lj))
      let rm = base / "readme-symlink"
      initProject(rm)
      discard initializeDatabaseProject(readProject(rm))
      let readme = rm / "db/migrations/README.md"
      writeFile(base / "outside-readme.md", readFile(readme))
      removeFile(readme)
      createSymlink(base / "outside-readme.md", readme)
      expect CatchableError: discard initializeDatabaseProject(readProject(rm))
      check symlinkExists(readme)
      let realRoot = base / "root-real"
      createDir(realRoot)
      discard generateScaffold(ScaffoldOptions(mode: smApplication), realRoot)
      let aliasRoot = base / "root-alias"
      createSymlink(realRoot, aliasRoot)
      expect CatchableError:
        discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
          fields: @["title:string"]), aliasRoot)

  test "schema 1 keeps ordinary timestamp-named fields":
    let legacy = base / "schema1-audit"
    copyDir(fixture, legacy)
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Audit",
      fields: @["createdAt:string"]), legacy)
    check fileExists(legacy / "app/models/audit.nim")
    var migration = ""
    for path in walkFiles(legacy / "db/migrations/*_create_audits.nim"): migration = readFile(path)
    check "string createdAt" in migration

proc boundedChild(dir, command: string, seconds = 900): tuple[code: int, output: string] =
  ## A bounded, always-cleaned-up child for the F2 compatibility evidence.
  var wrapped = command
  when defined(posix): wrapped = "timeout " & $seconds & " " & command
  let child = startProcess(wrapped, workingDir = dir,
    options = {poUsePath, poStdErrToStdOut, poEvalCommand})
  try:
    result.output = child.outputStream.readAll()
    result.code = child.waitForExit()
  finally:
    if child.running:
      child.terminate()
      result.code = 124
    child.close()

proc nimCommand(source, outPath, srcRoot, cache: string): string =
  compiler() & " c -r --hints:off --path:" & srcRoot & " --nimcache:" & cache &
    " --out:" & outPath & " " & source

suite "legacy registry compatibility (F2)":
  test "customized and missing legacy registries are refused with zero writes":
    let custom = base / "f2-custom-init"
    copyDir(fixture, custom)
    let reg = custom / "app/generated/migrations.nim"
    let customBytes = readFile(reg) & "\n# custom\n"
    writeFile(reg, customBytes)
    expect CatchableError: discard initializeDatabaseProject(readProject(custom))
    check readFile(reg) == customBytes
    let customRes = base / "f2-custom-res"
    copyDir(fixture, customRes)
    let reg2 = customRes / "app/generated/migrations.nim"
    writeFile(reg2, readFile(reg2) & "\n# custom\n")
    expect CatchableError:
      discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
        fields: @["title:string"]), customRes)
    check "# custom" in readFile(reg2)
    let missing = base / "f2-missing"
    copyDir(fixture, missing)
    removeFile(missing / "app/generated/migrations.nim")
    expect CatchableError: discard initializeDatabaseProject(readProject(missing))

  test "the recognized legacy registry becomes a stable delegate":
    let app = base / "f2-delegate"
    copyDir(fixture, app)
    let oldUp = readFile(app / "db/migrations/001_create_tasks.up.sql")
    let seeded = app / "target/seeded.sqlite3"
    createDir(seeded.parentDir)
    block:
      let db = openDatabase(seeded)
      db.migrate(@[Migration(version: 1, name: "001_create_tasks", sql: oldUp)])
      discard db.execute("INSERT INTO tasks(title,done) VALUES (?,?)",
        @[dbValue("original"), dbValue(false)])
      db.close()
    discard initializeDatabaseProject(readProject(app))
    let delegate = readFile(app / "app/generated/migrations.nim")
    check "proc generatedMigrations*(): seq[MigrationDefinition]" in delegate
    check "catalog.applicationMigrations()" in delegate
    check readFile(app / "db/migrations/001_create_tasks.up.sql") == oldUp
    let source = currentSourcePath().parentDir.parentDir.parentDir / "src"
    writeFile(app / "tests/f2_caller.nim", """
import leaf/sqlite
import ../app/generated/migrations

let db = openDatabase("target/seeded.sqlite3")
db.migrate(generatedMigrations())
doAssert db.query("SELECT title FROM tasks")[0][0].asString == "original"
doAssert readMigrationHistory(db).len == 1
db.close()
echo "caller ok"
""")
    let run = boundedChild(app, nimCommand(app / "tests/f2_caller.nim",
      app / "target/f2-caller", source, app / "target/f2-cache"))
    checkpoint run.output
    check run.code == 0
    check "caller ok" in run.output
    # A later Nim resource uses the same fixed delegate without rewriting it.
    let before = readFile(app / "app/generated/migrations.nim")
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
      fields: @["title:string"]), app)
    check readFile(app / "app/generated/migrations.nim") == before
    let manifest = parseFile(app / ".leaf/scaffold.json")
    check manifest["schema"].getInt == 3

  test "legacy sources and metadata are validated before any write":
    proc snapshot(root: string): Table[string, string] =
      for path in walkDirRec(root): result[relativePath(path, root)] = readFile(path)
    proc attempt(root: string): string =
      try:
        discard initializeDatabaseProject(readProject(root))
        result = "accepted"
      except CatchableError as error: result = "controlled:" & error.msg
      except Defect as error: result = "DEFECT:" & $error.name & ":" & error.msg
    for kind in ["missing_up", "up_symlink", "bad_schema2_metadata", "noncanonical_model",
        "wrong_fields_kind"]:
      let root = base / ("f2-" & kind)
      copyDir(fixture, root)
      let manifest = root / ".leaf/scaffold.json"
      var value = parseFile(manifest)
      case kind
      of "missing_up": removeFile(root / "db/migrations/001_create_tasks.up.sql")
      of "up_symlink":
        let outside = base / "outside-up.sql"
        writeFile(outside, readFile(root / "db/migrations/001_create_tasks.up.sql"))
        removeFile(root / "db/migrations/001_create_tasks.up.sql")
        createSymlink(outside, root / "db/migrations/001_create_tasks.up.sql")
      of "bad_schema2_metadata":
        value["schema"] = %2
        value["model_api"] = %0
        value["timestamps"] = %false
        writeFile(manifest, pretty(value))
      of "noncanonical_model":
        value["resources"] = %*[{"model": "FORGED_MODEL", "singular": "note",
          "fields": [{"name": "title", "type": "string"}], "migration": 2}]
        writeFile(manifest, pretty(value))
      else:
        value["resources"] = %*[{"model": "Note", "singular": "note",
          "fields": 7, "migration": 2}]
        writeFile(manifest, pretty(value))
      let before = snapshot(root)
      let outcome = attempt(root)
      checkpoint kind & " -> " & outcome
      check outcome.startsWith("controlled:")
      check snapshot(root) == before
    # A fresh app with a decimal version too large for int64 is refused too.
    let overflow = base / "f2-overflow"
    createDir(overflow)
    discard generateScaffold(ScaffoldOptions(mode: smApplication), overflow)
    var fresh = parseFile(overflow / ".leaf/scaffold.json")
    fresh["resources"] = %*[{"model": "Note", "singular": "note",
      "fields": [{"name": "title", "type": "string"}],
      "migration": "99999999999999999999999999999999999"}]
    writeFile(overflow / ".leaf/scaffold.json", pretty(fresh))
    let overflowBefore = snapshot(overflow)
    check attempt(overflow).startsWith("controlled:")
    check snapshot(overflow) == overflowBefore

  test "a schema 2 legacy caller keeps its sources and upgrades the manifest":
    const tasksUp = "CREATE TABLE tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, done INTEGER NOT NULL);\n"
    const notesUp = "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL);\n"
    const Schema2Registry = "# Generated by leaf scaffold. Do not edit this file.\n" &
      "import leaf/sqlite\n\nconst\n" &
      "  migrationSql1 = staticRead(\"../../db/migrations/001_create_tasks.up.sql\")\n" &
      "  migrationSql2 = staticRead(\"../../db/migrations/002_create_notes.up.sql\")\n\n" &
      "proc generatedMigrations*(): seq[Migration] =\n  @[\n" &
      "    Migration(version: 1, name: \"001_create_tasks\", sql: migrationSql1),\n" &
      "    Migration(version: 2, name: \"002_create_notes\", sql: migrationSql2)\n" &
      "  ]\n"
    let app = base / "f2-schema2"
    copyDir(fixture, app)
    writeFile(app / "db/migrations/001_create_tasks.up.sql", tasksUp)
    writeFile(app / "db/migrations/002_create_notes.up.sql", notesUp)
    writeFile(app / "db/migrations/002_create_notes.down.sql", "DROP TABLE notes;\n")
    writeFile(app / "app/generated/migrations.nim", Schema2Registry)
    writeFile(app / ".leaf/scaffold.json",
      "{\"schema\": 2, \"model_api\": 1, \"timestamps\": true, \"resources\": [" &
      "{\"model\": \"Note\", \"singular\": \"note\", " &
      "\"fields\": [{\"name\": \"title\", \"type\": \"string\"}], \"migration\": 2}]}\n")
    let seeded = app / "target/seeded.sqlite3"
    createDir(seeded.parentDir)
    block:
      let db = openDatabase(seeded)
      db.migrate(@[Migration(version: 1, name: "001_create_tasks", sql: tasksUp),
        Migration(version: 2, name: "002_create_notes", sql: notesUp)])
      discard db.execute("INSERT INTO notes(title) VALUES (?)", @[dbValue("independent")])
      db.close()
    discard initializeDatabaseProject(readProject(app))
    check readFile(app / "db/migrations/001_create_tasks.up.sql") == tasksUp
    check readFile(app / "db/migrations/002_create_notes.up.sql") == notesUp
    let upgraded = parseFile(app / ".leaf/scaffold.json")
    check upgraded["schema"].getInt == 3
    check upgraded["model_schema"].getInt == 2
    check upgraded["timestamps"].getBool
    check upgraded["resources"][0]["model"].getStr == "Note"
    check upgraded["resources"][0]["migration"].kind == JString
    check upgraded["resources"][0]["migration"].getStr == "2"
    let source = currentSourcePath().parentDir.parentDir.parentDir / "src"
    writeFile(app / "tests/f2_schema2_caller.nim", """
import leaf/sqlite
import ../app/generated/migrations

let db = openDatabase("target/seeded.sqlite3")
db.migrate(generatedMigrations())
doAssert db.query("SELECT title FROM notes")[0][0].asString == "independent"
echo "history ", readMigrationHistory(db).len
db.close()
""")
    let first = boundedChild(app, nimCommand(app / "tests/f2_schema2_caller.nim",
      app / "target/f2-s2", source, app / "target/s2-cache"))
    checkpoint first.output
    check first.code == 0
    check "history 2" in first.output
    # A later hand-written Nim migration is discovered by the SAME delegate.
    writeFile(app / "db/migrations/003_create_tags.nim",
      "import leaf/migrations\n\nmigration create_tags:\n  change:\n" &
      "    createTable tags:\n      string name, nullable = false\n")
    let delegate = readFile(app / "app/generated/migrations.nim")
    check "seq[MigrationDefinition]" in delegate
    let second = boundedChild(app, nimCommand(app / "tests/f2_schema2_caller.nim",
      app / "target/f2-s2b", source, app / "target/s2-cache-b"))
    checkpoint second.output
    check second.code == 0
    check "history 3" in second.output
    check readFile(app / "app/generated/migrations.nim") == delegate
    let third = boundedChild(app, app / "target/f2-s2b")
    checkpoint third.output
    check third.code == 0
    check "history 3" in third.output
