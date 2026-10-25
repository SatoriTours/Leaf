## Schema 2 pages keep draft values separate from persisted model objects.
import std/strutils
import ./[scaffold_types, scaffold_model_templates]

proc logicCode(resource: ResourceSpec): string =
  let m = "record_model." & resource.model
  result = "import leaf\ntype\n  Panel = enum listPanel, editorPanel, detailPanel\n  Draft = object\n"
  for field in resource.fields:
    result.add("    " & field.name & ": " & (if field.kind == "bool": "bool" else: "string") & "\n")
  result.add("  State = ref object\n    draft: Draft\n    panel: Panel\n    editingId, selectedId: int64\n    error: string\n    model: leaf.State[State]\n\nproc toDraft(value: " & m & "): Draft =\n")
  for field in resource.fields:
    result.add("  result." & field.name & " = " & (if field.kind in ["bool", "string"]: "" else: "$") & "value." & field.name & "\n")
  result.add("\nproc snapshotState(state: State): State =\n  State(draft: state.draft, panel: state.panel, editingId: state.editingId,\n    selectedId: state.selectedId, error: state.error)\n\nproc edit(state: State, change: proc(v: var State)) =\n  discard state.model.update(proc(current: State): State =\n    result = snapshotState(current)\n    change(result))\n\n")
  result.add("proc back(state: State) =\n  state.edit(proc(v: var State) = (v.panel = listPanel; v.error = \"\"))\n\nproc beginNew(state: State) =\n  state.edit(proc(v: var State) =\n    (v.draft = Draft(); v.editingId = 0; v.error = \"\"; v.panel = editorPanel))\n\nproc beginEdit(state: State, id: int64) =\n  let value = " & m & ".find(id)\n  state.edit(proc(v: var State) =\n    (v.draft = toDraft(value); v.editingId = id; v.error = \"\";\n     v.panel = editorPanel))\n\nproc show(state: State, id: int64) =\n  discard " & m & ".find(id)\n  state.edit(proc(v: var State) =\n    (v.selectedId = id; v.panel = detailPanel))\n\nproc remove(state: State, id: int64) =\n  var panel = state.model.read().panel\n  var error = \"\"\n  try:\n    " & m & ".find(id).destroyOrRaise()\n    panel = listPanel\n  except PostCommitError as caught:\n    panel = listPanel\n    error = caught.msg\n  except CatchableError as caught: error = caught.msg\n  state.edit(proc(v: var State) = (v.panel = panel; v.error = error))\n\nproc submit(state: State) =\n  let current = state.model.read()\n  var draft = current.draft\n  var editingId = current.editingId\n  var panel = current.panel\n  var error = \"\"\n  try:\n    let value = if editingId == 0: " & m & ".build() else: " & m & ".find(editingId)\n")
  for field in resource.fields:
    let expression = case field.kind
      of "int": "parseInt(current.draft." & field.name & ".strip())"
      of "float": "parseFloat(current.draft." & field.name & ".strip())"
      else: "current.draft." & field.name
    result.add("    value." & field.name & " = " & expression & "\n")
  result.add("    if value.save():\n      draft = Draft()\n      editingId = 0\n      panel = listPanel\n    else: error = errors(value).fullMessages.join(\"\\n\")\n  except PostCommitError as caught:\n    draft = Draft()\n    editingId = 0\n    panel = listPanel\n    error = caught.msg\n  except CatchableError as caught: error = caught.msg\n  state.edit(proc(v: var State) =\n    (v.draft = draft; v.editingId = editingId; v.panel = panel; v.error = error))\n\n")

proc listCode(resource: ResourceSpec): string =
  let p = resource.plural
  result = "proc renderRecord(state: State, item: " & "record_model." & resource.model & "): Node =\n  let id = item.id\n  view:\n    column:\n      key: \"" & p & "_row_\" & $id\n      styles: {\"gap\": \"8\", \"padding\": \"12\"}\n"
  for field in resource.fields:
    result.add("      text " & (if field.kind == "string": "" else: "$") & "item." & field.name & ":\n        key: \"" & p & "_" & field.name & "_\" & $id\n")
  let actions = "      row:\n        styles: {\"gap\": \"8\"}\n        button \"View\":\n          key: \"" & p & "_show_\" & $id\n          variant: \"secondary\"\n          styles: {\"height\": \"32\"}\n          onClick(e): state.show(id)\n        button \"Edit\":\n          key: \"" & p & "_edit_\" & $id\n          variant: \"secondary\"\n          styles: {\"height\": \"32\"}\n          onClick(e): state.beginEdit(id)\n        button \"Delete\":\n          key: \"" & p & "_delete_\" & $id\n          variant: \"secondary\"\n          styles: {\"height\": \"32\"}\n          onClick(e): state.remove(id)\n\n"
  result.add("      when defined(android):\n")
  for line in actions.replace("      row:", "      column:").splitLines():
    if line.len > 0: result.add("  " & line & "\n")
  result.add("      else:\n")
  for line in actions.splitLines():
    if line.len > 0: result.add("  " & line & "\n")

  let desktopList = "proc renderList(state: State): Node =\n  let items = record_model." & resource.model & ".all\n  view:\n    column:\n      styles: {\"gap\": \"12\", \"overflow\": \"scroll\", \"flex_grow\": \"1\"}\n      button \"New " & resource.model & "\":\n        key: \"" & p & "_new\"\n        onClick(e): state.beginNew()\n      text state.error:\n        key: \"" & p & "_error\"\n        variant: \"danger\"\n      if items.len == 0:\n        emptyState(\"No records yet\", \"" & p & "_empty\")\n      for item in items:\n        renderRecord(state, item)\n"
  let nativeList = """  when defined(android) or defined(windows):
    var keys: seq[string]
    for item in items: keys.add($item.id)
    let rows = virtualList("@P@_list", keys,
      proc(index: int): Node = renderRecord(state, items[index]),
      rowHeight = 0, estimatedHeight = 120, overscan = 1,
      styles = style({"flex_grow": "1", "width": "full"}))
    view:
      column:
        styles: {"gap": "12", "flex_grow": "1"}
        button "New @MODEL@":
          key: "@P@_new"
          onClick(e): state.beginNew()
        text state.error:
          key: "@P@_error"
          variant: "danger"
        if items.len == 0:
          emptyState("No records yet", "@P@_empty")
        else:
          rows
  else:
""".replace("@P@", p).replace("@MODEL@", resource.model)
  let bodyStart = desktopList.find("  view:")
  result.add(desktopList[0 ..< bodyStart])
  result.add(nativeList)
  for line in desktopList[bodyStart .. ^1].splitLines():
    if line.len > 0: result.add("  " & line & "\n")

