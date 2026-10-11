## Real current-project CLI acceptance for merging migration branches.
import ./cleanup_support
import std/[json, os, sequtils, strtabs, tempfiles, unittest]
import leaf/[project, sqlite]
import ./migration_compile_support

let root = createTempDir("leaf-branch-migrations-", "")
removeDirectoryOnExit(root)
let tools = root / "tools"
createDir(tools)
let cli = buildProbe(tools, currentSourcePath().parentDir.parentDir.parentDir / "src/leaf_cli.nim",
  root / "cli-cache", "leaf", outPath = root / "leaf")
doAssert cli.code == 0, cli.output

proc migration(name, table: string): string =
  "import leaf/migrations\n\nmigration " & name & ":\n  change:\n    createTable " &
    table & ":\n      string title, nullable = false\n"

suite "Merged migration branches":
  test "earlier additions preserve existing data and missing branches refuse writes":
    let app = root / "app 中文"
    initProject(app)
    let initialized = runCli(cli.binary, app, @["db", "init"])
    require initialized.code == 0
    let later = app / "db/migrations/003_create_later.nim"
    let earlier = app / "db/migrations/002_create_earlier.nim"
    writeFile(later, migration("create_later", "later_records"))
    let storage = app / "var/application.sqlite3"
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = storage
    proc run(args: seq[string]): CliRun = runCli(cli.binary, app, args, env)
    let first = run(@["db", "migrate", "--json"])
    checkpoint first.stderrText & first.stdoutText
    require first.code == 0
    check parseJson(first.stdoutText)["executed"][0]["version"].getStr == "3"
    block:
      let db = openDatabase(storage)
      defer: db.close()
      discard db.execute("INSERT INTO later_records(title) VALUES (?)", @[dbValue("保留的数据")])
    # Merge branch B after branch A has already run a higher version.
    writeFile(earlier, migration("create_earlier", "earlier_records"))
    let merged = run(@["db", "migrate", "--json"])
    require merged.code == 0
    let report = parseJson(merged.stdoutText)
    check report["executed"].len == 1
    check report["executed"][0]["version"].getStr == "2"
    check report["current_version"].getStr == "3"
    block:
      let db = openDatabase(storage)
      defer: db.close()
      check db.query("SELECT title FROM later_records")[0][0].asString == "保留的数据"
      check db.query("SELECT version FROM leaf_schema_migrations ORDER BY version").mapIt(it[0].asInt) == @[2, 3]
    # The merged catalog also applies to an empty database in sorted order.
    env["LEAF_DATABASE_PATH"] = app / "empty.sqlite3"
    let empty = run(@["db", "migrate", "--json"])
    require empty.code == 0
    let executed = parseJson(empty.stdoutText)["executed"]
    check executed.len == 2
    check executed[0]["version"].getStr == "2"
    check executed[1]["version"].getStr == "3"
    env["LEAF_DATABASE_PATH"] = storage
    # A duplicate identity is rejected at compilation, before storage changes.
    let duplicate = app / "db/migrations/003_duplicate.nim"
    writeFile(duplicate, migration("duplicate", "duplicate_records"))
    check run(@["db", "migrate", "--json"]).code == 1
    removeFile(duplicate)
    # A semantic collision rolls back the failing step and retains prior data.
    let conflict = app / "db/migrations/004_conflict.nim"
    writeFile(conflict, migration("conflict", "later_records"))
    let failed = run(@["db", "migrate", "--json"])
    require failed.code == 1
    check parseJson(failed.stdoutText)["executed"].len == 0
    removeFile(conflict)
    # Switching back to B cannot forget A's applied history.
    removeFile(later)
    let missing = run(@["db", "status", "--json"])
    require missing.code == 1
    let missingReport = parseJson(missing.stdoutText)
    check missingReport["statuses"].anyIt(it["version"].getStr == "3" and it["state"].getStr == "missing")
    check run(@["db", "migrate", "--json"]).code == 1
    block:
      let db = openDatabase(storage)
      defer: db.close()
      check db.query("SELECT title FROM later_records")[0][0].asString == "保留的数据"
      check db.query("SELECT count(*) FROM leaf_schema_migrations")[0][0].asInt == 2
