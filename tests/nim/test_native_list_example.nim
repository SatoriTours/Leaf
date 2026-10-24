## The real example must persist by id, never list position or mounted-row slot.
## UI edits stay local and unsaved until Save; scrolling must not write SQLite.
import ./cleanup_support
import std/[unittest, os, tempfiles, tables]
import leaf/[core, widgets, components, sqlite]
import ../../examples/native_list/[store, application]

let base = createTempDir("leaf-native-list-", "")
removeDirectoryOnExit(base)

suite "native list example SQLite storage":
  test "new database is sparse and exposes both ends of the 10k source":
    let path = base / "中文 空格" / "fresh.sqlite3"
    let storage = openListStore(path)
    defer: storage.close()
    check storage.loadItem(0) == ListItem(id: 0)
    check storage.loadItem(9999) == ListItem(id: 9999)
    let db = openDatabaseReadOnly(path)
    defer: db.close()
    check db.query("SELECT count(*) FROM native_list_items")[0][0].asInt == 0

  test "saved UTF-8 bound values survive close and reopen under the same id":
    let path = base / "persist.sqlite3"
    let storage = openListStore(path)
    let note = "中文 😀 '); DROP TABLE native_list_items; --\0tail"
    storage.saveItem(ListItem(id: 9999, note: note, done: true))
    storage.close()
    let reopened = openListStore(path)
    defer: reopened.close()
    check reopened.loadItem(9999) == ListItem(id: 9999, note: note, done: true)
    check reopened.loadItem(0) == ListItem(id: 0)

  test "repeated save updates only its id rather than duplicating or replacing peers":
    let path = base / "updates.sqlite3"
    let storage = openListStore(path)
    storage.saveItem(ListItem(id: 3, note: "first", done: true))
    storage.saveItem(ListItem(id: 8, note: "peer", done: true))
    storage.saveItem(ListItem(id: 3, note: "second", done: false))
    storage.close()
    let reopened = openListStore(path)
    defer: reopened.close()
    check reopened.loadItem(3) == ListItem(id: 3, note: "second")
    check reopened.loadItem(8) == ListItem(id: 8, note: "peer", done: true)

  test "invalid row ids cannot create invisible records":
    let storage = openListStore(base / "invalid.sqlite3")
    defer: storage.close()
    for id in [-1, 10000]:
      expect ValueError: discard storage.loadItem(id)
      expect ValueError: storage.saveItem(ListItem(id: id, note: "bad"))
    check storage.loadItem(0) == ListItem(id: 0)

  test "closed storage fails instead of reporting a successful save":
    let storage = openListStore(base / "closed.sqlite3")
    storage.close()
    storage.close()
    expect DatabaseError: storage.saveItem(ListItem(id: 5, note: "lost"))
    expect DatabaseError: discard storage.loadItem(5)

suite "native list example managed application":
  test "editing and checkbox stay local until explicit save then reopen by id":
    let path = base / "ui.sqlite3"
    let storage = openListStore(path)
    let runtime = newRuntime(nativeListApp(storage))
    discard runtime.materialize("items", 0, 2)
    check runtime.find("items").node.listSource.len == 10000
    let source = runtime.find("items").node.listSource.generation
    # The real example requests one overscan row as well as the two visible rows.
    check runtime.find("items").children.len == 3
    check runtime.find("items").children[2].listIndex == 2
    discard runtime.dispatch("edit-0", Event(kind: change, value: "edited 中文 😀"))
    discard runtime.dispatch("done-0", Event(kind: change, checked: true))
    check storage.loadItem(0) == ListItem(id: 0)
    check runtime.find("edit-0").node.text == "edited 中文 😀"
    check runtime.find("edit-1").node.text == ""
    check runtime.find("items").node.listSource.generation == source
    discard runtime.dispatch("save-0", Event(kind: click))
    check runtime.find("status-0").node.text == "已保存"
    runtime.closeRuntime()
    storage.close()
    let reopened = openListStore(path)
    defer: reopened.close()
    check reopened.loadItem(0) == ListItem(id: 0, note: "edited 中文 😀", done: true)
    check reopened.loadItem(1) == ListItem(id: 1)
    let nextRuntime = newRuntime(nativeListApp(reopened))
    defer: nextRuntime.closeRuntime()
    discard nextRuntime.materialize("items", 0, 1)
    check nextRuntime.find("edit-0").node.text == "edited 中文 😀"
    check nextRuntime.find("done-0").node.attributes["checked"] == "true"

  test "scrolling to the final id loads its own saved value without mounting 10k rows":
    let storage = openListStore(base / "last.sqlite3")
    defer: storage.close()
    storage.saveItem(ListItem(id: 9999, note: "last row"))
    let runtime = newRuntime(nativeListApp(storage))
    defer: runtime.closeRuntime()
    discard runtime.materialize("items", 9998, 10000)
    check runtime.find("items").children.len == 3
    check runtime.find("items").children[0].listIndex == 9997
    check runtime.find("items").children[2].listIndex == 9999
    check runtime.find("edit-9998").node.text == ""
    check runtime.find("edit-9999").node.text == "last row"

  test "failed database write keeps the draft and shows failure rather than saved":
    let storage = openListStore(base / "write-failure.sqlite3")
    let runtime = newRuntime(nativeListApp(storage))
    defer: runtime.closeRuntime()
    discard runtime.materialize("items", 0, 1)
    discard runtime.dispatch("edit-0", Event(kind: change, value: "keep draft"))
    storage.close()
    discard runtime.dispatch("save-0", Event(kind: click))
    check runtime.find("status-0").node.text == "保存失败：database is closed"
    check runtime.find("edit-0").node.text == "keep draft"
