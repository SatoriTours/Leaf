## Build-time project configuration and resource paths. No interpreter is used.
import std/[os, json, strutils, tables, unicode]
import ./core
when defined(windows): import ./windows_paths

const
  MainTemplate = staticRead("templates/main.nim")
  AppTemplate = staticRead("templates/app.nim")

type
  PlatformConfig* = object
    binary*, icon*: string
  Project* = object
    root*, entry*, entryRelative*, name*, identifier*, version*, configFile*: string
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
    if field notin ["name", "identifier", "version", "entry", "include", "platforms"]:
      fail("unknown project field: " & field)
  for field in ["name", "identifier", "version", "entry"]:
    if field notin config or config[field].kind != JString or config[field].getStr.len == 0:
      fail("missing or invalid project field: " & field)
  result = Project(root: realPath(root), name: config["name"].getStr,
    identifier: config["identifier"].getStr, version: config["version"].getStr,
    configFile: realPath(configPath), entryRelative: config["entry"].getStr)
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
      if target notin ["linux", "macos", "windows"]: fail("unknown platform: " & target)
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

proc initProject*(path: string) =
  if fileExists(path) or dirExists(path): fail("refusing to overwrite existing project: " & path)
  let config = newProjectConfig(path.normalizedPath.extractFilename, "src/main.nim", @["src", "assets"])
  createDir(path / "src")
  createDir(path / "assets")
  writeFile(path / "leaf.json", pretty(config) & "\n")
  writeFile(path / "assets" / "message.txt", "多文件应用 · 资源随发布包迁移\n")
  writeFile(path / "src" / "main.nim", MainTemplate)
  writeFile(path / "src" / "app.nim", AppTemplate)
