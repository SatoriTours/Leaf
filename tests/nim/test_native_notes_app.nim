import ./cleanup_support
import std/[unittest, os, tempfiles, tables, strutils]
import leaf/[core, components]
import ../../examples/native_notes/[store, application]

let base = createTempDir("leaf-notes-app-", "")
removeDirectoryOnExit(base)

suite "Leaf Notes real application":
  test "edits stay draft across note changes and only save persists across reopen":
    let path = base / "drafts.sqlite3"
    let store = openNotesStore(path)
    let rt = newRuntime(notesApp(store))
    let first = store.notes()[0].id
    let second = store.notes()[1].id
    discard rt.materialize("notes", 0, 4)
    discard rt.dispatch("title", Event(kind: change, value: "新的中文标题 😀"))
    discard rt.dispatch("body", Event(kind: change, value: "多行\n正文"))
    check store.loadNote(first).title == "Leaf 的第一份笔记"
    discard rt.dispatch("note-" & $second, Event(kind: click))
    discard rt.dispatch("note-" & $first, Event(kind: click))
    check rt.find("title").node.text == "新的中文标题 😀"
    check rt.find("body").node.text == "多行\n正文"
    check rt.find("saveStatus").node.text.contains("未保存")
    discard rt.dispatch("save", Event(kind: click))
    check rt.find("saveStatus").node.text == "所有更改已保存"
    rt.closeRuntime()
    store.close()
    let reopened = openNotesStore(path)
    defer: reopened.close()
    check reopened.loadNote(first).title == "新的中文标题 😀"
    check reopened.loadNote(first).body == "多行\n正文"

  test "search empty state recovers and new note is selectable":
    let store = openNotesStore(base / "search.sqlite3")
    defer: store.close()
    let rt = newRuntime(notesApp(store))
    defer: rt.closeRuntime()
    discard rt.dispatch("search", Event(kind: change, value: "找不到的笔记"))
    check rt.find("emptyNotes") != nil
    expect UiError: discard rt.find("title")
    discard rt.dispatch("search", Event(kind: change, value: ""))
    check rt.find("title") != nil
    discard rt.dispatch("new", Event(kind: click))
    check store.notes().len == 5
    check rt.find("title").node.text == "未命名笔记"

  test "favorite archive and restore use real persisted records":
    let store = openNotesStore(base / "organize.sqlite3")
    defer: store.close()
    let id = store.notes()[0].id
    let rt = newRuntime(notesApp(store))
    defer: rt.closeRuntime()
    discard rt.dispatch("favorite", Event(kind: click))
    check not store.loadNote(id).favorite
    discard rt.dispatch("archive", Event(kind: click))
    check store.loadNote(id).archived
    discard rt.dispatch("nav-archive", Event(kind: click))
    check rt.find("title").node.text == "Leaf 的第一份笔记"
    discard rt.dispatch("archive", Event(kind: click))
    check not store.loadNote(id).archived
    check rt.find("emptyNotes") != nil

  test "organizing a note never silently saves an edited title or body":
    let store = openNotesStore(base / "metadata.sqlite3")
    defer: store.close()
    let original = store.notes()[0]
    let rt = newRuntime(notesApp(store))
    defer: rt.closeRuntime()
    discard rt.dispatch("title", Event(kind: change, value: "未保存的新标题"))
    discard rt.dispatch("body", Event(kind: change, value: "未保存的正文"))
    discard rt.dispatch("favorite", Event(kind: click))
    check store.loadNote(original.id).title == original.title
    check store.loadNote(original.id).body == original.body
    check rt.find("title").node.text == "未保存的新标题"
    check rt.find("body").node.text == "未保存的正文"
    check rt.find("saveStatus").node.text.contains("未保存")

  test "blank title and failed writes preserve current draft and expose errors":
    let store = openNotesStore(base / "failure.sqlite3")
    let rt = newRuntime(notesApp(store))
    defer: rt.closeRuntime()
    discard rt.dispatch("title", Event(kind: change, value: "  "))
    discard rt.dispatch("save", Event(kind: click))
    check rt.find("saveStatus").node.text.contains("标题不能为空")
    check rt.find("title").node.text == "  "
    discard rt.dispatch("title", Event(kind: change, value: "不要丢失"))
    store.close()
    discard rt.dispatch("save", Event(kind: click))
    check rt.find("saveStatus").node.text.contains("保存失败")
    check rt.find("title").node.text == "不要丢失"
