## Schema 2 pages keep draft values separate from persisted model objects.
import std/strutils
import ./[scaffold_types, scaffold_model_templates]

proc logicCode(resource: ResourceSpec): string =
  let m = "record_model." & resource.model
  result = "type\n  Panel = enum listPanel, editorPanel, detailPanel\n  Draft = object\n"
  for field in resource.fields:
    result.add("    " & field.name & ": " & (if field.kind == "bool": "bool" else: "string") & "\n")
  result.add("  State = ref object\n    draft: Draft\n    panel: Panel\n    editingId, selectedId: int64\n    error: string\n\nproc toDraft(value: " & m & "): Draft =\n")
  for field in resource.fields:
    result.add("  result." & field.name & " = " & (if field.kind in ["bool", "string"]: "" else: "$") & "value." & field.name & "\n")
  result.add("\nproc back(state: State) =\n  state.panel = listPanel\n  state.error = \"\"\n\nproc beginNew(state: State) =\n  state.draft = Draft()\n  state.editingId = 0\n  state.error = \"\"\n  state.panel = editorPanel\n\nproc beginEdit(state: State, id: int64) =\n  state.draft = toDraft(" & m & ".find(id))\n  state.editingId = id\n  state.error = \"\"\n  state.panel = editorPanel\n\nproc show(state: State, id: int64) =\n  discard " & m & ".find(id)\n  state.selectedId = id\n  state.panel = detailPanel\n\nproc remove(state: State, id: int64) =\n  try:\n    " & m & ".find(id).destroyOrRaise()\n    state.back()\n  except CatchableError as error: state.error = error.msg\n\nproc submit(state: State) =\n  try:\n    let value = if state.editingId == 0: " & m & ".build() else: " & m & ".find(state.editingId)\n")
  for field in resource.fields:
    let expression = case field.kind
      of "int": "parseInt(state.draft." & field.name & ".strip())"
      of "float": "parseFloat(state.draft." & field.name & ".strip())"
      else: "state.draft." & field.name
    result.add("    value." & field.name & " = " & expression & "\n")
  result.add("    if value.save():\n      state.draft = Draft()\n      state.editingId = 0\n      state.back()\n    else: state.error = value.errors.fullMessages.join(\"\\n\")\n  except CatchableError as error: state.error = error.msg\n\n")

proc listCode(resource: ResourceSpec): string =
  let p = resource.plural
  result = "proc renderRecord(state: State, item: " & "record_model." & resource.model & "): Node =\n  let id = item.id\n  view:\n    column:\n      key: \"" & p & "_row_\" & $id\n      styles: {\"gap\": \"8\", \"padding\": \"12\"}\n"
  for field in resource.fields:
    result.add("      text " & (if field.kind == "string": "" else: "$") & "item." & field.name & ":\n        key: \"" & p & "_" & field.name & "_\" & $id\n")
  result.add("      row:\n        styles: {\"gap\": \"8\"}\n        button \"View\":\n          key: \"" & p & "_show_\" & $id\n          onClick(e): state.show(id)\n        button \"Edit\":\n          key: \"" & p & "_edit_\" & $id\n          onClick(e): state.beginEdit(id)\n        button \"Delete\":\n          key: \"" & p & "_delete_\" & $id\n          onClick(e): state.remove(id)\n\n")
  result.add("proc renderList(state: State): Node =\n  let items = record_model." & resource.model & ".all\n  view:\n    column:\n      styles: {\"gap\": \"12\", \"overflow\": \"scroll\", \"flex_grow\": \"1\"}\n      button \"New " & resource.model & "\":\n        key: \"" & p & "_new\"\n        onClick(e): state.beginNew()\n      text state.error:\n        key: \"" & p & "_error\"\n      if items.len == 0:\n        emptyState(\"No records yet\", \"" & p & "_empty\")\n      for item in items:\n        renderRecord(state, item)\n")

proc editorCode(resource: ResourceSpec): string =
  let p = resource.plural
  result = "proc renderEditor(state: State): Node =\n  view:\n    column:\n      styles: {\"gap\": \"12\"}\n      text (if state.editingId == 0: \"Create " & resource.model & "\" else: \"Edit " & resource.model & "\")\n"
  for field in resource.fields:
    result.add("      text " & field.name.escape & "\n")
    if field.kind == "bool":
      result.add("      checkbox(" & field.name.escape & ", state.draft." & field.name & "):\n        key: \"" & p & "_field_" & field.name & "\"\n        onChange(e): state.draft." & field.name & " = e.checked\n")
    else:
      result.add("      input state.draft." & field.name & ":\n        key: \"" & p & "_field_" & field.name & "\"\n        onChange(e): state.draft." & field.name & " = e.value\n")
  result.add("      text state.error:\n        key: \"" & p & "_error\"\n      row:\n        styles: {\"gap\": \"8\"}\n        button \"Save\":\n          key: \"" & p & "_save\"\n          onClick(e): state.submit()\n        button \"Cancel\":\n          key: \"" & p & "_cancel\"\n          onClick(e): state.back()\n")

proc detailCode(resource: ResourceSpec): string =
  let p = resource.plural
  result = "proc renderDetail(state: State): Node =\n  let item = record_model." & resource.model & ".find(state.selectedId)\n  view:\n    column:\n      styles: {\"gap\": \"12\"}\n      text \"" & resource.model & " #\" & $item.id\n"
  for field in resource.fields:
    result.add("      text " & field.name.escape & "\n      text " & (if field.kind == "string": "" else: "$") & "item." & field.name & ":\n        key: \"" & p & "_detail_" & field.name & "\"\n")
  result.add("      button \"Back\":\n        key: \"" & p & "_back\"\n        onClick(e): state.back()\n")

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
    "import std/strutils\nimport leaf\nimport leaf/model\nfrom ../../models/" & resource.singular & " as record_model import build, modelTable, modelFields, modelValues, assignModelValues, storageType, toStorage, fromStorage, runValidations, runCallbacks\nimport ../../components/empty_state\n\ninclude logic\ninclude views/list\ninclude views/editor\ninclude views/detail\ninclude views/index\n\nproc definition*(): PageDefinition =\n  PageDefinition(name: \"" & p & "\", views: @[\"index\"],\n    create: proc(): PageGroup =\n      let state = State()\n      PageGroup(render: proc(ctx: BuildContext, panel: string): Node = renderIndex(state)))\n"))
