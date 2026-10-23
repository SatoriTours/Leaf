import std/os
import leaf
import leaf/app_resources
import leaf/sqlite
import ../app/application
import ./headless_rows
let data = currentSourcePath().parentDir / "private-data"
let cache = currentSourcePath().parentDir / "private-cache"
createDir(data); createDir(cache)
let resources = directoryResources(currentSourcePath().parentDir.parentDir / "assets", data, cache)
let first = newRuntime(createApplication(resources=resources))
doAssert first.dispatchFixture("task_draft", Event(kind: change, value: "中文😀 task"))
doAssert first.dispatchFixture("task_add", Event(kind: click))
doAssert first.find("task_title_1").node.text == "中文😀 task"
doAssert first.dispatchFixture("task_done_1", Event(kind: change, checked: true))
doAssert first.dispatchFixture("nav_notes", Event(kind: click))
doAssert first.dispatchFixture("notes_new", Event(kind: click))
doAssert first.dispatchFixture("notes_field_title", Event(kind: change, value: "中文😀 note"))
doAssert first.dispatchFixture("notes_save", Event(kind: click))
doAssert first.find("notes_title_1").node.text == "中文😀 note"
first.closeRuntime()
let reopened = newRuntime(createApplication(resources=resources))
reopened.realizeRows()
doAssert reopened.find("task_title_1").node.text == "中文😀 task"
doAssert reopened.dispatchFixture("nav_notes", Event(kind: click))
doAssert reopened.find("notes_title_1").node.text == "中文😀 note"
doAssert reopened.dispatchFixture("notes_delete_1", Event(kind: click))
reopened.closeRuntime()
let db = openDatabase(resources.dataPath("application.sqlite3"))
doAssert db.query("SELECT done FROM tasks")[0][0].asInt64 == 1
doAssert db.query("SELECT count(*) FROM notes")[0][0].asInt64 == 0
db.close(); resources.close()
echo "generated scaffold resources CRUD and reopen: passed"
