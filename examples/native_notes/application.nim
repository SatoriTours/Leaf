## A real three-pane Leaf application. Store is borrowed until run() returns.
import std/[strutils, unicode]
import leaf/[core, widgets, components, native_theme]
import ./store

type Notebook = object
  drafts, saved: seq[Note]
  selected: int
  query, tag, status: string
  view: NotesView

proc snapshot(model: Notebook): Notebook =
  result = model
  result.drafts = @[]
  result.saved = @[]
  for note in model.drafts: result.drafts.add(note)
  for note in model.saved: result.saved.add(note)

proc indexOf(model: Notebook, id: int): int =
  for index, note in model.drafts:
    if note.id == id: return index
  -1

proc dirty(model: Notebook, note: Note): bool =
  for saved in model.saved:
    if saved.id == note.id: return note != saved
  true

proc visible(model: Notebook): seq[Note] =
  let needle = unicode.toLower(strutils.strip(model.query))
  for note in model.drafts:
    let inView = case model.view
      of notesAll: not note.archived
      of notesFavorites: note.favorite and not note.archived
      of notesArchive: note.archived
    if inView and (model.tag.len == 0 or note.tag == model.tag) and
        (needle.len == 0 or unicode.toLower(note.title & "\n" & note.body).contains(needle)):
      result.add(note)

proc reconcileSelection(model: var Notebook) =
  let shown = model.visible()
  for note in shown:
    if note.id == model.selected: return
  model.selected = if shown.len > 0: shown[0].id else: 0

proc viewLabel(view: NotesView): string =
  case view
  of notesAll: "全部笔记"
  of notesFavorites: "已收藏"
  of notesArchive: "归档"

proc excerpt(value: string): string =
  for line in value.splitLines():
    if strutils.strip(line).len > 0:
      let runes = line.toRunes()
      return $runes[0 ..< min(22, runes.len)]
  "还没有正文，写下第一个想法。"

proc persist(model: Notebook, storage: NotesStore, favorite = false, archive = false): Notebook =
  result = model.snapshot()
  let index = model.indexOf(model.selected)
  if index < 0: return
  var note = model.drafts[index]
  try:
    var stored = if favorite or archive: storage.loadNote(note.id) else: note
    if favorite:
      stored.favorite = not note.favorite
      note.favorite = stored.favorite
    if archive:
      stored.archived = not note.archived
      note.archived = stored.archived
    storage.save(stored)
    stored = storage.loadNote(note.id)
    if not favorite and not archive: note = stored
    else: note.updated = stored.updated
    result.drafts[index] = note
    for i in 0 ..< result.saved.len:
      if result.saved[i].id == note.id: result.saved[i] = stored
    result.status = ""
    if archive: result.reconcileSelection()
  except CatchableError as error:
    result.status = "保存失败：" & error.msg

proc navAction(target: NotesView, state: State[Notebook]): Callback =
  ## Bind the target by parameter. Capturing the loop-local value made every
  ## navigation button act on the final enum value (archive).
  result = proc(e: Event) =
    discard state.update(proc(value: Notebook): Notebook =
      result = value
      result.view = target
      result.tag = ""
      result.status = ""
      result.reconcileSelection())

proc tagAction(filter: string, state: State[Notebook]): Callback =
  ## Same reason as navAction: capture the filter by parameter.
  result = proc(e: Event) =
    discard state.update(proc(value: Notebook): Notebook =
      result = value
      result.view = notesAll
      result.tag = filter
      result.status = ""
      result.reconcileSelection())

proc quiet(label, key: string, selected: bool, action: Callback): Node =
  button(label, key=key, variant=(if selected: "primary" else: "ghost"),
    styles=style({"width":"full", "height":"34"}), onClick=action)

