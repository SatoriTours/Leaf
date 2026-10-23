## Build-time project configuration and resource paths. No interpreter is used.
import std/[os, json, strutils, tables, unicode]
import ./[core, targets]
export targets
when defined(windows): import ./windows_paths

const
  MainTemplate = staticRead("templates/main.nim")
  AppTemplate = staticRead("templates/app.nim")
  MobileTemplate = staticRead("templates/mobile.nim")
  LegacyMainTemplate = staticRead("templates/legacy_init/main.nim")
  LegacyAppTemplate = staticRead("templates/legacy_init/app.nim")

type
  PlatformConfig* = object
    binary*, icon*: string
  AndroidProjectConfig* = object
    enabled*: bool
    entry*, entryRelative*: string
    minSdk*, targetSdk*, versionCode*: int
    abis*: seq[string]
  Project* = object
    root*, entry*, entryRelative*, name*, identifier*, version*, configFile*: string
    android*: AndroidProjectConfig
    backend*: BackendChoice
    includedPaths*: seq[string]
    platforms*: Table[string, PlatformConfig]

proc realPath*(path: string): string =
  when defined(windows): windows_paths.realPath(path)
  else: expandFilename(path)

proc portableRelative*(path: string): string =
  if path.len == 0 or validateUtf8(path) != -1 or isAbsolute(path):
    fail("expected portable relative path: " & path)
  for part in path.split('/'):
    if part.len == 0 or part in [".", ".."] or part.endsWith('.') or part.endsWith(' '):
      fail("expected portable relative path: " & path)
    for c in part:
      if ord(c) < 32 or ord(c) == 127 or c in {'\\', ':', '*', '?', '"', '<', '>', '|'}:
        fail("filename is not portable: " & path)
    for rune in part.runes:
      if int(rune) in 127..159: fail("filename contains a control character: " & path)
    let stem = part.split('.')[0].toUpperAscii()
    if stem in ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]:
      fail("filename is reserved: " & path)
  path

proc slug*(project: Project): string = project.identifier.split('.')[^1]

proc within*(root, path: string): bool =
  var base = normalizedPath(absolutePath(root))
  var full = normalizedPath(absolutePath(path))
  when defined(windows):
    base = base.toLowerAscii()
    full = full.toLowerAscii()
  full == base or full.startsWith(base & DirSep)

proc resolve*(root, relative: string, mustExist = true): string =
  discard portableRelative(relative)
  result = normalizedPath(absolutePath(root / relative))
  if not within(root, result): fail("project path escapes root: " & relative)
  if mustExist:
    if not fileExists(result) and not dirExists(result): fail("missing project path: " & relative)
    # Canonicalize existing symlinks so resources cannot escape via an alias.
    let canonicalRoot = realPath(root)
    let canonicalPath = realPath(result)
    if not within(canonicalRoot, canonicalPath): fail("project symlink escapes root: " & relative)
    result = canonicalPath

