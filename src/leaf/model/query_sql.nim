## Query compilation keeps ordering, pagination and tail-window semantics together.
import std/[options, sequtils, strutils]
import ../sqlite
import ./[metadata, query_expression]

type
  SortDirection* = enum Asc, Desc
  OrderTerm* = tuple[field: string, direction: SortDirection]
  QueryMode* = enum queryRows, queryCount, queryExists, queryFirst, queryLast
  QueryDescription* = object
    database*: Database
    table*: string
    fields*: seq[FieldMeta]
    predicate*: Predicate
    orders*: seq[OrderTerm]
    rowLimit*, rowOffset*: Option[int]

proc effectiveOrders(description: QueryDescription): seq[OrderTerm] =
  var hasId = false
  for order in description.orders:
    result.add(order)
    if order.field == "id": hasId = true
  if not hasId: result.add(("id", Asc))

proc orderSql(description: QueryDescription, reverse = false): string =
  var terms: seq[string]
  for order in description.effectiveOrders:
    let direction = if reverse: (if order.direction == Asc: Desc else: Asc) else: order.direction
    terms.add(quoteIdentifier(order.field) & (if direction == Asc: " ASC" else: " DESC"))
  " ORDER BY " & terms.join(", ")

proc appendPage(compiled: var SqlResult, description: QueryDescription) =
  if description.rowLimit.isSome:
    compiled.sql.add(" LIMIT ?")
    compiled.values.add(dbValue(description.rowLimit.get))
  elif description.rowOffset.isSome: compiled.sql.add(" LIMIT -1")
  if description.rowOffset.isSome:
    compiled.sql.add(" OFFSET ?")
    compiled.values.add(dbValue(description.rowOffset.get))

proc compileDescription*(description: QueryDescription, selectedFields: seq[string], mode: QueryMode, n: int): SqlResult =
  let predicate = compilePredicate(description.predicate)
  let fromClause = " FROM " & quoteIdentifier(description.table) & " WHERE " & predicate.sql
  result.values = predicate.values
  if mode == queryCount:
    result.sql = "SELECT COUNT(*)" & fromClause
    return
  if mode == queryExists:
    result.sql = "SELECT 1" & fromClause & " LIMIT 1"
    return
  let fields = if selectedFields.len == 0: description.fields.mapIt(it.name) else: selectedFields
  let columns = fields.mapIt(quoteIdentifier(it)).join(", ")
  if mode in {queryFirst, queryLast}:
    let reverse = mode == queryLast
    if description.rowLimit.isSome or description.rowOffset.isSome:
      # Select all fields in the inner window so outer ordering can use omitted fields.
      var window: SqlResult = ("SELECT " & description.fields.mapIt(quoteIdentifier(it.name)).join(", ") &
        fromClause & description.orderSql(), predicate.values)
      window.appendPage(description)
      result = ("SELECT " & columns & " FROM (" & window.sql & ") AS \"_leaf_window\"" &
        description.orderSql(reverse) & " LIMIT ?", window.values)
    else:
      result.sql = "SELECT " & columns & fromClause & description.orderSql(reverse) & " LIMIT ?"
    result.values.add(dbValue(n))
  else:
    result.sql = "SELECT " & columns & fromClause & description.orderSql()
    result.appendPage(description)
