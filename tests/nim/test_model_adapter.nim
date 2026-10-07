import std/[unittest, options, times]
import leaf/sqlite
import leaf/model/adapters/norm_sqlite
import norm/[model, pragmas]

type AdapterTask {.tableName: "tasks".} = ref object of Model
  title: string
  done: bool
  due: Option[DateTime]

suite "Norm shares Leaf SQLite":
  test "shared memory handle preserves text, null and 64 bit identity":
    let db = openDatabase(":memory:")
    defer: db.close()
    db.migrate(@[Migration(version: 1, name: "tasks", sql:
      "CREATE TABLE tasks(id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE, done INTEGER NOT NULL, due REAL);")])
    discard db.execute("INSERT INTO tasks(id,title,done) VALUES(?,?,?)",
      @[dbValue(4_999_999_999'i64), dbValue("seed"), dbValue(false)])
    var task = AdapterTask(title: "中文'\0尾部", done: true, due: none(DateTime))
    db.insertStorage(task)
    check task.id == 5_000_000_000'i64
    check db.lastInsertId64 == task.id
    let rows = selectStorage[AdapterTask](db, "SELECT title,done,due,id FROM tasks WHERE id=?", @[dbValue(task.id)])
    require rows.len == 1
    check rows[0].title == task.title
    check rows[0].done
    check rows[0].due.isNone
    check db.query("SELECT title FROM tasks WHERE id=?", @[dbValue(task.id)])[0][0].asString == task.title
    var duplicate = AdapterTask(title: task.title)
    expect ConstraintError: db.insertStorage(duplicate)
    expect ConstraintError:
      discard db.execute("INSERT INTO tasks(title,done) VALUES(NULL,0)")
    let other = openDatabase(":memory:")
    defer: other.close()
    expect DatabaseError: discard other.query("SELECT * FROM tasks")
    db.close()
    db.close()
    expect DatabaseError: discard selectStorage[AdapterTask](db, "SELECT * FROM tasks", [])

  test "each mapped row owns independent values and UTC dates":
    let db = openDatabase(":memory:")
    defer: db.close()
    db.executeScript("CREATE TABLE tasks(id INTEGER PRIMARY KEY, title TEXT UNIQUE, done INTEGER, due REAL);")
    let date = fromUnixFloat(1_700_000_000.125).utc
    var first = AdapterTask(title: "one", due: some(date))
    var second = AdapterTask(title: "two")
    db.insertStorage(first)
    db.insertStorage(second)
    let rows = selectStorage[AdapterTask](db, "SELECT title,done,due,id FROM tasks ORDER BY id", [])
    check rows.len == 2
    check rows[0] != rows[1]
    check rows[0].due.get.toTime.toUnixFloat == date.toTime.toUnixFloat
    rows[0].title = "changed"
    check rows[1].title == "two"
    check db.executeAffected("UPDATE tasks SET done=? WHERE id=?", @[dbValue(true), dbValue(first.id)]) == 1'i64
    check db.executeAffected("DELETE FROM tasks WHERE id=?", @[dbValue(99)]) == 0'i64
    expect DatabaseError: discard selectStorage[AdapterTask](db, "SELECT title FROM tasks", [])
