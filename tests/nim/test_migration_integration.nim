import ./cleanup_support
import std/[algorithm, json, monotimes, os, osproc, sequtils, strutils, streams, tables, tempfiles, times, unittest]
import leaf/[project, package_files, build, process_io, scaffold, scaffold_types, sqlite, migrations]
import leaf/migrations/initialization
import ./migration_compile_support
import ./symlink_support
when defined(posix): import std/posix

let base = createTempDir("leaf-migration-integration-", "")
removeDirectoryOnExit(base)
let fixture = currentSourcePath().parentDir.parentDir / "fixtures" / "scaffold_v1"

proc boundedChild(exe: string, args: seq[string], dir: string,
    seconds = 900): tuple[code: int, output: string] =
  ## Managed child: literal arguments (never a shell), a monotonic deadline and
  ## a `finally` that drains, kills the process group and reaps it.
  let child = startManaged(exe, args, dir)
  try:
    let deadline = getMonoTime() + initDuration(seconds = seconds)
    while not child.poll():
      if getMonoTime() > deadline:
        result.code = 124
        break
      sleep(10)
    if result.code != 124: result.code = child.code
    result.output = child.output.diagnosticText()
  finally:
    child.close()

proc stamp(path: string): string =
  ## Exact seconds and nanoseconds; no float rounding.
  let value = when defined(windows): getFileInfo(path).lastWriteTime
    else: getLastModificationTime(path)
  $value.toUnix & "." & $value.nanosecond

proc snapshotTree(root: string): Table[string, string] =
  ## Bytes plus exact mtime for the root, every file and every directory.
  result["."] = "dir:" & stamp(root)
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    let rel = relativePath(path, root)
    if dirExists(path):
      result[rel & "/"] = "dir:" & stamp(path)
    else:
      result[rel] = "file:" & stamp(path) & ":" & readFile(path)

proc waitReady(children: seq[ManagedProcess], marker: proc(): bool {.closure.},
    seconds: int): void =
  ## Real monotonic readiness wait: raises on an unexpected early exit or on a
  ## genuine deadline instead of continuing past a failed check.
  let deadline = getMonoTime() + initDuration(seconds = seconds)
  while true:
    for child in children:
      discard child.poll()
      if child.code != -1:
        raise newException(IOError, "child exited before readiness: " & $child.code)
    if marker(): return
    if getMonoTime() > deadline:
      raise newException(IOError, "readiness deadline expired")
    sleep(10)

proc finishBounded(child: ManagedProcess, seconds = 900): int =
  let deadline = getMonoTime() + initDuration(seconds = seconds)
  while not child.poll():
    if getMonoTime() > deadline: return 124
    sleep(10)
  child.code

