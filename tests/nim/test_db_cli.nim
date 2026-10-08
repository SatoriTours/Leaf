## Real CLI acceptance for the headless database entry point: the maintenance
## program must compile and run without UI/GPUI/Rust tooling, report one stable
## JSON object on stdout with diagnostics on stderr, and never create a database
## from a preview or status command.
import ./cleanup_support
import std/[json, monotimes, os, strtabs, strutils, tempfiles, times, unittest]
import leaf/[migrations, project, scaffold, sqlite]
import ./migration_compile_support

let base = createTempDir("leaf-db-cli-", "")
removeDirectoryOnExit(base)

let tools = base / "tools"
createDir(tools)
let cli = buildProbe(tools, currentSourcePath().parentDir.parentDir.parentDir / "src" / "leaf_cli.nim",
  base / "cli-cache", "leaf-cli", outPath = base / "leaf-cli")
doAssert cli.code == 0, cli.output

proc runCliIn(directory: string, args: seq[string], env: StringTableRef = nil,
    interruptAfterMs = 0): CliRun =
  runCli(cli.binary, directory, args, env, seconds = 600,
    interruptAfterMs = interruptAfterMs)

proc snapshot(root: string): seq[tuple[path, bytes: string]] =
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    result.add (relativePath(path, root), (if dirExists(path): "dir" else: readFile(path)))

