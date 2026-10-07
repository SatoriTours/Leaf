import std/[unittest, strutils, math]
import leaf/model
import leaf/sqlite
import ./model_compile_support
import ./model_fixtures

var phases: seq[string]
type Shared = ref object of TimestampedRecord
  title: string
  raw: string
proc baseBefore(record: Shared) =
  phases.add("base_before")
  record.title = record.title.strip()
proc baseAfter(record: Shared) = phases.add("base_after")
defineAbstractModel(Shared):
  validates title, presence = true
  beforeValidation baseBefore
  afterValidation baseAfter

type Checked = ref object of Shared
  amount: float
  optional: Option[float]
proc childBefore(record: Checked) =
  phases.add("child_before")
  discard currentDatabase().query("SELECT 1")
proc childAfter(record: Checked) = phases.add("child_after")
defineModel(Checked, table = "checked"):
  validates title, maxLength = 200
  validates amount, finite = true
  validates optional, finite = true
  beforeValidation childBefore
  afterValidation childAfter

type Cancelled = ref object of Record
  title: string
proc cancel(record: Cancelled) = record.abortOperation()
defineModel(Cancelled, table = "cancelled"):
  beforeValidation cancel

type Recursive = ref object of Record
  title: string
proc recurse(record: Recursive)
defineModel(Recursive, table = "recursive"):
  beforeValidation recurse
proc recurse(record: Recursive) = discard record.valid()

suite "inherited validation and callbacks":
  test "unicode rules and callback order, without implicit trim":
    let db = openDatabase(":memory:")
    defer: db.close()
    withDatabase(db):
      phases = @[]
      let task = Checked.build(title = "  " & "中".repeat(200) & "  ", raw = " raw ")
      check task.valid()
      check task.title == "中".repeat(200)
      check task.raw == " raw "
      check phases == @["base_before", "child_before", "child_after", "base_after"]
      task.title = "中".repeat(201)
      check not task.valid()
      check task.errors.forField("title")[0].code == "too_long"
      task.title = "ok"
      check task.valid()
      check task.errors.forField("title").len == 0
      task.title = " "
      check not task.valid()
      check task.errors.forField("title")[0].code == "blank"
      task.title = "finite"
      task.amount = Inf
      task.optional = some(NaN)
      check not task.valid()
      check task.errors.forField("amount")[0].code == "not_finite"
      check task.errors.forField("optional")[0].code == "not_finite"
      check db.query("SELECT name FROM sqlite_master WHERE type='table'").len == 0
    expect DatabaseContextError: discard Checked.build().valid()

  test "cancellation and reentry clean up operation guards":
    let db = openDatabase(":memory:")
    defer: db.close()
    withDatabase(db):
      check not Cancelled.build(title = "ok").valid()
      let record = Recursive.build()
      expect ModelUsageError: discard record.valid()
      expect ModelUsageError: discard record.valid()

  test "private callbacks and shared rules survive module boundaries":
    let db = openDatabase(":memory:")
    defer: db.close()
    withDatabase(db):
      let task = Task.build(title = " task ", category = " home ")
      check task.valid()
      check task.title == "task"
      check task.category == "home"
      task.category = "中".repeat(201)
      check not task.valid()
      check task.errors.forField("category")[0].code == "too_long"
  test "invalid validators and callback signatures fail in declaration":
    for body in ["validates missing, presence=true", "validates number, maxLength=200",
        "validates title, maxLength= -1", "beforeValidation wrong"]:
      let compiled = compileModelFailure("type Bad = ref object of Record\n  title:string\n  number:int\nproc wrong(a:int)=discard\ndefineModel(Bad,table=\"bad\"):\n  " & body)
      checkpoint compiled.output
      check compiled.code != 0
      check "invalid.nim" in compiled.output
