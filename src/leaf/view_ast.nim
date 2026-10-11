## Shared AST vocabulary for view and componentView; no runtime state.
import std/macros
import ./core

const Properties = [
  "key", "styles", "children", "disabled", "variant", "placeholder",
  "onClick", "onChange", "onSubmit", "keys", "builder", "rowHeight",
  "estimatedHeight", "overscan", "gap", "height", "width", "align",
  "color", "size", "value", "checked", "label", "heading", "description"
]

proc property*(node: NimNode): bool =
  if node.kind notin {nnkCall, nnkCommand} or node.len < 2 or
      node[^1].kind != nnkStmtList or node[0].kind != nnkIdent:
    return false
  if node.len != 2:
    return node.len == 3 and node[1].kind == nnkIdent and
      (node[0].eqIdent("onClick") or node[0].eqIdent("onChange") or
       node[0].eqIdent("onSubmit"))
  for name in Properties:
    if node[0].eqIdent(name): return true

proc expression(body: NimNode): NimNode =
  if body.len == 1: body[0] else: newBlockStmt(body)

proc argument*(node: NimNode): NimNode =
  var value: NimNode
  if node.len == 3:
    node[1].expectKind(nnkIdent)
    value = newProc(params = @[newEmptyNode(), newIdentDefs(node[1], bindSym"Event")],
      body = node[^1], procType = nnkLambda)
  else:
    if node.len != 2: error("a property takes one value", node)
    value = expression(node[^1])
    if node[0].eqIdent("styles") and value.kind == nnkTableConstr:
      value = newCall(bindSym"style", value)
  newTree(nnkExprEqExpr, node[0], value)

proc collectChildren*(body, children, append: NimNode, expand: proc(node:NimNode):NimNode): NimNode =
  result = newStmtList()
  for statement in body:
    case statement.kind
    of nnkForStmt, nnkWhileStmt, nnkBlockStmt:
      let expanded = statement.copyNimTree()
      expanded[^1] = collectChildren(statement[^1], children, append, expand)
      result.add(expanded)
    of nnkIfStmt, nnkWhenStmt, nnkCaseStmt:
      let expanded = statement.copyNimTree()
      for i in 0..<expanded.len:
        if expanded[i].kind in {nnkElifBranch, nnkElse, nnkOfBranch}:
          expanded[i][^1] = collectChildren(statement[i][^1], children, append, expand)
      result.add(expanded)
    of nnkLetSection, nnkVarSection, nnkConstSection, nnkCommentStmt,
        nnkAsgn, nnkDiscardStmt, nnkBreakStmt, nnkContinueStmt, nnkRaiseStmt:
      result.add(statement)
    else:
      if property(statement):
        error("properties must be directly inside a component", statement)
      result.add(newCall(append, children, expand(statement)))

