## CI: run the platform's actual installer, relocated SDK smoke and failed update.
import std/[os, tempfiles, strutils, uri, parseopt, tables]
import ./[package_sdk, smoke_sdk]

type VerifyOptions* = object
  target*, channel*, version*, root*: string
  headlessOnly*: bool

proc fileUrl*(path: string): string =
  var value = absolutePath(path).replace('\\', '/')
  if not value.startsWith('/'): value = "/" & value
  "file://" & encodeUrl(value, usePlus = false).replace("%2F", "/").replace("%3A", ":")

proc verifySdkInstall*(options: VerifyOptions) =
  let root = if options.root.len > 0: options.root else: RepositoryRoot
  let base = createTempDir("leaf install ", "")
  defer: removeDir(base)
  let mirror = base / "downloads"
  let location = mirror / "releases" / (if options.channel == "beta": "download/beta" else: "latest/download")
  copyDir(root / "dist/sdk", location)
  let prefix = base / "SDK 中文 with spaces"
  let binDir = base / "commands"
  var command, entry: string
  var arguments: seq[string]
  when defined(windows):
    let toolchains = mirror / "toolchains"
    createDir(toolchains)
    for filename in ["mingw64.7z", "mingw64.7z.sha256", "7zr.exe"]:
      copyFile(getEnv("RUNNER_TEMP") / "leaf-mingw" / filename, toolchains / filename)
    command = "pwsh"
    arguments = @["-NoProfile", "-File", root / "install.ps1", "-Channel", options.channel,
      "-Prefix", prefix, "-BinDir", binDir, "-DownloadBase", fileUrl(mirror), "-NoPath"]
    entry = binDir / "leaf.cmd"
  else:
    command = "sh"
    arguments = @[root / "install.sh", "--channel", options.channel, "--prefix", prefix,
      "--bin-dir", binDir, "--download-base", fileUrl(mirror), "--no-path"]
    entry = binDir / "leaf"
  stdout.write(checkedCommand(command, arguments))
  let output = checkedCommand(entry, @["--version"])
  if options.version notin output or options.channel notin output:
    raise newException(ValueError, "installed version/channel mismatch: " & output)
  var sdk = ""
  for kind, path in walkDir(prefix / "versions"):
    if not path.extractFilename.startsWith('.'):
      sdk = path
      break
  if sdk.len == 0: raise newException(ValueError, "installed SDK version is missing")
  smokeSdk(sdk, options.headlessOnly)
  stdout.write(checkedCommand(command, arguments))
  let before = when defined(windows): readFile(entry) else: expandSymlink(entry)
  when defined(windows):
    let extractor = mirror / "toolchains/7zr.exe"
    let original = readFile(extractor)
    writeFile(extractor, "broken extractor")
    let rejected = runCommand(command, arguments)
    stdout.write(rejected.output)
    if rejected.exitCode == 0 or before != readFile(entry):
      raise newException(ValueError, "corrupt extractor changed the previous installation")
    writeFile(extractor, original)
  let extension = when defined(windows): ".zip" else: ".tar.gz"
  writeFile(location / ("leaf-sdk-" & options.target & extension), "broken update")
  let failed = runCommand(command, arguments)
  stdout.write(failed.output)
  if failed.exitCode == 0: raise newException(ValueError, "corrupt SDK update unexpectedly succeeded")
  let after = when defined(windows): readFile(entry) else: expandSymlink(entry)
  if before != after or checkedCommand(entry, @["--version"]) != output:
    raise newException(ValueError, "failed update changed the previous installation")
  echo "Native installer, channel, relocation, repeat install and failed update verified"

proc parseVerifyOptions*(arguments: seq[string]): VerifyOptions =
  var values = initTable[string, string]()
  var parser = initOptParser(arguments)
  while true:
    parser.next()
    case parser.kind
    of cmdEnd: break
    of cmdLongOption:
      let option = parser.key
      if option == "headless-only":
        if parser.val.len > 0: raise newException(ValueError, "--headless-only takes no value")
        result.headlessOnly = true
      else:
        if option notin ["target", "channel", "version"]: raise newException(ValueError, "unknown option: --" & option)
        var value = parser.val
        if value.len == 0:
          parser.next()
          if parser.kind != cmdArgument: raise newException(ValueError, "missing value for --" & option)
          value = parser.key
        values[option] = value
    else: raise newException(ValueError, "unexpected argument: " & parser.key)
  for key in ["target", "channel", "version"]:
    if key notin values: raise newException(ValueError, "required option: --" & key)
  result.target = values["target"]
  result.channel = values["channel"]
  result.version = values["version"]

when isMainModule:
  if "--help" in commandLineParams() or "-h" in commandLineParams():
    echo "Usage: verify_sdk_install --target TARGET --channel CHANNEL --version VERSION [--headless-only]"
  else:
    try: verifySdkInstall(parseVerifyOptions(commandLineParams()))
    except CatchableError as error:
      stderr.writeLine("SDK installation verification failed: " & error.msg)
      quit(1)
