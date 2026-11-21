## A small in-memory example; Save updates the list, not a database.
import std/strutils
import leaf

type
  Note = object
    id: int
    title: string
  Book = object
    query: string
    notes: array[2, Note]

proc matchingNotes(book: Book): seq[Note] =
  for note in book.notes:
    if book.query in note.title: result.add(note)

proc findNote(book: Book, id: int): Note =
  for note in book.notes:
    if note.id == id: return note
  raise newException(ValueError, "Unknown note: " & $id)

proc withNote(book: Book, draft: Note): Book =
  result = book
  for note in result.notes.mitems:
    if note.id == draft.id: note = draft

component NoteList:
  prop shown: seq[Note]
  event onSelect: int
  view:
    list shown, key = "notes", rowHeight = 36, styles = style({"height": "120", "width": "full"}):
      text item.title:
        key: "note-" & $item.id
      button "打开", key = "open-" & $item.id:
        onSelect(item.id)

component NoteEditor:
  model draft: Note
  event onSave
  view:
    column:
      text "编辑标题"
      textField draft.title, key = "title"
      button "保存", key = "save", disabled = draft.title.len == 0:
        onSave()

component ReadingList:
  state:
    book = Book(notes: [Note(id: 1, title: "Ada"), Note(id: 2, title: "Nim")])
    draft = book.notes[0]
    status = ""
  view:
    column:
      padding: 16
      gap: 8
      text "读书清单"
      textField book.query, placeholder = "搜索标题", key = "search"
      noteList book.matchingNotes:
        onSelect(id):
          draft = findNote(book, id)
          status = ""
      noteEditor draft:
        onSave:
          book = withNote(book, draft)
          status = "已保存：" & draft.title
      text status:
        key: "status"

proc readingListApp*(): Application =
  app(ReadingList, title = "Leaf · 读书清单", width = 520, height = 360)

when isMainModule:
  when defined(android) and not defined(leafHeadlessOnly):
    import leaf/mobile
    registerAndroidApplication(proc(resources: HostResources): Application =
      readingListApp())
  else:
    quit(run(readingListApp()))
