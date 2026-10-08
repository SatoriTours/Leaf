## SQLite DDL rendering and backend capability checks. Rendering never opens a
## database; capability checks compare versions without connecting.
import std/[math, options, sequtils, strutils]
import ./types
import ../sqlite

proc quoteIdentifier(name: string): string =
  if name.len == 0 or '\0' in name:
    raise migrationError("invalid_identifier", "SQLite identifier is empty or contains NUL")
  "\"" & name.replace("\"", "\"\"") & "\""

proc typeName(kind: ColumnKind): string =
  case kind
  of ckText: "TEXT"
  of ckInteger: "INTEGER"
  of ckReal: "REAL"
  of ckBoolean: "INTEGER"
  of ckDateTime: "REAL"

proc literalSql(value: SqlValue): string =
  case value.kind
  of sqlNull: "NULL"
  of sqlInteger: $value.integer
  of sqlFloat:
    if classify(value.number) in {fcNan, fcInf, fcNegInf}:
      raise migrationError("invalid_default", "default number must be finite")
    $value.number
  of sqlText:
    if '\0' in value.text:
      raise migrationError("invalid_default", "default text cannot contain NUL")
    "'" & value.text.replace("'", "''") & "'"

proc renderColumn(column: ColumnSpec): string =
  result = quoteIdentifier(column.name) & " " & typeName(column.kind)
  if not column.nullable: result.add " NOT NULL"
  if column.defaultValue.isSome: result.add " DEFAULT " & literalSql(column.defaultValue.get())
  if column.kind == ckBoolean:
    result.add " CHECK (" & quoteIdentifier(column.name) & " IN (0, 1))"

proc renderCreateTable(spec: TableSpec): string =
  var definitions: seq[string]
  if spec.hasId:
    var id = quoteIdentifier("id") & " INTEGER PRIMARY KEY"
    if spec.autoIncrement: id.add " AUTOINCREMENT"
    definitions.add id
  for column in spec.columns: definitions.add renderColumn(column)
  "CREATE TABLE " & quoteIdentifier(spec.name) & " (" & definitions.join(", ") & ")"

proc renderStatements*(operations: openArray[SchemaOperation]): seq[string] =
  ## One deterministic SQLite statement per operation, in declaration order.
  for operation in operations:
    case operation.kind
    of moCreateTable:
      result.add renderCreateTable(operation.tableSpec)
    of moDropTable:
      result.add "DROP TABLE " & quoteIdentifier(operation.tableSpec.name)
    of moAddColumn:
      result.add "ALTER TABLE " & quoteIdentifier(operation.tableName) & " ADD COLUMN " &
        renderColumn(operation.columnSpec)
    of moRemoveColumn:
      result.add "ALTER TABLE " & quoteIdentifier(operation.tableName) & " DROP COLUMN " &
        quoteIdentifier(operation.columnSpec.name)
    of moRenameTable:
      result.add "ALTER TABLE " & quoteIdentifier(operation.oldTableName) & " RENAME TO " &
        quoteIdentifier(operation.newTableName)
    of moRenameColumn:
      result.add "ALTER TABLE " & quoteIdentifier(operation.columnTableName) &
        " RENAME COLUMN " & quoteIdentifier(operation.oldColumnName) & " TO " &
        quoteIdentifier(operation.newColumnName)
    of moAddIndex:
      result.add "CREATE " & (if operation.indexSpec.unique: "UNIQUE " else: "") &
        "INDEX " & quoteIdentifier(operation.indexSpec.name) & " ON " &
        quoteIdentifier(operation.indexSpec.table) & " (" &
        operation.indexSpec.columns.mapIt(quoteIdentifier(it)).join(", ") & ")"
    of moRemoveIndex:
      result.add "DROP INDEX " & quoteIdentifier(operation.indexSpec.name)

proc atLeast(version: tuple[major, minor, patch: int],
    major, minor, patch: int): bool =
  version.major > major or (version.major == major and
    (version.minor > minor or (version.minor == minor and version.patch >= patch)))

proc versionText(version: tuple[major, minor, patch: int]): string =
  $(version.major) & "." & $(version.minor) & "." & $(version.patch)

proc checkCapabilities*(operations: openArray[SchemaOperation],
    version: tuple[major, minor, patch: int]) =
  ## Reject operations whose SQLite backend requirement is unmet, before writing.
  for operation in operations:
    case operation.kind
    of moRenameColumn:
      if not version.atLeast(3, 25, 0):
        raise migrationError("unsupported_sqlite", "renameColumn requires SQLite 3.25 or newer, found " &
          versionText(version))
    of moRemoveColumn:
      if not version.atLeast(3, 35, 0):
        raise migrationError("unsupported_sqlite", "removeColumn requires SQLite 3.35 or newer, found " &
          versionText(version))
    else: discard
