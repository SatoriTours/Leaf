## Indented UI descriptions, expanded into the ordinary typed constructors.
import std/macros
import ./[widgets,view_ast]

proc component(node: NimNode): NimNode

template appendChild(children: var seq[Node], content: untyped) =
  when typeof(content) is void:
    content
  else:
    children.add(content)

template rootNode(content: Node): Node = content

proc collect(body,children:NimNode):NimNode =
  collectChildren(body,children,bindSym"appendChild",component)

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
