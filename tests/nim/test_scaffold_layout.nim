## Exercise generated application state and the real shared layout engine.
## Regressions: intrinsic task titles/drafts must not push actions offscreen.
import ./[cleanup_support, migration_compile_support, scaffold_headless_support]
import std/[unittest, os, tempfiles, strutils]
import leaf/scaffold

let base = createTempDir("leaf-scaffold-layout-", "")
removeDirectoryOnExit(base)
discard generateScaffold(ScaffoldOptions(mode: smApplication), base)
discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note",
  fields: @["title:string"]), base)
writeHeadlessRows(base)
# Use the real Windows shell style in Linux's shared-native-layout probe too:
# its GTK/CSS min_width:0 branch is outside this engine's capability contract.
let shell = base / "app/shell.nim"
writeFile(shell, readFile(shell).replace("when defined(windows): style(",
  "when defined(windows) or defined(leafHeadlessOnly): style("))
# Select only the Windows list construction branch, without defining the OS
# globally (which would incorrectly select Win32 APIs on the Linux host).
let taskList = base / "app/pages/home/views/list.nim"
let listSource = readFile(taskList)
let listBranch = "when defined(android) or defined(windows):"
doAssert listBranch in listSource, "update the fixture when the template changes"
writeFile(taskList, listSource.replace(listBranch,
  "when defined(android) or defined(windows) or defined(leafHeadlessOnly):"))
