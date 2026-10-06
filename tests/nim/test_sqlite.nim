import ./cleanup_support
import std/[unittest, os, tempfiles]
import leaf/sqlite

let base = createTempDir("leaf-sqlite-", "")
removeDirectoryOnExit(base)

suite "SQLite storage":
  test "bound values preserve types and text without interpreting SQL":
    let db = openDatabase(":memory:")
    defer: db.close()
    db.executeScript("CREATE TABLE records (id INTEGER PRIMARY KEY, title TEXT, count INTEGER, amount REAL, done INTEGER);")
    let title = "中文 '); DROP TABLE records; --\0tail"
    discard db.execute("INSERT INTO records (title, count, amount, done) VALUES (?, ?, ?, ?)",
      @[dbValue(title), dbValue(-42), dbValue(1.25), dbValue(true)])
    let rows = db.query("SELECT title, count, amount, done FROM records WHERE id = ?", @[dbValue(1)])
    check rows.len == 1
    check rows[0][0].asString == title
    check rows[0][1].asInt == -42
    check rows[0][2].asFloat == 1.25
    check rows[0][3].asBool
    expect DatabaseError: discard db.execute("INSERT INTO records (title) VALUES (?)")
    expect DatabaseError: discard db.execute("DELETE FROM records; DROP TABLE records")
    check db.query("SELECT count(*) FROM records")[0][0].asInt == 1

  test "committed records survive closing and reopening a file database":
    let path = base / "nested/data.sqlite3"
    var db = openDatabase(path)
    db.executeScript("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL);")
    discard db.execute("INSERT INTO notes (title) VALUES (?)", @[dbValue("first")])
    check db.lastInsertId == 1
    db.close()
    expect DatabaseError: discard db.query("SELECT * FROM notes")
    db = openDatabase(path)
    defer: db.close()
    check db.query("SELECT title FROM notes")[0][0].asString == "first"
    check db.execute("UPDATE notes SET title = ? WHERE id = ?", @[dbValue("updated"), dbValue(1)]) == 1
    check db.execute("DELETE FROM notes WHERE id = ?", @[dbValue(99)]) == 0

  test "migrations run once in version order and reject changed history":
    let db = openDatabase(":memory:")
    defer: db.close()
    let migrations = @[
      Migration(version: 2, name: "add-note", sql: "INSERT INTO notes VALUES (1, 'one');"),
      Migration(version: 1, name: "notes", sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT);")]
    db.migrate(migrations)
    db.migrate(migrations)
    check db.query("SELECT title FROM notes")[0][0].asString == "one"
    expect DatabaseError:
      db.migrate(@[Migration(version: 1, name: "notes", sql: "CREATE TABLE other (id INTEGER);")])
    expect DatabaseError: db.migrate(@[migrations[0], migrations[0]])
    check db.query("SELECT count(*) FROM leaf_schema_migrations")[0][0].asInt == 2

  test "failed migration rolls back its statements and can be retried after repair":
    let db = openDatabase(":memory:")
    defer: db.close()
    expect DatabaseError:
      db.migrate(@[Migration(version: 1, name: "broken", sql:
        "CREATE TABLE partial (id INTEGER); INSERT INTO missing VALUES (1);")])
    check db.query("SELECT name FROM sqlite_master WHERE name = 'partial'").len == 0
    check db.query("SELECT count(*) FROM leaf_schema_migrations")[0][0].asInt == 0
    db.migrate(@[Migration(version: 1, name: "repaired", sql: "CREATE TABLE partial (id INTEGER);")])
    check db.query("SELECT name FROM sqlite_master WHERE name = 'partial'").len == 1

  test "migration scripts cannot commit the runner's transaction":
    let db = openDatabase(":memory:")
    defer: db.close()
    expect DatabaseError:
      db.migrate(@[Migration(version: 1, name: "commit", sql: "CREATE TABLE partial (id INTEGER); COMMIT;")])
    check db.query("SELECT name FROM sqlite_master WHERE name = 'partial'").len == 0
    check db.query("SELECT count(*) FROM leaf_schema_migrations")[0][0].asInt == 0
