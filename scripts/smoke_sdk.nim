## Verify a relocated SDK builds a SQLite application without checkout overrides.
import std/[os, osproc, strtabs, streams, json, tempfiles, strutils]
when defined(windows): import ../src/leaf/windows_paths

type CommandResult* = object
  output*: string
  exitCode*: int

proc processEnvironment*(): StringTableRef =
  result = newStringTable(when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  for key, value in envPairs(): result[key] = value

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
  result.output = process.outputStream.readAll()
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

proc smokeSdk*(sdkPath: string, headlessOnly = false) =
  let sdk = absolutePath(sdkPath)
  let cli = sdk / (when defined(windows): "bin/leaf.exe" else: "bin/leaf")
  let environment = processEnvironment()
  for key in ["NIM", "LEAF_LIBRARY", "LEAF_GPUI_ROOT", "LEAF_GPUI_LIBRARY"]: environment.del(key)
  let root = createTempDir("leaf sdk smoke ", "")
  defer: removeDir(root)
  let project = root / "smoke-app"
  environment["LEAF_DATABASE_PATH"] = root / "application.sqlite3"
  proc run(arguments: varargs[string]): string =
    checkedCommand(cli, @arguments, root, environment)
  stdout.write(run("--version"))
  let metadata = parseFile(sdk / "sdk.json")
  require(metadata["channel"].getStr in run("--version"), "SDK channel missing from version output")
  let report = parseJson(run("doctor", "--json"))
  require(within(report["nim"].getStr, sdk), "Nim is outside relocated SDK: " & $report)
  require(within(report["library"].getStr, sdk), "Leaf library is outside relocated SDK: " & $report)
  when defined(windows):
    require(within(report["cc"].getStr, sdk), "C compiler is outside relocated SDK: " & $report)
  if not headlessOnly: require(report["gpui"]["available"].getBool, "GPUI unavailable: " & $report["gpui"])
  discard run("g", "scaffold", project)
  discard run("g", "scaffold", "Note", "title:string", "archived:bool", "--project", project)
  discard run("--check", project)
  require(fileExists(root / "application.sqlite3"), "SQLite application database was not created")
  discard run("--check", project)
  let binary = project / (when defined(windows): "target/nim/app.exe" else: "target/nim/app")
  require(fileExists(binary), "Application binary was not created")
  echo "SDK relocation + SQLite scaffold build passed"

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
