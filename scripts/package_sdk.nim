## Assemble a relocatable developer SDK with the bundled Nim archive writers.
import std/[os, strutils, json, tempfiles, algorithm, parseopt, tables, sets]
import ../src/leaf/[archives, checksum, licenses]

const RepositoryRoot* = currentSourcePath().parentDir.parentDir
const SdkTargets* = ["linux-x86_64", "macos-x86_64", "macos-aarch64", "windows-x86_64"]
type PackageOptions* = object
  nimRoot*, cli*, bridge*, output*, target*, channel*, version*, commit*: string
  root*: string

proc bridgeName*(target: string): string =
  case target
  of "linux-x86_64": "libleaf_gpui.so"
  of "macos-x86_64", "macos-aarch64": "libleaf_gpui.dylib"
  of "windows-x86_64": "leaf_gpui.dll"
  else: raise newException(ValueError, "unsupported SDK target: " & target)

proc releaseVersion(version: string): bool =
  if not version.startsWith('v'): return false
  let parts = version[1..^1].split('.')
  if parts.len != 3: return false
  for part in parts:
    if part.len == 0 or not part.allCharsInSet({'0'..'9'}): return false
  true

proc copyTree(source, destination: string, ancestors: HashSet[string] = initHashSet[string]()) =
  # Materialize linked inputs so
  # archives remain relocatable and contain regular files, even for Nim libraries.
  let resolved = expandFilename(source)
  if resolved in ancestors: raise newException(ValueError, "SDK input contains a directory link cycle: " & source)
  var visited = ancestors
  visited.incl(resolved)
  createDir(destination)
  for kind, path in walkDir(source):
    let target = destination / path.extractFilename
    case kind
    of pcDir, pcLinkToDir: copyTree(path, target, visited)
    of pcFile, pcLinkToFile: copyFileWithPermissions(path, target)

proc packageSdk*(options: PackageOptions): string =
  let root = if options.root.len > 0: options.root else: RepositoryRoot
  let windows = options.target.startsWith("windows")
  let executable = if windows: ".exe" else: ""
  let library = bridgeName(options.target)
  if options.channel notin ["release", "beta"]:
    raise newException(ValueError, "channel must be release or beta")
  for path in [options.cli, options.bridge, options.nimRoot / ("bin/nim" & executable),
               options.nimRoot / "lib/system.nim", options.nimRoot / "config/nim.cfg"]:
    if not fileExists(path): raise newException(ValueError, "SDK input is missing: " & path)
  if options.channel == "release" and not releaseVersion(options.version):
    raise newException(ValueError, "release version must be vX.Y.Z")
  if options.commit.len notin 6..40 or not options.commit.allCharsInSet({'0'..'9', 'a'..'f'}):
    raise newException(ValueError, "commit must be a Git SHA")
  verifyOrmSources(root / "src")
  createDir(options.output)
  let temporary = createTempDir("leaf-sdk-package-", "")
  defer: removeDir(temporary)
  let sdk = temporary / "leaf-sdk"
  for directory in ["bin", "lib", "toolchain/nim/bin", "licenses"]: createDir(sdk / directory)
  copyFileWithPermissions(options.cli, sdk / ("bin/leaf" & executable))
  copyFileWithPermissions(options.bridge, sdk / "lib" / library)
  copyTree(root / "src", sdk / "src")
  copyFileWithPermissions(root / "LICENSE", sdk / "LICENSE")
  copyFileWithPermissions(options.nimRoot / ("bin/nim" & executable), sdk / ("toolchain/nim/bin/nim" & executable))
  for directory in ["lib", "config"]: copyTree(options.nimRoot / directory, sdk / "toolchain/nim" / directory)
  collectLicenses(sdk / "licenses")
  let vendor = root / "src/leaf/vendor"
  for filename in ["Nim-LICENSE.txt", "GPUI-NOTICES.json", "provenance.json"]:
    copyFileWithPermissions(vendor / filename, sdk / "licenses" / filename)
  writeFile(sdk / "sdk.json", (%*{
    "schema": 1, "version": options.version, "channel": options.channel,
    "commit": options.commit, "target": options.target, "nim_version": "2.2.6"
  }).pretty & "\n")
  writeFile(sdk / "licenses/SDK-SOURCES.txt",
    "Leaf: https://github.com/SatoriTours/Leaf\n" &
    "Nim 2.2.6 (MIT): https://nim-lang.org/download/nim-2.2.6.tar.xz\n" &
    "ORM sources, MIT licenses and pinned commits: see orm/lock.json and inventory.json\n" &
    "GPUI and dependencies: see GPUI-NOTICES.json and src/leaf/vendor\n" &
    "Windows installer downloads MinGW directly from https://nim-lang.org/download/mingw64.7z\n" &
    "OS graphics libraries, C compiler on Unix and platform runtimes are system prerequisites.\n")
  var entries = @[ArchiveEntry(source: sdk, name: "leaf-sdk", directory: true)]
  var paths: seq[string]
  for path in walkDirRec(sdk, yieldFilter = {pcFile, pcDir}): paths.add(path)
  paths.sort()
  for path in paths:
    let directory = dirExists(path)
    entries.add(ArchiveEntry(source: path, name: "leaf-sdk/" & relativePath(path, sdk).replace('\\', '/'),
      directory: directory, executable: not directory and fpUserExec in getFilePermissions(path)))
  let extension = if windows: ".zip" else: ".tar.gz"
  result = options.output / ("leaf-sdk-" & options.target & extension)
  if windows: writeZip(entries, result)
  else: writeTarGzip(entries, result)
  writeFile(result & ".sha256", sha256File(result) & "  " & result.extractFilename & "\n")

proc parsePackageOptions*(arguments: seq[string]): PackageOptions =
  var values = initTable[string, string]()
  var parser = initOptParser(arguments)
  while true:
    parser.next()
    case parser.kind
    of cmdEnd: break
    of cmdLongOption:
      if parser.key notin ["nim-root", "cli", "bridge", "output", "target", "channel", "version", "commit"]:
        raise newException(ValueError, "unknown option: --" & parser.key)
      let option = parser.key
      var value = parser.val
      if value.len == 0:
        parser.next()
        if parser.kind != cmdArgument: raise newException(ValueError, "missing value for --" & option)
        value = parser.key
      values[option] = value
    else: raise newException(ValueError, "unexpected argument: " & parser.key)
  for key in ["nim-root", "cli", "bridge", "output", "target", "channel", "version", "commit"]:
    if key notin values: raise newException(ValueError, "required option: --" & key)
  PackageOptions(nimRoot: values["nim-root"], cli: values["cli"], bridge: values["bridge"],
    output: values["output"], target: values["target"], channel: values["channel"],
    version: values["version"], commit: values["commit"])

when isMainModule:
  if "--help" in commandLineParams() or "-h" in commandLineParams():
    echo "Usage: package_sdk --nim-root PATH --cli PATH --bridge PATH --output PATH --target TARGET --channel {release,beta} --version VERSION --commit SHA"
  else:
    try: echo packageSdk(parsePackageOptions(commandLineParams()))
    except CatchableError as error:
      stderr.writeLine("SDK packaging failed: " & error.msg)
      quit(1)
