import std/[unittest, sequtils, strutils]
import leaf/model
import leaf/model/query
import leaf/model/query_sql
import leaf/sqlite
import ./[model_fixtures, model_compile_support]

type NullableQuery = ref object of Record
  label: Option[string]
defineModel(NullableQuery, table = "nullable")

proc database(): Database =
  result = openDatabase(":memory:")
  result.executeScript("""CREATE TABLE tasks(id INTEGER PRIMARY KEY,title TEXT NOT NULL,done INTEGER,
    priority INTEGER,category TEXT,created_at REAL,updated_at REAL);
    CREATE TABLE nullable(id INTEGER PRIMARY KEY,label TEXT);""")

proc wrongThread(payload: tuple[query: ptr Query[Task], rejected: ptr bool]) {.thread.} =
  try: discard payload.query[].count
  except DatabaseError: payload.rejected[] = true

suite "direct model queries":
  setup:
    let db = database()
    withDatabase(db):
      for i in 1..6:
        discard Task.createOrRaise(title = "task" & $i, done = i mod 2 == 0,
          priority = (i-1) div 2, category = if i <= 3: "home" else: "work")
  teardown: db.close()

  test "type shortcuts, scope and immutable branches share behavior":
    withDatabase(db):
      check Task.all.len == 6
      check Task.first.get.id == 1'i64
      check Task.first().get.id == 1'i64
      check Task.last.get.id == 6'i64
      check Task.count == 6'i64
      check Task.exists
      check Task.exists(1)
      check not Task.exists(99)
      check Task.firstOrRaise.id == 1'i64
      check Task.lastOrRaise.id == 6'i64
      check Task.unfinished.ids == @[1'i64, 3'i64, 5'i64]
      check Task.where(priority = 1).unfinished.ids == @[3'i64]
      check Task.home.ids == @[1'i64, 2'i64, 3'i64]
      let base = Task.where(done = false)
      let low = base.where(it.priority < 1)
      let high = base.where(it.priority >= 1)
      check low.ids == @[1'i64]
      check high.ids == @[3'i64, 5'i64]
      check base.ids == @[1'i64, 3'i64, 5'i64]
      let ascending = base.orderBy(it.priority, Asc)
      let descending = base.orderBy(it.priority, Desc)
      check ascending.ids == @[1'i64, 3'i64, 5'i64]
      check descending.ids == @[5'i64, 3'i64, 1'i64]
      check base.ids == @[1'i64, 3'i64, 5'i64]

  test "first and last preserve order and the pagination window":
    withDatabase(db):
      check Task.first(3).mapIt(it.id) == @[1'i64, 2'i64, 3'i64]
      check Task.last(3).mapIt(it.id) == @[4'i64, 5'i64, 6'i64]
      check Task.offset(1).limit(3).last(2).mapIt(it.id) == @[3'i64, 4'i64]
      check Task.offset(1).limit(3).first(2).mapIt(it.id) == @[2'i64, 3'i64]
      check Task.offset(2).last(2).mapIt(it.id) == @[5'i64, 6'i64]
      let mixed = Task.orderBy(it.priority, Desc).orderBy(it.done, Asc)
      check mixed.ids == @[5'i64, 6'i64, 3'i64, 4'i64, 1'i64, 2'i64]
      check mixed.last(3).mapIt(it.id) == @[4'i64, 1'i64, 2'i64]
      check mixed.offset(1).limit(4).last(3).mapIt(it.id) == @[3'i64, 4'i64, 1'i64]
      check Task.first(0).len == 0
      check Task.last(0).len == 0
      check Task.limit(2).limit(3).offset(1).offset(2).ids == @[3'i64, 4'i64, 5'i64]
      check Task.limit(0).count == 6'i64
      check Task.limit(0).exists
      check Task.limit(0).all.len == 0
      check Task.offset(99).first.isNone
      expect RecordNotFound: discard Task.offset(99).firstOrRaise
      expect RecordNotFound: discard Task.offset(99).lastOrRaise
      expect ModelUsageError: discard Task.first(-1)
      expect ModelUsageError: discard Task.last(-1)
      expect ModelUsageError: discard Task.limit(-1)
      expect ModelUsageError: discard Task.offset(-1)
      let efficient = compileQuery(Task.orderBy(it.priority, Asc), @[], queryLast, 2)
      check efficient.sql.count("SELECT") == 1
      check "LIMIT ?" in efficient.sql
      let window = compileQuery(Task.offset(1).limit(3), @[], queryLast, 2)
      check window.sql.count("SELECT") == 2
      check "LIMIT ? OFFSET ?" in window.sql

  test "named equality, expressions, null and typed projections":
    withDatabase(db):
      check Task.where(done = false, priority = 1).ids == @[3'i64]
      check Task.where((it.done == false) and ((it.priority >= 1) or (it.id == 1'i64))).count == 3'i64
      check Task.where(not (it.done == true)).count == 3'i64
      check Task.where(it.id in @[1'i64, 5'i64]).ids == @[1'i64, 5'i64]
      check Task.where(it.id notin @[1'i64, 5'i64]).count == 4'i64
      check Task.where(it.id in newSeq[int64]()).count == 0'i64
      check Task.where(it.id notin newSeq[int64]()).count == 6'i64
      check Task.findBy(done = false).get.id == 1'i64
      check Task.findByOrRaise(done = false).id == 1'i64
      check Task.findBy(title = "missing").isNone
      expect RecordNotFound: discard Task.findByOrRaise(title = "missing")
      check Task.limit(2).pluck(it.title) == @["task1", "task2"]
      let tuples = Task.limit(2).pluck(it.id, it.title)
      check tuples == @[(id: 1'i64, title: "task1"), (id: 2'i64, title: "task2")]
      discard NullableQuery.createOrRaise(label = none(string))
      discard NullableQuery.createOrRaise(label = some("value"))
      check NullableQuery.where(label = none(string)).count == 1'i64
      check NullableQuery.where(isNull(it.label)).count == 1'i64
      check NullableQuery.where(it.label != none(string)).count == 1'i64
      check NullableQuery.pluck(it.label) == @[none(string), some("value")]

  test "literal LIKE escapes and parameter text survive":
    withDatabase(db):
      let text = "中文'\0尾部"
      discard Task.createOrRaise(title = text)
      check Task.where(title = text).pluck(it.title) == @[text]
      discard Task.createOrRaise(title = "100%_\\done")
      discard Task.createOrRaise(title = "100XXdone")
      check Task.where(contains(it.title, "%_\\")).count == 1'i64
      check Task.where(startsWith(it.title, "100%")).count == 1'i64
      check Task.where(endsWith(it.title, "\\done")).count == 1'i64
      discard Task.createOrRaise(title = "ABC")
      check Task.where(contains(it.title, "abc")).count == 1'i64

  test "captured connection remains stable outside scope and during another context":
    var captured: Query[Task]
    withDatabase(db): captured = Task.where(done = false)
    check captured.count == 3'i64
    let other = database()
    defer: other.close()
    withDatabase(other):
      check captured.count == 3'i64
      check currentDatabase() == other
      transaction:
        expect ModelUsageError: discard captured.all
    db.close()
    expect DatabaseError: discard captured.count
    expect DatabaseError: discard captured.first(0)

  test "captured queries reject a different thread":
    var captured: Query[Task]
    withDatabase(db): captured = Task.where(done = false)
    var rejected = false
    var worker: Thread[tuple[query: ptr Query[Task], rejected: ptr bool]]
    createThread(worker, wrongThread, (addr captured, addr rejected))
    joinThread(worker)
    check rejected
    check captured.count == 3'i64

  test "empty tables and controlled full-row raw queries":
    withDatabase(db):
      check NullableQuery.first.isNone
      check NullableQuery.last.isNone
      check NullableQuery.last(2).len == 0
      expect RecordNotFound: discard NullableQuery.firstOrRaise
      let rows = Task.rawQuery("SELECT title,done,priority,category,created_at,updated_at,id FROM tasks WHERE id=?", @[dbValue(1)])
      check rows[0].id == 1'i64
      expect DatabaseError: discard Task.rawQuery("SELECT title FROM tasks", [])
      expect DatabaseError:
        discard Task.rawQuery("SELECT NULL,done,priority,category,created_at,updated_at,id FROM tasks WHERE id=1", [])
      expect DatabaseError:
        discard Task.rawQuery("SELECT 42,done,priority,category,created_at,updated_at,id FROM tasks WHERE id=1", [])

  test "invalid query fields, types, SQL and abstract models fail at compile time":
    let model = "type A = ref object of Record\n  title:string\n  done:bool\ndefineModel(A,table=\"a\")\n"
    for query in ["A.where(missing=1)", "A.where(done=\"false\")", "A.where(it.title > 5)",
        "A.where(arbitrary(it.title))", "A.where(\"1=1\")", "A.where(it.done == false, title=\"x\")",
        "A.orderBy(it.missing, Asc)", "A.pluck(it.errors)", "A.pluck(it.title,it.title)",
        "Record.first", "A().update(id=1)", "A().update(created_at=none(DateTime))"]:
      let compiled = compileModelFailure(model & "discard " & query)
      checkpoint compiled.output
      check compiled.code != 0
      check "invalid.nim" in compiled.output
    let invalidScope = compileModelFailure("type A = ref object of Record\n  title:string\ndefineModel(A,table=\"a\"):\n  scope first, it.title == \"x\"")
    check invalidScope.code != 0
    check "scope name conflicts" in invalidScope.output
