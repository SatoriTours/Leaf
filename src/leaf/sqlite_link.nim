## Every binding shares both the dynamic library choice and the bundled link.
## Android always uses the app-private engine; the define supports native tests.
const BundledSqliteEnabled* = defined(android) or defined(leafBundledSqlite)
const DefaultSqliteLibrary = when defined(windows): "winsqlite3.dll"
  elif defined(macosx): "libsqlite3.dylib"
  else: "libsqlite3.so(|.0)"
const leafOrmSqliteLibrary {.strdefine.} = DefaultSqliteLibrary
const SqliteDynamicLibrary* = leafOrmSqliteLibrary
when BundledSqliteEnabled:
  {.compile: "vendor/sqlite/leaf_sqlite.c".}
