## Restricted compile-time DSL for declarative migrations. Bare names need no
## variables; unknown options, invalid defaults and unsupported statements fail
## at compile time with the migration file and line. Nothing here opens a
## database or executes user Nim.
import std/[macros, math, options, strutils]
import ./types
import ./files
import ./operations
import ./fingerprint
import ../sqlite

proc dslError(node: NimNode, message: string) {.noreturn.} =
  error(message, node)

proc tokenName(node: NimNode, what: string): string =
  ## Preserve the raw spelling of a bare identifier (including backticks).
  case node.kind
  of nnkIdent:
    # The parser already guarantees a legal Nim identifier token; Unicode names
    # are legal database names and keep their spelling.
    result = node.strVal
    if result.len == 0: dslError(node, what & " must be a bare identifier")
  of nnkAccQuoted:
    if node.len == 0: dslError(node, what & " must be a bare identifier")
    for index, part in node:
      if part.kind != nnkIdent: dslError(node, what & " must be a bare identifier")
      let text = part.strVal
      let wordLike = text.len > 0 and (text[0].isAlphaAscii or text[0] == '_')
      if index > 0 and wordLike:
        let previous = node[index - 1].strVal
        if previous.len > 0 and (previous[0].isAlphaAscii or previous[0] == '_'):
          result.add ' '
      result.add text
    if result.len == 0: dslError(node, what & " must not be empty")
    for c in result:
      if c == '\0' or ord(c) < 32 or ord(c) == 127:
        dslError(node, what & " contains an unsupported character")
  else:
    dslError(node, what & " must be a bare identifier")

proc boolLiteral(node: NimNode, what: string): bool =
  if node.kind == nnkIdent:
    case node.strVal
    of "true": return true
    of "false": return false
    else: discard
  dslError(node, what & " must be true or false")

proc tableName(node: NimNode): string =
  result = tokenName(node, "table name")
  let lowered = result.toLowerAscii
  if lowered == "leaf_schema_migrations":
    dslError(node, "table name leaf_schema_migrations is reserved: " & result)
  if lowered.startsWith("sqlite_"):
    dslError(node, "table names beginning with sqlite_ are reserved: " & result)

proc columnKind(node: NimNode): ColumnKind =
  if node.kind == nnkIdent:
    case node.strVal
    of "string", "text": return ckText
    of "integer": return ckInteger
    of "float": return ckReal
    of "boolean": return ckBoolean
    of "datetime": return ckDateTime
    else: discard
  dslError(node, "column type must be string, text, integer, float, boolean or datetime")

const
  SignedIntLiterals = {nnkIntLit, nnkInt8Lit, nnkInt16Lit, nnkInt32Lit, nnkInt64Lit}
  FloatLiterals = {nnkFloatLit, nnkFloat32Lit, nnkFloat64Lit, nnkFloat128Lit}

