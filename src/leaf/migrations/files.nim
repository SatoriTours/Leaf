## Pure migration file identity parsing. Discovery scanning (Task 3) reuses it;
## this module intentionally performs no filesystem access.
import std/[os, strutils]
import ../core

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