writeFile(base / "layout_probe.nim", """
import std/[os, tables, strutils, unicode, math, options]
import leaf
import leaf/[backend, native_layout, styles]
import app/application
import config/database
import tests/headless_rows

let db = openApplicationDatabase(":memory:")
let rt = newRuntime(createApplication(db))
proc change(key, value: string) =
  doAssert rt.dispatchFixture(key, Event(kind: change, value: value))
proc click(key: string) =
  doAssert rt.dispatchFixture(key, Event(kind: click))

# Deterministic font metrics exercise width-sensitive layout, not Win32 pixels.
# Full native font/geometry and visual validation are separate required checks.
proc measure(entity: MountedEntity, available: DipSize): DipSize =
  case entity.kind
  of NodeKind.text:
    let natural = float64(entity.props.accessibility.label.get("").runeLen * 8)
    let width = max(1.0, available.width)
    DipSize(width: min(natural, width),
      height: (if natural == 0: 0.0 else: ceil(natural / width) * 20.0))
  of NodeKind.virtualList:
    # Match Win32Backend.measureControl: a viewport consumes the offered
    # width even before its lazy rows have been laid out.
    DipSize(width: available.width, height: 0)
  of NodeKind.input:
    DipSize(width: max(160.0, float64(entity.props.control.value.get("").runeLen * 8)), height: 40)
  of NodeKind.button:
    DipSize(width: float64(entity.props.control.label.get("").runeLen * 8 + 24), height: 32)
  of NodeKind.checkbox:
    DipSize(width: 60, height: 24)
  else: DipSize(width: 0, height: 0)

proc boxesFor(root: MountedNode, width: float64): Table[string, DipRect] =
  var entities: Table[NodeHandle, MountedEntity]
  var keys: Table[NodeHandle, string]
  var serial = 0'u64
  proc collect(node: MountedNode, parent: NodeHandle, index: int) =
    inc serial
    let handle = NodeHandle(serial)
    keys[handle] = node.node.key
    entities[handle] = MountedEntity(handle: handle, parent: parent,
      index: index, nodeId: $serial, kind: node.node.kind,
      props: normalizeProps(node.node))
    for i, child in node.children: collect(child, handle, i)
  collect(root, NoHandle, 0)
  for box in layoutTree(entities, DipSize(width: width, height: 600), measure):
    result[keys[box.handle]] = box.rect

proc parentOf(node: MountedNode, key: string): MountedNode =
  for child in node.children:
    if child.node.key == key: return node
    result = parentOf(child, key)
    if result != nil: return

proc checkTask(width: float64, title: string) =
  doAssert rt.find("task_title_1").node.text == title
  let boxes = boxesFor(rt.find("task_row_1"), width)
  let done = boxes["task_done_1"]
  let text = boxes["task_title_1"]
  let action = boxes["task_delete_1"]
  doAssert done.x >= 8 and done.width > 0
  doAssert text.width > 0 and text.x >= done.x + done.width + 12
  doAssert action.width >= 72 and action.height >= 32
  doAssert action.x >= text.x + text.width + 12
  doAssert action.x + action.width <= width - 8 + 0.01,
    "Delete must remain inside the task row at width " & $width & ": " & $action
  if title.runeLen > 100:
    doAssert text.height > 20, "long title wraps instead of hiding its action"

case paramStr(1)
of "empty-home":
  for value in ["", repeat("draft ", 50), ""]:
    change("task_draft", value)
    for width in [960.0, 584.0, 960.0]:
      let boxes = boxesFor(rt.snapshot.root, width)
      let edit = boxes["task_draft"]
      let add = boxes["task_add"]
      # 48px shell padding + 160px sidebar + 20px gap + 96px Add + 8px gap.
      doAssert abs(edit.width - (width - 332)) < 0.01,
        "empty home must allocate the whole page to its form: " & $edit
      doAssert abs(add.x + add.width - (width - 24)) < 0.01
of "long-title":
  let title = repeat("task title ", 12) & "中文 😀"
  change("task_draft", title)
  click("task_add")
  doAssert rt.find("task_list") != nil, "exercise the Windows virtual-list branch"
  doAssert rt.find("task_list").node.kind == NodeKind.virtualList
  for width in [960.0, 584.0, 960.0]:
    let page = boxesFor(rt.snapshot.root, width)
    let viewport = page["task_list"]
    doAssert abs(viewport.width - (width - 228)) < 0.01,
      "nonempty list must use the page width: " & $viewport
    doAssert viewport.height > 0
    doAssert viewport.x + viewport.width <= width - 24 + 0.01
  for width in [480.0, 320.0, 480.0]: checkTask(width, title.strip)
  doAssert db.query("SELECT title FROM tasks")[0][0].asString == title.strip
of "long-draft":
  let value = repeat("draft 中文 😀 ", 30)
  change("task_draft", value)
  let form = parentOf(rt.snapshot.root, "task_draft")
  doAssert form != nil
  for width in [480.0, 320.0, 480.0]:
    let boxes = boxesFor(form, width)
    let edit = boxes["task_draft"]
    let add = boxes["task_add"]
    doAssert edit.width > 0 and edit.height == 40
    doAssert add.width == 96 and add.height == 32
    doAssert add.x >= edit.x + edit.width + 8
    doAssert add.x + add.width <= width + 0.01,
      "Add must remain reachable after a long draft at width " & $width
  doAssert rt.find("task_draft").node.text == value
of "resource-editor-layout":
  click("nav_notes")
  click("notes_new")
  for value in ["", "short", repeat("note 中文 😀 ", 12), ""]:
    change("notes_field_title", value)
    for width in [960.0, 584.0, 960.0]:
      let boxes = boxesFor(rt.snapshot.root, width)
      let edit = boxes["notes_field_title"]
      let save = boxes["notes_save"]
      let cancel = boxes["notes_cancel"]
      doAssert abs(edit.width - (width - 228)) < 0.01,
        "resource editor must use the page width: " & $edit
      doAssert edit.height == 40 and save.width == 96 and cancel.width == 96
      doAssert save.y >= edit.y + edit.height
      doAssert cancel.x >= save.x + save.width + 8
      doAssert cancel.x + cancel.width <= width - 24 + 0.01
  click("notes_save")
  doAssert rt.find("notes_error").node.text.len > 0
  doAssert db.query("SELECT id FROM notes").len == 0
  change("notes_field_title", "corrected")
  click("notes_save")
  click("notes_edit_1")
  doAssert rt.find("notes_field_title").node.text == "corrected"
of "resource-long-content":
  let title = repeat("note title ", 12) & "中文 😀"
  click("nav_notes")
  click("notes_new")
  change("notes_field_title", title)
  click("notes_save")
  for width in [480.0, 320.0, 480.0]:
    let boxes = boxesFor(rt.find("notes_row_1"), width)
    let text = boxes["notes_title_1"]
    let view = boxes["notes_show_1"]
    let edit = boxes["notes_edit_1"]
    let delete = boxes["notes_delete_1"]
    doAssert text.x >= 12 and text.x + text.width <= width - 12 + 0.01
    doAssert text.height > 20
    doAssert view.y >= text.y + text.height + 8
    doAssert edit.x >= view.x + view.width + 8
    doAssert delete.x >= edit.x + edit.width + 8
    doAssert delete.x + delete.width <= width - 12 + 0.01
  click("notes_show_1")
  for width in [960.0, 584.0, 960.0]:
    let boxes = boxesFor(rt.snapshot.root, width)
    let detail = boxes["notes_detail_title"]
    let back = boxes["notes_back"]
    doAssert detail.height > 20
    doAssert detail.x + detail.width <= width - 24 + 0.01,
      "detail remains inside the Windows page: " & $detail
    doAssert back.y >= detail.y + detail.height + 12
  click("notes_back")
  click("notes_edit_1")
  change("notes_field_title", "short")
  click("notes_save")
  doAssert rt.find("notes_title_1").node.text == "short"
  doAssert db.query("SELECT title FROM notes")[0][0].asString == "short"
of "editor-switch":
  click("nav_notes")
  for title in ["first note", "second note"]:
    click("notes_new")
    change("notes_field_title", title)
    click("notes_save")
  click("notes_edit_1")
  change("notes_field_title", "unsaved 中文 😀")
  click("notes_cancel")
  click("notes_edit_2")
  doAssert rt.find("notes_field_title").node.text == "second note"
  change("notes_field_title", "saved 中文 😀")
  click("notes_save")
  click("nav_home")
  click("nav_notes")
  doAssert rt.find("notes_title_1").node.text == "first note"
  doAssert rt.find("notes_title_2").node.text == "saved 中文 😀"
  let rows = db.query("SELECT title FROM notes ORDER BY id")
  doAssert rows.len == 2
  doAssert rows[0][0].asString == "first note"
  doAssert rows[1][0].asString == "saved 中文 😀"
of "filter-restore":
  change("task_draft", "first 中文 😀")
  click("task_add")
  change("task_draft", "second item")
  click("task_add")
  click("nav_search")
  change("search_query", "no match")
  doAssert rt.find("home_empty") != nil
  change("search_query", "first")
  checkTask(320, "first 中文 😀")
  click("task_delete_1")
  doAssert rt.find("home_empty") != nil
  change("search_query", "")
  doAssert rt.find("task_title_2").node.text == "second item"
  doAssert db.query("SELECT title FROM tasks").len == 1
else: doAssert false
rt.closeRuntime()
db.close()
""")
let compiled = buildProbe(base, "layout_probe.nim", base / "cache",
  extraArgs = @["-d:leafHeadlessOnly"])
suite "generated application dynamic layout":
  for scenario in ["empty-home", "long-title", "long-draft", "filter-restore",
      "editor-switch", "resource-editor-layout", "resource-long-content"]:
    test scenario:
      if compiled.code != 0: checkpoint compiled.output
      require compiled.code == 0
      let ran = runManagedBounded(compiled.binary, @[scenario], base, seconds = 20)
      checkpoint ran.output
      check ran.code == 0
