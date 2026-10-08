## Migration template generation: UTC millisecond versions, snake_case names,
## an owned generation lock and zero-write dry runs.
import std/[os, strutils, times]
import ./files
import ./locking
import ../core
import ../scaffold_files
import ./types

const
  MigrationsRelative = "db/migrations"
  GenerationLockRelative* = "target/leaf-migration-generation.lock"
  # Same list as scaffold_types.Keywords: a generated template must never emit
  # `migration <keyword>:`, which the DSL rejects at compile time.
  NimKeywords = ["addr", "and", "as", "asm", "bind", "block", "break", "case",
    "cast", "concept", "const", "continue", "converter", "defer", "discard",
    "distinct", "div", "do", "elif", "else", "end", "enum", "except", "export",
    "finally", "for", "from", "func", "if", "import", "in", "include", "interface",
    "is", "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "nil",
    "not", "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref",
    "return", "shl", "shr", "static", "template", "try", "tuple", "type", "using",
    "var", "when", "while", "xor", "yield"]

proc migrationName*(name: string): string =
  ## Same CamelCase/acronym boundary rule as `scaffold_types.snake`, then the
  ## stricter migration-name validation (ASCII snake_case, positive identity).
  for index, c in name:
    if c in {'A'..'Z'} and index > 0 and name[index-1] != '_' and
        (name[index-1] in {'a'..'z', '0'..'9'} or
          (index + 1 < name.len and name[index+1] in {'a'..'z'})):
      result.add('_')
    result.add(c.toLowerAscii)
  if result.len == 0 or result[0] notin {'a'..'z'} or result[^1] == '_' or "__" in result:
    raise migrationError("invalid_migration_name", "invalid migration name: " & name)
  for c in result:
    if c notin {'a'..'z', '0'..'9', '_'}:
      raise migrationError("invalid_migration_name", "invalid migration name: " & name)
  if result in NimKeywords:
    raise migrationError("invalid_migration_name",
      "migration name is a Nim keyword: " & name)

proc utcVersion(now: Time): int64 =
  ## UTC `yyyyMMddHHmmssfff` as a positive int64. The explicit year bound keeps
  ## the arithmetic safe in release builds instead of relying on overflow checks.
  let date = now.utc
  if date.year < 1 or date.year > 9999:
    raise migrationError("migration_version_overflow",
      "UTC year is outside the yyyyMMddHHmmssfff range: " & $date.year)
  int64(date.year) * 10_000_000_000_000'i64 +
    int64(ord(date.month)) * 100_000_000_000'i64 +
    int64(date.monthday) * 1_000_000_000'i64 +
    int64(date.hour) * 10_000_000'i64 +
    int64(date.minute) * 100_000'i64 +
    int64(date.second) * 1_000'i64 +
    int64(date.nanosecond) div 1_000_000

proc nextMigrationVersion*(files: openArray[MigrationFile], now: Time): int64 =
  ## Maximum of the UTC clock version and the largest discovered version + 1.
  let clock = utcVersion(now)
  var maximum = 0'i64
  for file in files:
    if file.version > maximum: maximum = file.version
  if maximum == high(int64):
    raise migrationError("migration_version_overflow",
      "cannot allocate a migration version after high(int64)")
  max(clock, maximum + 1)

proc pendingTemplate(name: string): string =
  "import leaf/migrations\n\nmigration " & name & ":\n  change:\n    pending()\n"

proc checkNameAvailable(files: openArray[MigrationFile], name: string) =
  for file in files:
    if file.name == name:
      raise migrationError("duplicate_migration_name",
        "migration name already exists: " & file.upPath)

proc safePath(root, relative: string): string =
  ## guardedPath reports UiError; migration APIs expose MigrationError.
  try:
    guardedPath(root, relative)
  except UiError as error:
    raise migrationError("unsafe_migration_path", error.msg)

proc generateMigration*(root, name: string, dryRun = false): seq[string] =
  ## Create `<version>_<snake_case_name>.nim` with a pending() template, or
  ## return the planned path for a dry run without creating anything.
  let normalized = migrationName(name)
  let migrationDirectory = safePath(root, MigrationsRelative)
  let lockPath = safePath(root, GenerationLockRelative)
  if dirExists(lockPath):
    raise migrationError("invalid_lock_path", "generation lock path is a directory: " & lockPath)
  if dryRun:
    let existing = scanMigrationFiles(migrationDirectory)
    checkNameAvailable(existing, normalized)
    let version = nextMigrationVersion(existing, getTime())
    return @[migrationDirectory / ($version & "_" & normalized & ".nim")]
  createDir(lockPath.parentDir)
  let lock = acquireFileLock(lockPath)
  try:
    let existing = scanMigrationFiles(migrationDirectory)
    checkNameAvailable(existing, normalized)
    let version = nextMigrationVersion(existing, getTime())
    let target = migrationDirectory / ($version & "_" & normalized & ".nim")
    if fileExists(target) or dirExists(target):
      raise migrationError("migration_target_exists", "refusing to overwrite: " & target)
    createDir(migrationDirectory)
    writeFile(target, pendingTemplate(normalized))
    result = @[target]
  finally:
    lock.release()
