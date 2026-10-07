import std/unittest
import leaf
import leaf/model
import leaf/sqlite
import ./model_fixtures

proc database(): Database =
  result = openDatabase(":memory:")
  result.executeScript("CREATE TABLE tasks(id INTEGER PRIMARY KEY,title TEXT,done INTEGER,priority INTEGER,category TEXT,created_at REAL,updated_at REAL)")

proc application(db: Database): Application =
  proc scope(body: proc() {.closure.}) =
    withDatabase(db): body()
  proc render(ctx: BuildContext): Node =
    doAssert currentDatabase() == db
    column(@[
      text($Task.count, key = "count"),
      button("Add", key = "add", onClick = proc(e: Event) =
        doAssert currentDatabase() == db
        discard Task.createOrRaise(title = "task" & $Task.count)),
      button("Error", key = "error", onClick = proc(e: Event) =
        doAssert currentDatabase() == db
        raise newException(ValueError, "event failure"))])
  Application(title: "Model runtime", width: 640, height: 480,
    render: render, executionScope: scope)

suite "application model context":
  test "alternating application render and later events use their own connection":
    let a = database()
    let b = database()
    defer: a.close()
    defer: b.close()
    let left = newRuntime(application(a))
    let right = newRuntime(application(b))
    check left.dispatch("add", Event(kind: click))
    check right.dispatch("add", Event(kind: click))
    check left.dispatch("add", Event(kind: click))
    check left.find("count").node.text == "2"
    check right.find("count").node.text == "1"
    check a.query("SELECT COUNT(*) FROM tasks")[0][0].asInt64 == 2'i64
    check b.query("SELECT COUNT(*) FROM tasks")[0][0].asInt64 == 1'i64
    expect ValueError: discard left.dispatch("error", Event(kind: click))
    expect DatabaseContextError: discard currentDatabase()
    check right.refresh()
    expect DatabaseContextError: discard currentDatabase()

  test "late virtual row builders and validators run inside the application scope":
    let db = database()
    defer: db.close()
    var rowsBuilt = 0
    proc scope(body: proc() {.closure.}) =
      withDatabase(db): body()
    proc render(ctx: BuildContext): Node =
      virtualList("list", @["one", "two"], proc(index: int): Node =
        doAssert currentDatabase() == db
        inc rowsBuilt
        text($Task.count, key = "row"))
    let runtime = newRuntime(Application(title: "rows", width: 640, height: 480,
      render: render, executionScope: scope))
    check rowsBuilt == 0
    runtime.setValidator(proc(snapshot: Snapshot) = doAssert currentDatabase() == db)
    check runtime.materialize("list", 0, 2).len == 2
    check rowsBuilt == 2
    runtime.setPreparer(proc(candidate: Runtime) =
      doAssert currentDatabase() == db
      discard candidate.materialize("list", 0, 1))
    runtime.prepare()
    expect DatabaseContextError: discard currentDatabase()