proc widenFloat32(value: float64): float64 =
  ## Round a float64 to the nearest float32 and widen it exactly back. The Nim
  ## VM folds `float64(float32(x))` to `x`, so decode the narrowed bits instead.
  let bits = cast[uint32](float32(value))
  let sign = uint64(bits shr 31) shl 63
  let exponent = (bits shr 23) and 0xFF'u32
  var fraction = uint64(bits and 0x7FFFFF'u32)
  if exponent == 0xFF'u32:
    let payload = if fraction != 0: 0x8000000000000'u64 else: 0'u64
    return cast[float64](sign or 0x7FF0000000000000'u64 or payload)
  if exponent == 0'u32:
    if fraction == 0: return cast[float64](sign)
    var unbiased = -126
    while (fraction and 0x800000'u64) == 0:
      fraction = fraction shl 1
      dec unbiased
    fraction = fraction and 0x7FFFFF'u64
    return cast[float64](sign or (uint64(unbiased + 1023) shl 52) or (fraction shl 29))
  return cast[float64](sign or (uint64(int(exponent) - 127 + 1023) shl 52) or
    (fraction shl 29))

proc floatLiteral(node: NimNode): float =
  ## Apply the declared precision of a supported float literal before storing it
  ## as a SQLite REAL: an f32 literal rounds to single precision first, so its
  ## finite/overflow boundaries follow Nim literal semantics, not raw float64.
  if node.kind == nnkFloat32Lit:
    widenFloat32(node.floatVal)
  else:
    node.floatVal

proc defaultLiteral(node: NimNode, kind: ColumnKind, columnName: string,
    nullable: bool): Option[SqlValue] =
  let label = "invalid default for column: " & columnName
  if node.kind == nnkNilLit:
    if not nullable:
      dslError(node, "column " & columnName & " cannot default to nil unless nullable = true")
    return some(SqlValue(kind: sqlNull))
  # A unary minus is only meaningful for numeric literals; text/boolean defaults
  # must not silently drop it.
  var signedNegative = false
  var literal = node
  if literal.kind == nnkPrefix and literal.len == 2 and literal[0].kind == nnkIdent and
      literal[0].strVal == "-":
    signedNegative = true
    literal = literal[1]
  case kind
  of ckText:
    if node.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      let text = node.strVal
      if '\0' in text:
        dslError(node, label & " (text default cannot contain NUL)")
      return some(SqlValue(kind: sqlText, text: text))
    dslError(node, label)
  of ckInteger:
    if literal.kind in SignedIntLiterals:
      return some(SqlValue(kind: sqlInteger,
        integer: (if signedNegative: -literal.intVal else: literal.intVal)))
    dslError(node, label)
  of ckReal, ckDateTime:
    if literal.kind in FloatLiterals:
      var number = floatLiteral(literal)
      if signedNegative: number = -number
      if classify(number) in {fcNan, fcInf, fcNegInf}: dslError(node, label)
      return some(SqlValue(kind: sqlFloat, number: number))
    if literal.kind in SignedIntLiterals:
      let number = float(if signedNegative: -literal.intVal else: literal.intVal)
      return some(SqlValue(kind: sqlFloat, number: number))
    dslError(node, label)
  of ckBoolean:
    if not signedNegative and node.kind == nnkIdent and node.strVal in ["true", "false"]:
      return some(SqlValue(kind: sqlInteger,
        integer: (if node.strVal == "true": 1 else: 0)))
    dslError(node, label)

type OperationArguments = object
  positional: seq[NimNode]
  options: seq[NimNode]
  body: NimNode

proc parseArguments(node: NimNode, operation: string): OperationArguments =
  var last = node.len - 1
  if last >= 1 and node[last].kind == nnkStmtList:
    result.body = node[last]
    dec last
  for index in 1 .. last:
    let child = node[index]
    if child.kind == nnkExprEqExpr:
      if child[0].kind != nnkIdent:
        dslError(child, operation & " option must be a bare name")
      result.options.add child
    else:
      result.positional.add child

proc validateOptions(options: seq[NimNode], allowed: openArray[string]) =
  var seen: seq[string]
  for option in options:
    let name = option[0].strVal
    if name notin allowed:
      dslError(option[0], "unknown option: " & name)
    if name in seen:
      dslError(option[0], "duplicate option: " & name)
    seen.add name

proc optionValue(options: seq[NimNode], name: string): NimNode =
  for option in options:
    if option[0].strVal == name: return option
  nil

proc parseColumnSpec(nameNode, typeNode: NimNode, options: seq[NimNode]): ColumnSpec =
  validateOptions(options, ["nullable", "default"])
  let name = tokenName(nameNode, "column name")
  let kind = columnKind(typeNode)
  var nullable = true
  let nullableOption = optionValue(options, "nullable")
  if nullableOption != nil: nullable = boolLiteral(nullableOption[1], "nullable")
  var defaultValue = none(SqlValue)
  let defaultOption = optionValue(options, "default")
  if defaultOption != nil:
    defaultValue = defaultLiteral(defaultOption[1], kind, name, nullable)
  ColumnSpec(name: name, kind: kind, nullable: nullable, defaultValue: defaultValue)

proc addColumnSpec(columns: var seq[ColumnSpec], seen: var seq[string],
    column: ColumnSpec, node: NimNode, hasId: bool) =
  let lowered = column.name.toLowerAscii
  if lowered in seen:
    dslError(node, "duplicate column: " & column.name)
  if lowered == "id" and hasId:
    dslError(node, "column id conflicts with the automatic id column")
  seen.add lowered
  columns.add column

proc parseTableBody(body: NimNode, hasId: bool): seq[ColumnSpec] =
  var seen: seq[string]
  for statement in body:
    if statement.kind == nnkCommentStmt: continue
    if statement.kind notin {nnkCommand, nnkCall} or statement.len == 0 or
        statement[0].kind != nnkIdent:
      dslError(statement, "expected a column declaration")
    let head = statement[0]
    if head.strVal == "timestamps":
      if statement.len != 1: dslError(statement, "timestamps() takes no options")
      addColumnSpec(result, seen,
        ColumnSpec(name: "created_at", kind: ckDateTime, nullable: false), statement, hasId)
      addColumnSpec(result, seen,
        ColumnSpec(name: "updated_at", kind: ckDateTime, nullable: false), statement, hasId)
      continue
    if head.strVal notin ["string", "text", "integer", "float", "boolean", "datetime"]:
      dslError(head, "column type must be string, text, integer, float, boolean or datetime")
    if statement.len < 2:
      dslError(statement, "column declaration is missing a name")
    if statement[1].kind == nnkExprEqExpr:
      dslError(statement, "column declaration is missing a name")
    var options: seq[NimNode]
    for index in 2 ..< statement.len:
      if statement[index].kind != nnkExprEqExpr:
        dslError(statement[index], "unexpected column argument: " & statement[index].repr)
      options.add statement[index]
    addColumnSpec(result, seen, parseColumnSpec(statement[1], head, options),
      statement[1], hasId)

proc parseTable(node: NimNode, operation: string,
    requireBody: bool): tuple[spec: TableSpec, bodyProvided: bool] =
  let arguments = parseArguments(node, operation)
  validateOptions(arguments.options, ["id", "autoIncrement"])
  if arguments.positional.len != 1:
    dslError(node, operation & " requires exactly one table name")
  let name = tableName(arguments.positional[0])
  var hasId = true
  var autoIncrement = false
  for option in arguments.options:
    case option[0].strVal
    of "id": hasId = boolLiteral(option[1], "id")
    of "autoIncrement": autoIncrement = boolLiteral(option[1], "autoIncrement")
    else: discard
  if autoIncrement and not hasId:
    dslError(node, "autoIncrement requires the automatic id column")
  var columns: seq[ColumnSpec]
  if arguments.body != nil:
    columns = parseTableBody(arguments.body, hasId)
  elif requireBody:
    dslError(node, operation & " in change requires the original table structure")
  if not hasId and columns.len == 0:
    dslError(node, "table " & name & " must declare at least one column when id = false")
  result = (spec: TableSpec(name: name, columns: columns, hasId: hasId,
    autoIncrement: autoIncrement), bodyProvided: arguments.body != nil)

proc parseOperation(node: NimNode, inChange: bool): seq[SchemaOperation] =
  if node.kind notin {nnkCommand, nnkCall} or node.len == 0 or node[0].kind != nnkIdent:
    dslError(node, "unsupported migration statement: " & node.repr)
  let operation = node[0].strVal
  case operation
  of "createTable":
    let parsed = parseTable(node, "createTable", requireBody = false)
    result.add SchemaOperation(kind: moCreateTable, tableSpec: parsed.spec,
      tableDefinitionProvided: true)
  of "dropTable":
    let parsed = parseTable(node, "dropTable", requireBody = inChange)
    result.add SchemaOperation(kind: moDropTable, tableSpec: parsed.spec,
      tableDefinitionProvided: parsed.bodyProvided)
  of "renameTable":
    let arguments = parseArguments(node, operation)
    if arguments.body != nil: dslError(arguments.body, "renameTable does not accept a block")
    validateOptions(arguments.options, [])
    if arguments.positional.len != 2:
      dslError(node, "renameTable requires the old and the new table name")
    result.add SchemaOperation(kind: moRenameTable,
      oldTableName: tableName(arguments.positional[0]),
      newTableName: tableName(arguments.positional[1]))
  of "addColumn":
    let arguments = parseArguments(node, operation)
    if arguments.body != nil: dslError(arguments.body, "addColumn does not accept a block")
    validateOptions(arguments.options, ["nullable", "default"])
    if arguments.positional.len != 3:
      dslError(node, "addColumn requires a table, a column and a type")
    result.add SchemaOperation(kind: moAddColumn,
      tableName: tableName(arguments.positional[0]),
      columnSpec: parseColumnSpec(arguments.positional[1], arguments.positional[2],
        arguments.options),
      columnDefinitionProvided: true)
  of "removeColumn":
    let arguments = parseArguments(node, operation)
    if arguments.body != nil: dslError(arguments.body, "removeColumn does not accept a block")
    validateOptions(arguments.options, ["nullable", "default"])
    if arguments.positional.len notin [2, 3]:
      dslError(node, "removeColumn requires a table, a column and optionally the original type")
    var column: ColumnSpec
    var provided = false
    if arguments.positional.len == 3:
      column = parseColumnSpec(arguments.positional[1], arguments.positional[2],
        arguments.options)
      provided = true
    else:
      if arguments.options.len > 0:
        dslError(node, "removeColumn requires the original column type before options")
      column = ColumnSpec(name: tokenName(arguments.positional[1], "column name"))
    if inChange and not provided:
      dslError(node, "removeColumn in change requires the original column type")
    result.add SchemaOperation(kind: moRemoveColumn,
      tableName: tableName(arguments.positional[0]), columnSpec: column,
      columnDefinitionProvided: provided)
  of "renameColumn":
    let arguments = parseArguments(node, operation)
    if arguments.body != nil: dslError(arguments.body, "renameColumn does not accept a block")
    validateOptions(arguments.options, [])
    if arguments.positional.len != 3:
      dslError(node, "renameColumn requires a table, the old column and the new column")
    result.add SchemaOperation(kind: moRenameColumn,
      columnTableName: tableName(arguments.positional[0]),
      oldColumnName: tokenName(arguments.positional[1], "column name"),
      newColumnName: tokenName(arguments.positional[2], "column name"))
  of "addIndex", "removeIndex":
    let arguments = parseArguments(node, operation)
    if arguments.body != nil: dslError(arguments.body, operation & " does not accept a block")
    validateOptions(arguments.options, ["unique", "name"])
    if arguments.positional.len != 2:
      dslError(node, operation & " requires a table and a column list")
    let table = tableName(arguments.positional[0])
    let list = arguments.positional[1]
    if list.kind != nnkBracket or list.len == 0:
      dslError(list, operation & " requires a non-empty [column, ...] list")
    var columns: seq[string]
    var seen: seq[string]
    for columnNode in list:
      let column = tokenName(columnNode, "index column")
      if column.toLowerAscii in seen:
        dslError(columnNode, "duplicate index column: " & column)
      seen.add column.toLowerAscii
      columns.add column
    var unique = false
    let uniqueOption = optionValue(arguments.options, "unique")
    if uniqueOption != nil: unique = boolLiteral(uniqueOption[1], "unique")
    var indexName = "index_" & table & "_on_" & columns.join("_and_")
    let nameOption = optionValue(arguments.options, "name")
    if nameOption != nil: indexName = tokenName(nameOption[1], "index name")
    let indexSpec = IndexSpec(table: table, name: indexName, columns: columns, unique: unique)
    if operation == "addIndex":
      result.add SchemaOperation(kind: moAddIndex, indexSpec: indexSpec)
    else:
      result.add SchemaOperation(kind: moRemoveIndex, indexSpec: indexSpec)
  of "addTimestamps":
    let arguments = parseArguments(node, operation)
    if arguments.body != nil: dslError(arguments.body, "addTimestamps does not accept a block")
    validateOptions(arguments.options, ["nullable", "default"])
    if arguments.positional.len != 1:
      dslError(node, "addTimestamps requires exactly one table name")
    let table = tableName(arguments.positional[0])
    var nullable = false
    let nullableOption = optionValue(arguments.options, "nullable")
    if nullableOption != nil: nullable = boolLiteral(nullableOption[1], "nullable")
    var defaultValue = none(SqlValue)
    let defaultOption = optionValue(arguments.options, "default")
    if defaultOption != nil:
      defaultValue = defaultLiteral(defaultOption[1], ckDateTime, "created_at", nullable)
    for columnName in ["created_at", "updated_at"]:
      result.add SchemaOperation(kind: moAddColumn, tableName: table,
        columnSpec: ColumnSpec(name: columnName, kind: ckDateTime, nullable: nullable,
          defaultValue: defaultValue), columnDefinitionProvided: true)
  of "pending":
    dslError(node, "pending() must be the only statement in change")
  else:
    dslError(node[0], "unsupported operation: " & operation)

proc parseOperations(body: NimNode, inChange: bool): seq[SchemaOperation] =
  for statement in body:
    if statement.kind == nnkCommentStmt: continue
    result.add parseOperation(statement, inChange)

proc isPendingStatement(node: NimNode): bool =
  node.kind in {nnkCommand, nnkCall} and node.len >= 1 and node[0].kind == nnkIdent and
    node[0].strVal == "pending"

proc hasOperations(body: NimNode): bool =
  for statement in body:
    if statement.kind != nnkCommentStmt: return true
  false

proc sqlValueNode(value: SqlValue): NimNode =
  result = nnkObjConstr.newTree(bindSym"SqlValue")
  result.add nnkExprColonExpr.newTree(ident"kind", newLit(value.kind))
  case value.kind
  of sqlNull: discard
  of sqlInteger: result.add nnkExprColonExpr.newTree(ident"integer", newLit(value.integer))
  of sqlFloat: result.add nnkExprColonExpr.newTree(ident"number", newLit(value.number))
  of sqlText: result.add nnkExprColonExpr.newTree(ident"text", newLit(value.text))

proc defaultNode(value: Option[SqlValue]): NimNode =
  ## `Option` fields are private, so emit `some(...)` / `none[T]()` explicitly.
  if value.isSome:
    newCall(bindSym"some", sqlValueNode(value.get()))
  else:
    newCall(nnkBracketExpr.newTree(bindSym"none", bindSym"SqlValue"))

proc stringSeqNode(items: seq[string]): NimNode =
  let bracket = nnkBracket.newTree
  for item in items: bracket.add newLit(item)
  nnkPrefix.newTree(ident"@", bracket)

proc columnNode(column: ColumnSpec): NimNode =
  result = nnkObjConstr.newTree(bindSym"ColumnSpec")
  result.add nnkExprColonExpr.newTree(ident"name", newLit(column.name))
  result.add nnkExprColonExpr.newTree(ident"kind", newLit(column.kind))
  result.add nnkExprColonExpr.newTree(ident"nullable", newLit(column.nullable))
  result.add nnkExprColonExpr.newTree(ident"defaultValue", defaultNode(column.defaultValue))

proc columnSeqNode(items: seq[ColumnSpec]): NimNode =
  let bracket = nnkBracket.newTree
  for item in items: bracket.add columnNode(item)
  nnkPrefix.newTree(ident"@", bracket)

proc tableNode(table: TableSpec): NimNode =
  result = nnkObjConstr.newTree(bindSym"TableSpec")
  result.add nnkExprColonExpr.newTree(ident"name", newLit(table.name))
  result.add nnkExprColonExpr.newTree(ident"columns", columnSeqNode(table.columns))
  result.add nnkExprColonExpr.newTree(ident"hasId", newLit(table.hasId))
  result.add nnkExprColonExpr.newTree(ident"autoIncrement", newLit(table.autoIncrement))

proc indexNode(index: IndexSpec): NimNode =
  result = nnkObjConstr.newTree(bindSym"IndexSpec")
  result.add nnkExprColonExpr.newTree(ident"table", newLit(index.table))
  result.add nnkExprColonExpr.newTree(ident"name", newLit(index.name))
  result.add nnkExprColonExpr.newTree(ident"columns", stringSeqNode(index.columns))
  result.add nnkExprColonExpr.newTree(ident"unique", newLit(index.unique))

proc operationNode(operation: SchemaOperation): NimNode =
  result = nnkObjConstr.newTree(bindSym"SchemaOperation")
  result.add nnkExprColonExpr.newTree(ident"kind", newLit(operation.kind))
  case operation.kind
  of moCreateTable, moDropTable:
    result.add nnkExprColonExpr.newTree(ident"tableSpec", tableNode(operation.tableSpec))
    result.add nnkExprColonExpr.newTree(ident"tableDefinitionProvided",
      newLit(operation.tableDefinitionProvided))
  of moAddColumn, moRemoveColumn:
    result.add nnkExprColonExpr.newTree(ident"tableName", newLit(operation.tableName))
    result.add nnkExprColonExpr.newTree(ident"columnSpec", columnNode(operation.columnSpec))
    result.add nnkExprColonExpr.newTree(ident"columnDefinitionProvided",
      newLit(operation.columnDefinitionProvided))
  of moRenameTable:
    result.add nnkExprColonExpr.newTree(ident"oldTableName", newLit(operation.oldTableName))
    result.add nnkExprColonExpr.newTree(ident"newTableName", newLit(operation.newTableName))
  of moRenameColumn:
    result.add nnkExprColonExpr.newTree(ident"columnTableName",
      newLit(operation.columnTableName))
    result.add nnkExprColonExpr.newTree(ident"oldColumnName", newLit(operation.oldColumnName))
    result.add nnkExprColonExpr.newTree(ident"newColumnName", newLit(operation.newColumnName))
  of moAddIndex, moRemoveIndex:
    result.add nnkExprColonExpr.newTree(ident"indexSpec", indexNode(operation.indexSpec))

proc operationSeqNode(items: seq[SchemaOperation]): NimNode =
  let bracket = nnkBracket.newTree
  for item in items: bracket.add operationNode(item)
  nnkPrefix.newTree(ident"@", bracket)

proc definitionNode(definition: MigrationDefinition): NimNode =
  result = nnkObjConstr.newTree(bindSym"MigrationDefinition")
  result.add nnkExprColonExpr.newTree(ident"version", newLit(definition.version))
  result.add nnkExprColonExpr.newTree(ident"name", newLit(definition.name))
  result.add nnkExprColonExpr.newTree(ident"sourcePath", newLit(definition.sourcePath))
  result.add nnkExprColonExpr.newTree(ident"sourceChecksum", newLit(definition.sourceChecksum))
  result.add nnkExprColonExpr.newTree(ident"format", newLit(definition.format))
  result.add nnkExprColonExpr.newTree(ident"upOps", operationSeqNode(definition.upOps))
  result.add nnkExprColonExpr.newTree(ident"downOps", operationSeqNode(definition.downOps))
  result.add nnkExprColonExpr.newTree(ident"legacyUp", newLit(definition.legacyUp))
  result.add nnkExprColonExpr.newTree(ident"legacyDown", newLit(definition.legacyDown))
  result.add nnkExprColonExpr.newTree(ident"hasDown", newLit(definition.hasDown))
  result.add nnkExprColonExpr.newTree(ident"pending", newLit(definition.pending))

macro migration*(name, body: untyped): untyped =
  ## Declare the single migration of this file and export `migrationDefinition`.
  let sourcePath = name.lineInfoObj.filename
  let declaredName = tokenName(name, "migration name")
  var version: int64
  var expectedName: string
  try:
    let identity = parseMigrationIdentity(sourcePath)
    version = identity.version
    expectedName = identity.name
  except CatchableError as failure:
    dslError(name, "migration file name must be <version>_<snake_case_name>.nim: " &
      failure.msg)
  if declaredName != expectedName:
    dslError(name, "migration name " & declaredName & " does not match file name " &
      expectedName)
  var sourceChecksum: string
  try:
    sourceChecksum = sha256Text(readFile(sourcePath))
  except CatchableError as failure:
    dslError(name, "cannot read migration source " & sourcePath & ": " & failure.msg)

  if body.kind != nnkStmtList:
    dslError(body, "migration body must contain a change or up/down block")
  var changeBlock, upBlock, downBlock: NimNode
  for statement in body:
    if statement.kind == nnkCommentStmt: continue
    if statement.kind notin {nnkCall, nnkCommand} or statement.len != 2 or
        statement[0].kind != nnkIdent or statement[^1].kind != nnkStmtList:
      dslError(statement, "change, up and down take only an indented block")
    let section = statement[0].strVal
    case section
    of "change":
      if changeBlock != nil: dslError(statement, "duplicate change block")
      changeBlock = statement[^1]
    of "up":
      if upBlock != nil: dslError(statement, "duplicate up block")
      upBlock = statement[^1]
    of "down":
      if downBlock != nil: dslError(statement, "duplicate down block")
      downBlock = statement[^1]
    else:
      dslError(statement, "migration body must contain a change or up/down block")
  if changeBlock != nil and (upBlock != nil or downBlock != nil):
    dslError(body, "change and up/down are mutually exclusive")

  var upOps: seq[SchemaOperation]
  var downOps: seq[SchemaOperation]
  var pending = false
  var hasDown = true
  if changeBlock != nil:
    var statements: seq[NimNode]
    for statement in changeBlock:
      if statement.kind != nnkCommentStmt: statements.add statement
    if statements.len == 0:
      dslError(changeBlock, "change requires at least one operation")
    if statements.len == 1 and statements[0].isPendingStatement:
      if statements[0].len != 1:
        dslError(statements[0], "pending() takes no arguments")
      pending = true
      hasDown = false
    else:
      for statement in statements:
        if statement.isPendingStatement:
          dslError(statement, "pending() must be the only statement in change")
      upOps = parseOperations(changeBlock, inChange = true)
      downOps = invertOperations(upOps)
  elif upBlock != nil or downBlock != nil:
    if upBlock == nil or downBlock == nil:
      dslError(body, "up and down must both be provided")
    if not upBlock.hasOperations: dslError(upBlock, "up requires at least one operation")
    if not downBlock.hasOperations: dslError(downBlock, "down requires at least one operation")
    upOps = parseOperations(upBlock, inChange = false)
    downOps = parseOperations(downBlock, inChange = false)
  else:
    dslError(body, "migration requires a change or up/down block")

  let definition = MigrationDefinition(
    version: version,
    name: declaredName,
    sourcePath: sourcePath,
    sourceChecksum: sourceChecksum,
    format: mfNimV1,
    upOps: upOps,
    downOps: downOps,
    legacyUp: "",
    legacyDown: "",
    hasDown: hasDown,
    pending: pending)
  result = newStmtList()
  result.add nnkLetSection.newTree(nnkIdentDefs.newTree(
    nnkPostfix.newTree(ident"*", ident"migrationDefinition"),
    newEmptyNode(),
    definitionNode(definition)))
