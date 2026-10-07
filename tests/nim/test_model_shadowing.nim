import std/unittest
import leaf/model
import leaf/sqlite

type NewFlag = ref object of Record
  title: string
  isNewRecord: bool
defineModel(NewFlag, table = "newflags")
type PersistedFlag = ref object of Record
  title: string
  isPersisted: bool
defineModel(PersistedFlag, table = "persistedflags")
type ChangesField = ref object of Record
  title: string
  changes: string
defineModel(ChangesField, table = "changesfields")
type AbortFlag = ref object of Record
  title: string
  operationAborted: bool
proc cancel(flag: AbortFlag) = flag.abortOperation()
defineModel(AbortFlag, table = "abortflags"):
  beforeSave cancel

suite "business fields cannot replace framework state":
  test "lifecycle and dirty tracking use the framework rather than business values":
    let db = openDatabase(":memory:")
    defer: db.close()
    db.executeScript("""CREATE TABLE newflags(id INTEGER PRIMARY KEY,title TEXT,isNewRecord INTEGER);
      CREATE TABLE persistedflags(id INTEGER PRIMARY KEY,title TEXT,isPersisted INTEGER);
      CREATE TABLE changesfields(id INTEGER PRIMARY KEY,title TEXT,changes TEXT);
      CREATE TABLE abortflags(id INTEGER PRIMARY KEY,title TEXT,operationAborted INTEGER);""")
    withDatabase(db):
      let first = NewFlag.createOrRaise(title = "before", isNewRecord = true)
      first.title = "after"
      check first.save()
      check NewFlag.find(first.id).title == "after"
      check NewFlag.count == 1'i64
      let removed = PersistedFlag.createOrRaise(title = "remove", isPersisted = false)
      check removed.destroy()
      check PersistedFlag.count == 0'i64
      let dirty = ChangesField.createOrRaise(title = "before", changes = "")
      dirty.title = "after"
      check dirty.changed
      check dirty.save()
      check ChangesField.find(dirty.id).title == "after"
      let aborted = AbortFlag.build(title = "cancelled")
      check not aborted.save()
      check AbortFlag.count == 0'i64
