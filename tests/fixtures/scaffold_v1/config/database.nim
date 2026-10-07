## Importing configuration does not open storage; application startup does.
import std/os
import leaf/sqlite
import ../app/generated/migrations
export sqlite

proc databasePath*(): string =
  getEnv("LEAF_DATABASE_PATH", getDataDir() / "scaffold_v1" / "application.sqlite3")

proc openApplicationDatabase*(path = databasePath()): Database =
  result = openDatabase(path)
  try:
    result.migrate(generatedMigrations())
  except CatchableError:
    result.close()
    raise
