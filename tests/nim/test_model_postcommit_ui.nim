import std/[unittest, strutils]
import leaf/model
import leaf/sqlite

type Task = ref object of Record
  title: string
  done: bool
proc failedNotification(task: Task, event: ModelEvent) =
  raise newException(ValueError, "notification unavailable")
defineModel(Task, table = "tasks"):
  validates title, presence = true
  afterCommit failedNotification
include "../../src/leaf/templates/scaffold/model_home_logic.nim"

suite "committed writes and notification errors in pages":
  test "home creation clears the committed draft before a user retries":
    let db = openDatabase(":memory:")
    defer: db.close()
    db.executeScript("CREATE TABLE tasks(id INTEGER PRIMARY KEY,title TEXT,done INTEGER)")
    withDatabase(db):
      let state = HomeState(draft: "Buy milk")
      state.addTask()
      check Task.count == 1'i64
      check state.draft == ""
      check "committed" in state.error
      state.addTask()
      check Task.count == 1'i64