proc readAndroid(project: Project, settings: JsonNode): AndroidProjectConfig =
  if settings.kind != JObject: fail("Android settings must be an object")
  for field in settings.keys:
    if field notin ["entry", "minSdk", "targetSdk", "versionCode", "abis"]:
      fail("unknown Android field: " & field)
  if "entry" notin settings or settings["entry"].kind != JString:
    fail("Android requires an explicit Nim entry")
  result = AndroidProjectConfig(enabled: true, entryRelative: settings["entry"].getStr,
    minSdk: 26, targetSdk: 36, versionCode: 1, abis: @["arm64-v8a", "x86_64"])
  if not result.entryRelative.endsWith(".nim"): fail("Android entry must end in .nim")
  result.entry = resolve(project.root, result.entryRelative)
  if not fileExists(result.entry): fail("Android entry must be a regular file")
  var included = false
  for item in project.includedPaths:
    if result.entryRelative == item or result.entryRelative.startsWith(item & "/"):
      included = true
  if not included: fail("Android entry is missing from include")
  for field in ["minSdk", "targetSdk", "versionCode"]:
    if field notin settings: continue
    let value = settings[field]
    let maximum = if field == "versionCode": 2_100_000_000'i64 else: 1000'i64
    let minimum = if field == "versionCode": 1'i64 else: 26'i64
    if value.kind != JInt or value.getBiggestInt < minimum or value.getBiggestInt > maximum:
      fail("invalid Android " & field)
    case field
    of "minSdk": result.minSdk = int(value.getBiggestInt)
    of "targetSdk": result.targetSdk = int(value.getBiggestInt)
    else: result.versionCode = int(value.getBiggestInt)
  if result.targetSdk < result.minSdk: fail("Android targetSdk must be >= minSdk")
  if "abis" in settings:
    if settings["abis"].kind != JArray or settings["abis"].len == 0:
      fail("Android abis must be a nonempty array")
    result.abis = @[]
    for abi in settings["abis"]:
      if abi.kind != JString or abi.getStr notin ["arm64-v8a", "x86_64"] or abi.getStr in result.abis:
        fail("unknown or repeated Android ABI")
      result.abis.add(abi.getStr)
  # Package names become source-level Kotlin and Java identifiers.
  for part in project.identifier.split('.'):
    if '-' in part or part in ["abstract", "as", "assert", "boolean", "break", "byte", "case", "catch",
        "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends",
        "false", "final", "finally", "float", "for", "fun", "goto", "if", "implements", "import",
        "in", "instanceof", "int", "interface", "is", "long", "native", "new", "null", "object",
        "package", "private", "protected", "public", "return", "short", "static", "strictfp",
        "super", "switch", "synchronized", "this", "throw", "throws", "transient", "true", "try",
        "typealias", "typeof", "val", "var", "void", "volatile", "when", "while"]:
      fail("Android identifier is not a Kotlin-safe package name")

proc readProject*(path: string): Project =
  let absolute = absolutePath(path)
  if fileExists(absolute) and absolute.endsWith(".nim"):
    return Project(root: absolute.parentDir, entry: absolute,
      entryRelative: absolute.extractFilename,
      name: absolute.extractFilename.changeFileExt(""), identifier: "org.leaf.app", version: "0.1.0")
  let root = if dirExists(absolute): absolute else: absolute.parentDir
  let configPath = if dirExists(absolute): root / "leaf.json" else: absolute
  let config = parseFile(configPath)
  if config.kind != JObject: fail("leaf.json must contain an object")
  for field in config.keys:
    if field notin ["name", "identifier", "version", "entry", "include", "platforms", "backend"]:
      fail("unknown project field: " & field)
  for field in ["name", "identifier", "version", "entry"]:
    if field notin config or config[field].kind != JString or config[field].getStr.len == 0:
      fail("missing or invalid project field: " & field)
  result = Project(root: realPath(root), name: config["name"].getStr,
    identifier: config["identifier"].getStr, version: config["version"].getStr,
    configFile: realPath(configPath), entryRelative: config["entry"].getStr)
  if "backend" in config:
    if config["backend"].kind != JString: fail("backend must be a string")
    result.backend = parseBackend(config["backend"].getStr)
  if '/' in result.name: fail("invalid application name")
  discard portableRelative(result.name)
  let components = result.identifier.split('.')
  if components.len < 2: fail("identifier must be a reverse DNS name")
  for component in components:
    if component.len == 0 or not component[0].isAlphaAscii: fail("identifier must be a reverse DNS name")
    for c in component:
      if not c.isAlphaNumeric or ord(c) > 127:
        if c != '-': fail("identifier must be a reverse DNS name")
  discard portableRelative(result.slug)
  let version = result.version.split('.')
  if version.len != 3: fail("version must be MAJOR.MINOR.PATCH")
  for component in version:
    if component.len == 0: fail("version must be MAJOR.MINOR.PATCH")
    var value: uint64
    for c in component:
      if c notin {'0'..'9'}: fail("version must be MAJOR.MINOR.PATCH")
      value = value * 10 + uint64(ord(c) - ord('0'))
      if value > uint64(high(uint32)): fail("version component exceeds uint32")
  if not result.entryRelative.endsWith(".nim"): fail("Nim project entry must end in .nim")
  result.entry = resolve(result.root, result.entryRelative)
  if not fileExists(result.entry): fail("Nim entry must be a regular file")
  if "include" in config:
    if config["include"].kind != JArray: fail("include must be an array")
    for item in config["include"]:
      if item.kind != JString: fail("include paths must be strings")
      discard resolve(result.root, item.getStr)
      result.includedPaths.add(item.getStr)
  if result.includedPaths.len == 0: fail("include must list application files/directories")
  var included = false
  for path in result.includedPaths:
    if result.entryRelative == path or result.entryRelative.startsWith(path & "/"): included = true
  if not included: fail("entry is missing from include; add its directory")
  if "platforms" in config:
    if config["platforms"].kind != JObject: fail("platforms must be an object")
    for target, settings in config["platforms"]:
      if target notin ["linux", "macos", "windows", "android"]: fail("unknown platform: " & target)
      if target == "android":
        result.android = readAndroid(result, settings)
        continue
      if settings.kind != JObject: fail("platform settings must be an object")
      var platform: PlatformConfig
      for field, value in settings:
        if field notin ["binary", "icon"]: fail("unknown platform field: " & field)
        if value.kind != JString or value.getStr.len == 0: fail("invalid platform field: " & field)
        if field == "binary":
          platform.binary = value.getStr
          if '\0' in platform.binary: fail("invalid binary path")
        else:
          platform.icon = portableRelative(value.getStr)
      result.platforms[target] = platform