let NotebookView = defineComponent[NotesStore, State[Notebook]]("LeafNotes",
  proc(ctx: MountContext, storage: NotesStore): State[Notebook] =
    let records = storage.notes() & storage.notes(view=notesArchive)
    ctx.state(Notebook(drafts: records, saved: records,
      selected: (if records.len > 0: records[0].id else: 0)), snapshot=snapshot),
  proc(ctx: ComponentContext, storage: NotesStore, state: State[Notebook]): UiDescription =
    let model = ctx.value(state)
    let shown = model.visible()
    let currentIndex = model.indexOf(model.selected)
    let actionStyle = style({"height":"32"})
    var navigation = @[
      text("Leaf Notes", key="brand", variant="primary", styles=style({"height":"36"})),
      text("想法，有处安放。", key="brandHint", variant="secondary",
        styles=style({"height":"28"})),
      button("＋ 新建笔记", key="new", styles=style({"width":"full", "height":"34"}),
        onClick=proc(e: Event) =
          var next = model.snapshot()
          try:
            let id = storage.createNote()
            let note = storage.loadNote(id)
            next.drafts.insert(note, 0)
            next.saved.insert(note, 0)
            next.selected = id
            next.query = ""; next.tag = ""; next.view = notesAll; next.status = ""
          except CatchableError as error:
            next.status = "新建失败：" & error.msg
          discard state.set(next)),
      text("我的空间", key="space", variant="secondary", styles=style({"height":"32"}))]
    for view in NotesView:
      let key = case view
        of notesAll: "nav-all"
        of notesFavorites: "nav-favorites"
        of notesArchive: "nav-archive"
      navigation.add(quiet(view.viewLabel, key, model.view == view and model.tag.len == 0,
        navAction(view, state)))
    navigation.add(text("标签", key="tagsLabel", variant="secondary",
      styles=style({"height":"40"})))
    for label in ["灵感", "日常", "项目"]:
      navigation.add(quiet("·  " & label, "tag-" & label, model.tag == label,
        tagAction(label, state)))
    navigation.add(column(@[], key="navSpace", styles=style({"height":"full", "flex_grow":"1"})))
    navigation.add(separator(key="navRule", styles=style({"width":"full"})))
    navigation.add(text("仅存于本机 · SQLite", key="local", variant="secondary"))

    var keys: seq[string]
    for note in shown: keys.add($note.id)
    let list = virtualList("notes", keys,
      proc(index: int): Node =
        let note = shown[index]
        let id = note.id
        column(@[
          button((if note.favorite: "☆ " else: "") & note.title, key="note-" & $id,
            variant="ghost", styles=style({"width":"full", "height":"32"}),
            onClick=proc(e: Event) =
              discard state.update(proc(value: Notebook): Notebook =
                result = value; result.selected = id; result.status = "")),
          text(note.body.excerpt, key="excerpt-" & $id, variant="secondary",
            styles=style({"width":"full", "height":"20"})),
          text(note.tag & "  ·  " & note.updated &
            (if model.dirty(note): "  ·  未保存" else: ""), key="meta-" & $id,
            variant="secondary", styles=style({"height":"18"}))],
          key="card-" & $id, variant=(if model.selected == id: "primary" else: "secondary"),
          styles=style({"padding":"10", "gap":"3", "width":"full", "height":"100"})),
      rowHeight=100, overscan=1,
      styles=style({"width":"full", "height":"full", "flex_grow":"1"}))
    var listChildren = @[
      text((if model.tag.len > 0: model.tag else: model.view.viewLabel),
        key="listHeading", variant="primary", styles=style({"height":"36"})),
      input(model.query, key="search", placeholder="搜索标题与正文",
        styles=style({"width":"full", "height":"36"}),
        onChange=proc(e: Event) =
          discard state.update(proc(value: Notebook): Notebook =
            result = value; result.query = e.value; result.status = ""
            result.reconcileSelection())),
      text($shown.len & " 份笔记", key="resultCount", variant="secondary",
        styles=style({"height":"22"}))]
    if shown.len == 0:
      listChildren.add(text("没有找到笔记\n试试其他关键词，或新建一份。", key="emptyNotes",
        variant="secondary", styles=style({"width":"full", "height":"64"})))
    else: listChildren.add(list)

    var editor: Node
    if currentIndex < 0:
      editor = column(@[
        text("留一点空间，给新的想法。", key="emptyEditor", variant="primary"),
        text("选择左侧笔记，或点击「新建笔记」开始。", key="emptyHint", variant="secondary"),
        text(model.status, key="saveStatus", variant="danger")], key="editor",
        variant="primary", styles=style({"width":"full", "height":"full", "padding":"40", "gap":"16"}))
    else:
      let note = model.drafts[currentIndex]
      let isDirty = model.dirty(note)
      let status = if model.status.len > 0: model.status
        elif isDirty: "更改尚未保存 · 关闭前请保存"
        else: "所有更改已保存"
      editor = column(@[
        row(@[
          text(model.view.viewLabel & "  /  笔记", key="breadcrumb", variant="secondary",
            styles=style({"width":"full"})),
          button((if note.favorite: "取消收藏" else: "收藏"), key="favorite", variant="ghost",
            styles=actionStyle, onClick=proc(e: Event) =
              discard state.set(model.persist(storage, favorite=true))),
          button((if note.archived: "移回笔记" else: "归档"), key="archive", variant="ghost",
            styles=actionStyle, onClick=proc(e: Event) =
              discard state.set(model.persist(storage, archive=true))),
          button("保存", key="save", styles=style({"width":"80", "height":"32"}),
            onClick=proc(e: Event) =
              discard state.set(model.persist(storage)))],
          key="editorToolbar", styles=style({"width":"full", "height":"32", "gap":"8", "align":"center"})),
        separator(key="editorRule", styles=style({"width":"full"})),
        text(note.tag & "  /  本地笔记", key="noteTag", variant="secondary",
          styles=style({"height":"24"})),
        input(note.title, key="title", placeholder="给这份笔记起个名字",
          resetToken=uint64(note.id), variant="primary",
          styles=style({"width":"full", "height":"52"}),
          onChange=proc(e: Event) =
            discard state.update(proc(value: Notebook): Notebook =
              result = value; let i = result.indexOf(note.id)
              if i >= 0: result.drafts[i].title = e.value
              result.status = "")),
        text("编辑于 " & note.updated & "  ·  " & $unicode.runeLen(note.body) & " 字",
          key="noteTime", variant="secondary", styles=style({"height":"24"})),
        input(note.body, key="body", multiline=true, resetToken=uint64(note.id), variant="ghost",
          styles=style({"width":"full", "height":"full", "flex_grow":"1"}),
          onChange=proc(e: Event) =
            discard state.update(proc(value: Notebook): Notebook =
              result = value; let i = result.indexOf(note.id)
              if i >= 0: result.drafts[i].body = e.value.replace("\r\n", "\n")
              result.status = "")),
        text(status, key="saveStatus", variant=(if model.status.len > 0: "danger" else: "secondary"),
          styles=style({"width":"full", "height":"22"}))],
        key="editor", variant="primary",
        styles=style({"width":"full", "height":"full", "padding":"28", "gap":"12"}))
    host(row(@[
      column(navigation, key="navigation", styles=style({"width":"182", "height":"full", "padding":"18", "gap":"8"})),
      column(listChildren, key="noteList", variant="secondary",
        styles=style({"width":"272", "height":"full", "padding":"18", "gap":"12"})),
      editor], key="notebook", styles=style({"width":"full", "height":"full", "gap":"1"}))))

proc notesApp*(storage: NotesStore, theme = matsuLight): Application =
  componentApplication(component(NotebookView, storage), "Leaf Notes", 1184, 660).withNativeTheme(theme)
