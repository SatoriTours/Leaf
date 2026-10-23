{.define: leafBundledSqlite.}
## The app-linked mode must use one private SQLite implementation across all
## bindings; matching public types alone is insufficient for borrowed handles.
import std/[unittest, os, tempfiles, strutils]
import ./cleanup_support
import leaf/[sqlite, sqlite_native, orm_config]
import leaf/model/adapters/norm_sqlite
import norm/[model, pragmas]
import db_connector/sqlite3 as connector
import lowdb/wrappers/sqlite3 as lowraw

proc directDbHandle(statement: connector.PStmt): connector.PSqlite3
  {.cdecl, importc: "sqlite3_db_handle".}

type BundledRecord {.tableName: "bundled_records".} = ref object of Model
  title: string

let directory = createTempDir("leaf-bundled-sqlite-", "")
removeDirectoryOnExit(directory)

suite "one bundled SQLite engine":
  test "all entry points resolve to the pinned implementation":
    let db = openDatabase(":memory:")
    defer: db.close()
    check db.query("SELECT sqlite_version()")[0][0].asString == "3.54.1"
    check libraryVersionNumber() == 3_054_001
    check connector.libversion_number() == 3_054_001
    check cast[pointer](libraryVersionNumber) == cast[pointer](connector.libversion_number)
    check cast[pointer](lowraw.db_handle) == cast[pointer](directDbHandle)
    check db.query("SELECT sqlite_compileoption_used('THREADSAFE=1')")[0][0].asInt == 1
    check db.query("SELECT sqlite_compileoption_used('OMIT_LOAD_EXTENSION')")[0][0].asInt == 1

  test "connector and lowdb keep the original Leaf owner handle":
    require cast[pointer](lowraw.db_handle) == cast[pointer](directDbHandle)
    require cast[pointer](libraryVersionNumber) == cast[pointer](connector.libversion_number)
    let db = openDatabase(":memory:")
    defer: db.close()
    let handle = cast[connector.PSqlite3](db.borrowSqliteHandle())
    var statement: connector.PStmt
    check connector.prepare_v2(handle, "SELECT 42", -1, statement, nil) == 0
    require statement != nil
    defer: discard connector.finalize(statement)
    check lowraw.db_handle(statement) == handle
    check directDbHandle(statement) == handle
    check connector.step(statement) == connector.SQLITE_ROW
    check connector.column_int64(statement, 0) == 42

  test "Norm shares transactions, Unicode, constraints and 64-bit persistent identity":
    require cast[pointer](libraryVersionNumber) == cast[pointer](connector.libversion_number)
    let path = directory / "app-data/records.sqlite3"
    var db = openDatabase(path)
    db.executeScript("CREATE TABLE bundled_records(id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE);")
    discard db.execute("INSERT INTO bundled_records(id,title) VALUES(?,?)",
      @[dbValue(4_999_999_999'i64), dbValue("seed")])
    var row = BundledRecord(title: "中文😀'\0tail")
    db.executeScript("BEGIN")
    db.insertStorage(row)
    check row.id == 5_000_000_000'i64
    check db.lastInsertId64 == row.id
    db.executeScript("COMMIT")
    db.close()
    db = openDatabase(path)
    defer: db.close()
    check db.query("SELECT title FROM bundled_records WHERE id=?", @[dbValue(row.id)])[0][0].asString == row.title
    let mapped = selectStorage[BundledRecord](db, "SELECT title,id FROM bundled_records WHERE id=?", @[dbValue(row.id)])
    require mapped.len == 1
    check mapped[0].title == row.title
    var duplicate = BundledRecord(title: row.title)
    expect ConstraintError: db.insertStorage(duplicate)
    db.executeScript("BEGIN")
    var undone = BundledRecord(title: "rollback")
    db.insertStorage(undone)
    db.executeScript("ROLLBACK")
    check db.query("SELECT count(*) FROM bundled_records WHERE title='rollback'")[0][0].asInt == 0

  test "Android compiler configuration selects the bundled engine":
    let args = ormCompilerArgs("/leaf/src", "android")
    check "-d:leafBundledSqlite" in args
    for argument in args:
      check not argument.startsWith("-d:leafOrmSqliteLibrary=")
