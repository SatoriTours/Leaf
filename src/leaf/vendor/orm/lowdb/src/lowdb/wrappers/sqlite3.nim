## Bindings that are not in ``std/sqlite3`` yet.

import leaf/sqlite_link
const Lib = SqliteDynamicLibrary

when NimMajor == 1 and NimMinor <= 7:
  import std/sqlite3
else:
  import db_connector/sqlite3

export sqlite3

when BundledSqliteEnabled:
  proc db_handle*(para1: Pstmt): PSqlite3 {.cdecl, importc: "sqlite3_db_handle".}
else:
  proc db_handle*(para1: Pstmt): PSqlite3 {.cdecl, dynlib: Lib, importc: "sqlite3_db_handle".}
