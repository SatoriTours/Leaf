## Windows database contract. Compare resolved entry points before handing an
## owned Leaf connection or statement to either ORM binding.
when not defined(windows):
  {.error: "This test requires a real Windows process".}

import std/[unittest, os, tempfiles]
import ../nim/cleanup_support
import leaf/[sqlite, sqlite_native]
import leaf/model/adapters/norm_sqlite
import norm/[model, pragmas]
import db_connector/sqlite3 as connector
import lowdb/wrappers/sqlite3 as lowraw

proc windowsDbHandle(statement: connector.PStmt): connector.PSqlite3
  {.cdecl, dynlib: "winsqlite3.dll", importc: "sqlite3_db_handle".}

type WindowsRecord {.tableName: "windows_records".} = ref object of Model
  title: string

let directory = createTempDir("leaf-windows-sqlite-", "")
removeDirectoryOnExit(directory)

suite "Windows one SQLite engine":
  test "both ORM bindings resolve the Leaf engine before borrowing handles":
    check cast[pointer](libraryVersionNumber) == cast[pointer](connector.libversion_number)
    check cast[pointer](lowraw.db_handle) == cast[pointer](windowsDbHandle)

  test "connector statement belongs to the original Leaf connection":
    require cast[pointer](libraryVersionNumber) == cast[pointer](connector.libversion_number)
    require cast[pointer](lowraw.db_handle) == cast[pointer](windowsDbHandle)
    let db = openDatabase(":memory:")
    defer: db.close()
    let handle = cast[connector.PSqlite3](db.borrowSqliteHandle())
    var statement: connector.PStmt
    require connector.prepare_v2(handle, "SELECT 42", -1, statement, nil) == 0
    require statement != nil
    defer: discard connector.finalize(statement)
    check windowsDbHandle(statement) == handle
    check lowraw.db_handle(statement) == handle
    require connector.step(statement) == connector.SQLITE_ROW
    check connector.column_int64(statement, 0) == 42

  test "Norm preserves 64-bit identity and binary UTF8 across close and reopen":
    require cast[pointer](libraryVersionNumber) == cast[pointer](connector.libversion_number)
    require cast[pointer](lowraw.db_handle) == cast[pointer](windowsDbHandle)
    let path = directory / "数据" / "notes.sqlite3"
    var db = openDatabase(path)
    db.executeScript("CREATE TABLE windows_records(id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE);")
    discard db.execute("INSERT INTO windows_records(id,title) VALUES(?,?)",
      @[dbValue(4_999_999_999'i64), dbValue("seed")])
    var row = WindowsRecord(title: "中文😀'\0tail")
    db.executeScript("BEGIN")
    db.insertStorage(row)
    check row.id == 5_000_000_000'i64
    db.executeScript("COMMIT")
    db.close()
    db = openDatabase(path)
    defer: db.close()
    let rows = selectStorage[WindowsRecord](db,
      "SELECT title,id FROM windows_records WHERE id=?", @[dbValue(row.id)])
    require rows.len == 1
    check rows[0].id == row.id
    check rows[0].title == row.title
    var duplicate = WindowsRecord(title: row.title)
    expect ConstraintError: db.insertStorage(duplicate)
    db.executeScript("BEGIN")
    var undone = WindowsRecord(title: "rolled back")
    db.insertStorage(undone)
    db.executeScript("ROLLBACK")
    check db.query("SELECT count(*) FROM windows_records WHERE title=?",
      @[dbValue(undone.title)])[0][0].asInt == 0
