## Real CLI acceptance for the headless database entry point: the maintenance
## program must compile and run without UI/GPUI/Rust tooling, report one stable
## JSON object on stdout with diagnostics on stderr, and never create a database
## from a preview or status command.
import ./cleanup_support
import std/[json, monotimes, os, strtabs, strutils, tempfiles, times, unittest]
import leaf/[db_cli, migrations, process_io, project, scaffold, sqlite]
import ./migration_compile_support
when defined(posix): import std/posix

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
    let relative = relativePath(path, root)
    let portable = relative.replace('\\', '/')
    # Status may rebuild its own maintenance executable (PE timestamps differ
    # on Windows); the read-only contract covers storage and project sources.
    if portable == MaintenanceRelative or portable.startsWith(MaintenanceRelative & "/"):
      continue
    result.add (relative, (if dirExists(path): "dir" else: readFile(path)))

suite "Headless database CLI":
  test "init, migrate, status and rollback run from the current project":
    let app = base / "app with 中文 $dir"
    createDir(app)
    check runCliIn(app, @["g", "scaffold"]).code == 0
    checkpoint "before init cwd=" & getCurrentDir() & " appExists=" & $dirExists(app) &
      " binExists=" & $fileExists(cli.binary)
    let initRun = runCliIn(app, @["db", "init"])
    checkpoint "init code=" & $initRun.code & " out=" & initRun.stdoutText & " err=" & initRun.stderrText
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

  test "the report decoder rejects every malformed document":
    proc canonical(): JsonNode =
      %*{"command": "migrate", "database": "/tmp/x.sqlite3", "dry_run": true,
        "execution_confirmed": true, "planned": [], "executed": [], "skipped": [],
        "current_version": "0", "pending_versions": [], "statuses": [], "errors": []}
    var decoded: MigrationResult
    check decodeReport(canonical().pretty(), "migrate", true, decoded)
    check decoded.command == "migrate" and decoded.dryRun
    check decoded.currentVersion == some(0'i64)
    var value = canonical(); value["errors"] = newJNull()
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical(); value["planned"] = %*[123]
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical(); value["statuses"] = %*["bad"]
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical(); value["current_version"] = %"NOT_VERSION"
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical(); value["pending_versions"] = %*[true]
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical(); value["current_version"] = %"999999999999999999999999999999"
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical(); value["execution_confirmed"] = %false
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    check not decodeReport(canonical().pretty(), "status", true, decoded)
    check not decodeReport(canonical().pretty(), "migrate", false, decoded)
    check not decodeReport(canonical().pretty() & "{}", "migrate", true, decoded)

  test "the decoder enforces field domains and nullable consistency":
    proc canonical(): JsonNode =
      %*{"command": "migrate", "database": "/tmp/x.sqlite3", "dry_run": true,
        "execution_confirmed": true, "planned": [], "executed": [], "skipped": [],
        "current_version": "0", "pending_versions": [], "statuses": [], "errors": []}
    var decoded: MigrationResult
    check decodeReport(canonical().pretty(), "migrate", true, decoded)
    var value = canonical()
    value["planned"] = %*[{"version": "0", "direction": "up", "name": "n",
      "file": "f", "statements": []}]
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical(); value["current_version"] = %"-1"
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical(); value["pending_versions"] = %*["-2"]
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical()
    value["statuses"] = %*[{"version": "-3", "name": "n", "file": "f",
      "state": "up", "issues": []}]
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical()
    value["statuses"] = %*[{"version": "1", "name": "n", "file": "f",
      "state": "NOT_A_STATE", "issues": []}]
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical(); value["pending_versions"] = newJNull()
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical(); value["execution_confirmed"] = %false
    value["executed"] = newJNull(); value["current_version"] = %"99"
    value["pending_versions"] = %*[100]
    check not decodeReport(value.pretty(), "migrate", true, decoded)
    value = canonical()
    value["errors"] = %*[{"code": "x", "message": "m", "file": "",
      "version": "-9223372036854775808", "direction": "up"}]
    check decodeReport(value.pretty(), "migrate", true, decoded)
    check decoded.errors[0].version == some(low(int64))
    for state in ["up", "down", "pending-template", "corrupt", "unknown-format",
        "missing", "legacy-unverified-down", "modified"]:
      var entry = canonical()
      entry["statuses"] = %*[{"version": "1", "name": "n", "file": "f",
        "state": state, "issues": []}]
      check decodeReport(entry.pretty(), "migrate", true, decoded)

  test "default text database commands keep their existing presentation":
    let app = base / "text-mode"
    createDir(app)
    check runCliIn(app, @["g", "scaffold"]).code == 0
    let database = app / "var" / "text.sqlite3"
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = database
    let status = runCliIn(app, @["db", "status"], env)
    check status.code == 0
    check "status" in status.stdoutText
    check "{" notin status.stdoutText
    let dry = runCliIn(app, @["db", "migrate", "--dry-run"], env)
    check dry.code == 0
    check "planned up" in dry.stdoutText
    check not fileExists(database)
    let migrate = runCliIn(app, @["db", "migrate"], env)
    check migrate.code == 0
    check "executed up" in migrate.stdoutText
    check fileExists(database)
    let down = runCliIn(app, @["db", "rollback", "--steps", "1"], env)
    check down.code == 0
    check "executed down" in down.stdoutText

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
    when defined(posix):
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
          # Cancel only after the first migration is actually committed.
          var probe: Database
          try:
            probe = openDatabaseReadOnly(database)
            let committed = readMigrationHistory(probe).len >= 1
            if committed:
              signalled = true
              return true
          except CatchableError:
            discard
          finally:
            if probe != nil: probe.close()
          false)
      checkpoint "code=" & $interrupted.code & " stdout=" & interrupted.stdoutText &
        " stderr=" & interrupted.stderrText
      check interrupted.code == 130
      let value = parseJson(interrupted.stdoutText.strip())
      # The cancellation must land after the first committed step, so the report is
      # confirmed and names exactly what committed.
      check value["execution_confirmed"].getBool
      var cancelled = 0
      for issue in value["errors"]:
        if issue["code"].getStr == "migration_cancelled": inc cancelled
      check cancelled == 1
      check value["executed"].len == 1
      let taskVersion = value["current_version"].getStr
      check taskVersion.len > 0
      check value["executed"][0]["version"].getStr == taskVersion
      check value["executed"][0]["direction"].getStr == "up"
      let db = openDatabaseReadOnly(database)
      let history = readMigrationHistory(db)
      db.close()
      check history.len == 1
      check $history[0].version == taskVersion
      var leftover = 0
      for path in walkFiles(app / "target" / "leaf-db" / "cancel-*.token"): inc leftover
      for path in walkFiles(app / "target" / "leaf-db" / "report-*.json"): inc leftover
      check leftover == 0

  test "an interrupted migration reports 130 without inventing committed steps":
    when defined(posix):
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
      check not value["execution_confirmed"].getBool or value["errors"].len > 0
      if not value["execution_confirmed"].getBool:
        check value["executed"].kind == JNull
        check value["current_version"].kind == JNull
        var unconfirmed = 0
        for issue in value["errors"]:
          if issue["code"].getStr in ["interrupted_unconfirmed", "migration_interrupted"]:
            inc unconfirmed
        check unconfirmed >= 1
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
    # A read-only status must not upgrade the legacy history shape or add WAL.
    block:
      let db = openDatabaseReadOnly(database)
      let columns = db.query("PRAGMA table_info(leaf_schema_migrations)")
      db.close()
      check columns.len == 3
    check not fileExists(database & "-wal")
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

  test "read-only status and preview change no source bytes or mtimes":
    let app = base / "readonly"
    createDir(app)
    check runCliIn(app, @["g", "scaffold"]).code == 0
    let database = app / "var" / "readonly.sqlite3"
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = database
    # Finish fixture writes before warming the maintenance build.
    writeFile(app / "target-notes.txt", "in scope\n")
    check runCliIn(app, @["db", "migrate", "--json"], env).code == 0
    proc stamp(path: string): string =
      let value = when defined(windows): getFileInfo(path).lastWriteTime
        else: getLastModificationTime(path)
      $value.toUnix & "." & $value.nanosecond
    proc snap(root: string): seq[tuple[path, text: string]] =
      result.add (".", "dir:" & stamp(root))
      for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
        let rel = relativePath(path, root)
        # Only the permitted maintenance compile artifacts are excluded.
        let normalized = rel.replace('\\', '/')
        if normalized == "target/leaf-db" or normalized.startsWith("target/leaf-db/"): continue
        if dirExists(path): result.add (rel & "/", "dir:" & stamp(path))
        else: result.add (rel, "file:" & stamp(path) & ":" & readFile(path))
    let before = snap(app)
    check runCliIn(app, @["db", "status", "--json"], env).code == 0
    check runCliIn(app, @["db", "migrate", "--dry-run", "--json"], env).code == 0
    check snap(app) == before
    check not fileExists(database & "-wal")

  test "a damaged nearest project never falls back to an ancestor":
    let app = base / "nearest"
    createDir(app)
    check runCliIn(app, @["g", "scaffold"]).code == 0
    let nested = app / "nested"
    createDir(nested)
    writeFile(nested / "leaf.json", "this is not json !!!\n")
    let ran = runCliIn(nested, @["db", "status", "--json"])
    check ran.code == 1
    check parseJson(ran.stdoutText.strip())["errors"][0]["code"].getStr == "invalid_arguments"

  test "the maintenance program never imports main or the UI":
    let app = base / "poison"
    createDir(app)
    check runCliIn(app, @["g", "scaffold"]).code == 0
    writeFile(app / "main.nim", "this is not valid nim !!!\n")
    writeFile(app / "app" / "application.nim", "also not valid nim !!!\n")
    let database = app / "var" / "poison.sqlite3"
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = database
    let status = runCliIn(app, @["db", "status", "--json"], env)
    check status.code == 0
    check parseJson(status.stdoutText.strip())["command"].getStr == "status"

  test "targets, steps and directions reach real database states":
    let app = base / "states"
    createDir(app)
    check runCliIn(app, @["g", "scaffold"]).code == 0
    let database = app / "var" / "states.sqlite3"
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = database
    proc state(): string =
      let value = parseJson(runCliIn(app, @["db", "status", "--json"], env).stdoutText.strip())
      value["current_version"].getStr
    check runCliIn(app, @["db", "migrate", "--json"], env).code == 0
    let version = state()
    check version.len > 0
    check runCliIn(app, @["db", "migrate", "--to", "0", "--json"], env).code == 0
    check state() == "0"
    check runCliIn(app, @["db", "up", version, "--json"], env).code == 0
    check state() == version
    check runCliIn(app, @["db", "down", version, "--json"], env).code == 0
    check state() == "0"
    check runCliIn(app, @["db", "forward", "--steps", "1", "--json"], env).code == 0
    check state() == version
    check runCliIn(app, @["db", "rollback", "--steps", "1", "--json"], env).code == 0
    check state() == "0"

  test "an unresponsive ready child is forced and never claims confirmation":
    when defined(posix):
      let app = base / "forced"
      createDir(app)
      check runCliIn(app, @["g", "scaffold"]).code == 0
      # A configuration that blocks at import time: the maintenance child becomes
      # ready but can never observe the cancellation token.
      let marker = app / "target" / "forced-ready"
      createDir(marker.parentDir)
      # Keep the configuration API and block the import afterwards.
      writeFile(app / "config" / "database.nim",
        readFile(app / "config" / "database.nim") &
        "\nimport std/os\n" &
        "writeFile(" & marker.escape & ", \"ready\")\n" &
        "sleep(60_000)\n")
      let database = app / "var" / "forced.sqlite3"
      var env = newStringTable(modeCaseSensitive)
      for key, value in envPairs(): env[key] = value
      env["LEAF_DATABASE_PATH"] = database
      var signalled = false
      let started = getMonoTime()
      let forced = runCli(cli.binary, app, @["db", "migrate", "--json"], env,
        seconds = 300, ready = proc(): bool =
          if signalled: return false
          signalled = fileExists(marker)
          signalled)
      let elapsed = getMonoTime() - started
      check elapsed > initDuration(seconds = 9)
      check elapsed < initDuration(seconds = 40)
      checkpoint "forced code=" & $forced.code & " signalled=" & $signalled &
        " marker=" & $fileExists(marker) & " stdout=" & forced.stdoutText &
        " stderr-tail=" & (if forced.stderrText.len > 80: forced.stderrText[^80..^1] else: forced.stderrText)
      check signalled
      check fileExists(marker)
      check forced.code == 130
      let value = parseJson(forced.stdoutText.strip())
      check not value["execution_confirmed"].getBool
      check value["executed"].kind == JNull
      check value["current_version"].kind == JNull
      var unconfirmed = 0
      for issue in value["errors"]:
        if issue["code"].getStr == "interrupted_unconfirmed": inc unconfirmed
      check unconfirmed == 1
      check not fileExists(database)
      # A follow-up status must work and report the known-empty state.
      let after = runCliIn(app, @["db", "status", "--json"], env)
      check after.code == 0
      check parseJson(after.stdoutText.strip())["current_version"].getStr == "0"
      var leftovers = 0
      for path in walkFiles(app / "target" / "leaf-db" / "cancel-*.token"): inc leftovers
      for path in walkFiles(app / "target" / "leaf-db" / "report-*.json"): inc leftovers
      for path in walkFiles(app / "target" / "leaf-db" / "report-*.json.tmp"): inc leftovers
      check leftovers == 0

  when defined(linux):
    test "the split helper cleans LEAF nested children after the leader exits":
      let tools = base / "tools-nested"
      createDir(tools)
      writeProbeFiles(tools, @[("nested.nim", """
import std/[os, strutils]
import leaf/process_io

let sleeper = findExe("sleep")
let leaf = startSplitManaged(sleeper, @["60"], getCurrentDir())
writeFile(paramStr(1), $leaf.splitPid())
sleep(200)
"""), ("nested_managed.nim", """
import std/[os, strutils]
import leaf/process_io

let sleeper = findExe("sleep")
let leaf = startManaged(sleeper, @["60"], getCurrentDir())
writeFile(paramStr(1), $leaf.pid)
sleep(200)
""")])
      for name in ["nested", "nested_managed"]:
        let fixture = buildProbe(tools, name & ".nim", base / "nested-cache", name)
        check fixture.code == 0
        if fixture.code == 0:
          let marker = base / ("nested-" & name & ".pid")
          let ran = runCli(fixture.binary, tools, @[marker], seconds = 20)
          check ran.code == 0
          let leaf = parseInt(readFile(marker))
          var alive = true
          for attempt in 0 ..< 100:
            var state = '?'
            try:
              let stat = readFile("/proc/" & $leaf & "/stat")
              state = stat[stat.rfind(')') + 2]
            except CatchableError:
              state = 'X'
            if state in {'Z', 'X'}: alive = false; break
            sleep(20)
          check not alive

  when defined(posix):
    test "a forced timeout keeps the confirmed report facts":
      for jsonMode in [true, false]:
        let app = base / ("forced-facts-" & $jsonMode)
        createDir(app)
        check runCliIn(app, @["g", "scaffold"]).code == 0
        let marker = app / "target" / "facts-ready"
        createDir(marker.parentDir)
        writeFile(app / "config" / "database.nim",
          readFile(app / "config" / "database.nim") &
          "\nimport std/[os, exitprocs]\naddExitProc(proc() =\n  writeFile(" & marker.escape &
          ", \"ready\")\n  sleep(60_000))\n")
        let database = app / "var" / "facts.sqlite3"
        var env = newStringTable(modeCaseSensitive)
        for key, value in envPairs(): env[key] = value
        env["LEAF_DATABASE_PATH"] = database
        var signalled = false
        var arguments = @["db", "migrate"]
        if jsonMode: arguments.add "--json"
        let forced = runCli(cli.binary, app, arguments, env, seconds = 120,
          ready = proc(): bool =
            if signalled: return false
            if not fileExists(marker): return false
            sleep(300)
            signalled = true
            true)
        checkpoint "json=" & $jsonMode & " code=" & $forced.code & " out=" &
          forced.stdoutText
        check forced.code == 130
        if jsonMode:
          let value = parseJson(forced.stdoutText.strip())
          check value["execution_confirmed"].getBool
          check value["executed"].len == 1
          check value["current_version"].kind == JString
          check value["database"].getStr.len > 0
          var interrupted = 0
          for issue in value["errors"]:
            if issue["code"].getStr == "interrupted_unconfirmed": inc interrupted
          check interrupted == 1
        else:
          check "executed up" in forced.stdoutText
          check "current version:" in forced.stdoutText
        let probe = openDatabaseReadOnly(database)
        let history = readMigrationHistory(probe)
        probe.close()
        check history.len == 1

  when not defined(posix):
    test "signal-driven cancellation is POSIX-only":
      skip()

  test "the selected-direction capability gate rejects an unsupported backend":
    let definition = MigrationDefinition(version: 2, name: "drop_title",
      format: mfNimV1, hasDown: true, sourcePath: "db/migrations/2_drop_title.nim",
      upOps: @[SchemaOperation(kind: moRemoveColumn)])
    let plan = MigrationPlan(steps: @[MigrationStep(version: 2, direction: mdUp,
      name: "drop_title")])
    let rejected = selectedCapabilityIssues(@[definition], plan, (3, 24, 0))
    check rejected.len == 1
    check rejected[0].code == "unsupported_sqlite"
    check rejected[0].version == some(2'i64)
    check rejected[0].direction == some(mdUp)
    check rejected[0].file == "db/migrations/2_drop_title.nim"
    check selectedCapabilityIssues(@[definition], plan, (3, 40, 0)).len == 0

  when defined(linux):
    test "sibling splits and live nested trees are always owned and reaped":
      let tools = base / "tools-guardian"
      createDir(tools)
      writeProbeFiles(tools, @[
        ("sleeper.nim", "import std/os\nsleep(60_000)\n"),
        ("live_middle.nim", """
import std/[os, strutils]
import leaf/process_io

let sleeper = findExe("sleep")
let leaf = startManaged(sleeper, @["60"], getCurrentDir())
writeFile(paramStr(1), $leaf.pid)
sleep(60_000)
""")])
      let sleeper = buildProbe(tools, "sleeper.nim", base / "guardian-cache", "sleeper")
      let middle = buildProbe(tools, "live_middle.nim", base / "guardian-cache", "live_middle")
      check sleeper.code == 0
      check middle.code == 0
      if sleeper.code == 0 and middle.code == 0:
        proc alive(pid: int): bool =
          if not fileExists("/proc/" & $pid & "/stat"): return false
          let stat = readFile("/proc/" & $pid & "/stat")
          stat[stat.rfind(')') + 2] notin {'Z', 'X'}
        # E1: two siblings, close order must not matter and must not hang.
        for order in [0, 1]:
          var a: SplitProcess
          var b: SplitProcess
          try:
            a = startSplitManaged(sleeper.binary, @[], tools)
            b = startSplitManaged(sleeper.binary, @[], tools)
            let first = if order == 0: a else: b
            let second = if order == 0: b else: a
            let started = getMonoTime()
            first.closeSplit()
            second.closeSplit()
            check (getMonoTime() - started) < initDuration(seconds = 10)
            check a.code != -1
            check b.code != -1
          finally:
            if a != nil: a.closeSplit()
            if b != nil: b.closeSplit()
        # E2: a live middle with a session-opening managed child is cleaned.
        let marker = base / "guardian-leaf.pid"
        var running: SplitProcess
        var leaf = 0
        try:
          running = startSplitManaged(middle.binary, @[marker], tools)
          var ready = false
          for attempt in 0 ..< 500:
            if fileExists(marker): ready = true; break
            sleep(10)
          check ready
          if ready:
            leaf = parseInt(readFile(marker))
            check alive(leaf)
            let started = getMonoTime()
            running.closeSplit()
            check (getMonoTime() - started) < initDuration(seconds = 10)
            var stopped = false
            for attempt in 0 ..< 500:
              if not alive(leaf): stopped = true; break
              sleep(10)
            check stopped
        finally:
          if running != nil: running.closeSplit()
          if leaf > 0 and alive(leaf):
            when defined(posix): discard kill(Pid(leaf), SIGKILL)