proc nimArgs(source, outPath, srcRoot, cache: string): seq[string] =
  @["c", "-r", "--hints:off", "--path:" & srcRoot, "--nimcache:" & cache,
    "--out:" & outPath, source]


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
    let staged = boundedChild(compiler(), nimArgs(app / "tests/staged_check.nim",
      binary, source, app / "target/cache"), app)
    checkpoint staged.output
    check staged.code == 0
    check "catalog ok" in staged.output
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
    let legacy = boundedChild(compiler(), nimArgs(app / "tests/legacy_check.nim",
      binary, source, app / "target/lc-cache"), app)
    checkpoint legacy.output
    check legacy.code == 0
    check "legacy ok" in legacy.output

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
      var children: seq[ManagedProcess]
      try:
        children.add startManaged(worker.binary, @[app, "Alpha"], app)
        children.add startManaged(worker.binary, @[app, "Beta"], app)
        check finishBounded(children[0]) == 0
        check finishBounded(children[1]) == 0
      finally:
        for child in children: child.close()
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
    check fileExists(legacy / "app/services/audit_service.nim")
    # An underscore spelling is an ordinary schema 1 field too.
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Event",
      fields: @["created_at:string"]), legacy)
    let source = currentSourcePath().parentDir.parentDir.parentDir / "src"
    writeFile(legacy / "tests/schema1_audit.nim", """
import std/strutils
import leaf/sqlite
import ../config/database
import ../db/catalog
import ../app/models/audit as audit_model
import ../app/services/audit_service
import ../app/models/event as event_model
import ../app/services/event_service

let db = openApplicationDatabase(":memory:")
let audits = db.query("SELECT sql FROM sqlite_master WHERE name='audits'")[0][0].asString
doAssert "AUTOINCREMENT" in audits, audits
var names: seq[string]
for row in db.query("PRAGMA table_info(audits)"): names.add row[1].asString
doAssert "createdAt" in names, $names
doAssert "created_at" notin names, $names
doAssert "updated_at" notin names, $names
# Real generated service CRUD and validation.
let service = newAuditService(db)
var rejected = false
try: discard service.save(audit_model.Audit(createdAt: "   "))
except audit_model.AuditValidationError: rejected = true
doAssert rejected, "empty string must fail generated validation"
var created = service.save(audit_model.Audit(createdAt: "  2024-01-01  "))
doAssert created.id > 0, "AUTOINCREMENT id"
doAssert created.createdAt == "2024-01-01", created.createdAt
doAssert service.all().len == 1
var found = service.find(created.id)
found.createdAt = "2024-01-02"
discard service.save(found)
doAssert service.find(created.id).createdAt == "2024-01-02"
service.delete(created.id)
doAssert service.all().len == 0
# The underscore spelling is an ordinary field on its own model and service.
let events = newEventService(db)
var event = events.save(event_model.Event(created_at: "2024-02-02"))
doAssert event.created_at == "2024-02-02"
doAssert events.find(event.id).created_at == "2024-02-02"
events.delete(event.id)
doAssert events.all().len == 0
db.close()
echo "schema1 ok"
""")
    let ran = boundedChild(compiler(), nimArgs(legacy / "tests/schema1_audit.nim",
      legacy / "target/schema1-audit", source, legacy / "target/s1-cache"), legacy)
    checkpoint ran.output
    check ran.code == 0
    check "schema1 ok" in ran.output

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
    let run = boundedChild(compiler(), nimArgs(app / "tests/f2_caller.nim",
      app / "target/f2-caller", source, app / "target/f2-cache"), app)
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
    for kind in ["missing_up", "bad_schema2_metadata", "noncanonical_model",
        "wrong_fields_kind"]:
      let root = base / ("f2-" & kind)
      copyDir(fixture, root)
      let manifest = root / ".leaf/scaffold.json"
      var value = parseFile(manifest)
      case kind
      of "missing_up": removeFile(root / "db/migrations/001_create_tasks.up.sql")
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

  test "symlinked legacy SQL is rejected before any write":
    if not canCreateSymlink(base, directory = false):
      checkpoint "SKIP: Windows user cannot create file symlinks (error 1314)"
      skip()
    else:
      let root = base / "f2-up-symlink"
      copyDir(fixture, root)
      let sql = root / "db/migrations/001_create_tasks.up.sql"
      let outside = base / "outside-up.sql"
      let original = readFile(sql)
      writeFile(outside, original)
      removeFile(sql)
      createSymlink(outside, sql)
      proc snapshot(): Table[string, string] =
        for path in walkDirRec(root): result[relativePath(path, root)] = readFile(path)
      let before = snapshot()
      expect CatchableError: discard initializeDatabaseProject(readProject(root))
      check snapshot() == before
      check symlinkExists(sql)
      check readFile(outside) == original

  test "implicit task sources and converted manifests are validated":
    proc snapshot(root: string): Table[string, string] =
      for path in walkDirRec(root): result[relativePath(path, root)] = readFile(path)
    proc attempt(root: string): string =
      try:
        discard initializeDatabaseProject(readProject(root))
        result = "accepted"
      except CatchableError as error: result = "controlled:" & error.msg
      except Defect as error: result = "DEFECT:" & $error.name & ":" & error.msg
    for kind in ["task_up_down", "task_down"]:
      let root = base / ("f2b-" & kind)
      copyDir(fixture, root)
      removeFile(root / "db/migrations/001_create_tasks.up.sql")
      if kind == "task_up_down": removeFile(root / "db/migrations/001_create_tasks.down.sql")
      let before = snapshot(root)
      let outcome = attempt(root)
      checkpoint kind & " -> " & outcome
      check outcome.startsWith("controlled:")
      check snapshot(root) == before
    # A converted (schema 3) scaffold validates registered resources too.
    let forged = base / "f2b-forged-schema3"
    copyDir(fixture, forged)
    discard initializeDatabaseProject(readProject(forged))
    let manifest = forged / ".leaf/scaffold.json"
    var value = parseFile(manifest)
    value["resources"] = %*[{"model": "Note", "singular": "note",
      "fields": [{"name": "title", "type": "string"}], "migration": "1"}]
    writeFile(manifest, pretty(value))
    let forgedBefore = snapshot(forged)
    let forgedOutcome = attempt(forged)
    checkpoint "forged_schema3 -> " & forgedOutcome
    check forgedOutcome.startsWith("controlled:")
    check snapshot(forged) == forgedBefore

  test "manifest conversion preserves unrelated metadata":
    let app = base / "f2b-metadata"
    copyDir(fixture, app)
    let manifest = app / ".leaf/scaffold.json"
    var value = parseFile(manifest)
    value["custom_metadata"] = %*{"keep": true, "note": "user data"}
    value["resources"] = %*[{"model": "Note", "singular": "note", "custom": "kept",
      "fields": [{"name": "title", "type": "string"}], "migration": 2}]
    writeFile(manifest, pretty(value))
    writeFile(app / "db/migrations/002_create_notes.up.sql", "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL);\n")
    writeFile(app / "db/migrations/002_create_notes.down.sql", "DROP TABLE notes;\n")
    writeFile(app / "app/generated/migrations.nim", "# Generated by leaf scaffold. Do not edit this file.\n" &
      "import leaf/sqlite\n\nconst\n" &
      "  migrationSql1 = staticRead(\"../../db/migrations/001_create_tasks.up.sql\")\n" &
      "  migrationSql2 = staticRead(\"../../db/migrations/002_create_notes.up.sql\")\n\n" &
      "proc generatedMigrations*(): seq[Migration] =\n  @[\n" &
      "    Migration(version: 1, name: \"001_create_tasks\", sql: migrationSql1),\n" &
      "    Migration(version: 2, name: \"002_create_notes\", sql: migrationSql2)\n" &
      "  ]\n")
    discard initializeDatabaseProject(readProject(app))
    let upgraded = parseFile(manifest)
    check upgraded["schema"].getInt == 3
    check upgraded["model_schema"].getInt == 1
    check upgraded["custom_metadata"]["keep"].getBool
    check upgraded["custom_metadata"]["note"].getStr == "user data"
    check upgraded["resources"][0]["custom"].getStr == "kept"
    check upgraded["resources"][0]["migration"].kind == JString
    check fileExists(app / "target/leaf-migration-generation.lock")
    # On Windows `app` may be a short 8.3 temp path (RUNNER~1), while the
    # initializer reports the expanded canonical long path, so compare
    # against realPath(app) instead of `app` itself.
    check initializeDatabaseProject(readProject(app)) == @["initialized " & realPath(app)]

  test "resource generation preserves allowed manifest metadata":
    let app = base / "f6-metadata"
    createDir(app)
    discard generateScaffold(ScaffoldOptions(mode: smApplication), app)
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
      fields: @["title:string"]), app)
    let path = app / ".leaf/scaffold.json"
    var value = parseFile(path)
    value["custom_metadata"] = %*{"keep": true}
    value["resources"][0]["custom"] = %"kept"
    writeFile(path, pretty(value) & "\n")
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Metric",
      fields: @["count:int"]), app)
    let updated = parseFile(path)
    check updated["schema"].getInt == 3
    check updated["custom_metadata"]["keep"].getBool
    check updated["resources"][0]["custom"].getStr == "kept"
    check updated["resources"].len == 2
    check updated["resources"][1]["migration"].kind == JString

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
    let first = boundedChild(compiler(), nimArgs(app / "tests/f2_schema2_caller.nim",
      app / "target/f2-s2", source, app / "target/s2-cache"), app)
    checkpoint first.output
    check first.code == 0
    check "history 2" in first.output
    # A later hand-written Nim migration is discovered by the SAME delegate.
    writeFile(app / "db/migrations/003_create_tags.nim",
      "import leaf/migrations\n\nmigration create_tags:\n  change:\n" &
      "    createTable tags:\n      string name, nullable = false\n")
    let delegate = readFile(app / "app/generated/migrations.nim")
    check "seq[MigrationDefinition]" in delegate
    let second = boundedChild(compiler(), nimArgs(app / "tests/f2_schema2_caller.nim",
      app / "target/f2-s2b", source, app / "target/s2-cache-b"), app)
    checkpoint second.output
    check second.code == 0
    check "history 3" in second.output
    check readFile(app / "app/generated/migrations.nim") == delegate
    let third = boundedChild(app / "target/f2-s2b".changeFileExt(ExeExt), @[], app)
    checkpoint third.output
    check third.code == 0
    check "history 3" in third.output

  test "collected files compile and import from a different staging root":
    let app = base / "stage-source"
    createDir(app)
    discard generateScaffold(ScaffoldOptions(mode: smApplication), app)
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
      fields: @["title:string"]), app)
    let stage = base / "stage with 中文 $dir"
    for item in collectFiles(readProject(app)):
      let target = stage / item.relative
      if dirExists(item.source):
        createDir(target)
      else:
        createDir(target.parentDir)
        writeFile(target, readFile(item.source))
    check fileExists(stage / "config/database.nim")
    check fileExists(stage / "db/catalog.nim")
    createDir(stage / "tests")
    writeFile(stage / "tests/stage_check.nim", """
import std/[os, strutils]
import leaf/sqlite
import ../config/database
import ../db/catalog

delEnv("LEAF_DATABASE_PATH")
doAssert databasePath().isAbsolute
doAssert databasePath().endsWith("application.sqlite3")
doAssert not fileExists(databasePath())
let deep = getCurrentDir() / "target/deep/custom.sqlite3"
putEnv("LEAF_DATABASE_PATH", deep)
doAssert databasePath() == deep
doAssert not dirExists(deep.parentDir)
let db = openApplicationDatabase(":memory:")
db.close()
doAssert not dirExists(deep.parentDir)
doAssert applicationMigrations().len == 2
echo "staging ok"
""")
    let source = currentSourcePath().parentDir.parentDir.parentDir / "src"
    let ran = boundedChild(compiler(), nimArgs(stage / "tests/stage_check.nim",
      base / "stage-check", source, base / "stage-cache"), stage)
    checkpoint ran.output
    check ran.code == 0
    check "staging ok" in ran.output

  test "initializer dry run and exact no-op change no bytes or mtimes":
    let app = base / "f7-init-idempotent"
    createDir(app)
    discard generateScaffold(ScaffoldOptions(mode: smApplication), app)
    let before = snapshotTree(app)
    discard initializeDatabaseProject(readProject(app), dryRun = true)
    check snapshotTree(app) == before
    check initializeDatabaseProject(readProject(app)) == @["initialized " & realPath(app)]
    check snapshotTree(app) == before
    let legacy = base / "f7-init-dryrun"
    copyDir(fixture, legacy)
    let legacyBefore = snapshotTree(legacy)
    discard initializeDatabaseProject(readProject(legacy), dryRun = true)
    check snapshotTree(legacy) == legacyBefore
    check not fileExists(legacy / "target/leaf-migration-generation.lock")

  test "scaffold dry runs change no bytes or mtimes":
    let fresh = base / "f7-app-dryrun"
    createDir(fresh)
    let freshBefore = snapshotTree(fresh)
    discard generateScaffold(ScaffoldOptions(mode: smApplication, dryRun: true), fresh)
    check snapshotTree(fresh) == freshBefore
    check not dirExists(fresh / "target")
    let app = base / "f7-resource-dryrun"
    createDir(app)
    discard generateScaffold(ScaffoldOptions(mode: smApplication), app)
    let before = snapshotTree(app)
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
      fields: @["title:string"], dryRun: true), app)
    check snapshotTree(app) == before

  test "managed children report known exits, honour deadlines and always reap":
    let tools = base / "tools-managed"
    writeProbeFiles(tools, @[
      ("exit7.nim", "import std/os\nquit(7)\n"),
      ("blocker.nim", "import std/os\nsleep(60_000)\n")])
    let exit7 = buildProbe(tools, "exit7.nim", base / "tools-managed-cache", "exit7")
    let blocker = buildProbe(tools, "blocker.nim", base / "tools-managed-cache", "blocker")
    check exit7.code == 0
    check blocker.code == 0
    if exit7.code == 0 and blocker.code == 0:
      check boundedChild(exit7.binary, @[], tools).code == 7
      let started = getMonoTime()
      check boundedChild(blocker.binary, @[], tools, seconds = 1).code == 124
      check (getMonoTime() - started) < initDuration(seconds = 10)
      # The deadline path reaps the child instead of leaking it.
      let child = startManaged(blocker.binary, @[], tools)
      check finishBounded(child, 1) == 124
      let pid = child.pid
      child.close()
      check child.code != -1
      when defined(posix):
        check posix.kill(Pid(pid), 0) != 0
      # A never-ready live child raises on the deadline instead of looping.
      let neverReady = startManaged(blocker.binary, @[], tools)
      let waitStarted = getMonoTime()
      var timedOut = false
      try:
        waitReady(@[neverReady], proc(): bool = false, 1)
      except CatchableError:
        timedOut = true
      finally:
        neverReady.close()
      check timedOut
      check (getMonoTime() - waitStarted) < initDuration(seconds = 10)
      check neverReady.code != -1
      # A child that exits before readiness is a real error, not a silent wait.
      let early = startManaged(exit7.binary, @[], tools)
      var earlyFailed = false
      try:
        waitReady(@[early], proc(): bool = false, 30)
      except CatchableError:
        earlyFailed = true
      finally:
        early.close()
      check earlyFailed
      # A failed second spawn still closes and reaps a genuinely active child.
      var children: seq[ManagedProcess]
      var raised = false
      try:
        children.add startManaged(blocker.binary, @[], tools)
        discard children[0].poll()
        check children[0].code == -1
        let pid = children[0].pid
        children.add startManaged(tools / "missing-binary-xyz", @[], tools)
        check false
      except CatchableError:
        raised = true
      finally:
        for child in children: child.close()
      check raised
      check children.len == 1
      check children[0].code != -1
      when defined(posix):
        check posix.kill(Pid(children[0].pid), 0) != 0

  test "generator races share one lock and keep an exact consistent catalog":
    let tools = base / "tools-race"
    writeProbeFiles(tools, @[("worker.nim", """
import std/os
import leaf/scaffold
import leaf/migrations

let kind = paramStr(1)
let root = paramStr(2)
writeFile(paramStr(4), "ready")
try:
  if kind == "resource":
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
      fields: @["title:string"]), root)
  else:
    discard generateMigration(root, paramStr(3))
  echo "ok"
except CatchableError as error:
  stderr.writeLine(error.msg)
  quit(1)
""")])
    let worker = buildProbe(tools, "worker.nim", base / "tools-race-cache", "worker")
    check worker.code == 0
    if worker.code == 0:
      for scenario in ["same-resource", "migration-collision", "migration-distinct"]:
        let root = base / (scenario & " 中文 $literal")
        createDir(root)
        discard generateScaffold(ScaffoldOptions(mode: smApplication), root)
        let lock = acquireFileLock(root / GenerationLockRelative)
        var released = false
        var children: seq[ManagedProcess]
        try:
          let secondKind = if scenario == "same-resource": "resource" else: "migration"
          let migrationName = if scenario == "migration-distinct": "create_tags" else: "create_notes"
          children.add startManaged(worker.binary,
            @["resource", root, "", root / "target/first"], root)
          children.add startManaged(worker.binary,
            @[secondKind, root, migrationName, root / "target/second"], root)
          waitReady(children, proc(): bool =
            fileExists(root / "target/first") and fileExists(root / "target/second"), 30)
          sleep(600)
          for child in children: discard child.poll()
          let blocked = children[0].code == -1 and children[1].code == -1
          check blocked
          lock.release()
          released = true
          var codes: seq[int]
          for child in children: codes.add finishBounded(child, 60)
          checkpoint scenario & " " & $codes
          let value = parseFile(root / ".leaf/scaffold.json")
          var catalog: seq[string]
          var notesCount = 0
          var noteVersion = 0'i64
          for file in scanMigrationFiles(root / "db/migrations"):
            catalog.add file.name
            if file.name == "create_notes":
              inc notesCount
              noteVersion = file.version
          check notesCount == 1
          if scenario == "migration-distinct":
            check codes == @[0, 0]
            check catalog.len == 3
            check value["resources"].len == 1
          else:
            check (codes == @[0, 1] or codes == @[1, 0])
            check catalog.len == 2
            let expected = if scenario == "same-resource": 1 else: (if codes[0] == 0: 1 else: 0)
            check value["resources"].len == expected
          if value["resources"].len == 1:
            check value["resources"][0]["migration"].getStr == $noteVersion
            check fileExists(root / "app/models/note.nim")
          else:
            check not fileExists(root / "app/models/note.nim")
        finally:
          if not released:
            try: lock.release()
            except CatchableError: discard
          for child in children: child.close()
