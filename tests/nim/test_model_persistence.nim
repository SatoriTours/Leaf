import std/[unittest, sequtils, strutils, os, tempfiles]
import leaf/model
import leaf/sqlite
import ./model_fixtures

proc database(): Database =
  result = openDatabase(":memory:")
  result.executeScript("""CREATE TABLE tasks(id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE,
    done INTEGER NOT NULL, priority INTEGER NOT NULL, category TEXT NOT NULL,
    created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE audited(id INTEGER PRIMARY KEY, title TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE guarded(id INTEGER PRIMARY KEY, title TEXT NOT NULL);
    CREATE TABLE recursive(id INTEGER PRIMARY KEY, title TEXT NOT NULL);""")

var lifecycle: seq[string]
var commits: seq[ModelEvent]
var rollbacks: int
var failCommit: bool
type Audited = ref object of TimestampedRecord
  title: string
proc beforeSaveAudit(record: Audited) = lifecycle.add("beforeSave")
proc beforeCreateAudit(record: Audited) = lifecycle.add("beforeCreate")
proc afterCreateAudit(record: Audited) = lifecycle.add("afterCreate")
proc afterSaveAudit(record: Audited) =
  lifecycle.add("afterSave")
  if record.title == "mutate": record.title = "later input"
  if record.title == "raise": raise newException(ValueError, "after save failure")
proc committedAudit(record: Audited, event: ModelEvent) =
  commits.add(event)
  if failCommit: raise newException(ValueError, "commit notification failure")
proc rollbackAudit(record: Audited, event: ModelEvent) = inc rollbacks
defineModel(Audited, table = "audited"):
  validates title, presence = true
  beforeSave beforeSaveAudit
  beforeCreate beforeCreateAudit
  afterCreate afterCreateAudit
  afterSave afterSaveAudit
  afterCommit committedAudit
  afterRollback rollbackAudit

type Guarded = ref object of Record
  title: string
proc cancelSave(record: Guarded) =
  if record.title == "cancel": record.abortOperation()
proc cancelDestroy(record: Guarded) = record.abortOperation()
defineModel(Guarded, table = "guarded"):
  beforeSave cancelSave
  beforeDestroy cancelDestroy

type RecursiveSave = ref object of Record
  title: string
proc nestedSave(record: RecursiveSave)
defineModel(RecursiveSave, table = "recursive"):
  beforeSave nestedSave
proc nestedSave(record: RecursiveSave) = record.saveOrRaise()

