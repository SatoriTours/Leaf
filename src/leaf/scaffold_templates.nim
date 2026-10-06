## Typed resource source and SQL generators. Fixed application templates live nearby.
import std/[strutils, sequtils]
import ./scaffold_types

proc modelCode*(resource: ResourceSpec): string =
  let m = resource.model
  result = "from \"$lib/system\" as nim_system import nil\n"
  if resource.fields.anyIt(it.kind == "string"): result.add("import std/strutils\n")
  if resource.fields.anyIt(it.kind == "float"): result.add("import std/math\n")
  result.add("\ntype\n  " & m & "ValidationError* = object of nim_system.ValueError\n  " & m & "* = object\n    id*: int\n")
  for field in resource.fields: result.add("    " & field.name & "*: " & field.kind & "\n")
  result.add("\nproc validate*(value: " & m & ") =\n")
  var checked = false
  for field in resource.fields:
    if field.kind == "string":
      checked = true
      result.add("  if value." & field.name & ".strip().len == 0:\n    raise newException(" & m & "ValidationError, " & (field.name & " cannot be empty").escape & ")\n")
    elif field.kind == "float":
      checked = true
      result.add("  if classify(value." & field.name & ") in {fcNan, fcInf, fcNegInf}:\n    raise newException(" & m & "ValidationError, " & (field.name & " must be finite").escape & ")\n")
  if not checked: result.add("  discard value\n")

proc serviceCode*(resource: ResourceSpec): string =
  let m = resource.model
  let modelType = "record_model." & m
  let table = "\"" & resource.plural & "\""
  var columns, placeholders, updates, values: seq[string]
  for field in resource.fields:
    let column = "\"" & field.name & "\""
    columns.add(column)
    placeholders.add("?")
    updates.add(column & " = ?")
    values.add("storage.dbValue(candidate." & field.name & ")")
  let selectSql = "SELECT id, " & columns.join(", ") & " FROM " & table
  result = "from \"$lib/system\" as nim_system import nil\nimport leaf/sqlite as storage\nfrom ../models/" & resource.singular & " as record_model import validate\n"
  if resource.fields.anyIt(it.kind == "string"): result.add("import std/strutils\n")
  result.add("\ntype " & m & "Service* = ref object\n  database: storage.Database\n\n")
  result.add("proc new" & m & "Service*(database: storage.Database): " & m & "Service =\n  if database == nil: raise newException(nim_system.ValueError, \"Database is required\")\n  " & m & "Service(database: database)\n\n")
  result.add("proc toModel(row: seq[storage.SqlValue]): " & modelType & " =\n  result.id = row[0].asInt\n")
  for i, field in resource.fields:
    let decode = case field.kind
      of "string": "asString"
      of "bool": "asBool"
      of "int": "asInt"
      else: "asFloat"
    result.add("  result." & field.name & " = row[" & $(i+1) & "]." & decode & "\n")
  result.add("\nproc all*(service: " & m & "Service): seq[" & modelType & "] =\n  for row in service.database.query(" & (selectSql & " ORDER BY id").escape & "):\n    result.add(toModel(row))\n\n")
  result.add("proc find*(service: " & m & "Service, id: int): " & modelType & " =\n  let rows = service.database.query(" & (selectSql & " WHERE id = ?").escape & ", @[storage.dbValue(id)])\n  if rows.len == 0: raise newException(nim_system.ValueError, \"Record no longer exists\")\n  toModel(rows[0])\n\n")
  result.add("proc save*(service: " & m & "Service, value: " & modelType & "): " & modelType & " =\n  var candidate = value\n")
  for field in resource.fields:
    if field.kind == "string": result.add("  candidate." & field.name & " = candidate." & field.name & ".strip()\n")
  result.add("  candidate.validate()\n  let values = @[" & values.join(", ") & "]\n  if candidate.id == 0:\n    discard service.database.execute(" & ("INSERT INTO " & table & " (" & columns.join(", ") & ") VALUES (" & placeholders.join(", ") & ")").escape & ", values)\n    candidate.id = service.database.lastInsertId\n  else:\n    if service.database.execute(" & ("UPDATE " & table & " SET " & updates.join(", ") & " WHERE id = ?").escape & ", values & @[storage.dbValue(candidate.id)]) == 0:\n      raise newException(nim_system.ValueError, \"Record no longer exists\")\n  candidate\n\n")
  result.add("proc delete*(service: " & m & "Service, id: int) =\n  if service.database.execute(" & ("DELETE FROM " & table & " WHERE id = ?").escape & ", @[storage.dbValue(id)]) == 0:\n    raise newException(nim_system.ValueError, \"Record no longer exists\")\n")

