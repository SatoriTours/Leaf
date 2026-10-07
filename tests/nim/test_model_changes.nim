import std/[unittest, tables, options, times, sequtils]
import leaf/model
import leaf/model/[record, metadata]
import leaf/sqlite
import ./model_fixtures

type Nullable = ref object of Record
  value: Option[string]
defineModel(Nullable, table = "nullable")

suite "errors and changes":
  test "a field holds multiple structured errors and clears independently":
    let task = Task.build(title = "draft")
    task.errors.add("title", "blank", "is required")
    task.errors.add("title", "too_long", "is too long", {"maximum": "200"}.toTable)
    check task.errors.forField("title").len == 2
    check task.errors.forField("title")[1].params["maximum"] == "200"
    check task.errors.fullMessages == @["title is required", "title is too long"]
    var returned = task.errors.forField("title")
    returned[0].message = "bad"
    check task.errors.forField("title")[0].message == "is required"
    task.errors.clear()
    check task.errors.fullMessages.len == 0

  test "new absent values differ from persisted NULL and reverting is clean":
    let nullable = Nullable.build()
    check nullable.changes[0].before.isNone
    check nullable.changes[0].after.get.kind == sqlNull
    let db = openDatabase(":memory:")
    defer: db.close()
    markLoaded(nullable, db, 1, modelValues(nullable))
    check not nullable.changed
    nullable.value = some("new")
    check nullable.changes[0].before.get.kind == sqlNull
    nullable.value = none(string)
    check not nullable.changed
    var nilTask: Task
    expect ModelUsageError: discard nilTask.changed

  test "dup and state rollback retain business input but reset framework data":
    let db = openDatabase(":memory:")
    defer: db.close()
    let task = Task.build(title = "original", category = "home")
    task.created_at = some(fromUnix(100).utc)
    task.updated_at = task.created_at
    markLoaded(task, db, 5_000_000_000'i64, modelValues(task))
    let state = captureState(task)
    task.title = "user edit"
    let delta = task.changes
    acceptPersistedValues(task, db, task.id, modelValues(task), delta)
    check not task.changed
    var exposed = task.savedChanges
    exposed[0].field = "wrong"
    check task.savedChanges[0].field == "title"
    task.title = "after save edit"
    task.errors.add("title", "invalid", "error stays")
    restoreState(task, state)
    check task.title == "after save edit"
    check task.changed
    check task.savedChanges.len == 0
    check task.errors.forField("title").len == 1
    let duplicate = task.dupRecord()
    check duplicate != task
    check duplicate.title == task.title
    check duplicate.category == task.category
    check duplicate.id == 0'i64
    check duplicate.isNewRecord
    check duplicate.created_at.isNone
    check duplicate.updated_at.isNone
    check duplicate.errors.fullMessages.len == 0
    check duplicate.changes.allIt(it.before.isNone)
