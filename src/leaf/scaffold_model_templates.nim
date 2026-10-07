## Schema 2 model declarations. The schema 1 templates remain unchanged.
import std/[strutils, sequtils]
import ./scaffold_types

proc checkModelFields*(resource: ResourceSpec) =
  for field in resource.fields:
    if identity(field.name) in ["createdat", "updatedat"]:
      raise newException(ValueError, "reserved model timestamp: " & field.name)

proc modelCodeV2*(resource: ResourceSpec): string =
  checkModelFields(resource)
  result = "import leaf/model\nimport ./application_record\n"
  if resource.fields.anyIt(it.kind == "string"): result.add("import std/strutils\n")
  result.add("\ntype " & resource.model & "* = ref object of ApplicationRecord\n")
  for field in resource.fields: result.add("  " & field.name & "*: " & field.kind & "\n")
  if resource.fields.anyIt(it.kind == "string"):
    result.add("\nproc normalize(record: " & resource.model & ") =\n")
    for field in resource.fields:
      if field.kind == "string": result.add("  record." & field.name & " = record." & field.name & ".strip()\n")
  result.add("\ndefineModel(" & resource.model & ", table = " & resource.plural.escape & ")")
  var rules: seq[string]
  if resource.fields.anyIt(it.kind == "string"): rules.add("  beforeValidation normalize")
  for field in resource.fields:
    if field.kind == "string": rules.add("  validates " & field.name & ", presence = true, maxLength = 200")
    elif field.kind == "float": rules.add("  validates " & field.name & ", finite = true")
  if rules.len > 0: result.add(":\n" & rules.join("\n"))
  result.add("\n")

proc migrationFilesV2*(resource: ResourceSpec): seq[ScaffoldFile] =
  checkModelFields(resource)
  let base = "db/migrations/" & align($resource.migration, 3, '0') & "_create_" & resource.plural
  var columns = @["  id INTEGER PRIMARY KEY"]
  for field in resource.fields:
    let sqlType = case field.kind
      of "string": "TEXT"
      of "float": "REAL"
      else: "INTEGER"
    var column = "  \"" & field.name & "\" " & sqlType & " NOT NULL"
    if field.kind == "bool": column.add(" CHECK (\"" & field.name & "\" IN (0, 1))")
    columns.add(column)
  columns.add("  created_at REAL NOT NULL")
  columns.add("  updated_at REAL NOT NULL")
  result.add(ScaffoldFile(path: base & ".up.sql", content: "CREATE TABLE \"" & resource.plural & "\" (\n" & columns.join(",\n") & "\n);\n"))
  result.add(ScaffoldFile(path: base & ".down.sql", content: "DROP TABLE \"" & resource.plural & "\";\n"))

proc modelTestCodeV2*(resource: ResourceSpec): string =
  var assignments: seq[string]
  for field in resource.fields:
    assignments.add(field.name & " = " & (case field.kind
      of "string": "\"Example\""
      of "bool": "false"
      of "int": "42"
      else: "1.5"))
  let m = "record_model." & resource.model
  result = "import leaf/model\nimport leaf/sqlite as storage\nfrom ../config/database as database_config import nil\nfrom ../app/models/" & resource.singular & " as record_model import build, modelTable, modelFields, modelValues, assignModelValues, storageType, toStorage, fromStorage, runValidations, runCallbacks\n\nlet connection = database_config.openApplicationDatabase(\":memory:\")\nwithDatabase(connection):\n  let saved = " & m & ".build(" & assignments.join(", ") & ")\n  saved.saveOrRaise()\n  doAssert saved.id == 1'i64\n  doAssert count(" & m & ") == 1'i64\n  doAssert " & m & ".find(saved.id).id == saved.id\n  saved.reload()\n  doAssert not saved.changed\n  saved.destroyOrRaise()\n  doAssert " & m & ".all.len == 0\n"
  if resource.fields.anyIt(it.kind == "string"):
    result.add("  let invalid = " & m & ".build()\n  doAssert not invalid.save()\n  doAssert invalid.errors.fullMessages.len > 0\n")
  result.add("storage.close(connection)\necho " & (resource.plural & " model tests passed").escape & "\n")
