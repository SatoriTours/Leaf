import std/[unittest, options, times, sequtils, os, osproc, tempfiles, strutils, streams]
import leaf/model
import leaf/model/[metadata, record]
import leaf/model/adapters/norm_sqlite
import leaf/sqlite
import ./model_fixtures

type ScalarRecord = ref object of Record
  text: string
  flag: bool
  number: int
  big: int64
  decimal: float
  date: DateTime
  optText: Option[string]
  optFlag: Option[bool]
  optInt: Option[int]
  optBig: Option[int64]
  optFloat: Option[float]
  optDate: Option[DateTime]
defineModel(ScalarRecord, table = "scalars")

suite "model declarations":
  test "models inherit fields without persisting Record runtime state":
    check Task().isNewRecord
    let task = Task.build(title = "测试", done = true, category = "home")
    check task.id == 0'i64
    check task.title == "测试"
    check task.category == "home"
    check task.created_at.isNone
    check Note.build(body = "note").isNewRecord
    check modelTable(Task) == "tasks"
    check modelFields(Task).mapIt(it.name) ==
      @["title", "done", "priority", "category", "created_at", "updated_at", "id"]
    check modelFields(Task).allIt(it.name notin ["errors", "baseline", "savedChanges"])
    check modelValues(task).len == modelFields(Task).len

  test "all scalar and optional types round trip through generated storage":
    let db = openDatabase(":memory:")
    defer: db.close()
    db.executeScript("""CREATE TABLE scalars(id INTEGER PRIMARY KEY, text TEXT, flag INTEGER,
      number INTEGER, big INTEGER, decimal REAL, date REAL, optText TEXT, optFlag INTEGER,
      optInt INTEGER, optBig INTEGER, optFloat REAL, optDate REAL);""")
    let date = fromUnixFloat(1_700_000_000.125).utc
    let original = ScalarRecord.build(text = "中'\0文", flag = true, number = 5,
      big = 5_000_000_000'i64, decimal = 1.5, date = date,
      optText = some("可空"), optFlag = some(false), optInt = some(3),
      optBig = some(5_000_000_000'i64), optFloat = some(2.5), optDate = some(date))
    var stored = toStorage(original)
    db.insertStorage(stored)
    let fields = modelFields(ScalarRecord).mapIt(quoteIdentifier(it.name)).join(",")
    let rows = selectStorage[storageType(ScalarRecord)](db, "SELECT " & fields & " FROM scalars", [])
    let restored = fromStorage(ScalarRecord, rows[0], db)
    check restored.isPersisted
    check not original.isPersisted
    check restored.text == original.text
    check restored.big == original.big
    check restored.flag
    check restored.optFlag == some(false)
    check restored.optText == original.optText
    check restored.optDate.get.toTime.toUnixFloat == date.toTime.toUnixFloat
    check modelValues(restored) == modelValues(fromStorage(ScalarRecord, rows[0], db))
    let blank = ScalarRecord.build(date = date)
    var blankStored = toStorage(blank)
    db.insertStorage(blankStored)
    let blanks = selectStorage[storageType(ScalarRecord)](db, "SELECT " & fields & " FROM scalars WHERE id=?", @[dbValue(blankStored.id)])
    check fromStorage(ScalarRecord, blanks[0], db).optDate.isNone

  test "invalid declarations and identities fail at compile time":
    let root = createTempDir("leaf-model-compile-", "")
    defer: removeDir(root)
    let source = currentSourcePath().parentDir.parentDir.parentDir / "src"
    for declaration in [
        "type Bad = ref object of Record\n  bytes: seq[int]\ndefineModel(Bad, table=\"bad\")",
        "type Bad = ref object of Task\ndefineModel(Bad, table=\"bad\")",
        "type Bad = ref object of Record\n  i_d: int64\ndefineModel(Bad, table=\"bad\")",
        "type Bad = ref object of Record\n  createdAt: string\ndefineModel(Bad, table=\"bad\")",
        "type Bad = ref object of Record\n  created_at: Option[DateTime]\ndefineModel(Bad, table=\"bad\")",
        "let task = Task()\ntask.id = 100'i64",
        "defineModel(ApplicationRecord, table=\"bad\")"]:
      let path = root / "invalid.nim"
      writeFile(path, "import leaf/model\nimport " & (currentSourcePath().parentDir / "model_fixtures").escape & "\n" & declaration & "\n")
      var args = @["c", "--hints:off", "--path:" & source,
        "--nimcache:" & root / "cache", "--out:" & root / "invalid", path]
      # Same vendored config as generated applications, independent of user Nimble.
      for package in ["norm", "lowdb", "db_connector"]:
        args.insert("--path:" & source / "leaf/vendor/orm" / package / "src", 1)
      const Compiler = getCurrentCompilerExe()
      let process = startProcess(Compiler, args=args,
        options={poUsePath, poStdErrToStdOut})
      let output = process.outputStream.readAll()
      let code = process.waitForExit()
      process.close()
      checkpoint output
      check code != 0
      check "invalid.nim" in output
