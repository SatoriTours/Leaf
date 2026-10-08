## Pure CLI parser contract: no project resolution, no filesystem IO.
import std/[options, unittest]
import leaf/[cli_options, core, migrations]

suite "CLI option parsing":
  test "current project commands reject selectors but preserve event values":
    check parseCli(@["build"]).kind == ccBuild
    check parseCli(@["g", "scaffold"]).kind == ccScaffoldApp
    check parseCli(@["--headless", "--change", "title", "--project"]).runArgs[^1] == "--project"
    expect UiError: discard parseCli(@["build", "."])
    expect UiError: discard parseCli(@["db", "migrate", "--project", "."])
    expect UiError: discard parseCli(@["build", "app"])
    expect UiError: discard parseCli(@["g", "scaffold", "Note", "title:string", "--project"])

  test "commands and defaults":
    check parseCli(@[]).kind == ccRun
    check parseCli(@["--help"]).kind == ccHelp
    check parseCli(@["-h"]).kind == ccHelp
    check parseCli(@["--version"]).kind == ccVersion
    check parseCli(@["-v"]).kind == ccVersion
    let verify = parseCli(@["--verify-sdk", "stable", "linux"])
    check verify.kind == ccVerifySdk
    check verify.sdkArgs == @["stable", "linux"]
    check parseCli(@["init", "app"]).initDirectory == "app"
    check parseCli(@["doctor"]).kind == ccDoctor
    check parseCli(@["doctor", "--json"]).jsonOutput
    check parseCli(@["g", "scaffold", "--dry-run"]).kind == ccScaffoldApp
    check parseCli(@["g", "scaffold", "--dry-run"]).dryRun
    let resource = parseCli(@["g", "scaffold", "Note", "title:string"])
    check resource.kind == ccScaffoldResource
    check resource.scaffold.target == "Note"
    let migration = parseCli(@["g", "migration", "add_users", "--dry-run"])
    check migration.kind == ccMigrationGenerate
    check migration.migrationName == "add_users"
    check migration.dryRun
    check parseCli(@["generate", "migration", "add_users"]).kind == ccMigrationGenerate
    check parseCli(@["build"]).kind == ccBuild
    check parseCli(@["build", "--output", "out"]).output == "out"
    let pack = parseCli(@["pack", "--target", "linux", "--binary", "bin", "--output", "dist"])
    check pack.kind == ccPack
    check pack.target == "linux"
    check pack.binary == "bin"
    check pack.output == "dist"
    check parseCli(@["--watch"]).watching
    check parseCli(@["--watch"]).kind == ccDeveloper

  test "database commands and version semantics":
    check parseCli(@["db", "init"]).databaseInit
    check parseCli(@["db", "init", "--dry-run"]).dryRun
    let status = parseCli(@["db", "status", "--json"])
    check status.kind == ccDatabase
    check status.request.kind == mrStatus
    check status.jsonOutput
    let migrate = parseCli(@["db", "migrate", "--to", "0", "--json"])
    check migrate.request.kind == mrMigrate
    check migrate.request.target == some(0'i64)
    check migrate.jsonOutput
    check parseCli(@["db", "migrate"]).request.target.isNone
    let rollback = parseCli(@["db", "rollback"])
    check rollback.request.kind == mrRollback
    check rollback.request.steps == 1
    check parseCli(@["db", "rollback", "--steps", "3"]).request.steps == 3
    check parseCli(@["db", "forward", "--steps", "2"]).request.kind == mrForward
    let up = parseCli(@["db", "up", "12"])
    check up.request.kind == mrUp
    check up.request.target == some(12'i64)
    check parseCli(@["db", "down", "7"]).request.kind == mrDown

  test "rejections are explicit":
    for args in [@["--version", "extra"], @["init"], @["init", "a", "b"], @["g"],
        @["g", "unknown"], @["g", "migration"], @["g", "migration", "n", "--json"],
        @["build", "--output"], @["build", "--output", "a", "b"], @["doctor", "--nope"],
        @["pack", "--target"], @["pack", "--target", "all", "--binary", "b"],
        @["pack", "--target", "solaris"], @["db"], @["db", "unknown"],
        @["db", "init", "--json"], @["db", "status", "--dry-run"],
        @["db", "migrate", "--to"], @["db", "migrate", "--to", "-1"],
        @["db", "migrate", "--to", "1.5"], @["db", "migrate", "--steps", "2"],
        @["db", "rollback", "--steps", "0"], @["db", "rollback", "--steps", "x"],
        @["db", "up"], @["db", "up", "0"], @["db", "up", "--to", "3"],
        @["db", "migrate", "--to", "99999999999999999999999999"],
        @["--change", "title"], @["--change", "title", "value", "--nope"],
        @["--change", "title", "value"], @["--watch", "--change", "x", "y"],
        @["--watch", "--headless"], @["--headless", "--headless"],
        @["--log-file"], @["--log-file", "a", "--log-file", "b"], @["unknown"],
        @["build", "--project", "x"]]:
      expect UiError:
        discard parseCli(args)

  test "event arity consumes option-shaped values":
    let command = parseCli(@["--headless", "--list", "key", "--project", "--headless",
      "--change", "title", "value", "--stats"])
    check command.kind == ccRun
    check command.runArgs == @["--headless", "--list", "key", "--project", "--headless",
      "--change", "title", "value", "--stats"]
    let repeated = parseCli(@["--headless", "--change", "a", "1", "--change", "b", "2"])
    check repeated.runArgs == @["--headless", "--change", "a", "1", "--change", "b", "2"]
