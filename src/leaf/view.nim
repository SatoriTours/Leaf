## Indented UI descriptions, expanded into the ordinary typed constructors.
import std/macros
import ./widgets

const Properties = [
  "key", "styles", "children", "disabled", "variant", "placeholder",
  "onClick", "onChange", "onSubmit", "keys", "builder", "rowHeight",
  "estimatedHeight", "overscan", "gap", "height", "width", "align",
  "color", "size", "value", "checked", "label", "heading", "description"
]

proc property(node: NimNode): bool =
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

proc argument(node: NimNode): NimNode =
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

proc component(node: NimNode): NimNode

template appendChild(children: var seq[Node], content: untyped) =
  when typeof(content) is void:
    content
  else:
    children.add(content)

template rootNode(content: Node): Node = content

proc collect(body, children: NimNode): NimNode =
  result = newStmtList()
  for statement in body:
    case statement.kind
    of nnkForStmt, nnkWhileStmt, nnkBlockStmt:
      let expanded = statement.copyNimTree()
      expanded[^1] = collect(statement[^1], children)
      result.add(expanded)
    of nnkIfStmt, nnkWhenStmt, nnkCaseStmt:
      let expanded = statement.copyNimTree()
      for i in 0..<expanded.len:
        if expanded[i].kind in {nnkElifBranch, nnkElse, nnkOfBranch}:
          expanded[i][^1] = collect(statement[i][^1], children)
      result.add(expanded)
    of nnkLetSection, nnkVarSection, nnkConstSection, nnkCommentStmt,
        nnkAsgn, nnkDiscardStmt, nnkBreakStmt, nnkContinueStmt, nnkRaiseStmt:
      result.add(statement)
    else:
      if property(statement):
        error("properties must be directly inside a component", statement)
      result.add(newCall(bindSym"appendChild", children, component(statement)))

proc component(node: NimNode): NimNode =
  if node.kind notin {nnkCall, nnkCommand} or node.len < 2 or
      node[^1].kind != nnkStmtList:
    return node
  let call = newCall(node[0])
  call.copyLineInfo(node)
  for i in 1..<node.len - 1: call.add(node[i])
  var content = newStmtList()
  var explicitChildren = false
  for statement in node[^1]:
    if statement.kind == nnkCommentStmt: continue
    if property(statement):
      let arg = argument(statement)
      for existing in call:
        if existing.kind == nnkExprEqExpr and existing[0].eqIdent(arg[0]):
          error("duplicate property: " & arg[0].strVal, statement)
      call.add(arg)
      if statement[0].eqIdent("children"): explicitChildren = true
    else:
      content.add(statement)
  if explicitChildren and content.len > 0:
    error("use either children: or nested components", node)
  let container = node[0].kind == nnkIdent and
    (node[0].eqIdent("column") or node[0].eqIdent("row"))
  if content.len == 0 and (not container or explicitChildren): return call
  let children = genSym(nskVar, "children")
  let body = newStmtList()
  body.add quote do:
    var `children`: seq[Node] = @[]
  body.add(collect(content, children))
  call.add(newTree(nnkExprEqExpr, ident"children", children))
  body.add(call)
  result = newBlockStmt(body)

macro view*(body: untyped): untyped =
  ## Exactly one root component. Properties use `name: value`; event blocks
  ## use `onClick(e): ...`. Nested layouts accept ordinary Nim if/for/case.
  body.expectKind(nnkStmtList)
  var roots: seq[NimNode]
  for node in body:
    if node.kind != nnkCommentStmt: roots.add(node)
  if roots.len != 1: error("view needs exactly one root component", body)
  if property(roots[0]): error("view needs a component, not a property", roots[0])
  result = newCall(bindSym"rootNode", component(roots[0]))

macro views*(body: untyped): untyped =
  ## A sequence of sibling components, for existing collection-based APIs.
  body.expectKind(nnkStmtList)
  let children = genSym(nskVar, "children")
  let statements = newStmtList()
  statements.add quote do:
    var `children`: seq[Node] = @[]
  statements.add(collect(body, children))
  statements.add(children)
  result = newBlockStmt(statements)
