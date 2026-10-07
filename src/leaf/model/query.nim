import std/[macros, options, algorithm, sets]
import ../sqlite
import ./[record, metadata, context, errors, introspection, query_expression, query_sql]
import ./adapters/norm_sqlite
export SortDirection

type Query*[T] = object
  description: QueryDescription

proc newQuery*[T: Record](_: typedesc[T]): Query[T] =
  mixin modelTable, modelFields
  result.description = QueryDescription(database: currentDatabase(),
    table: modelTable(T), fields: modelFields(T))
proc asQuery*[T: Record](model: typedesc[T]): Query[T] = newQuery(model)
proc asQuery*[T: Record](query: Query[T]): Query[T] = query
proc withPredicate*[T: Record](query: Query[T], predicate: Predicate): Query[T] =
  result = query
  result.description.predicate = andPredicate(query.description.predicate, predicate)
proc withOrder[T: Record](query: Query[T], field: string, direction: SortDirection): Query[T] =
  result = query
  result.description.orders.add((field, direction))

proc limit*[T: Record](query: Query[T], n: int): Query[T] =
  if n < 0: raise newException(ModelUsageError, "limit cannot be negative")
  result = query
  result.description.rowLimit = some(n)
proc offset*[T: Record](query: Query[T], n: int): Query[T] =
  if n < 0: raise newException(ModelUsageError, "offset cannot be negative")
  result = query
  result.description.rowOffset = some(n)
proc limit*[T: Record](model: typedesc[T], n: int): Query[T] = newQuery(model).limit(n)
proc offset*[T: Record](model: typedesc[T], n: int): Query[T] = newQuery(model).offset(n)

proc compileQuery*[T: Record](query: Query[T], selectedFields: seq[string] = @[],
                             mode = queryRows, n = 0): SqlResult =
  compileDescription(query.description, selectedFields, mode, n)

proc rows[T: Record](query: Query[T], mode: QueryMode, n = 0): seq[T] =
  mixin storageType, fromStorage
  if n < 0: raise newException(ModelUsageError, "first/last count cannot be negative")
  let compiled = query.compileQuery(@[], mode, n)
  withDatabase(query.description.database):
    for stored in selectStorage[storageType(T)](currentDatabase(), compiled.sql, compiled.values):
      result.add(fromStorage(T, stored, currentDatabase()))
  if mode == queryLast: result.reverse()

proc all*[T: Record](query: Query[T]): seq[T] = query.rows(queryRows)
proc first*[T: Record](query: Query[T], n: int): seq[T] = query.rows(queryFirst, n)
proc last*[T: Record](query: Query[T], n: int): seq[T] = query.rows(queryLast, n)
proc first*[T: Record](query: Query[T]): Option[T] =
  let values = query.first(1)
  if values.len == 0: none(T) else: some(values[0])
proc last*[T: Record](query: Query[T]): Option[T] =
  let values = query.last(1)
  if values.len == 0: none(T) else: some(values[0])
proc firstOrRaise*[T: Record](query: Query[T]): T =
  let value = query.first()
  if value.isNone: raise newException(RecordNotFound, "no first record")
  value.get
proc lastOrRaise*[T: Record](query: Query[T]): T =
  let value = query.last()
  if value.isNone: raise newException(RecordNotFound, "no last record")
  value.get
proc count*[T: Record](query: Query[T]): int64 =
  let compiled = query.compileQuery(@[], queryCount)
  withDatabase(query.description.database):
    result = currentDatabase().query(compiled.sql, compiled.values)[0][0].asInt64
proc exists*[T: Record](query: Query[T]): bool =
  let compiled = query.compileQuery(@[], queryExists)
  withDatabase(query.description.database):
    result = currentDatabase().query(compiled.sql, compiled.values).len > 0
proc exists*[T: Record](query: Query[T], id: int64): bool =
  query.withPredicate(comparisonPredicate("id", int64, "=", id)).exists()

proc projectionRows*[T: Record](query: Query[T], fields: seq[string]): seq[seq[SqlValue]] =
  let compiled = query.compileQuery(fields)
  withDatabase(query.description.database):
    result = currentDatabase().query(compiled.sql, compiled.values)
proc ids*[T: Record](query: Query[T]): seq[int64] =
  for row in query.projectionRows(@["id"]): result.add(row[0].asInt64)