suite "shared model persistence":
  setup:
    let db = database()
    lifecycle = @[]
    commits = @[]
    rollbacks = 0
    failCommit = false
  teardown: db.close()

  test "create, update, reload, delete and structured validation failure":
    withDatabase(db):
      let invalid = Task.create(title = " ")
      check invalid.isNewRecord
      check invalid.errors.forField("title").len == 1
      check not invalid.save()
      expect RecordInvalid: invalid.saveOrRaise()
      expect RecordInvalid: discard Task.createOrRaise(title = "")
      let task = Task.createOrRaise(title = " milk ")
      check task.isPersisted
      check task.title == "milk"
      check task.created_at.isSome
      check task.updated_at == task.created_at
      let id = task.id
      check Task.find(id).title == "milk"
      check task.update(title = "new", done = true)
      check not task.changed
      check Task.find(id).done
      check not task.update(title = " ")
      check task.title == ""
      check Task.find(id).title == "new"
      task.reload()
      check task.title == "new"
      check task.errors.fullMessages.len == 0
      task.updateOrRaise(title = "changed")
      check task.destroy()
      check task.isDestroyed
      check task.id == id
      expect RecordNotFound: discard Task.find(id)
      expect ModelUsageError: discard task.save()
      expect ModelUsageError: discard task.destroy()

  test "callbacks, clean save and selective updates retain untouched database values":
    withDatabase(db):
      let audited = Audited.createOrRaise(title = "mutate")
      check lifecycle == @["beforeSave", "beforeCreate", "afterCreate", "afterSave"]
      check audited.title == "later input"
      check audited.changed
      check Audited.find(audited.id).title == "mutate"
      audited.saveOrRaise()
      check not audited.changed
      db.executeScript("CREATE TABLE update_log(id INTEGER); CREATE TRIGGER audited_update AFTER UPDATE ON audited BEGIN INSERT INTO update_log VALUES(new.id); END;")
      let previousTime = audited.updated_at
      let commitCount = commits.len
      audited.saveOrRaise()
      check audited.updated_at == previousTime
      check audited.savedChanges.len == 0
      check commits.len == commitCount
      check db.query("SELECT COUNT(*) FROM update_log")[0][0].asInt64 == 0'i64
      let first = Task.createOrRaise(title = "one")
      let second = Task.find(first.id)
      first.done = true
      first.saveOrRaise()
      second.title = "two"
      second.saveOrRaise()
      check Task.find(first.id).done
      first.title = "last"
      first.saveOrRaise()
      check Task.find(first.id).title == "last"
      discard db.execute("DELETE FROM audited WHERE id=?", @[dbValue(audited.id)])
      expect RecordNotFound: audited.saveOrRaise()
      expect RecordNotFound: audited.reload()
      expect RecordNotFound: audited.destroyOrRaise()

  test "constraint, cancellation, wrong database and recursive callbacks throw correctly":
    withDatabase(db):
      discard Task.createOrRaise(title = "unique")
      expect ConstraintError: discard Task.createOrRaise(title = "unique")
      let cancelled = Guarded.create(title = "cancel")
      check cancelled.isNewRecord
      expect RecordNotSaved: cancelled.saveOrRaise()
      let protected = Guarded.createOrRaise(title = "protected")
      check not protected.destroy()
      expect RecordNotDestroyed: protected.destroyOrRaise()
      check protected.isPersisted
      expect ModelUsageError: discard RecursiveSave.createOrRaise(title = "bad")
      let other = database()
      defer: other.close()
      let task = Task.find(1)
      expect ModelUsageError: task.saveOrRaise(other)
      let duplicate = task.dupRecord()
      duplicate.saveOrRaise(other)
      check Task.find(other, duplicate.id).title == task.title
      var empty: Task
      expect ModelUsageError: discard empty.save()

  test "outer rollback restores identity, timestamps and baseline while preserving input":
    withDatabase(db):
      let existing = Task.createOrRaise(title = "old")
      let fresh = Task.build(title = "new")
      let originalTime = existing.updated_at
      try:
        transaction:
          fresh.saveOrRaise()
          existing.updateOrRaise(title = "user input")
          check Task.find(existing.id).title == "user input"
          raise newException(ValueError, "rollback")
      except ValueError: discard
      check fresh.id == 0'i64
      check fresh.isNewRecord
      check fresh.created_at.isNone
      check existing.title == "user input"
      check existing.changed
      check existing.updated_at == originalTime
      check Task.find(existing.id).title == "old"
      transaction:
        existing.saveOrRaise()
        check not Task.build(title = "").save()
      check Task.find(existing.id).title == "user input"
      expect ValueError:
        transaction:
          existing.destroyOrRaise()
          check existing.isDestroyed
          raise newException(ValueError, "undo delete")
      check existing.isPersisted
      check Task.find(existing.id).title == "user input"

  test "afterSave errors roll back, and commit events keep immutable operation deltas":
    withDatabase(db):
      let failed = Audited.build(title = "raise")
      expect ValueError: failed.saveOrRaise()
      check failed.id == 0'i64
      check failed.isNewRecord
      check rollbacks == 1
      let task = Audited.build(title = "first")
      transaction:
        task.saveOrRaise()
        task.updateOrRaise(title = "second")
        check commits.len == 0
      check commits.len == 2
      check commits[0].eventChanges.filterIt(it.field == "title")[0].after.get.asString == "first"
      check commits[1].eventChanges.filterIt(it.field == "title")[0].after.get.asString == "second"
      failCommit = true
      expect PostCommitError: task.updateOrRaise(title = "committed")
      check Audited.find(task.id).title == "committed"
      check task.isPersisted

  test "read-only and locked databases report database failures without stale object state":
    db.executeScript("PRAGMA query_only=ON")
    withDatabase(db):
      let task = Task.build(title = "read only")
      expect DatabaseError: task.saveOrRaise()
      check task.isNewRecord
      check task.id == 0'i64
    let directory = createTempDir("leaf-model-lock-", "")
    defer: removeDir(directory)
    let a = openDatabase(directory / "db.sqlite3")
    let b = openDatabase(directory / "db.sqlite3")
    defer: a.close()
    defer: b.close()
    a.executeScript("CREATE TABLE guarded(id INTEGER PRIMARY KEY,title TEXT NOT NULL)")
    discard a.execute("BEGIN IMMEDIATE")
    b.executeScript("PRAGMA busy_timeout=1")
    withDatabase(b):
      expect DatabaseError: discard Guarded.createOrRaise(title = "locked")
    discard a.execute("ROLLBACK")
