import std/os
import leaf/[core, components, component_description, component_state, widgets, native_ffi, sqlite, sqlite_native, app_resources]
import leaf/model/adapters/norm_sqlite
import leaf/backends/android/ffi
import norm/[model, pragmas]
import db_connector/sqlite3 as connector
import lowdb/wrappers/sqlite3 as lowraw
export native_ffi

type StoredNote {.tableName: "notes".} = ref object of Model
  title: string
var path, migration: string
var resources:HostResources
var rejected: int
const Binary = "binary\0中文😀"
var db: Database
var factories, initializations, disposals, opens: int
var saved: State[int64]
const Title = "中文😀'\0tail"
proc directDbHandle(s: connector.PStmt): connector.PSqlite3 {.importc: "sqlite3_db_handle", cdecl.}
proc checkEngine() =
  doAssert libraryVersionNumber() == 3_054_001
  doAssert cast[pointer](libraryVersionNumber) == cast[pointer](connector.libversion_number)
  doAssert cast[pointer](lowraw.db_handle) == cast[pointer](directDbHandle)
  let h = cast[connector.PSqlite3](db.borrowSqliteHandle())
  var statement: connector.PStmt
  doAssert connector.prepare_v2(h, "SELECT 42", -1, statement, nil) == 0
  doAssert statement != nil
  defer: discard connector.finalize(statement)
  doAssert lowraw.db_handle(statement) == h
  doAssert connector.step(statement) == connector.SQLITE_ROW
  doAssert connector.column_int64(statement, 0) == 42
proc last(): int64 = db.query("SELECT max(id) FROM notes")[0][0].asInt64
proc verifyStored() =
  let id = last()
  if id >= 5_000_000_000'i64:
    doAssert db.query("SELECT title FROM notes WHERE id=?", @[dbValue(id)])[0][0].asString == Title
    let rows = selectStorage[StoredNote](db, "SELECT title,id FROM notes WHERE id=?", @[dbValue(id)])
    doAssert rows.len == 1 and rows[0].title == Title and rows[0].id == id
proc openStorage() =
  db = openDatabase(path)
  inc opens
  checkEngine()
  db.migrate(@[Migration(version:1, name:"notes", sql:migration)])
  discard db.execute("INSERT OR IGNORE INTO notes(id,title) VALUES(?,?)", @[dbValue(4_999_999_999'i64),dbValue("seed")])
  verifyStored()
let Root = defineComponent[int,State[int64]]("AndroidSqliteRoot",
  proc(ctx:MountContext,p:int):State[int64] =
    inc initializations
    doAssert path.len > 0 and migration.len > 0 and db == nil
    openStorage()
    ctx.onDispose(proc(e:LifecycleContext) =
      doAssert resources.readAsset("binary.bin") == Binary
      db.close()
      db = nil
      inc disposals)
    result = ctx.state(last())
    saved = result,
  proc(ctx:ComponentContext,p:int,s:State[int64]):UiDescription =
    host(column(@[
      text("资源 · SQLite 3.54.1 中文😀",key="engine",styles=style({"height":"48"})),
      text("记录=" & $ctx.value(s),key="saved",styles=style({"height":"48"})),
      button("保存记录",key="save",styles=style({"height":"48"}),onClick=proc(e:Event) =
        var row = StoredNote(title:Title)
        db.insertStorage(row)
        doAssert db.lastInsertId64 == row.id
        verifyStored()
        s.set(row.id)),
      button("关闭重开数据库",key="reopen",styles=style({"height":"48"}),onClick=proc(e:Event) =
        let before = last()
        db.close()
        openStorage()
        doAssert last() == before
        s.set(last()))
    ],key="body",styles=style({"width":"full"}))))
proc application(host:HostResources):Application =
  resources=host
  migration=host.readAsset("migrations/001-notes.sql")
  doAssert migration==readFile(host.asset("migrations/001-notes.sql"))
  doAssert host.readAsset("binary.bin")==Binary
  doAssert host.readAsset("empty",0)==""
  for name in ["missing", "../escape", "large.bin"]:
    var refused=false
    try: discard host.readAsset(name)
    except UiError: refused=true
    doAssert refused
    inc rejected
  doAssert rejected==3
  path=host.dataPath("数据/notes.sqlite3")
  inc factories
  componentApplication(component(Root,0),"SQLite",400,600)
registerAndroidApplication(application)
proc leaf_sqlite_probe*(which:cint):int64 {.exportc,dynlib,cdecl,raises:[].} =
  try:
    case which
    of 0: int64(factories)
    of 1: int64(initializations)
    of 2: int64(disposals)
    of 3: int64(opens)
    of 4: saved.read()
    of 5: int64(libraryVersionNumber())
    of 6: int64(connector.libversion_number())
    of 7:
      checkEngine()
      1
    of 8:
      try:
        if resources.readAsset("binary.bin")==Binary: 1 else: 0
      except CatchableError: 0
    of 9: int64(rejected)
    else: -1
  except Exception: -2
