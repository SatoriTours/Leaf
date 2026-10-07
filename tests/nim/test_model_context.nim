import std/unittest
import leaf/sqlite
import leaf/model/[context, errors]

proc earlyReturn(db: Database) =
  withDatabase(db):
    doAssert currentDatabase() == db
    return

proc foreignThread(payload: tuple[handle: pointer, rejected: ptr bool]) {.thread.} =
  let db {.cursor.} = cast[Database](payload.handle)
  try:
    db.requireUsable()
  except DatabaseError:
    payload.rejected[] = true
  # The owning thread keeps the borrowed reference alive until joinThread.

suite "model database context":
  test "missing scope and nested exceptions restore previous context":
    let a = openDatabase(":memory:")
    let b = openDatabase(":memory:")
    defer: a.close()
    defer: b.close()
    expect DatabaseContextError: discard currentDatabase()
    withDatabase(a):
      let outer = currentContext()
      withDatabase(a): check currentContext() == outer
      withDatabase(b): check currentDatabase() == b
      check currentDatabase() == a
      expect ValueError:
        withDatabase(b): raise newException(ValueError, "test")
      check currentDatabase() == a
      b.earlyReturn()
      check currentDatabase() == a
    expect DatabaseContextError: discard currentDatabase()
    a.earlyReturn()
    expect DatabaseContextError: discard currentDatabase()
    discard a.query("SELECT 1")

  test "active transactions reject connection switches and closed handles":
    let a = openDatabase(":memory:")
    let b = openDatabase(":memory:")
    defer: a.close()
    defer: b.close()
    withDatabase(a):
      currentContext().transactionDepth = 1
      expect ModelUsageError:
        withDatabase(b): discard
      withDatabase(a): check currentDatabase() == a
      currentContext().transactionDepth = 0
    b.close()
    expect DatabaseError:
      withDatabase(b): discard

  test "the owning thread must perform database operations":
    let db = openDatabase(":memory:")
    defer: db.close()
    var rejected = false
    var thread: Thread[tuple[handle: pointer, rejected: ptr bool]]
    createThread(thread, foreignThread, (cast[pointer](db), addr rejected))
    joinThread(thread)
    check rejected
    discard db.query("SELECT 1")
