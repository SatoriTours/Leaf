import std/[macros, options, strutils]
import ../sqlite
import ./[metadata, errors, introspection]

type
  PredicateKind = enum comparison, membership, textMatch, nullCheck, conjunction, disjunction, negation
  Predicate* = ref object
    kind: PredicateKind
    field, operator: string
    values: seq[SqlValue]
    children: seq[Predicate]
  SqlResult* = tuple[sql: string, values: seq[SqlValue]]

proc comparisonPredicate*[F](field: string, _: typedesc[F], operator: string, value: F): Predicate =
  Predicate(kind: comparison, field: field, operator: operator, values: @[fieldValue(value)])
proc membershipPredicate*[F](field: string, _: typedesc[F], values: openArray[F], negative: bool): Predicate =
  result = Predicate(kind: membership, field: field, operator: if negative: "NOT IN" else: "IN")
  for value in values: result.values.add(fieldValue(value))
proc textPredicate*[F: string | Option[string]](field: string, _: typedesc[F], value: string, mode: string): Predicate =
  var pattern = value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
  if mode in ["contains", "endsWith"]: pattern = "%" & pattern
  if mode in ["contains", "startsWith"]: pattern.add("%")
  Predicate(kind: textMatch, field: field, values: @[dbValue(pattern)])
proc nullPredicate*(field: string): Predicate = Predicate(kind: nullCheck, field: field)
proc andPredicate*(left, right: Predicate): Predicate =
  if left == nil: return right
  if right == nil: return left
  Predicate(kind: conjunction, children: @[left, right])
proc orPredicate*(left, right: Predicate): Predicate = Predicate(kind: disjunction, children: @[left, right])
proc notPredicate*(child: Predicate): Predicate = Predicate(kind: negation, children: @[child])

proc compilePredicate*(predicate: Predicate): SqlResult =
  if predicate == nil: return ("1", @[])
  let column = if predicate.field.len > 0: quoteIdentifier(predicate.field) else: ""
  case predicate.kind
  of comparison:
    if predicate.values[0].kind == sqlNull and predicate.operator in ["=", "<>"]:
      result.sql = column & (if predicate.operator == "=": " IS NULL" else: " IS NOT NULL")
    else:
      result.sql = column & " " & predicate.operator & " ?"
      result.values = predicate.values
  of membership:
    if predicate.values.len == 0: result.sql = if predicate.operator == "IN": "0" else: "1"
    else:
      var placeholders: seq[string]
      for value in predicate.values: placeholders.add("?")
      result.sql = column & " " & predicate.operator & " (" & placeholders.join(",") & ")"
      result.values = predicate.values
  of textMatch:
    result.sql = column & " LIKE ? ESCAPE '\\'"
    result.values = predicate.values
  of nullCheck: result.sql = column & " IS NULL"
  of negation:
    let child = compilePredicate(predicate.children[0])
    result = ("NOT (" & child.sql & ")", child.values)
  of conjunction, disjunction:
    let left = compilePredicate(predicate.children[0])
    let right = compilePredicate(predicate.children[1])
    result.sql = "(" & left.sql & ") " & (if predicate.kind == conjunction: "AND" else: "OR") & " (" & right.sql & ")"
    result.values = left.values & right.values

proc queryField*(symbol, node: NimNode): string {.compileTime.} =
  if node.kind != nnkDotExpr or not node[0].eqIdent("it"):
    error("query requires an it.field expression", node)
  persistentFieldName(symbol, $node[1])

proc hasFieldReference(node: NimNode): bool {.compileTime.} =
  if node.kind == nnkDotExpr and node[0].eqIdent("it"): return true
  for child in node:
    if hasFieldReference(child): return true

proc compilePredicateNode*(symbol, expression: NimNode): NimNode {.compileTime.} =
  var node = expression
  while node.kind == nnkPar and node.len == 1: node = node[0]
  case node.kind
  of nnkInfix:
    let operator = $node[0]
    if operator in ["and", "or"]:
      return newCall(if operator == "and": bindSym"andPredicate" else: bindSym"orPredicate",
        compilePredicateNode(symbol, node[1]), compilePredicateNode(symbol, node[2]))
    let field = queryField(symbol, node[1])
    let fieldType = fieldTypeExpression(symbol, field)
    if hasFieldReference(node[2]): error("a comparison value must not contain an it.field reference", node[2])
    if operator in ["in", "notin"]:
      return newCall(bindSym"membershipPredicate", newLit(field), fieldType, node[2], newLit(operator == "notin"))
    if operator notin ["==", "!=", "<", "<=", ">", ">="]: error("unsupported query operator", node)
    let sqlOperator = if operator == "==": "=" elif operator == "!=": "<>" else: operator
    return newCall(bindSym"comparisonPredicate", newLit(field), fieldType, newLit(sqlOperator), node[2])
  of nnkPrefix:
    if node[0].eqIdent("not"): return newCall(bindSym"notPredicate", compilePredicateNode(symbol, node[1]))
    error("unsupported query prefix", node)
  of nnkCall, nnkCommand:
    let function = $node[0]
    if function == "isNull" and node.len == 2:
      return newCall(bindSym"nullPredicate", newLit(queryField(symbol, node[1])))
    if function in ["contains", "startsWith", "endsWith"] and node.len == 3:
      let field = queryField(symbol, node[1])
      if hasFieldReference(node[2]): error("text match needs a string value", node[2])
      return newCall(bindSym"textPredicate", newLit(field), fieldTypeExpression(symbol, field), node[2], newLit(function))
    error("unsupported query function; use isNull, contains, startsWith or endsWith", node)
  of nnkDotExpr:
    let field = queryField(symbol, node)
    return newCall(bindSym"comparisonPredicate", newLit(field), fieldTypeExpression(symbol, field), newLit("="), newLit(true))
  else: error("unsupported query expression; use typed it.field conditions", node)
