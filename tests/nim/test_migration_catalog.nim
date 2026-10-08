import ./cleanup_support
import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]
import leaf/migrations
import ./migration_compile_support

let base = createTempDir("leaf-migration-catalog-", "")
removeDirectoryOnExit(base)

const catalogSource = """
import leaf/migrations

discoverMigrations("migrations", applicationMigrations)
"""

const mainSource = """
import std/json
import db/catalog

let migrations = applicationMigrations()
var entries = newJArray()
for migration in migrations:
  entries.add(%*{"version": $migration.version, "name": migration.name,
    "format": $migration.format, "hasDown": migration.hasDown,
    "pending": migration.pending, "up": migration.legacyUp, "down": migration.legacyDown,
    "sourcePath": migration.sourcePath, "checksum": migration.sourceChecksum})
echo "count=", migrations.len
echo $entries
"""

proc nimMigration(name, table, column: string): string =
  "import leaf/migrations\n\nmigration " & name & ":\n  change:\n    createTable " &
    table & ":\n      string " & column & ", nullable = false\n"

proc catalogEntries(output: string): JsonNode =
  for line in output.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("["): return parseJson(trimmed)
  newJArray()

proc scanError(directory: string): string =
  try:
    discard scanMigrationFiles(directory)
    ""
  except MigrationError as error:
    error.msg

suite "migration catalog scanning":
  test "mixed Nim and SQL files sort numerically and keep legacy bytes":
    let directory = base / "mixed" / "migrations"
    createDir(directory)
    writeFile(directory / "README.md", "notes\n")
    writeFile(directory / ".gitkeep", "")
    writeFile(directory / "001_create_tasks.nim", nimMigration("create_tasks", "tasks", "title"))
    writeFile(directory / "20261008120000123_add_priority.up.sql",
      "CREATE TABLE priority (id INTEGER);\n")
    writeFile(directory / "20261008120000123_add_priority.down.sql", "DROP TABLE priority;\n")
    writeFile(directory / "002_notes.sql", "CREATE TABLE notes (id INTEGER);")
    let files = scanMigrationFiles(directory)
    check files.len == 3
    check files[0].version == 1'i64
    check files[0].name == "create_tasks"
    check files[0].format == mfNimV1
    check files[0].upPath == directory / "001_create_tasks.nim"
    check files[0].downPath == ""
    check files[1].version == 2'i64
    check files[1].name == "notes"
    check files[1].format == mfSqlV1
    check files[1].upPath.endsWith("002_notes.sql")
    check files[1].downPath == ""
    check files[2].version == 20261008120000123'i64
    check files[2].name == "add_priority"
    check files[2].upPath.endsWith("add_priority.up.sql")
    check files[2].downPath.endsWith("add_priority.down.sql")
    check readFile(files[2].upPath) == "CREATE TABLE priority (id INTEGER);\n"
    check readFile(files[2].downPath) == "DROP TABLE priority;\n"
    let fingerprint = catalogInputFingerprint(directory)
    check fingerprint.len == 64
    check catalogInputFingerprint(directory) == fingerprint
    let moved = base / "moved" / "migrations"
    createDir(moved.parentDir)
    copyDir(directory, moved)
    check catalogInputFingerprint(moved) == fingerprint
    writeFile(directory / "002_notes.sql", "CREATE TABLE notes (id INTEGER, body TEXT);")
    check catalogInputFingerprint(directory) != fingerprint

  test "invalid catalogs are rejected naming the conflicting files":
    proc caseDir(name: string): string =
      result = base / "invalid" / name
      createDir(result)

    var directory = caseDir("duplicate-version")
    writeFile(directory / "001_first.nim", nimMigration("first", "first", "title"))
    writeFile(directory / "001_second.nim", nimMigration("second", "second", "title"))
    var message = scanError(directory)
    check "001_first.nim" in message and "001_second.nim" in message

    directory = caseDir("duplicate-name")
    writeFile(directory / "001_create_tasks.nim", nimMigration("create_tasks", "tasks", "title"))
    writeFile(directory / "002_create_tasks.nim", nimMigration("create_tasks", "other", "title"))
    message = scanError(directory)
    check "001_create_tasks.nim" in message and "002_create_tasks.nim" in message

    directory = caseDir("orphan-down")
    writeFile(directory / "001_create_tasks.down.sql", "DROP TABLE tasks;")
    message = scanError(directory)
    check "001_create_tasks.down.sql" in message

    directory = caseDir("pair-mismatch")
    writeFile(directory / "001_alpha.up.sql", "CREATE TABLE alpha (id INTEGER);")
    writeFile(directory / "001_beta.down.sql", "DROP TABLE beta;")
    message = scanError(directory)
    check "001_alpha.up.sql" in message and "001_beta.down.sql" in message

    directory = caseDir("cross-format")
    writeFile(directory / "001_create_tasks.nim", nimMigration("create_tasks", "tasks", "title"))
    writeFile(directory / "001_create_tasks.up.sql", "CREATE TABLE tasks (id INTEGER);")
    message = scanError(directory)
    check "001_create_tasks.nim" in message and "001_create_tasks.up.sql" in message

    directory = caseDir("invalid-name")
    writeFile(directory / "001_CreateTasks.nim", nimMigration("CreateTasks", "tasks", "title"))
    message = scanError(directory)
    check "001_CreateTasks.nim" in message

    directory = caseDir("invalid-range")
    writeFile(directory / "000_zero.nim", nimMigration("zero", "zero", "title"))
    message = scanError(directory)
    check "000_zero.nim" in message

    directory = caseDir("unknown-suffix")
    writeFile(directory / "001_create_tasks.txt", "CREATE TABLE tasks (id INTEGER);")
    message = scanError(directory)
    check "001_create_tasks.txt" in message

    when defined(posix):
      directory = caseDir("symlink-file")
      writeFile(base / "outside.nim", nimMigration("outside", "outside", "title"))
      createSymlink(base / "outside.nim", directory / "001_linked.nim")
      message = scanError(directory)
      check "001_linked.nim" in message and "symbolic link" in message

      directory = caseDir("symlink-directory")
      createDir(base / "elsewhere")
      writeFile(base / "elsewhere" / "001_real.nim", nimMigration("real", "real", "title"))
      createSymlink(base / "elsewhere", directory / "linked")
      message = scanError(directory)
      check "linked" in message and "symbolic link" in message

