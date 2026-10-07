import std/unittest
import leaf/model
import leaf/model/[transactions, record, context, callbacks]
import leaf/sqlite
import ./model_fixtures

proc returnFromTransaction(db: Database) =
  db.transaction:
    discard db.execute("INSERT INTO entries VALUES(99)")
    return

suite "model transaction journal":
  test "nested savepoints preserve outer writes and explicit scopes restore":
    let db = openDatabase(":memory:")
    defer: db.close()
    db.executeScript("CREATE TABLE entries(id INTEGER PRIMARY KEY)")
    db.transaction:
      check currentDatabase() == db
      discard db.execute("INSERT INTO entries VALUES(1)")
      expect ValueError:
        transaction:
          discard db.execute("INSERT INTO entries VALUES(2)")
          raise newException(ValueError, "inner")
      check db.query("SELECT COUNT(*) FROM entries")[0][0].asInt64 == 1'i64
      transaction: discard db.execute("INSERT INTO entries VALUES(3)")
    check db.query("SELECT COUNT(*) FROM entries")[0][0].asInt64 == 2'i64
    expect DatabaseContextError: discard currentDatabase()
    returnFromTransaction(db)
    check db.query("SELECT COUNT(*) FROM entries")[0][0].asInt64 == 3'i64

  test "every frame restores its first touch and keeps user input":
    let db = openDatabase(":memory:")
    defer: db.close()
    let task = Task.build(title = "initial")
    withDatabase(db):
      expect ValueError:
        transaction:
          let outerState = captureState(task)
          enlist(task, proc() = restoreState(task, outerState))
          markLoaded(task, db, 1, modelValues(task))
          expect ValueError:
            transaction:
              let innerState = captureState(task)
              enlist(task, proc() = restoreState(task, innerState))
              markLoaded(task, db, 2, modelValues(task))
              task.title = "latest input"
              raise newException(ValueError, "inner")
          check task.id == 1'i64
          raise newException(ValueError, "outer")
      check task.id == 0'i64
      check task.isNewRecord
      check task.title == "latest input"
      check task.changed

  test "commit notifications run after outer commit and collect all errors":
    let db = openDatabase(":memory:")
    defer: db.close()
    db.executeScript("CREATE TABLE entries(id INTEGER PRIMARY KEY)")
    let task = Task.build(title = "task")
    var notifications: seq[string]
    withDatabase(db):
      try:
        transaction:
          discard db.execute("INSERT INTO entries VALUES(1)")
          queueEvent(task, newModelEvent(createOperation, @[]),
            proc() =
              notifications.add("first")
              raise newException(ValueError, "after commit"),
            proc() = notifications.add("rollback"))
          transaction:
            discard db.execute("INSERT INTO entries VALUES(2)")
            queueEvent(task, newModelEvent(updateOperation, @[]),
              proc() = notifications.add("second"), proc() = discard)
          check notifications.len == 0
        check false
      except PostCommitError as error:
        check error.committed
        check error.details.len == 1
      check notifications == @["first", "second"]
      check db.query("SELECT COUNT(*) FROM entries")[0][0].asInt64 == 2'i64
      check currentContext().transactionDepth == 0

  test "rollback callback failure neither masks error nor interrupts restoration":
    let db = openDatabase(":memory:")
    defer: db.close()
    let first = Task.build(title = "first")
    let second = Task.build(title = "second")
    var notified = 0
    withDatabase(db):
      try:
        transaction:
          let firstState = captureState(first)
          let secondState = captureState(second)
          enlist(first, proc() = restoreState(first, firstState))
          enlist(second, proc() = restoreState(second, secondState))
          markLoaded(first, db, 1, modelValues(first))
          markLoaded(second, db, 2, modelValues(second))
          queueEvent(first, newModelEvent(createOperation, @[]), proc() = discard,
            proc() =
              inc notified
              expect ModelUsageError: discard beginFrame()
              raise newException(ValueError, "rollback handler"))
          queueEvent(second, newModelEvent(createOperation, @[]), proc() = discard,
            proc() = inc notified)
          raise newException(ValueError, "original operation")
      except ValueError as error:
        check error.msg == "original operation"
      check first.isNewRecord
      check second.isNewRecord
      check notified == 2
      check currentContext().transactionDepth == 0