proc asset*(relative: string): string =
  ## Packaged programs keep assets beside the executable. Developers can set
  ## LEAF_PROJECT_ROOT; changing the working directory does not affect lookup.
  var root = getEnv("LEAF_PROJECT_ROOT")
  if root.len == 0:
    root = getAppDir()
    for candidate in [root / "app", root.parentDir / "app", root.parentDir / "Resources" / "app"]:
      if fileExists(candidate / "leaf.json"):
        root = candidate
        break
  resolve(root / "assets", relative)

proc newProjectConfig*(name, entry: string, included: seq[string]): JsonNode =
  ## Shared manifest naming for the minimal init and full application scaffold.
  discard portableRelative(name)
  var slug = ""
  for c in name:
    slug.add(if c.isAlphaNumeric and ord(c) < 128: c.toLowerAscii else: '-')
  if slug.len == 0 or not slug[0].isAlphaAscii: slug = "app-" & slug
  %*{"name": name, "identifier": "org.example." & slug,
    "version": "0.1.0", "entry": entry, "include": included}

proc mobileProjectConfig*(name, entry, mobileEntry: string, included: seq[string]): JsonNode =
  ## New templates share one Android-safe identifier across desktop and mobile.
  result = newProjectConfig(name, entry, included)
  result["identifier"] = %result["identifier"].getStr.replace("-", "")
  result["platforms"] = %*{"android": {"entry": mobileEntry}}

proc matchesMinimalTemplate*(root: string): bool =
  ## Recognize complete, byte-exact old or new init templates for safe upgrades.
  let name = absolutePath(root).extractFilename
  for relative in ["leaf.json", "assets/message.txt", "src/main.nim", "src/app.nim"]:
    if not fileExists(root / relative): return false
  if readFile(root / "assets/message.txt") != "多文件应用 · 资源随发布包迁移\n": return false
  let legacy = readFile(root / "leaf.json") ==
    pretty(newProjectConfig(name, "src/main.nim", @["src", "assets"])) & "\n" and
    readFile(root / "src/main.nim") == LegacyMainTemplate and
    readFile(root / "src/app.nim") == LegacyAppTemplate
  if legacy: return true
  readFile(root / "leaf.json") ==
    pretty(mobileProjectConfig(name, "src/main.nim", "src/mobile.nim", @["src", "assets"])) & "\n" and
    readFile(root / "src/main.nim") == MainTemplate and
    readFile(root / "src/app.nim") == AppTemplate and
    fileExists(root / "src/mobile.nim") and readFile(root / "src/mobile.nim") == MobileTemplate

proc initProject*(path: string) =
  if fileExists(path) or dirExists(path): fail("refusing to overwrite existing project: " & path)
  let config = mobileProjectConfig(path.normalizedPath.extractFilename,
    "src/main.nim", "src/mobile.nim", @["src", "assets"])
  createDir(path / "src")
  createDir(path / "assets")
  writeFile(path / "leaf.json", pretty(config) & "\n")
  writeFile(path / "assets" / "message.txt", "多文件应用 · 资源随发布包迁移\n")
  writeFile(path / "src" / "main.nim", MainTemplate)
  writeFile(path / "src" / "app.nim", AppTemplate)
  writeFile(path / "src" / "mobile.nim", MobileTemplate)
