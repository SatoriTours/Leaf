## Pure migration file identity parsing and direct-directory scanning. No
## filesystem recursion, no symlink following, no database access.
import std/[algorithm, options, os, strutils, tables]
import ./types
import ../core

type
  MigrationFile* = object
    version*: int64
    name*: string
    sourcePath*: string
    upPath*: string
    downPath*: string
    format*: MigrationFormat

proc parseMigrationIdentity*(filename: string): tuple[version: int64, name: string] =
  ## Parse `<version>_<snake_case_name>` out of a Nim or SQL migration filename.
  ## The version is a positive int64; leading zeros are accepted (old `001_...`).
  var base = extractFilename(filename)
  for suffix in [".up.sql", ".down.sql", ".sql", ".nim"]:
    if base.endsWith(suffix):
      base = base[0 ..< base.len - suffix.len]
      break
  let separator = base.find('_')
  if separator <= 0 or separator == base.len - 1:
    fail("migration file must be named <version>_<snake_case_name>: " & filename)
  let versionText = base[0 ..< separator]
  let name = base[separator + 1 .. ^1]
  var version: int64
  for c in versionText:
    if c notin {'0'..'9'}:
      fail("migration version must be a positive integer: " & filename)
    let digit = int64(ord(c) - ord('0'))
    if version > (high(int64) - digit) div 10:
      fail("migration version is out of range: " & filename)
    version = version * 10 + digit
  if version <= 0:
    fail("migration version must be positive: " & filename)
  if name.len == 0 or name[0] notin {'a'..'z'}:
    fail("migration name must be snake_case: " & filename)
  for c in name:
    if c notin {'a'..'z', '0'..'9', '_'}:
      fail("migration name must be snake_case: " & filename)
  if name[^1] == '_' or "__" in name:
    fail("migration name must be snake_case: " & filename)
  result = (version: version, name: name)

proc identityOrFail(path, filename: string): tuple[version: int64, name: string] =
  try:
    parseMigrationIdentity(filename)
  except UiError as error:
    raise migrationError("invalid_migration_name", error.msg)

proc pathIsSymlink*(path: string): bool =
  ## VM-compatible symlink detection: `walkDir` reports link components while
  ## `symlinkExists`/`getFileInfo` are FFI and unavailable at compile time.
  let normalized = normalizedPath(path)
  let parent = normalized.parentDir
  if parent.len == 0 or not dirExists(parent): return false
  for kind, entry in walkDir(parent, relative = false):
    if kind in {pcLinkToFile, pcLinkToDir} and normalizedPath(entry) == normalized:
      return true
  false

proc looksLikeMigration(filename: string): bool =
  ## Helper files (README.md, .gitkeep, notes.txt) are ignored; anything with a
  ## numeric version prefix and an unknown suffix is a rejected migration.
  let stem = filename.split('.')[0]
  let separator = stem.find('_')
  if separator <= 0: return false
  for c in stem[0 ..< separator]:
    if c notin {'0'..'9'}: return false
  true

proc scanMigrationFiles*(directory: string): seq[MigrationFile] =
  ## List the direct migration files of `directory`, sorted by version.
  let normalized = normalizedPath(directory)
  if fileExists(normalized) and not dirExists(normalized):
    raise migrationError("invalid_migration_directory",
      "migration path is not a directory: " & directory)
  if not dirExists(normalized): return @[]
  if pathIsSymlink(normalized):
    raise migrationError("symlink_migration",
      "migration directory cannot be a symbolic link: " & directory)
  var ups: seq[MigrationFile]
  var downs: Table[string, string]
  for kind, path in walkDir(normalized, relative = false):
    if kind in {pcLinkToFile, pcLinkToDir}:
      raise migrationError("symlink_migration",
        "migration cannot be a symbolic link: " & path)
    if kind != pcFile: continue
    let filename = extractFilename(path)
    if filename.endsWith(".nim"):
      let identity = identityOrFail(path, filename)
      ups.add MigrationFile(version: identity.version, name: identity.name,
        sourcePath: path, upPath: path, downPath: "", format: mfNimV1)
    elif filename.endsWith(".up.sql"):
      let stem = filename[0 ..< filename.len - ".up.sql".len]
      let identity = identityOrFail(path, stem & ".nim")
      ups.add MigrationFile(version: identity.version, name: identity.name,
        sourcePath: path, upPath: path, downPath: "", format: mfSqlV1)
    elif filename.endsWith(".down.sql"):
      downs[filename[0 ..< filename.len - ".down.sql".len]] = path
    elif filename.endsWith(".sql"):
      let stem = filename[0 ..< filename.len - ".sql".len]
      let identity = identityOrFail(path, stem & ".nim")
      ups.add MigrationFile(version: identity.version, name: identity.name,
        sourcePath: path, upPath: path, downPath: "", format: mfSqlV1)
    elif looksLikeMigration(filename):
      raise migrationError("unknown_migration_suffix",
        "unknown migration file suffix: " & path)
  for index in 0 ..< ups.len:
    let filename = extractFilename(ups[index].upPath)
    if filename.endsWith(".up.sql"):
      let stem = filename[0 ..< filename.len - ".up.sql".len]
      if downs.hasKey(stem):
        ups[index].downPath = downs[stem]
        downs.del(stem)
  for stem, path in downs:
    var version = 0'i64
    try:
      version = parseMigrationIdentity(stem & ".nim").version
    except UiError:
      discard
    for up in ups:
      if up.version == version:
        raise migrationError("mismatched_migration_pair",
          "down migration " & path & " does not match up migration " & up.upPath)
    raise migrationError("orphan_migration_down",
      "down migration has no matching up file: " & path)
  var byVersion: Table[int64, string]
  var byName: Table[string, string]
  for file in ups:
    if byVersion.hasKey(file.version):
      let error = migrationError("duplicate_migration_version",
        "duplicate migration version " & $file.version & ": " & byVersion[file.version] &
        " and " & file.upPath)
      error.migrationVersion = some(file.version)
      error.file = file.upPath
      raise error
    byVersion[file.version] = file.upPath
    if byName.hasKey(file.name):
      let error = migrationError("duplicate_migration_name",
        "duplicate migration name " & file.name & ": " & byName[file.name] &
        " and " & file.upPath)
      error.migrationVersion = some(file.version)
      error.file = file.upPath
      raise error
    byName[file.name] = file.upPath
  result = ups
  result.sort(proc(left, right: MigrationFile): int = cmp(left.version, right.version))
