import std/[unittest, strutils]
import leaf
import leaf/model
import leaf/sqlite
import leaf/component_state

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
      let store = newStateStore(1)
      let model = store.allocateState(1, HomeState(draft: "Buy milk"),
        snapshot = snapshotHome)
      let state = model.read()
      state.model = model
      state.addTask()
      store.accept(store.beginAttempt())
      check Task.count == 1'i64
      check model.read().draft == ""
      check "committed" in model.read().error
      let retry = model.read()
      retry.model = model
      retry.addTask()
      store.accept(store.beginAttempt())
      check Task.count == 1'i64
