## Verify a relocated SDK builds a SQLite application without checkout overrides.
import std/[os, osproc, strtabs, streams, json, tempfiles, strutils]
when defined(windows): import ../src/leaf/windows_paths

import ../src/leaf/orm_config

type CommandResult* = object
  output*: string
  exitCode*: int

proc processEnvironment*(): StringTableRef =
  result = newStringTable(when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  for key, value in envPairs(): result[key] = value

proc readCommandOutput*(stream: Stream): string =
  # A Windows pipe can return a nonzero short read while its child is still
  # writing. Drain until actual EOF before waiting for the process to exit.
  var buffer: array[4096,char]
  while true:
    let received=stream.readData(addr buffer[0],buffer.len)
    if received==0:break
    let previous=result.len
    result.setLen(previous+received)
    copyMem(addr result[previous],addr buffer[0],received)

proc runCommand*(command: string, arguments: seq[string] = @[], workingDir = "",
                 environment: StringTableRef = nil): CommandResult =
  var executable = command
  var parameters = arguments
  when defined(windows):
    if command.toLowerAscii.endsWith(".cmd") or command.toLowerAscii.endsWith(".bat"):
      # CreateProcess cannot execute batch entrypoints directly. The installer
      # already requires PowerShell, whose literal quoting preserves SDK paths.
      proc literal(value: string): string = "'" & value.replace("'", "''") & "'"
      var invocation = "& " & literal(command)
      for argument in arguments: invocation.add(" " & literal(argument))
      invocation.add("; exit $LASTEXITCODE")
      executable = "pwsh"
      parameters = @["-NoProfile", "-Command", invocation]
  let process = startProcess(executable, workingDir = workingDir, args = parameters,
    env = environment, options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  result.output = readCommandOutput(process.outputStream)
  result.exitCode = process.waitForExit()

proc checkedCommand*(command: string, arguments: seq[string] = @[], workingDir = "",
                     environment: StringTableRef = nil): string =
  let executed = runCommand(command, arguments, workingDir, environment)
  if executed.exitCode != 0:
    raise newException(IOError, "Command failed (" & $executed.exitCode & "): " & command &
      " " & arguments.join(" ") & "\n" & executed.output)
  executed.output

proc require(condition: bool, message: string) =
  if not condition: raise newException(ValueError, message)

proc within*(path, directory: string): bool =
  try:
    # Resolve both ends: macOS /var aliases and Windows junctions refer to
    # existing SDK files, while a link inside the SDK may really escape it.
    when defined(windows):
      let full = windows_paths.realPath(path)
      let base = windows_paths.realPath(directory)
    else:
      let full = expandFilename(path)
      let base = expandFilename(directory)
    let relative = relativePath(full, base)
    result = not relative.isAbsolute and relative != ".." and not relative.startsWith(".." & DirSep)
  except OSError:
    result = false

proc isolatedFixtureCommand*(sdk, project, test: string): tuple[exe: string, args: seq[string]] =
  ## Standalone fixture compile against SDK-relative paths only. On Windows the
  ## bundled ANSI MinGW toolchain cannot open Unicode SDK directories, so reuse
  ## the product build's short-path aliases for every path it consumes.
  var sources = sdk / "src"
  var cache = project / "target/isolated-cache"
  var output = project / "target" / test.addFileExt(ExeExt)
  var entry = project / "tests" / (test & ".nim")
  result.exe = sdk / "toolchain/nim/bin" / "nim".addFileExt(ExeExt)
  when defined(windows):
    result.exe = windows_paths.compilerPath(result.exe)
    sources = windows_paths.compilerPath(sources)
    cache = windows_paths.compilerPath(cache)
    output = windows_paths.compilerPath(output)
    entry = windows_paths.compilerPath(entry)
  result.args = @["c", "-r", "--threads:on", "--skipUserCfg:on", "--skipParentCfg:on", "--skipProjCfg:on", "--noNimblePath",
    "--path:" & sources.replace("$", "$$"), "--nimcache:" & cache.replace("$", "$$"), "--out:" & output.replace("$", "$$")]
  for argument in ormCompilerArgs(sources): result.args.add(argument.replace("$", "$$"))
  when defined(windows):
    # The relocated SDK ships MinGW at toolchain/mingw; never let the smoke
    # fall back to the runner's global gcc.
    let gcc = windows_paths.compilerPath(sdk / "toolchain/mingw/bin/gcc".addFileExt(ExeExt))
    require(fileExists(gcc), "bundled SDK gcc is missing: " & gcc)
    let configuredGcc = gcc.replace("$", "$$")
    result.args.add(@["--cc:gcc", "--gcc.exe:" & configuredGcc, "--gcc.linkerexe:" & configuredGcc])
  result.args.add(entry)

const sdkTaskFixtureSource* = """
import std/[os, monotimes, times]
import leaf/[core, widgets, components]
proc work(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} = input
var caption: State[string]
var disposed = 0
let Owner = defineComponent[int, State[string]]("SdkTaskFixture",
  proc(ctx: MountContext, p: int): State[string] =
    caption = ctx.state("loading")
    ctx.onMount(proc(e: LifecycleContext) =
      discard startTask(e.taskScope, "load", "后台完成", work,
        proc(value: string) = discard caption.set(value)))
    ctx.onDispose(proc(e: LifecycleContext) = inc disposed)
    caption,
  proc(ctx: ComponentContext, p: int, s: State[string]): UiDescription = host(text(ctx.value(s))))
let rt = newRuntime(componentApplication(component(Owner, 0), "SDK task"))
try:
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while caption.read() != "后台完成":
    discard rt.pumpTasks()
    doAssert getMonoTime() < deadline, "SDK task completion timeout"
    sleep(1)
  doAssert caption.read() == "后台完成"
  echo "SDK_TASK_RESULT=", caption.read()
finally:
  rt.closeRuntime()
doAssert disposed == 1
"""

proc smokeSdk*(sdkPath: string, headlessOnly = false) =
  let sdk = absolutePath(sdkPath)
  let cli = sdk / (when defined(windows): "bin/leaf.exe" else: "bin/leaf")
  let environment = processEnvironment()
  for key in ["NIM", "LEAF_LIBRARY", "LEAF_SDK"]: environment.del(key)
  let root = createTempDir("leaf sdk smoke ", "")
  defer: removeDir(root)
  let project = root / "smoke-app"
  environment["LEAF_DATABASE_PATH"] = root / "application.sqlite3"
  environment["NIMBLE_DIR"] = root / "empty-nimble"
  createDir(environment["NIMBLE_DIR"])
  createDir(project)
  proc run(arguments: varargs[string]): string =
    checkedCommand(cli, @arguments, project, environment)
  proc readList(directory, key: string, navigation: varargs[string]): string =
    var arguments = @["--headless"] & @navigation
    when defined(windows):
      # Native scaffold rows are lazy. Select a bounded viewport before using
      # the snapshot as the cross-process persistence oracle.
      arguments.add(@["--list", key, "0", "1"])
    checkedCommand(cli, arguments, directory, environment)
  stdout.write(run("--version"))
  let metadata = parseFile(sdk / "sdk.json")
  require(metadata["channel"].getStr in run("--version"), "SDK channel missing from version output")
  let report = parseJson(run("doctor", "--json"))
  require(within(report["nim"].getStr, sdk), "Nim is outside relocated SDK: " & $report)
  require(within(report["library"].getStr, sdk), "Leaf library is outside relocated SDK: " & $report)
  when defined(windows):
    require(within(report["cc"].getStr, sdk), "C compiler is outside relocated SDK: " & $report)
  if not headlessOnly: require(report["host_available"].getBool, "Native GUI host unavailable: " & $report)
  discard run("g", "scaffold")
  discard run("g", "scaffold", "Note", "title:string", "archived:bool")
  let preview = parseJson(run("db", "migrate", "--dry-run", "--json"))
  require(preview["executed"].len == 0, "Preview executed migrations")
  require(not fileExists(root / "application.sqlite3"), "Preview created storage")
  let applied = parseJson(run("db", "migrate", "--json"))
  require(applied["errors"].len == 0 and applied["executed"].len == 2, "Offline migrations failed")
  let settled = parseJson(run("db", "status", "--json"))
  require(settled["pending_versions"].len == 0, "Applied migrations remain pending")
  discard run("db", "rollback", "--json")
  discard run("db", "forward", "--json")
  discard run("--check")
  require(fileExists(root / "application.sqlite3"), "SQLite application database was not created")
  discard run("--check")
  let binary = project / (when defined(windows): "target/nim/app.exe" else: "target/nim/app")
  require(fileExists(binary), "Application binary was not created")
  let taskText = "SDK 中文持久化"
  discard run("--headless", "--change", "task_draft", taskText, "--click", "task_add")
  require(taskText in readList(project, "task_list"), "Task was not persisted across processes")
  let noteText = "SDK second model"
  discard run("--headless", "--click", "nav_notes", "--click", "notes_new",
    "--change", "notes_field_title", noteText, "--click", "notes_save")
  require(noteText in readList(project, "notes_list", "--click", "nav_notes"), "Note was not persisted")
  for test in ["test_home", "test_notes"]:
    let fixture = isolatedFixtureCommand(sdk, project, test)
    discard checkedCommand(fixture.exe, fixture.args, project, environment)
  # This fixture owns its explicit headless task pump; CLI --headless keeps
  # its existing synchronous semantics. Compile solely against relocated src.
  writeFile(project / "tests/test_component_tasks.nim", sdkTaskFixtureSource)
  let taskFixture = isolatedFixtureCommand(sdk, project, "test_component_tasks")
  let taskOutput = checkedCommand(taskFixture.exe, taskFixture.args, project, environment)
  require("SDK_TASK_RESULT=后台完成" in taskOutput, "relocated SDK worker did not deliver its result: " & taskOutput)
  echo "SDK_TASK_RESULT=后台完成 (relocated SDK, explicit pumpTasks)"
  let otherProject = root / "other-app"
  environment["LEAF_DATABASE_PATH"] = root / "other.sqlite3"
  createDir(otherProject)
  discard checkedCommand(cli, @["g", "scaffold"], otherProject, environment)
  discard checkedCommand(cli, @["--headless", "--change", "task_draft", "Independent application", "--click", "task_add"], otherProject, environment)
  require("Independent application" in readList(otherProject, "task_list"), "Second application did not persist")
  echo "SDK relocation + offline model CRUD and persistence passed"

when isMainModule:
  var sdk = ""
  var headlessOnly = false
  try:
    for argument in commandLineParams():
      case argument
      of "--headless-only": headlessOnly = true
      of "--help", "-h":
        echo "Usage: smoke_sdk SDK [--headless-only]"
        quit(0)
      else:
        if argument.startsWith('-') or sdk.len > 0: raise newException(ValueError, "unexpected argument: " & argument)
        sdk = argument
    if sdk.len == 0: raise newException(ValueError, "SDK path is required")
    smokeSdk(sdk, headlessOnly)
  except CatchableError as error:
    stderr.writeLine("SDK smoke failed: " & error.msg)
    quit(1)