proc editorCode(resource: ResourceSpec): string =
  let p = resource.plural
  result = "proc renderEditor(state: State): Node =\n  view:\n    column:\n      styles: {\"gap\": \"12\"}\n      text (if state.editingId == 0: \"Create " & resource.model & "\" else: \"Edit " & resource.model & "\"):\n        variant: \"primary\"\n"
  for field in resource.fields:
    result.add("      text " & field.name.escape & ":\n        variant: \"secondary\"\n")
    if field.kind == "bool":
      result.add("      checkbox(" & field.name.escape & ", state.draft." & field.name & "):\n        key: \"" & p & "_field_" & field.name & "\"\n        onChange(e): state.edit(proc(v: var State) = v.draft." & field.name & " = e.checked)\n")
    else:
      result.add("      input state.draft." & field.name & ":\n        key: \"" & p & "_field_" & field.name & "\"\n        styles: {\"width\": \"full\", \"height\": \"40\"}\n        onChange(e): state.edit(proc(v: var State) = v.draft." & field.name & " = e.value)\n")
  result.add("      text state.error:\n        key: \"" & p & "_error\"\n        variant: \"danger\"\n      row:\n        styles: {\"gap\": \"8\"}\n        button \"Save\":\n          key: \"" & p & "_save\"\n          styles: {\"width\": \"96\", \"height\": \"32\"}\n          onClick(e): state.submit()\n        button \"Cancel\":\n          key: \"" & p & "_cancel\"\n          variant: \"secondary\"\n          styles: {\"width\": \"96\", \"height\": \"32\"}\n          onClick(e): state.back()\n")

proc detailCode(resource: ResourceSpec): string =
  let p = resource.plural
  result = "proc renderDetail(state: State): Node =\n  let item = record_model." & resource.model & ".find(state.selectedId)\n  view:\n    column:\n      styles: {\"gap\": \"12\"}\n      text \"" & resource.model & " #\" & $item.id:\n        variant: \"primary\"\n"
  for field in resource.fields:
    result.add("      text " & field.name.escape & "\n      text " & (if field.kind == "string": "" else: "$") & "item." & field.name & ":\n        key: \"" & p & "_detail_" & field.name & "\"\n")
  result.add("      button \"Back\":\n        key: \"" & p & "_back\"\n        variant: \"secondary\"\n        styles: {\"height\": \"32\"}\n        onClick(e): state.back()\n")

proc resourceFilesV2*(resource: ResourceSpec): seq[ScaffoldFile] =
  let p = resource.plural
  let base = "app/pages/" & p & "/"
  result.add(ScaffoldFile(path: "app/models/" & resource.singular & ".nim", content: modelCodeV2(resource)))
  result.add(ScaffoldFile(path: base & "logic.nim", content: logicCode(resource)))
  result.add(ScaffoldFile(path: base & "views/list.nim", content: listCode(resource)))
  result.add(ScaffoldFile(path: base & "views/editor.nim", content: editorCode(resource)))
  result.add(ScaffoldFile(path: base & "views/detail.nim", content: detailCode(resource)))
  result.add(ScaffoldFile(path: base & "views/index.nim", content: "proc renderIndex(state: State): Node =\n  case state.panel\n  of listPanel: renderList(state)\n  of editorPanel: renderEditor(state)\n  of detailPanel: renderDetail(state)\n"))
  result.add(ScaffoldFile(path: base & "page.nim", content:
    "import std/strutils\nimport leaf\nimport leaf/model\nfrom ../../models/" & resource.singular & " as record_model import build, modelTable, modelFields, modelValues, assignModelValues, storageType, toStorage, fromStorage, runValidations, runCallbacks\nimport ../../components/empty_state\n\ninclude logic\ninclude views/list\ninclude views/editor\ninclude views/detail\ninclude views/index\n\nproc definition*(): ComponentPageDefinition =\n  let page = defineComponent[int, leaf.State[State]](\"" & resource.model & "Page\",\n    proc(ctx: MountContext, p: int): leaf.State[State] =\n      ctx.state(State(), snapshot = snapshotState),\n    proc(ctx: ComponentContext, p: int, model: leaf.State[State]): UiDescription =\n      let state = ctx.value(model)\n      state.model = model\n      host(renderIndex(state)))\n  ComponentPageDefinition(name: \"" & p & "\", views: @[\"index\"],\n    build: proc(view: string): UiDescription = component(page, 0))\n"))