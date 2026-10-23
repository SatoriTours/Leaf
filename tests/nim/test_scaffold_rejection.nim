import ./cleanup_support
import ./scaffold_headless_support
import std/[unittest, os, tempfiles, strtabs]
import leaf/[scaffold, build, process_io]

let base = createTempDir("leaf-scaffold-reject-", "")
removeDirectoryOnExit(base)

suite "generated page rejection isolation":
  test "model scaffold draft/panel/error actions use accepted State":
    let app = base / "model"
    createDir(app)
    discard generateScaffold(ScaffoldOptions(mode: smApplication), app)
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
      fields: @["title:string"]), app)
    writeHeadlessRows(app)
    let probe = app / "tests/rejection.nim"
    writeFile(probe, """
import std/strutils
import leaf
import leaf/host_session
import ../app/application
import ./headless_rows
import ../config/database
let db = openApplicationDatabase(":memory:")
let rt = newRuntime(createApplication(db))
proc click(key: string) = doAssert rt.dispatchFixture(key, Event(kind: click))
proc change(key, value: string) = doAssert rt.dispatchFixture(key, Event(kind: change, value: value))
# Model home: a rejected draft cannot be submitted by the next accepted add.
change("task_draft", "home baseline")
var homeReject = false
let homeSession = attachHostSession(rt, HostConsumer(sessionId: 773,
  prepare: proc(batch: HostBatch) = discard,
  apply: proc() =
    if homeReject: fail("generated model home rejection"),
  accept: proc(revision: uint64) {.raises: [].} = discard,
  discardPrepared: proc() {.raises: [].} = discard))
homeReject = true
try: change("task_draft", "home leak")
except UiError: discard
homeReject = false
click("task_add")
doAssert db.query("SELECT title FROM tasks")[0][0].asString == "home baseline"
homeSession.close()
click("nav_notes")
click("notes_new")
change("notes_field_title", "baseline")
var reject = false
let session = attachHostSession(rt, HostConsumer(sessionId: 772,
  prepare: proc(batch: HostBatch) = discard,
  apply: proc() =
    if reject: fail("generated model rejection"),
  accept: proc(revision: uint64) {.raises: [].} = discard,
  discardPrepared: proc() {.raises: [].} = discard))
reject = true
var rejected = false
try: change("notes_field_title", "leak")
except UiError: rejected = true
doAssert rejected
reject = false
# Saving immediately must use the accepted draft ("baseline"), not "leak".
click("notes_save")
doAssert db.query("SELECT title FROM notes")[0][0].asString == "baseline"
doAssert rt.find("notes_title_1").node.text == "baseline"
# A rejected editor draft is not inherited by the next accepted editor session.
click("notes_new")
change("notes_field_title", "draft two")
reject = true
try: change("notes_field_title", "leak two")
except UiError: discard
reject = false
click("notes_cancel")
var editorPresent = true
try: discard rt.find("notes_field_title")
except UiError: editorPresent = false
doAssert not editorPresent
click("notes_edit_1")
doAssert rt.find("notes_field_title").node.text == "baseline"
# Error/panel: a missing persisted record shows an error and stays in the editor.
discard db.execute("DELETE FROM notes WHERE id = 1")
click("notes_save")
doAssert rt.find("notes_error").node.text.len > 0
doAssert rt.find("notes_field_title") != nil
db.close()
""")
    let source = currentSourcePath().parentDir.parentDir.parentDir / "src"
    let binary = app / "target/rejection".addFileExt(ExeExt)
    createDir(binary.parentDir)
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["LEAF_DATABASE_PATH"] = app / "target/rejection.sqlite3"
    let child = startManaged(compiler(), @["c", "-r", "--path:" & source,
      "--nimcache:" & app / "target/cache", "--out:" & binary, probe], app, env)
    while not child.poll(): sleep(10)
    checkpoint child.output.diagnosticText()
    check child.code == 0
    child.close()
