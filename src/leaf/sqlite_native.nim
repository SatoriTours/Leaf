## Small binding to SQLite's stable C API; no compiler headers are required.
import ./sqlite_link
const SQLiteLibrary = SqliteDynamicLibrary

type
  SqliteConnection* = object
  SqliteStatement* = object
  Authorizer* = proc(context: pointer, action: cint, first, second, database, trigger: cstring): cint {.cdecl.}
  ProgressHandler* = proc(context: pointer): cint {.cdecl.}

{.push cdecl.}
when not BundledSqliteEnabled:
  {.push dynlib: SQLiteLibrary.}
proc openConnection*(path: cstring, db: ptr ptr SqliteConnection, flags: cint, vfs: cstring): cint {.importc: "sqlite3_open_v2".}
proc closeConnection*(db: ptr SqliteConnection): cint {.importc: "sqlite3_close_v2".}
proc errorMessage*(db: ptr SqliteConnection): cstring {.importc: "sqlite3_errmsg".}
proc errorCode*(db: ptr SqliteConnection): cint {.importc: "sqlite3_errcode".}
proc extendedErrorCode*(db: ptr SqliteConnection): cint {.importc: "sqlite3_extended_errcode".}
proc busyTimeout*(db: ptr SqliteConnection, milliseconds: cint): cint {.importc: "sqlite3_busy_timeout".}
proc prepareStatement*(db: ptr SqliteConnection, sql: cstring, bytes: cint, statement: ptr ptr SqliteStatement, tail: ptr cstring): cint {.importc: "sqlite3_prepare_v2".}
proc finalizeStatement*(statement: ptr SqliteStatement): cint {.importc: "sqlite3_finalize".}
proc step*(statement: ptr SqliteStatement): cint {.importc: "sqlite3_step".}
proc parameterCount*(statement: ptr SqliteStatement): cint {.importc: "sqlite3_bind_parameter_count".}
proc bindNull*(statement: ptr SqliteStatement, index: cint): cint {.importc: "sqlite3_bind_null".}
proc bindInteger*(statement: ptr SqliteStatement, index: cint, value: int64): cint {.importc: "sqlite3_bind_int64".}
proc bindFloat*(statement: ptr SqliteStatement, index: cint, value: cdouble): cint {.importc: "sqlite3_bind_double".}
proc bindText*(statement: ptr SqliteStatement, index: cint, value: cstring, bytes: cint, destructor: pointer): cint {.importc: "sqlite3_bind_text".}
proc columnCount*(statement: ptr SqliteStatement): cint {.importc: "sqlite3_column_count".}
proc columnType*(statement: ptr SqliteStatement, index: cint): cint {.importc: "sqlite3_column_type".}
proc columnInteger*(statement: ptr SqliteStatement, index: cint): int64 {.importc: "sqlite3_column_int64".}
proc columnFloat*(statement: ptr SqliteStatement, index: cint): cdouble {.importc: "sqlite3_column_double".}
proc columnText*(statement: ptr SqliteStatement, index: cint): pointer {.importc: "sqlite3_column_text".}
proc columnBytes*(statement: ptr SqliteStatement, index: cint): cint {.importc: "sqlite3_column_bytes".}
proc changedRows*(db: ptr SqliteConnection): cint {.importc: "sqlite3_changes".}
proc insertId*(db: ptr SqliteConnection): int64 {.importc: "sqlite3_last_insert_rowid".}
proc executeScript*(db: ptr SqliteConnection, sql: cstring, callback, context, error: pointer): cint {.importc: "sqlite3_exec".}
proc setAuthorizer*(db: ptr SqliteConnection, callback: Authorizer, context: pointer): cint {.importc: "sqlite3_set_authorizer".}
proc databaseFilename*(db: ptr SqliteConnection, name: cstring): cstring {.importc: "sqlite3_db_filename".}
proc getAutocommit*(db: ptr SqliteConnection): cint {.importc: "sqlite3_get_autocommit".}
proc libraryVersionNumber*(): cint {.importc: "sqlite3_libversion_number".}
proc setProgressHandler*(db: ptr SqliteConnection, interval: cint, callback: ProgressHandler, context: pointer) {.importc: "sqlite3_progress_handler".}
when not BundledSqliteEnabled: {.pop.}
{.pop.}
