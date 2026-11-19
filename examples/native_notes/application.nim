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
    let paragraph = strutils.strip(line)
    if paragraph.len > 0:
      # Leave room for the ellipsis in the fixed-width list at CJK glyph widths.
      let runes = paragraph.toRunes()
      return $runes[0 ..< min(12, runes.len)] & (if runes.len > 12: "…" else: "")
  "还没有正文"

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

let
  navigationControl = style({"width":"full", "height":"34"})
  editorCommand = style({"width":"84", "height":"34"})
  editorPane = style({"width":"full", "height":"full", "padding":"20", "gap":"8"})

proc navigationItem(label, key: string, selected: bool, action: Callback): Node =
  # Keep the native button left-aligned in both states. A separate surface
  # marks the current view without giving it the weight of a primary command.
  column(@[button(label, key=key, variant="ghost", styles=navigationControl,
    onClick=action)], key=key & "-surface",
    variant=(if selected: "primary" else: "default"), styles=navigationControl)

let NotebookView = defineComponent[NotesStore, State[Notebook]]("LeafNotes",
  proc(ctx: MountContext, storage: NotesStore): State[Notebook] =
    let records = storage.notes() & storage.notes(view=notesArchive)
    ctx.state(Notebook(drafts: records, saved: records,
      selected: (if records.len > 0: records[0].id else: 0)), snapshot=snapshot),
  proc(ctx: ComponentContext, storage: NotesStore, state: State[Notebook]): UiDescription =
    let model = ctx.value(state)
    let shown = model.visible()
    let currentIndex = model.indexOf(model.selected)
    var navigation = @[
      text("Leaf Notes", key="brand", variant="primary",
        styles=style({"width":"full", "height":"32"})),
      text("本地写作空间", key="brandHint", variant="secondary",
        styles=style({"width":"full", "height":"20"})),
      button("新建笔记", key="new", variant="secondary", styles=navigationControl,
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
      text("笔记库", key="space", variant="secondary",
        styles=style({"width":"full", "height":"26"}))]
    var views: seq[Node]
    for view in NotesView:
      let key = case view
        of notesAll: "nav-all"
        of notesFavorites: "nav-favorites"
        of notesArchive: "nav-archive"
      views.add(navigationItem(view.viewLabel, key,
        model.view == view and model.tag.len == 0, navAction(view, state)))
    navigation.add(column(views, key="views", styles=style({"width":"full", "gap":"2"})))
    navigation.add(text("标签", key="tagsLabel", variant="secondary",
      styles=style({"width":"full", "height":"26"})))
    var tags: seq[Node]
    for label in ["灵感", "日常", "项目"]:
      tags.add(navigationItem("·  " & label, "tag-" & label, model.tag == label, tagAction(label, state)))
    navigation.add(column(tags, key="tags", styles=style({"width":"full", "gap":"2"})))
    navigation.add(column(@[], key="navSpace", styles=style({"height":"full"})))
    navigation.add(text("仅存于本机", key="local", variant="secondary",
      styles=style({"width":"full", "height":"22"})))

    var keys: seq[string]
    for note in shown: keys.add($note.id)
    let list = virtualList("notes", keys,
      proc(index: int): Node =
        let note = shown[index]
        let id = note.id
        let selected = id == model.selected
        column(@[
          button(note.title, key="note-" & $id, variant="ghost", styles=navigationControl,
            onClick=proc(e: Event) =
              discard state.update(proc(value: Notebook): Notebook =
                result = value; result.selected = id; result.status = "")),
          column(@[
            text(note.body.excerpt, key="excerpt-" & $id, variant="secondary",
              styles=style({"width":"full", "height":"18"})),
            text(note.tag & (if note.favorite: " · 已收藏" else: "") &
              (if model.dirty(note): " · 未保存" elif selected: " · 正在编辑" else: ""),
              key="meta-" & $id, variant="secondary", styles=style({"width":"full", "height":"18"}))],
            key="details-" & $id, styles=style({"width":"full", "padding":"8", "gap":"2"}))],
          key="card-" & $id, variant=(if selected: "primary" else: "secondary"),
          styles=style({"width":"full", "height":"92"})),
      rowHeight=92, overscan=1,
      styles=style({"width":"full", "height":"full", "flex_grow":"1"}))
    var listChildren = @[
      text((if model.tag.len > 0: model.tag else: model.view.viewLabel),
        key="listHeading", variant="primary", styles=navigationControl),
      input(model.query, key="search", placeholder="搜索标题与正文",
        styles=navigationControl,
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
        text("未选择笔记", key="emptyEditor", variant="primary", styles=navigationControl),
        text("从列表选择笔记，或新建一份。", key="emptyHint", variant="secondary",
          styles=style({"width":"full", "height":"44"})),
        text(model.status, key="saveStatus", variant="danger",
          styles=style({"width":"full", "height":"28"}))], key="editor",
        variant="primary", styles=editorPane)
    else:
      let note = model.drafts[currentIndex]
      let isDirty = model.dirty(note)
      let status = if model.status.len > 0: model.status
        elif isDirty: "更改尚未保存 · 关闭前请保存"
        else: "所有更改已保存"
      editor = column(@[
        row(@[
          button((if note.favorite: "取消收藏" else: "收藏"), key="favorite", variant="secondary",
            styles=editorCommand, onClick=proc(e: Event) =
              discard state.set(model.persist(storage, favorite=true))),
          button((if note.archived: "移回笔记" else: "归档"), key="archive", variant="secondary",
            styles=editorCommand, onClick=proc(e: Event) =
              discard state.set(model.persist(storage, archive=true))),
          button("保存", key="save", styles=editorCommand,
            onClick=proc(e: Event) =
              discard state.set(model.persist(storage)))],
          key="editorToolbar", styles=style({"width":"full", "height":"34", "gap":"8", "justify":"end"})),
        text(note.tag & " · 本地笔记", key="noteTag", variant="secondary",
          styles=style({"width":"full", "height":"24"})),
        input(note.title, key="title", placeholder="给这份笔记起个名字",
          resetToken=uint64(note.id), variant="primary",
          styles=style({"width":"full", "height":"44"}),
          onChange=proc(e: Event) =
            discard state.update(proc(value: Notebook): Notebook =
              result = value; let i = result.indexOf(note.id)
              if i >= 0: result.drafts[i].title = e.value
              result.status = "")),
        input(note.body, key="body", multiline=true, resetToken=uint64(note.id), variant="ghost",
          styles=style({"width":"full", "height":"full", "flex_grow":"1"}),
          onChange=proc(e: Event) =
            discard state.update(proc(value: Notebook): Notebook =
              result = value; let i = result.indexOf(note.id)
              if i >= 0: result.drafts[i].body = e.value.replace("\r\n", "\n")
              result.status = "")),
        text(status, key="saveStatus", variant=(if model.status.len > 0: "danger" else: "secondary"),
          styles=style({"width":"full", "height":"22"}))],
        key="editor", variant="primary", styles=editorPane)
    host(row(@[
      column(navigation, key="navigation",
        styles=style({"width":"168", "height":"full", "padding":"20", "gap":"8"})),
      column(listChildren, key="noteList", variant="secondary",
        styles=style({"width":"224", "height":"full", "padding":"20", "gap":"8"})),
      editor], key="notebook", styles=style({"width":"full", "height":"full", "gap":"1"}))))

proc notesApp*(storage: NotesStore, theme = matsuLight): Application =
  componentApplication(component(NotebookView, storage), "Leaf Notes", 984, 580).withNativeTheme(theme)
