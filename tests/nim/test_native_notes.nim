## Real SQLite and real component events; no UI/storage mocks.
import ./cleanup_support
import std/[unittest, os, tempfiles, strutils]
import leaf/[core, components, sqlite]
import ../../examples/native_notes/store

let base = createTempDir("leaf-notes-", "")
removeDirectoryOnExit(base)

suite "Leaf Notes local notebook":
  test "first launch seeds useful notes only once and reopen preserves edits":
    let path = base / "中文 空格" / "notes.sqlite3"
    let db = openNotesStore(path)
    check db.notes().len == 4
    var note = db.notes()[0]
    note.title = "中文 😀 ' 引号"
    note.body = "第一行\n第二行\n'); DROP TABLE notes; --"
    db.save(note)
    db.close()
    let reopened = openNotesStore(path)
    defer: reopened.close()
    check reopened.notes().len == 4
    check reopened.loadNote(note.id).title == "中文 😀 ' 引号"
    check reopened.loadNote(note.id).body == "第一行\n第二行\n'); DROP TABLE notes; --"

  test "new note gets a stable id and search covers title and body":
    let db = openNotesStore(base / "search.sqlite3")
    defer: db.close()
    let id = db.createNote()
    var note = db.loadNote(id)
    note.title = "Project LEAF"
    note.body = "只有正文包含：松石😀"
    db.save(note)
    check db.notes("project leaf").len == 1
    check db.notes("松石😀").len == 1
    check db.notes("无此内容").len == 0
    check db.notes("松石😀")[0].id == id

  test "favorite and archive filters are persisted independently":
    let path = base / "filters.sqlite3"
    let db = openNotesStore(path)
    let id = db.createNote()
    var note = db.loadNote(id)
    note.favorite = true
    db.save(note)
    check db.notes(view = notesFavorites).len >= 1
    note.archived = true
    db.save(note)
    for item in db.notes(): check item.id != id
    for item in db.notes(view = notesFavorites): check item.id != id
    check db.notes(view = notesArchive).len == 1
    db.close()
    let reopened = openNotesStore(path)
    defer: reopened.close()
    check reopened.loadNote(id).favorite
    check reopened.loadNote(id).archived

  test "blank title and closed database fail without destroying saved note":
    let db = openNotesStore(base / "failure.sqlite3")
    var note = db.notes()[0]
    let original = note.title
    note.title = " \t\n "
    expect ValueError: db.save(note)
    check db.loadNote(note.id).title == original
    db.close()
    note.title = "未丢失的草稿"
    expect DatabaseError: db.save(note)