suite "discoverMigrations catalog":
  test "compiles mixed migrations, embeds legacy SQL and survives source removal":
    let project = base / "catalog mixed"
    writeProbeFiles(project, @[
      ("db/catalog.nim", catalogSource),
      ("db/migrations/001_create_tasks.nim", nimMigration("create_tasks", "tasks", "title")),
      ("db/migrations/002_notes.up.sql", "CREATE TABLE notes (id INTEGER);\n"),
      ("db/migrations/002_notes.down.sql", "DROP TABLE notes;\n"),
      ("main.nim", mainSource)])
    let probe = buildProbe(project, "main.nim", project / "target" / "cache", "app")
    check probe.code == 0
    if probe.code != 0:
      checkpoint(probe.output)
    else:
      let first = runBinary(probe.binary, project)
      check first.code == 0
      check "count=2" in first.output
      let entries = catalogEntries(first.output)
      check entries.len == 2
      check entries[0]["name"].getStr == "create_tasks"
      check entries[0]["format"].getStr == "mfNimV1"
      check entries[0]["sourcePath"].getStr.endsWith("001_create_tasks.nim")
      check entries[0]["checksum"].getStr.len == 64
      check entries[1]["name"].getStr == "002_notes"
      check entries[1]["format"].getStr == "mfSqlV1"
      check entries[1]["up"].getStr == "CREATE TABLE notes (id INTEGER);\n"
      check entries[1]["down"].getStr == "DROP TABLE notes;\n"
      check entries[1]["hasDown"].getBool
      check not entries[1]["pending"].getBool
      check not fileExists(project / "application.sqlite3")
      check toSeq(walkFiles(project / "*.sqlite3")).len == 0
      let artifacts = toSeq(walkDirRec(project / "target" / "leaf-migrations"))
      check artifacts.len == 1
      check artifacts[0].endsWith("leaf_migration_1_create_tasks.nim")
      check not dirExists(project / "db" / "target")
      removeDir(project / "db" / "migrations")
      let second = runBinary(probe.binary, project)
      check second.code == 0
      check second.output == first.output

  test "catalog literals survive Unicode, spaces and dollar signs":
    let project = base / "路径 with $space" / "app"
    writeProbeFiles(project, @[
      ("db/catalog.nim", catalogSource),
      ("db/migrations/001_create_tasks.nim", nimMigration("create_tasks", "tasks", "title")),
      ("db/migrations/002_notes.up.sql", "CREATE TABLE notes (id INTEGER);\n"),
      ("main.nim", mainSource)])
    let probe = buildProbe(project, "main.nim", base / "unicode-cache", "app",
      base / "unicode-app")
    check probe.code == 0
    if probe.code != 0:
      checkpoint(probe.output)
    else:
      let run = runBinary(probe.binary, project)
      check run.code == 0
      check "count=2" in run.output
      check catalogEntries(run.output)[1]["up"].getStr == "CREATE TABLE notes (id INTEGER);\n"

  test "the same nimcache observes added and removed migrations":
    let project = base / "cache sequence"
    writeProbeFiles(project, @[
      ("db/catalog.nim", catalogSource),
      ("db/migrations/001_create_tasks.nim", nimMigration("create_tasks", "tasks", "title")),
      ("main.nim", mainSource)])
    let cache = project / "target" / "cache"
    let first = buildProbe(project, "main.nim", cache, "app-1")
    check first.code == 0
    if first.code != 0:
      checkpoint(first.output)
    else:
      check "count=1" in runBinary(first.binary, project).output
      writeFile(project / "db" / "migrations" / "002_notes.nim",
        nimMigration("notes", "notes", "body"))
      let second = buildProbe(project, "main.nim", cache, "app-2")
      check second.code == 0
      if second.code != 0:
        checkpoint(second.output)
      else:
        check "count=2" in runBinary(second.binary, project).output
        removeFile(project / "db" / "migrations" / "002_notes.nim")
        let third = buildProbe(project, "main.nim", cache, "app-3")
        check third.code == 0
        if third.code != 0:
          checkpoint(third.output)
        else:
          check "count=1" in runBinary(third.binary, project).output

  test "extra top-level code is rejected before it can run":
    let project = base / "protocol"
    writeProbeFiles(project, @[
      ("db/catalog.nim", catalogSource),
      ("main.nim", mainSource)])
    createDir(project / "db" / "migrations")
    let extras = [
      (label: "extra import", source: "import std/os\n"),
      (label: "top-level const", source: "const Extra = 1\n"),
      (label: "top-level discard", source: "discard 1\n"),
      (label: "conditional", source: "when defined(windows):\n  discard\n"),
      (label: "include", source: "include \"other.nim\"\n"),
      (label: "macro definition", source: "macro extra(): untyped =\n  result = newStmtList()\n"),
      (label: "second migration", source: "migration evil2:\n  change:\n    createTable other:\n      string title\n")]
    for extra in extras:
      writeFile(project / "db" / "migrations" / "001_evil.nim",
        "import leaf/migrations\n" & extra.source &
          "writeFile(\"sentinel-ran.txt\", \"ran\")\n" &
          "migration evil:\n  change:\n    createTable tasks:\n      string title\n")
      removeFile(project / "sentinel-ran.txt")
      let probe = buildProbe(project, "main.nim", project / "target" / "cache", "app")
      check probe.code != 0
      check "001_evil.nim" in probe.output
      check not fileExists(project / "sentinel-ran.txt")
      check not fileExists(getCurrentDir() / "sentinel-ran.txt")
    removeFile(project / "db" / "migrations" / "001_evil.nim")

  when defined(posix):
    test "catalog rejects symlinked migrations at compile time":
      let project = base / "symlink catalog"
      writeProbeFiles(project, @[
        ("db/catalog.nim", catalogSource),
        ("main.nim", mainSource)])
      writeFile(project / "outside.nim", nimMigration("outside", "outside", "title"))
      createDir(project / "db" / "migrations")
      createSymlink(project / "outside.nim", project / "db" / "migrations" / "001_linked.nim")
      let probe = buildProbe(project, "main.nim", project / "target" / "cache", "app")
      check probe.code != 0
      check "001_linked.nim" in probe.output
      check "symbolic link" in probe.output

  test "concurrent catalog builds with separate caches both succeed":
    let project = base / "concurrent"
    writeProbeFiles(project, @[
      ("db/catalog.nim", catalogSource),
      ("db/migrations/001_create_tasks.nim", nimMigration("create_tasks", "tasks", "title")),
      ("db/migrations/002_notes.up.sql", "CREATE TABLE notes (id INTEGER);\n"),
      ("main.nim", mainSource)])
    let first = startBuild(project, "main.nim", project / "target" / "cache-a", "app-a")
    let second = startBuild(project, "main.nim", project / "target" / "cache-b", "app-b")
    let firstCode = first.waitForExit()
    let secondCode = second.waitForExit()
    first.close()
    second.close()
    check firstCode == 0
    check secondCode == 0
    if firstCode == 0 and secondCode == 0:
      check "count=2" in runBinary(project / "app-a", project).output
      check "count=2" in runBinary(project / "app-b", project).output

  when defined(posix):
    test "catalog rejects a symlinked artifact target without writing outside":
      let project = base / "artifact symlink"
      writeProbeFiles(project, @[
        ("db/catalog.nim", catalogSource),
        ("db/migrations/001_create_tasks.nim", nimMigration("create_tasks", "tasks", "title")),
        ("main.nim", mainSource)])
      let outside = base / "artifact-outside"
      createDir(outside)
      createSymlink(outside, project / "target")
      let probe = buildProbe(project, "main.nim", base / "artifact-cache", "app")
      check probe.code != 0
      check "symbolic link" in probe.output
      check toSeq(walkDirRec(outside)).len == 0

