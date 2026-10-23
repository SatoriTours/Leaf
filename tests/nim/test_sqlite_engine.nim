## Default and explicit dynamic library configurations must share one engine.
## Pointer guards precede all calls that borrow a Leaf connection/statement.
import std/[unittest, os, tempfiles]
import ./cleanup_support
import leaf/[sqlite, sqlite_native]
import leaf/model/adapters/norm_sqlite
import norm/[model, pragmas]
import db_connector/sqlite3 as connector
import lowdb/wrappers/sqlite3 as lowraw

when defined(windows):
  const ExpectedLibrary {.strdefine.} = "winsqlite3.dll"
elif defined(macosx):
  const ExpectedLibrary {.strdefine.} = "libsqlite3.dylib"
else:
  const ExpectedLibrary {.strdefine.} = "libsqlite3.so(|.0)"
proc expectedVersion(): cint
  {.cdecl, dynlib: ExpectedLibrary, importc: "sqlite3_libversion_number".}

proc expectedDbHandle(statement: connector.PStmt): connector.PSqlite3
  {.cdecl, dynlib: ExpectedLibrary, importc: "sqlite3_db_handle".}

type EngineRecord {.tableName: "engine_records".} = ref object of Model
  title: string

let directory = createTempDir("leaf-sqlite-engine-", "")
removeDirectoryOnExit(directory)

suite "one configured SQLite engine":
  test "both ORM bindings resolve the Leaf engine before borrowing handles":
    check cast[pointer](libraryVersionNumber) == cast[pointer](expectedVersion)
    check cast[pointer](connector.libversion_number) == cast[pointer](expectedVersion)
    check cast[pointer](lowraw.db_handle) == cast[pointer](expectedDbHandle)

  test "connector statement belongs to the original Leaf connection":
    require cast[pointer](libraryVersionNumber) == cast[pointer](expectedVersion)
    require cast[pointer](connector.libversion_number) == cast[pointer](expectedVersion)
    require cast[pointer](lowraw.db_handle) == cast[pointer](expectedDbHandle)
    let db = openDatabase(":memory:")
    defer: db.close()
    let handle = cast[connector.PSqlite3](db.borrowSqliteHandle())
    var statement: connector.PStmt
    require connector.prepare_v2(handle, "SELECT 42", -1, statement, nil) == 0
    require statement != nil
    defer: discard connector.finalize(statement)
    check expectedDbHandle(statement) == handle
    check lowraw.db_handle(statement) == handle
    require connector.step(statement) == connector.SQLITE_ROW
    check connector.column_int64(statement, 0) == 42

  test "Norm preserves 64-bit identity and binary UTF8 across close and reopen":
    require cast[pointer](libraryVersionNumber) == cast[pointer](expectedVersion)
    require cast[pointer](connector.libversion_number) == cast[pointer](expectedVersion)
    require cast[pointer](lowraw.db_handle) == cast[pointer](expectedDbHandle)
    let path = directory / "数据" / "notes.sqlite3"
    var db = openDatabase(path)
    db.executeScript("CREATE TABLE engine_records(id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE);")
    discard db.execute("INSERT INTO engine_records(id,title) VALUES(?,?)",
      @[dbValue(4_999_999_999'i64), dbValue("seed")])
    var row = EngineRecord(title: "中文😀'\0tail")
    db.executeScript("BEGIN")
    db.insertStorage(row)
    check row.id == 5_000_000_000'i64
    db.executeScript("COMMIT")
    db.close()
    db = openDatabase(path)
    defer: db.close()
    let rows = selectStorage[EngineRecord](db,
      "SELECT title,id FROM engine_records WHERE id=?", @[dbValue(row.id)])
    require rows.len == 1
    check rows[0].id == row.id
    check rows[0].title == row.title
    var duplicate = EngineRecord(title: row.title)
    expect ConstraintError: db.insertStorage(duplicate)
    db.executeScript("BEGIN")
    var undone = EngineRecord(title: "rolled back")
    db.insertStorage(undone)
    db.executeScript("ROLLBACK")
    check db.query("SELECT count(*) FROM engine_records WHERE title=?",
      @[dbValue(undone.title)])[0][0].asInt == 0