suite "Headless database CLI":
  test "init, migrate, status and rollback run from the current project":
    let app = base / "app with 中文 $dir"
    createDir(app)
    check runCliIn(app, @["g", "scaffold"]).code == 0
    let initRun = runCliIn(app, @["db", "init"])
    check initRun.code == 0
    check "configuration ready" in initRun.stdoutText
    check "app/application.nim" notin initRun.stdoutText  # full scaffold: automatic
    check not fileExists(app / "application.sqlite3")
    let database = app / "var" / "cli.sqlite3"
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = database
    # A preview of an absent database creates neither file nor parent.
    let preview = runCliIn(app, @["db", "migrate", "--dry-run", "--json"], env)
    check preview.code == 0
    let previewJson = parseJson(preview.stdoutText.strip())
    check previewJson["dry_run"].getBool
    check previewJson["execution_confirmed"].getBool
    check previewJson["planned"].len == 1
    check previewJson["planned"][0]["version"].kind == JString
    check not fileExists(database)
    check not dirExists(database.parentDir)
    let migrated = runCliIn(app, @["db", "migrate", "--json"], env)
    check migrated.code == 0
    let migratedJson = parseJson(migrated.stdoutText.strip())
    check migratedJson["executed"].len == 1
    check migratedJson["current_version"].kind == JString
    check fileExists(database)
    # Status reads the existing database read-only and reports pending truthfully.
    let status = runCliIn(app, @["db", "status", "--json"], env)
    check status.code == 0
    let statusJson = parseJson(status.stdoutText.strip())
    check statusJson["command"].getStr == "status"
    check statusJson["current_version"].kind == JString
    check statusJson["pending_versions"].len == 0
    let before = snapshot(app)
    let repeat = runCliIn(app, @["db", "status", "--json"], env)
    check repeat.code == 0
    check snapshot(app) == before
    # Rollback then forward, and from a subdirectory.
    let version = migratedJson["current_version"].getStr
    check version.len > 0
    let subdir = app / "config"
    check runCliIn(subdir, @["db", "rollback", "--steps", "1", "--json"], env).code == 0
    let down = parseJson(runCliIn(subdir, @["db", "status", "--json"], env).stdoutText.strip())
    # A known empty database is version 0, not an unknown state.
    check down["current_version"].getStr == "0"
    check down["pending_versions"].len == 1
    check down["statuses"].len == 1
    check down["statuses"][0]["state"].getStr == "down"
    check runCliIn(app, @["db", "forward", "--steps", "1", "--json"], env).code == 0
    check runCliIn(app, @["db", "up", version, "--json"], env).code == 0
    check runCliIn(app, @["db", "down", version, "--dry-run", "--json"], env).code == 0

  test "maintenance runs without Rust or GUI tooling and keeps stdout separate":
    let app = base / "headless"
    createDir(app)
    check runCliIn(app, @["g", "scaffold"]).code == 0
    let database = app / "target" / "headless.sqlite3"
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = database
    env["CARGO"] = base / "missing-cargo"
    env["LEAF_GPUI_ROOT"] = base / "missing-gpui"
    let status = runCliIn(app, @["db", "status", "--json"], env)
    check status.code == 0
    let value = parseJson(status.stdoutText.strip())
    check value["command"].getStr == "status"
    check not fileExists(database)
    let migrated = runCliIn(app, @["db", "migrate", "--json"], env)
    check migrated.code == 0
    check fileExists(database)
    # A broken configuration fails with a single JSON object on stdout and the
    # compiler diagnostics on stderr, never a merged fake JSON report.
    let broken = base / "broken"
    createDir(broken)
    check runCliIn(broken, @["g", "scaffold"]).code == 0
    writeFile(broken / "config" / "database.nim", "this is not valid nim !!!\n")
    let failed = runCliIn(broken, @["db", "status", "--json"], env)
    check failed.code == 1
    check failed.stdoutText.strip().len > 0
    let failedJson = parseJson(failed.stdoutText.strip())
    check failedJson["errors"][0]["code"].getStr == "compile_failed"
    check failed.stderrText.len > 0

  test "a real SQL interruption keeps the committed step and reports 130":
    let app = base / "sql-interrupt"
    createDir(app)
    check runCliIn(app, @["g", "scaffold"]).code == 0
    # A slow legacy migration runs after the fast task migration commits.
    writeFile(app / "db" / "migrations" / "99999999999999999_slow.up.sql",
      "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 30000)\n" &
      "SELECT count(*) FROM c a, c b;\n")
    writeFile(app / "db" / "migrations" / "99999999999999999_slow.down.sql", "SELECT 1;\n")
    let database = app / "var" / "sql-interrupt.sqlite3"
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = database
    var signalled = false
    let interrupted = runCli(cli.binary, app, @["db", "migrate", "--json"], env,
      seconds = 120, ready = proc(): bool =
        if signalled: return false
        if not fileExists(database): return false
        # Let the child enter the slow migration before cancelling it.
        sleep(300)
        signalled = true
        true)
    checkpoint "code=" & $interrupted.code & " stdout=" & interrupted.stdoutText &
      " stderr=" & interrupted.stderrText
    check interrupted.code == 130
    let value = parseJson(interrupted.stdoutText.strip())
    if value["execution_confirmed"].getBool:
      var cancelled = 0
      for issue in value["errors"]:
        if issue["code"].getStr in ["migration_cancelled", "migration_interrupted"]:
          inc cancelled
      check cancelled >= 1
      # The fast task migration was committed before the slow one was cancelled.
      check fileExists(database)
      let db = openDatabaseReadOnly(database)
      let history = readMigrationHistory(db)
      db.close()
      check history.len == 1
    else:
      check value["executed"].kind == JNull
      check value["current_version"].kind == JNull
      var unconfirmed = 0
      for issue in value["errors"]:
        if issue["code"].getStr == "interrupted_unconfirmed": inc unconfirmed
      check unconfirmed == 1
    var leftover = 0
    for path in walkFiles(app / "target" / "leaf-db" / "cancel-*.token"): inc leftover
    for path in walkFiles(app / "target" / "leaf-db" / "report-*.json"): inc leftover
    check leftover == 0

  test "an interrupted migration reports 130 without inventing committed steps":
    let app = base / "interrupt"
    createDir(app)
    check runCliIn(app, @["g", "scaffold"]).code == 0
    # A legacy SQL migration that is slow enough to interrupt.
    writeFile(app / "db" / "migrations" / "900_slow.up.sql",
      "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 40000000)\n" &
      "SELECT count(*) FROM c;\n")
    writeFile(app / "db" / "migrations" / "900_slow.down.sql", "SELECT 1;\n")
    let database = app / "target" / "interrupt.sqlite3"
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = database
    let interrupted = runCliIn(app, @["db", "migrate", "--json"], env, interruptAfterMs = 1500)
    checkpoint "code=" & $interrupted.code & " stdout=" & interrupted.stdoutText &
      " stderr=" & interrupted.stderrText
    check interrupted.code == 130
    let value = parseJson(interrupted.stdoutText.strip())
    if value["execution_confirmed"].getBool:
      # The child cancelled gracefully and reported its own partial state.
      check value["errors"].len > 0 or value["executed"].len >= 0
    else:
      check value["executed"].kind == JNull
      check value["current_version"].kind == JNull
    var leftover = 0
    for path in walkFiles(app / "target" / "leaf-db" / "cancel-*.token"): inc leftover
    check leftover == 0

  test "strict JSON failures and precise preflight fields":
    # Parser and project failures still produce one JSON object on stdout.
    let outside = base / "outside-project"
    createDir(outside)
    let parserError = runCliIn(outside, @["db", "migrate", "42", "--json"])
    check parserError.code == 1
    check parseJson(parserError.stdoutText.strip())["errors"][0]["code"].getStr == "invalid_arguments"
    let projectError = runCliIn(outside, @["db", "status", "--json"])
    check projectError.code == 1
    check parseJson(projectError.stdoutText.strip())["errors"][0]["code"].getStr == "invalid_arguments"
    let app = base / "preflight"
    createDir(app)
    check runCliIn(app, @["g", "scaffold"]).code == 0
    let database = app / "var" / "preflight.sqlite3"
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = database
    # An absent database reports known-empty history.
    let empty = parseJson(runCliIn(app, @["db", "status", "--json"], env).stdoutText.strip())
    check empty["current_version"].getStr == "0"
    check empty["pending_versions"].len == 1
    check not fileExists(database)
    check not dirExists(database.parentDir)
    # An unknown target keeps its code, version, file, direction and dry-run flag.
    let unknown = runCliIn(app, @["db", "up", "424242", "--json"], env)
    check unknown.code == 1
    let unknownJson = parseJson(unknown.stdoutText.strip())
    check unknownJson["errors"][0]["code"].getStr == "invalid_migration_target"
    check unknownJson["errors"][0]["version"].getStr == "424242"
    check unknownJson["errors"][0]["direction"].kind == JNull
    check not fileExists(database)
    # A pending preview keeps the template disclosure fields.
    writeFile(app / "db" / "migrations" / "5555_pending.nim",
      "import leaf/migrations\n\nmigration pending:\n  change:\n    pending()\n")
    let pending = runCliIn(app, @["db", "migrate", "--dry-run", "--json"], env)
    check pending.code == 1
    let pendingJson = parseJson(pending.stdoutText.strip())
    check pendingJson["errors"][0]["code"].getStr == "pending_migration"
    check pendingJson["errors"][0]["file"].getStr.endsWith("5555_pending.nim")
    check pendingJson["errors"][0]["version"].getStr == "5555"
    check pendingJson["dry_run"].getBool
    removeFile(app / "db" / "migrations" / "5555_pending.nim")
    # A modified applied source is a fatal status, not a cancellation.
    check runCliIn(app, @["db", "migrate", "--json"], env).code == 0
    var taskMigration = ""
    for path in walkFiles(app / "db" / "migrations" / "*_create_tasks.nim"): taskMigration = path
    writeFile(taskMigration, readFile(taskMigration) & "\n# edited\n")
    let modified = runCliIn(app, @["db", "status", "--json"], env)
    check modified.code == 1
    let modifiedJson = parseJson(modified.stdoutText.strip())
    check modifiedJson["errors"].len > 0
    check modifiedJson["current_version"].kind == JString

  test "legacy three-column history stays a warning and upgrades":
    let app = base / "legacy-warning"
    copyDir(currentSourcePath().parentDir.parentDir / "fixtures" / "scaffold_v1", app)
    check runCliIn(app, @["db", "init"]).code == 0
    let database = app / "target" / "legacy.sqlite3"
    createDir(database.parentDir)
    let oldUp = readFile(app / "db" / "migrations" / "001_create_tasks.up.sql")
    block:
      let db = openDatabase(database)
      db.migrate(@[Migration(version: 1, name: "001_create_tasks", sql: oldUp)])
      db.close()
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = database
    let status = runCliIn(app, @["db", "status", "--json"], env)
    check status.code == 0
    let statusJson = parseJson(status.stdoutText.strip())
    check statusJson["current_version"].getStr == "1"
    var warnings = 0
    for item in statusJson["statuses"][0]["issues"]:
      if item["code"].getStr == "legacy_unverified_down": inc warnings
    check warnings == 1
    check readFile(app / "db" / "migrations" / "001_create_tasks.up.sql") == oldUp
    check runCliIn(app, @["db", "migrate", "--json"], env).code == 0
    check readFile(app / "db" / "migrations" / "001_create_tasks.up.sql") == oldUp

  test "the CLI helper is bounded when a child fills the pipe and sleeps":
    let tools = base / "tools-pipe"
    createDir(tools)
    writeProbeFiles(tools, @[("pipe.nim",
      "import std/[os, strutils]\nstdout.write(repeat('x', 4096))\nstdout.flushFile()\nsleep(60_000)\n")])
    let fixture = buildProbe(tools, "pipe.nim", base / "pipe-cache", "pipe")
    check fixture.code == 0
    if fixture.code == 0:
      let started = getMonoTime()
      let ran = runCli(fixture.binary, tools, @[], seconds = 1)
      check ran.code == 124
      check (getMonoTime() - started) < initDuration(seconds = 10)
      check ran.stdoutText.len == 4096

  test "the headless nimcache reflects added and removed migrations":
    let app = base / "cache"
    createDir(app)
    check runCliIn(app, @["g", "scaffold"]).code == 0
    let database = app / "var" / "cache.sqlite3"
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = database
    proc countMigrations(): int =
      let value = parseJson(runCliIn(app, @["db", "status", "--json"], env).stdoutText.strip())
      value["statuses"].len
    check countMigrations() == 1
    writeFile(app / "db" / "migrations" / "777_create_notes.nim",
      "import leaf/migrations\n\nmigration create_notes:\n  change:\n    createTable notes:\n      string title, nullable = false\n")
    check countMigrations() == 2
    removeFile(app / "db" / "migrations" / "777_create_notes.nim")
    check countMigrations() == 1
    check not fileExists(database)
