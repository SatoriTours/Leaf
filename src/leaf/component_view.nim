## The existing view property/control-flow syntax with explicit component children.
import std/macros
import ./[view_ast,component_description]
template appendDescription(children:var seq[UiDescription],content:untyped)=
  when typeof(content) is void:content
  else:children.add(toDescription(content))
proc expandDescription(node:NimNode):NimNode=
  if node.kind notin {nnkCall,nnkCommand} or node.len<2 or node[^1].kind!=nnkStmtList:
    return newCall(bindSym"toDescription",node)
  if node[0].eqIdent("canvas"):
    return newCall(bindSym"toDescription",node)
  let call=newCall(node[0])
  call.copyLineInfo(node)
  for i in 1..<node.len-1:call.add(node[i])
  var content=newStmtList()
  var explicitChildren=false
  for statement in node[^1]:
    if statement.kind==nnkCommentStmt:continue
    if property(statement):
      let arg=argument(statement)
      for existing in call:
        if existing.kind==nnkExprEqExpr and existing[0].eqIdent(arg[0]):
          error("duplicate property: " & arg[0].strVal,statement)
      call.add(arg)
      if statement[0].eqIdent("children"):explicitChildren=true
    else:content.add(statement)
  if explicitChildren and content.len>0:error("use either children: or nested components",node)
  let container=node[0].kind==nnkIdent and (node[0].eqIdent("column") or node[0].eqIdent("row"))
  if content.len==0 and (not container or explicitChildren):
    return newCall(bindSym"toDescription",call)
  if not container:error("nested managed descriptions require row or column",node)
  let children=genSym(nskVar,"descriptions")
  let body=newStmtList()
  body.add quote do:
    var `children`:seq[UiDescription]= @[]
  body.add(collectChildren(content,children,bindSym"appendDescription",expandDescription))
  call.add(newTree(nnkExprEqExpr,ident"children",newTree(nnkPrefix,ident"@",newTree(nnkBracket))))
  body.add(newCall(bindSym"hostShell",call,children))
  newBlockStmt(body)
macro componentView*(body:untyped):untyped=
  body.expectKind(nnkStmtList)
  var roots:seq[NimNode]
  for node in body:
    if node.kind!=nnkCommentStmt:roots.add(node)
  if roots.len!=1:error("componentView needs exactly one root component",body)
  if property(roots[0]):error("componentView needs a component, not a property",roots[0])
  expandDescription(roots[0])