proc all*[T: Record](model: typedesc[T]): seq[T] = newQuery(model).all()
proc first*[T: Record](model: typedesc[T]): Option[T] = newQuery(model).first()
proc last*[T: Record](model: typedesc[T]): Option[T] = newQuery(model).last()
proc first*[T: Record](model: typedesc[T], n: int): seq[T] = newQuery(model).first(n)
proc last*[T: Record](model: typedesc[T], n: int): seq[T] = newQuery(model).last(n)
proc firstOrRaise*[T: Record](model: typedesc[T]): T = newQuery(model).firstOrRaise()
proc lastOrRaise*[T: Record](model: typedesc[T]): T = newQuery(model).lastOrRaise()
proc count*[T: Record](model: typedesc[T]): int64 = newQuery(model).count()
proc exists*[T: Record](model: typedesc[T]): bool = newQuery(model).exists()
proc exists*[T: Record](model: typedesc[T], id: int64): bool = newQuery(model).exists(id)
proc ids*[T: Record](model: typedesc[T]): seq[int64] = newQuery(model).ids()

proc rawQuery*[T: Record](model: typedesc[T], sql: string, values: openArray[SqlValue]): seq[T] =
  mixin storageType, fromStorage
  let db = currentDatabase()
  for stored in selectStorage[storageType(T)](db, sql, values): result.add(fromStorage(T, stored, db))

proc whereNode*(source, arguments: NimNode): NimNode {.compileTime.} =
  let symbol = symbolType(source)
  var predicate: NimNode
  if arguments.len > 0 and arguments[0].kind == nnkExprEqExpr:
    var seen = initHashSet[string]()
    for argument in arguments:
      if argument.kind != nnkExprEqExpr: error("cannot mix named and expression where conditions", argument)
      let field = persistentFieldName(symbol, $argument[0])
      if field in seen: error("duplicate where field", argument)
      seen.incl(field)
      let condition = newCall(bindSym"comparisonPredicate", newLit(field),
        fieldTypeExpression(symbol, field), newLit("="), argument[1])
      predicate = if predicate == nil: condition else: newCall(bindSym"andPredicate", predicate, condition)
  elif arguments.len == 1:
    predicate = compilePredicateNode(symbol, arguments[0])
  elif arguments.len > 1: error("where accepts named fields or one expression", arguments)
  result = newCall(bindSym"asQuery", source)
  if predicate != nil: result = newCall(bindSym"withPredicate", result, predicate)

macro where*(source: typed, arguments: varargs[untyped]): untyped = whereNode(source, arguments)
macro orderBy*(source: typed, field: untyped, direction: SortDirection = Asc): untyped =
  let name = queryField(symbolType(source), field)
  newCall(bindSym"withOrder", newCall(bindSym"asQuery", source), newLit(name), direction)
macro findBy*(source: typed, arguments: varargs[untyped]): untyped =
  newCall(bindSym"first", whereNode(source, arguments))
macro findByOrRaise*(source: typed, arguments: varargs[untyped]): untyped =
  newCall(bindSym"firstOrRaise", whereNode(source, arguments))

macro pluck*(source: typed, fields: varargs[untyped]): untyped =
  if fields.len == 0: error("pluck requires at least one it.field", source)
  let symbol = symbolType(source)
  let resultVar = genSym(nskVar, "projection")
  let rowVar = genSym(nskForVar, "row")
  var names = newNimNode(nnkBracket)
  var tupleType = newNimNode(nnkTupleTy)
  var tupleValue = newNimNode(nnkTupleConstr)
  var singleType, singleValue: NimNode
  var seen = initHashSet[string]()
  for i, fieldNode in fields:
    let field = queryField(symbol, fieldNode)
    if field in seen: error("pluck fields must be distinct", fieldNode)
    seen.incl(field)
    names.add(newLit(field))
    let fieldType = fieldTypeExpression(symbol, field)
    let value = newCall(bindSym"fieldFromValue", newTree(nnkBracketExpr, rowVar, newLit(i)), fieldType.copyNimTree)
    tupleType.add(newIdentDefs(ident(field), fieldType.copyNimTree))
    tupleValue.add(newTree(nnkExprColonExpr, ident(field), value))
    singleType = fieldType
    singleValue = value
  let elementType = if fields.len == 1: singleType else: tupleType
  let elementValue = if fields.len == 1: singleValue else: tupleValue
  result = newStmtList(newTree(nnkVarSection, newIdentDefs(resultVar,
    newTree(nnkBracketExpr, bindSym"seq", elementType))),
    newTree(nnkForStmt, rowVar, newCall(bindSym"projectionRows", newCall(bindSym"asQuery", source),
      newTree(nnkPrefix, ident"@", names)), newStmtList(newCall(bindSym"add", resultVar, elementValue))), resultVar)
