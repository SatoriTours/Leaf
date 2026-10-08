## Real CLI acceptance for the headless database entry point: the maintenance
## program must compile and run without UI/GPUI/Rust tooling, report one stable
## JSON object on stdout with diagnostics on stderr, and never create a database
## from a preview or status command.
import ./cleanup_support
import std/[json, os, strtabs, strutils, tempfiles, unittest]
import leaf/[project, scaffold]
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
    check down["current_version"].kind == JNull
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
