import ./cleanup_support
import std/[algorithm, os, osproc, sequtils, strutils, tempfiles, times, unittest]
import leaf/migrations
import ./migration_compile_support

let base = createTempDir("leaf-migration-generator-", "")
removeDirectoryOnExit(base)

const childSource = """
import std/os
import leaf/migrations

let paths = generateMigration(paramStr(1), paramStr(2))
echo paths[0]
"""

proc snapshot(root: string): seq[string] =
  for path in walkDirRec(root): result.add relativePath(path, root)
  result.sort()

suite "migration version allocation":
  test "UTC milliseconds and the maximum successor are combined":
    check nextMigrationVersion(@[], fromUnix(0)) == 19700101000000000'i64
    check nextMigrationVersion(@[MigrationFile(version: 20261008120000000'i64)],
      fromUnix(0)) == 20261008120000001'i64
    let sameMillisecond = dateTime(2026, mOct, 8, 12, 0, 0, 123_000_000, zone = utc()).toTime
    check nextMigrationVersion(@[], sameMillisecond) == 20261008120000123'i64
    check nextMigrationVersion(@[MigrationFile(version: 20261008120000123'i64)],
      sameMillisecond) == 20261008120000124'i64
    check nextMigrationVersion(@[MigrationFile(version: 20261008120000123'i64)],
      fromUnix(0)) == 20261008120000124'i64
    expect MigrationError:
      discard nextMigrationVersion(@[MigrationFile(version: high(int64))], fromUnix(0))

suite "migration template generation":
  test "names normalize to snake_case and malformed names are rejected":
    let root = base / "names"
    createDir(root)
    proc planned(name: string): string =
      generateMigration(root, name, dryRun = true)[0].extractFilename
    check planned("createTasks").endsWith("_create_tasks.nim")
    check planned("HTTPServer").endsWith("_http_server.nim")
    check planned("addHTTPSupport").endsWith("_add_http_support.nim")
    check planned("already_snake").endsWith("_already_snake.nim")
    expect MigrationError: discard generateMigration(root, "123bad", dryRun = true)
    expect MigrationError: discard generateMigration(root, "create-tasks", dryRun = true)
    expect MigrationError: discard generateMigration(root, "", dryRun = true)
    expect MigrationError: discard generateMigration(root, "bad__name", dryRun = true)
    expect MigrationError: discard generateMigration(root, "trailing_", dryRun = true)

  test "dry-run plans a path without writing anything":
    let root = base / "dryrun"
    createDir(root)
    writeFile(root / "unrelated.txt", "keep")
    let before = snapshot(root)
    let planned = generateMigration(root, "createTasks", dryRun = true)
    check planned.len == 1
    check planned[0].extractFilename.endsWith("_create_tasks.nim")
    check snapshot(root) == before
    check not dirExists(root / "target")
    check not dirExists(root / "db")

  test "generated pending template compiles without database side effects":
    let root = base / "template"
    createDir(root)
    let paths = generateMigration(root, "addPriorityToTasks")
    check paths.len == 1
    check fileExists(paths[0])
    check "pending()" in readFile(paths[0])
    let basename = paths[0].extractFilename
    check basename.endsWith("_add_priority_to_tasks.nim")
    let probe = compileProbe(@[
      ("db/migrations/" & basename, readFile(paths[0])),
      ("main.nim", "import std/os\ninclude \"db/migrations/" & basename & "\"\n" &
        "doAssert migrationDefinition.pending\n" &
        "doAssert not migrationDefinition.hasDown\n" &
        "doAssert migrationDefinition.upOps.len == 0\n" &
        "doAssert not fileExists(\"application.sqlite3\")\necho \"ok\"\n")],
      "main.nim", run = true)
    check probe.code == 0
    check "ok" in probe.output

  test "an existing name is refused and unrelated files survive":
    let root = base / "collision"
    createDir(root)
    let first = generateMigration(root, "createTasks")
    check fileExists(first[0])
    writeFile(root / "keep.txt", "keep")
    expect MigrationError: discard generateMigration(root, "createTasks")
    check readFile(root / "keep.txt") == "keep"
    check fileExists(first[0])

  test "sequential generation allocates increasing versions and keeps the lock":
    let root = base / "sequence"
    createDir(root)
    let first = generateMigration(root, "firstTask")
    let second = generateMigration(root, "secondTask")
    check first[0] != second[0]
    check fileExists(first[0])
    check fileExists(second[0])
    let files = scanMigrationFiles(root / "db" / "migrations")
    check files.len == 2
    check files[0].version != files[1].version
    check fileExists(root / "target" / "leaf-migration-generation.lock")

  test "blocked or symlinked paths fail without writing outside":
    let outside = base / "outside"
    createDir(outside)

    let blocked = base / "blocked"
    createDir(blocked)
    writeFile(blocked / "db", "not a directory")
    expect MigrationError: discard generateMigration(blocked, "createTasks")
    check readFile(blocked / "db") == "not a directory"
    check not dirExists(blocked / "target")

    let symlinkedMigrations = base / "symlinked-migrations"
    createDir(symlinkedMigrations / "db")
    createSymlink(outside, symlinkedMigrations / "db" / "migrations")
    expect MigrationError: discard generateMigration(symlinkedMigrations, "createTasks")
    expect MigrationError:
      discard generateMigration(symlinkedMigrations, "createTasks", dryRun = true)
    check toSeq(walkDirRec(outside)).len == 0

    let symlinkedTarget = base / "symlinked-target"
    createDir(symlinkedTarget)
    createSymlink(outside, symlinkedTarget / "target")
    expect MigrationError: discard generateMigration(symlinkedTarget, "createTasks")
    check toSeq(walkDirRec(outside)).len == 0

  test "two generator processes allocate distinct versions":
    let tools = base / "tools"
    writeProbeFiles(tools, @[("generate.nim", childSource)])
    let child = buildProbe(tools, "generate.nim", base / "tools-cache", "generate")
    check child.code == 0
    if child.code != 0:
      checkpoint(child.output)
    else:
      let root = base / "processes"
      createDir(root)
      let first = startProcess(child.binary, args = @[root, "alphaTask"],
        options = {poStdErrToStdOut})
      let second = startProcess(child.binary, args = @[root, "betaTask"],
        options = {poStdErrToStdOut})
      let firstCode = first.waitForExit()
      let secondCode = second.waitForExit()
      first.close()
      second.close()
      check firstCode == 0
      check secondCode == 0
      let files = scanMigrationFiles(root / "db" / "migrations")
      check files.len == 2
      check files[0].version != files[1].version
      check files[0].name != files[1].name

  test "a concurrent same-name generator refuses the second writer":
    let tools = base / "tools-same"
    writeProbeFiles(tools, @[("generate.nim", childSource)])
    let child = buildProbe(tools, "generate.nim", base / "tools-same-cache", "generate")
    check child.code == 0
    if child.code != 0:
      checkpoint(child.output)
    else:
      let root = base / "same-name"
      createDir(root)
      let first = startProcess(child.binary, args = @[root, "createTasks"],
        options = {poStdErrToStdOut})
      let second = startProcess(child.binary, args = @[root, "createTasks"],
        options = {poStdErrToStdOut})
      let firstCode = first.waitForExit()
      let secondCode = second.waitForExit()
      first.close()
      second.close()
      check (firstCode == 0) != (secondCode == 0)
      check scanMigrationFiles(root / "db" / "migrations").len == 1
