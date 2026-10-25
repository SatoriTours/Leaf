## Developer CLI: native Nim applications are compiled before execution.
## Commands always operate on the current directory's nearest Leaf project;
## the old PROJECT position argument and `--project` selector are gone.
import std/[os, json, strtabs, options]
import leaf/android_run
import leaf/[cli_options, core, project, project_context, build, doctor,
  developer_options, diagnostics, process_io, pack, scaffold, sdk, db_cli,
  migrations, targets]
export build

const HelpText = """Leaf Nim developer tools
  leaf init DIRECTORY              Create a native Nim application
  leaf g scaffold [--dry-run]       Create a full page-group application in the cwd
  leaf g scaffold MODEL FIELD:TYPE... [--dry-run]
                                   Add a resource with CRUD pages, routes and migrations
  leaf g migration NAME [--dry-run] Create a Nim migration in the current project
  leaf generate ...                Alias for leaf g ...
  leaf build [--output EXE] [--target TARGET] [--backend native]
                                   Compile the current project
  leaf run [--target TARGET] [--backend native] [--device SERIAL]
                                   Compile and open the current project
  leaf pack --target TARGET [--binary EXE] [--output DIR] [--backend native]
  leaf doctor [--json] [--target TARGET] [--backend native]
                                   Show the local build environment
  leaf --version                   Show SDK version and channel
  leaf --check [DIAGNOSTICS]       Compile and validate the current application
  leaf --headless [EVENTS] [DIAGNOSTICS] [--stats]
                                   Compile and run ordered events
  leaf                             Compile and open the Windows system-native controls
  leaf --watch [DIAGNOSTICS]       Rebuild and replace ready desktop windows
  leaf db init [--dry-run]         Install database configuration and catalog
  leaf db migrate [--to VERSION] [--dry-run] [--json]
  leaf db rollback [--steps N] [--dry-run] [--json]
  leaf db forward [--steps N] [--dry-run] [--json]
  leaf db up VERSION [--dry-run] [--json]
  leaf db down VERSION [--dry-run] [--json]
  leaf db status [--json]
  DIAGNOSTICS: --trace, --log-file FILE, --dump-tree FILE

Commands operate on the nearest project containing leaf.json; run them from the
project directory or one of its subdirectories. Applications are native
executables. TARGET: linux, macos, windows, android; packaging: windows or android; Linux/macOS GUI is not implemented.
"""

proc execute(exe: string, args: seq[string], workingDir: string): int =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  env["LEAF_PROJECT_ROOT"] = workingDir
  beginInterruptHandling()
  defer: endInterruptHandling()
  let process = startManaged(exe, args, workingDir, env, parentStreams = true)
  defer: process.close()
  while not process.poll():
    if wasInterrupted(): raise newException(ProcessInterruptedError, "application interrupted")
    sleep(10)
  process.code

proc launch(project: Project, runArgs: seq[string], target = "", backend = "", device = ""): int =
  let options = parseDeveloperOptions(runArgs, project.root)
  let headless = "--headless" in options.remaining or "--check" in options.remaining
  let binary = build(project, selection = some(resolveBuild(project.backend,
    target, backend, headlessOnly = headless)))
  if target == "android":return runAndroid(project,binary,device)
  result = execute(binary, options.launchArgs(), project.root)

proc main*(args: seq[string]): int =
  try:
    let command = parseCli(args)
    case command.kind
    of ccHelp:
      stdout.write(HelpText)
      return 0
    of ccVersion:
      stdout.writeLine(sdkVersion())
      return 0
    of ccVerifySdk:
      verifySdk(command.sdkArgs[0], command.sdkArgs[1],
        if command.sdkArgs.len == 3: command.sdkArgs[2] else: "")
      return 0
    of ccInit:
      initProject(command.initDirectory)
      return 0
    of ccScaffoldApp:
      for action in generateScaffold(command.scaffold, getCurrentDir()):
        stdout.writeLine(action)
      return 0
    of ccScaffoldResource:
      for action in generateScaffold(command.scaffold, requireCurrentProject().root):
        stdout.writeLine(action)
      return 0
    of ccMigrationGenerate:
      for action in generateMigration(requireCurrentProject().root,
          command.migrationName, command.dryRun):
        stdout.writeLine(action)
      return 0
    of ccBuild:
      let project = requireCurrentProject()
      stdout.writeLine(build(project, command.output,
        some(resolveBuild(project.backend, command.target, command.backend))))
      return 0
    of ccPack:
      let project = requireCurrentProject()
      let binary = if command.binary.len > 0: absolutePath(command.binary) else: ""
      let output = if command.output.len > 0: command.output else: "dist"
      for artifact in pack.pack(project, command.target, output, binary, command.backend):
        stdout.writeLine(artifact)
      return 0
    of ccDoctor:
      stdout.writeLine(doctorReport(some(resolveBuild(backendNative,
        command.target, command.backend))).pretty())
      return 0
    of ccDatabase:
      let project = requireCurrentProject()
      if command.databaseInit: return executeDatabaseInit(project, command.dryRun)
      return executeDatabaseCommand(project, command.request, command.dryRun,
        command.jsonOutput)
    of ccDeveloper:
      fail("native --watch is not supported in this batch")
    of ccRun:
      if command.runArgs.len == 0:
        let found = findCurrentProject()
        if found.isNone:
          stdout.write(HelpText)
          return 0
        return launch(found.get(), command.runArgs, command.target, command.backend, command.device)
      return launch(requireCurrentProject(), command.runArgs, command.target, command.backend, command.device)
  except ProcessInterruptedError:
    result = 130
  except CatchableError as error:
    # A requested database JSON report must stay machine readable even when the
    # parser, project resolution or the compiler is what failed.
    if wantsDatabaseJson(args):
      stdout.writeLine(errorJson(databaseCommandName(args), "invalid_arguments", error.msg))
    else:
      stderr.writeLine("leaf: " & error.msg)
    result = 1

proc exitCli*(code: int) {.noreturn.} =
  # Nim quit saturates POSIX integers to int8; preserve conventional 130 and
  # the full 8-bit exit status returned by a supervised application.
  when defined(posix): quit(if code in 128..255: code - 256 else: code)
  else: quit(code)

when isMainModule: exitCli(main(commandLineParams()))
