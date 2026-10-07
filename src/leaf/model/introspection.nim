## Shared compile-time field lookup, deliberately excluding Record runtime data.
import std/[macros, strutils]
import ./record

proc symbolType*(node: NimNode): NimNode {.compileTime.} =
  result = node.getTypeInst
  if result.kind == nnkBracketExpr: result = result[1]
  if result.kind != nnkSym: error("expected a model or Query type", node)

proc identifierKey*(name: string): string {.compileTime.} = name.replace("_", "").toLowerAscii

proc persistentFieldName*(symbol: NimNode, requested: string): string {.compileTime.} =
  let key = identifierKey(requested)
  if key == "id": return "id"
  if symbol == bindSym"Record": error("unknown persistent field: " & requested, symbol)
  var definition = symbol.getImpl[2]
  if definition.kind == nnkRefTy: definition = definition[0]
  if definition.kind != nnkObjectTy: error("expected a model ref object", symbol)
  for field in definition[2]:
    if field.kind != nnkIdentDefs: continue
    for i in 0..<field.len-2:
      var name = field[i]
      if name.kind == nnkPostfix: name = name[1]
      if name.kind == nnkPragmaExpr: name = name[0]
      if identifierKey($name) == key: return $name
  if definition[1].kind == nnkOfInherit:
    return persistentFieldName(definition[1][0], requested)
  error("unknown persistent field: " & requested, symbol)

proc fieldTypeExpression*(symbol: NimNode, field: string): NimNode {.compileTime.} =
  newCall(bindSym"typeof", newDotExpr(newCall(symbol), ident(field)))