proc logicCode(resource: ResourceSpec): string =
  let m = "record_model." & resource.model
  result = "# Dependencies are supplied by page.nim.\ntype\n  Panel = enum listPanel, editorPanel, detailPanel\n  Draft = object\n"
  for field in resource.fields:
    result.add("    " & field.name & ": " & (if field.kind == "bool": "bool" else: "string") & "\n")
  result.add("  State = ref object\n    service: record_service." & resource.model & "Service\n    draft: Draft\n    panel: Panel\n    editingId, selectedId: int\n    error: string\n\nproc toDraft(value: " & m & "): Draft =\n")
  for field in resource.fields:
    result.add("  result." & field.name & " = " & (if field.kind in ["bool", "string"]: "" else: "$") & "value." & field.name & "\n")
  result.add("\nproc beginNew(state: State) =\n  state.draft = toDraft(" & m & "())\n  state.editingId = 0\n  state.error = \"\"\n  state.panel = editorPanel\n\n")
  result.add("proc beginEdit(state: State, id: int) =\n  state.draft = toDraft(state.service.find(id))\n  state.editingId = id\n  state.error = \"\"\n  state.panel = editorPanel\n\n")
  result.add("proc show(state: State, id: int) =\n  discard state.service.find(id)\n  state.selectedId = id\n  state.panel = detailPanel\n\nproc back(state: State) =\n  state.panel = listPanel\n  state.error = \"\"\n\n")
  result.add("proc remove(state: State, id: int) =\n  try:\n    state.service.delete(id)\n    state.back()\n  except system.ValueError as error:\n    state.error = error.msg\n\nproc submit(state: State) =\n  try:\n    var value = " & m & "(id: state.editingId)\n")
  for field in resource.fields:
    let expression = case field.kind
      of "int": "parseInt(state.draft." & field.name & ".strip())"
      of "float": "parseFloat(state.draft." & field.name & ".strip())"
      else: "state.draft." & field.name
    result.add("    value." & field.name & " = " & expression & "\n")
  result.add("    discard state.service.save(value)\n    state.draft = Draft()\n    state.editingId = 0\n    state.back()\n  except system.ValueError as error:\n    state.error = error.msg\n")

proc listCode(resource: ResourceSpec): string =
  let p = resource.plural
  result = "proc renderRecord(state: State, item: " & "record_model." & resource.model & "): Node =\n  let id = item.id\n  view:\n    column:\n      key: \"" & p & "_row_\" & $id\n      styles: {\"gap\": \"8\", \"padding\": \"12\"}\n"
  for field in resource.fields:
    result.add("      text " & (if field.kind == "string": "" else: "$") & "item." & field.name & ":\n        key: \"" & p & "_" & field.name & "_\" & $id\n")
  result.add("      row:\n        styles: {\"gap\": \"8\"}\n        button \"View\":\n          key: \"" & p & "_show_\" & $id\n          onClick(e): state.show(id)\n        button \"Edit\":\n          key: \"" & p & "_edit_\" & $id\n          onClick(e): state.beginEdit(id)\n        button \"Delete\":\n          key: \"" & p & "_delete_\" & $id\n          onClick(e): state.remove(id)\n\n")
  result.add("proc renderList(state: State): Node =\n  let items = state.service.all()\n  view:\n    column:\n      styles: {\"gap\": \"12\", \"overflow\": \"scroll\", \"flex_grow\": \"1\"}\n      button \"New " & resource.model & "\":\n        key: \"" & p & "_new\"\n        onClick(e): state.beginNew()\n      text state.error:\n        key: \"" & p & "_error\"\n      if items.len == 0:\n        emptyState(\"No records yet\", \"" & p & "_empty\")\n      for item in items:\n        renderRecord(state, item)\n")

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
  result = "proc renderDetail(state: State): Node =\n  let item = state.service.find(state.selectedId)\n  view:\n    column:\n      styles: {\"gap\": \"12\"}\n      text \"" & resource.model & " #\" & $item.id\n"
  for field in resource.fields:
    result.add("      text " & field.name.escape & "\n      text " & (if field.kind == "string": "" else: "$") & "item." & field.name & ":\n        key: \"" & p & "_detail_" & field.name & "\"\n")
  result.add("      button \"Back\":\n        key: \"" & p & "_back\"\n        onClick(e): state.back()\n")