suite "migration catalog fix round 1":
  test "fingerprint tracks the actual file names, not only identity":
    let directory = base / "fingerprint-rename" / "migrations"
    createDir(directory)
    writeFile(directory / "001_sample.up.sql", "CREATE TABLE sample (id INTEGER);")
    let before = catalogInputFingerprint(directory)
    moveFile(directory / "001_sample.up.sql", directory / "1_sample.up.sql")
    let after = catalogInputFingerprint(directory)
    check before != after
    let moved = base / "fingerprint-moved" / "migrations"
    createDir(moved.parentDir)
    copyDir(directory, moved)
    check catalogInputFingerprint(moved) == after
    writeFile(directory / "002_create_tasks.nim", nimMigration("create_tasks", "tasks", "title"))
    let nimBefore = catalogInputFingerprint(directory)
    moveFile(directory / "002_create_tasks.nim", directory / "2_create_tasks.nim")
    check catalogInputFingerprint(directory) != nimBefore

  when defined(posix):
    test "symlinked or broken migration paths are rejected":
      let root = base / "symlink paths"
      createDir(root)
      createSymlink(root / "absent", root / "broken")
      let brokenError = scanError(root / "broken")
      check "broken" in brokenError
      check "symbolic link" in brokenError
      let real = root / "real"
      createDir(real)
      writeFile(real / "001_sample.up.sql", "SELECT 1;")
      createSymlink(root, root / "ancestor")
      let ancestorError = scanError(root / "ancestor" / "real")
      check "ancestor" in ancestorError
      check "symbolic link" in ancestorError

    test "the artifact guard rejects a visible symlinked project root":
      let realProject = base / "guard real project"
      createDir(realProject)
      createSymlink(realProject, base / "guard aliased project")
      var message = ""
      try:
        rejectSymlinkPath(base / "guard aliased project")
      except MigrationError as error:
        message = error.msg
      check "symbolic link" in message
      check "guard aliased project" in message

    test "the compiler canonicalizes aliased project roots before macros run":
      # Evidence for the coordinator: `projectFull`, `projectPath` and module
      # lineInfo all report the real path, so a compile-time alias is invisible
      # and artifacts belong to the canonical project root.
      let realProject = base / "canonical real"
      writeProbeFiles(realProject, @[
        ("db/catalog.nim", catalogSource),
        ("db/migrations/001_create_tasks.nim", nimMigration("create_tasks", "tasks", "title")),
        ("main.nim", mainSource)])
      createSymlink(realProject, base / "canonical alias")
      let probe = buildProbe(base, "canonical alias/main.nim", base / "canonical-cache",
        "canonical-app")
      check probe.code == 0
      if probe.code != 0:
        checkpoint(probe.output)
      else:
        check toSeq(walkDirRec(realProject / "target" / "leaf-migrations")).len == 1

  test "catalog escapes quoted relative directories":
    let project = base / "quoted directory"
    writeProbeFiles(project, @[
      ("db/catalog.nim", """
import leaf/migrations

discoverMigrations("mig\"quoted", applicationMigrations)
"""),
      ("db/mig\"quoted/001_create_tasks.nim", nimMigration("create_tasks", "tasks", "title")),
      ("main.nim", mainSource)])
    let probe = buildProbe(project, "main.nim", project / "target" / "cache", "app")
    check probe.code == 0
    if probe.code != 0:
      checkpoint(probe.output)
    else:
      let run = runBinary(probe.binary, project)
      check run.code == 0
      check "count=1" in run.output

  when defined(posix):
    test "catalog escapes literal backslash relative directories":
      let project = base / "backslash directory"
      writeProbeFiles(project, @[
        ("db/catalog.nim", "import leaf/migrations\n\ndiscoverMigrations(\"mig\\\\slash\", applicationMigrations)\n"),
        ("db/mig\\slash/001_create_tasks.nim", nimMigration("create_tasks", "tasks", "title")),
        ("main.nim", mainSource)])
      let probe = buildProbe(project, "main.nim", project / "target" / "cache", "app")
      check probe.code == 0
      if probe.code != 0:
        checkpoint(probe.output)
      else:
        let run = runBinary(probe.binary, project)
        check run.code == 0
        check "count=1" in run.output
