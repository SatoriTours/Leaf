import ./cleanup_support
import std/[unittest, os, tempfiles, tables, strutils]
import leaf/[core, components, backend, native_layout, styles]
import ../../examples/native_notes/[store, application]

let base = createTempDir("leaf-notes-app-", "")
removeDirectoryOnExit(base)

proc notebookBoxes(root: MountedNode, width: float64): Table[string, LayoutBox] =
  var entities: Table[NodeHandle, MountedEntity]
  var keys: Table[NodeHandle, string]
  proc collect(node: MountedNode, parent: NodeHandle, index: int) =
    let handle = NodeHandle(uint64(entities.len + 1))
    keys[handle] = node.node.key
    entities[handle] = MountedEntity(handle: handle, parent: parent, index: index,
      nodeId: node.id, kind: node.node.kind, props: normalizeProps(node.node))
    for i, child in node.children: collect(child, handle, i)
  collect(root, NoHandle, 0)
  # The critical boxes use explicit sizes or fill. Deliberately offer a large
  # intrinsic measure so text must not take width away from the commands.
  proc measure(entity: MountedEntity, available: DipSize): DipSize =
    DipSize(width: 600, height: 24)
  for box in layoutTree(entities, DipSize(width: width, height: 560), measure):
    result[keys[box.handle]] = box

suite "Leaf Notes real application":
  test "editor commands share a baseline and stay fully visible in a narrow window":
    let store = openNotesStore(base / "layout.sqlite3")
    defer: store.close()
    let rt = newRuntime(notesApp(store))
    defer: rt.closeRuntime()
    for width in [1000.0, 720.0]:
      let boxes = notebookBoxes(rt.find("notebook"), width)
      let first = boxes["favorite"].rect
      let last = boxes["save"].rect
      check first.width >= 72
      check first.height >= 32
      for key in ["favorite", "archive", "save"]:
        let box = boxes[key]
        check box.rect.width == first.width
        check box.rect.height == first.height
        check box.rect.y == first.y
        check box.rect.x >= box.clip.x
        check box.rect.x + box.rect.width <= box.clip.x + box.clip.width
      check last.x + last.width == boxes["title"].rect.x + boxes["title"].rect.width
      check boxes["body"].rect.width >= 280
      check boxes["body"].rect.height >= 220

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

  test "favourite views follow persisted flags and keep the search filter":
    # Mirrors the failing live step: seeds already carry two favourites, a new
    # note favourited in-session must appear in the favourites view, and the
    # search query survives a view change (it is not cleared by nav).
    let store = openNotesStore(base / "favorites-view.sqlite3")
    defer: store.close()
    let rt = newRuntime(notesApp(store))
    defer: rt.closeRuntime()
    check store.notes(view = notesFavorites).len == 2
    discard rt.dispatch("nav-favorites", Event(kind: click))
    check rt.find("listHeading").node.text == "已收藏"
    check rt.find("resultCount").node.text == "2 份笔记"
    discard rt.dispatch("nav-all", Event(kind: click))
    discard rt.dispatch("new", Event(kind: click))
    discard rt.dispatch("favorite", Event(kind: click))
    check store.notes(view = notesFavorites).len == 3
    discard rt.dispatch("nav-favorites", Event(kind: click))
    check rt.find("resultCount").node.text == "3 份笔记"
    check rt.find("title") != nil
    discard rt.dispatch("search", Event(kind: change, value: "专注"))
    check rt.find("resultCount").node.text == "1 份笔记"
    discard rt.dispatch("nav-all", Event(kind: click))
    check rt.find("resultCount").node.text == "1 份笔记"

  test "nav and tag bindings target their own view":
    # RED matrix for the loop-captured callbacks: every nav button and every tag
    # button must act on its own value, also after a re-render.
    let store = openNotesStore(base / "nav-matrix.sqlite3")
    defer: store.close()
    let rt = newRuntime(notesApp(store))
    defer: rt.closeRuntime()
    let view = proc(key: string): tuple[heading: string, count: string] =
      discard rt.dispatch(key, Event(kind: click))
      result.heading = rt.find("listHeading").node.text
      result.count = rt.find("resultCount").node.text
    var seen = view("nav-all")
    check seen.heading == "全部笔记"
    check seen.count == "4 份笔记"
    seen = view("nav-favorites")
    check seen.heading == "已收藏"
    check seen.count == "2 份笔记"
    seen = view("nav-archive")
    check seen.heading == "归档"
    check seen.count == "0 份笔记"
    check rt.find("emptyNotes") != nil
    # second pass after re-renders must still resolve per key
    seen = view("nav-favorites")
    check seen.count == "2 份笔记"
    seen = view("nav-all")
    check seen.count == "4 份笔记"
    seen = view("nav-favorites")
    check seen.count == "2 份笔记"
    # tags: 灵感 2, 日常 1, 项目 1 and each returns to its own filter
    seen = view("tag-灵感")
    check seen.heading == "灵感"
    check seen.count == "2 份笔记"
    seen = view("tag-日常")
    check seen.heading == "日常"
    check seen.count == "1 份笔记"
    seen = view("tag-项目")
    check seen.heading == "项目"
    check seen.count == "1 份笔记"
    seen = view("nav-all")
    check seen.heading == "全部笔记"
    check seen.count == "4 份笔记"

  test "selection and query stay consistent across nav and tags":
    let store = openNotesStore(base / "nav-query.sqlite3")
    defer: store.close()
    let rt = newRuntime(notesApp(store))
    defer: rt.closeRuntime()
    discard rt.dispatch("search", Event(kind: change, value: "专注"))
    check rt.find("resultCount").node.text == "1 份笔记"
    discard rt.dispatch("nav-favorites", Event(kind: click))
    check rt.find("resultCount").node.text == "1 份笔记"
    check rt.find("title") != nil
    discard rt.dispatch("tag-灵感", Event(kind: click))
    check rt.find("listHeading").node.text == "灵感"
    check rt.find("resultCount").node.text == "1 份笔记"
    discard rt.dispatch("search", Event(kind: change, value: ""))
    check rt.find("resultCount").node.text == "2 份笔记"