proc resourceFiles*(resource: ResourceSpec): seq[ScaffoldFile] =
  let p = resource.plural
  let base = "app/pages/" & p & "/"
  result.add(ScaffoldFile(path: "app/models/" & resource.singular & ".nim", content: modelCode(resource)))
  result.add(ScaffoldFile(path: "app/services/" & resource.singular & "_service.nim", content: serviceCode(resource)))
  result.add(ScaffoldFile(path: base & "logic.nim", content: logicCode(resource)))
  result.add(ScaffoldFile(path: base & "views/list.nim", content: listCode(resource)))
  result.add(ScaffoldFile(path: base & "views/editor.nim", content: editorCode(resource)))
  result.add(ScaffoldFile(path: base & "views/detail.nim", content: detailCode(resource)))
  result.add(ScaffoldFile(path: base & "views/index.nim", content: "proc renderIndex(state: State): Node =\n  case state.panel\n  of listPanel: renderList(state)\n  of editorPanel: renderEditor(state)\n  of detailPanel: renderDetail(state)\n"))
  result.add(ScaffoldFile(path: base & "page.nim", content:
    (if resource.fields.anyIt(it.kind in ["int", "float"]): "import std/strutils\n" else: "") &
    "import leaf\nimport leaf/sqlite as storage\nfrom ../../models/" & resource.singular & " as record_model import nil\nfrom ../../services/" & resource.singular & "_service as record_service import all, find, save, delete\nimport ../../components/empty_state\n\ninclude logic\ninclude views/list\ninclude views/editor\ninclude views/detail\ninclude views/index\n\nproc definition*(database: storage.Database): PageDefinition =\n  PageDefinition(name: \"" & p & "\", views: @[\"index\"],\n    create: proc(): PageGroup =\n      let state = State(service: record_service.new" & resource.model & "Service(database))\n      PageGroup(render: proc(ctx: BuildContext, panel: string): Node = renderIndex(state)))\n"))

proc migrationFiles*(resource: ResourceSpec): seq[ScaffoldFile] =
  let base = "db/migrations/" & align($resource.migration, 3, '0') & "_create_" & resource.plural
  var columns = @["  id INTEGER PRIMARY KEY AUTOINCREMENT"]
  for field in resource.fields:
    let sqlType = case field.kind
      of "string": "TEXT"
      of "float": "REAL"
      else: "INTEGER"
    var column = "  \"" & field.name & "\" " & sqlType & " NOT NULL"
    if field.kind == "bool": column.add(" CHECK (\"" & field.name & "\" IN (0, 1))")
    columns.add(column)
  result.add(ScaffoldFile(path: base & ".up.sql", content: "CREATE TABLE \"" & resource.plural & "\" (\n" & columns.join(",\n") & "\n);\n"))
  result.add(ScaffoldFile(path: base & ".down.sql", content: "DROP TABLE \"" & resource.plural & "\";\n"))

proc testCode*(resource: ResourceSpec): string =
  let m = resource.model
  var assignments: seq[string]
  for field in resource.fields:
    assignments.add(field.name & ": " & (case field.kind
      of "string": "\"Example\""
      of "bool": "false"
      of "int": "42"
      else: "1.5"))
  result = "import leaf/sqlite as storage\nfrom ../config/database as database_config import nil\nfrom ../app/models/" & resource.singular & " as record_model import nil\nfrom ../app/services/" & resource.singular & "_service as record_service import all, find, save, delete\n\nlet connection = database_config.openApplicationDatabase(\":memory:\")\nlet service = record_service.new" & m & "Service(connection)\nlet saved = service.save(record_model." & m & "(" & assignments.join(", ") & "))\ndoAssert saved.id == 1\ndoAssert service.all().len == 1\ndoAssert service.find(saved.id) == saved\n"
  let first = resource.fields[0]
  result.add("var edited = saved\nedited." & first.name & " = " & (case first.kind
    of "string": "\"Updated\""
    of "bool": "true"
    of "int": "43"
    else: "2.5") & "\ndiscard service.save(edited)\ndoAssert service.find(saved.id) == edited\nservice.delete(saved.id)\ndoAssert service.all().len == 0\n")
  if resource.fields.anyIt(it.kind == "string"):
    result.add("try:\n  discard service.save(record_model." & m & "())\n  doAssert false, \"blank values must fail\"\nexcept record_model." & m & "ValidationError:\n  discard\ndoAssert service.all().len == 0\n")
  result.add("connection.close()\necho \"" & resource.plural & " tests passed\"\n")
