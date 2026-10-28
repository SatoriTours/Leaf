## Component declarations lower to the existing managed runtime. There is no
## implicit State converter: only lexically bound managed variables are lowered.
import std/[macros, tables, sets]
import ./[core, component_state, component_description, component_view, managed_runtime, runner, graphics, canvas_input, animation, animation_state]

proc displayTextInternal*(value:string):string=value
proc displayTextInternal*[T:SomeInteger|SomeFloat](value:T):string= $value

proc run*[M](definition:ComponentDef[tuple[],M],title="Leaf",width=640,height=480,
    canvasRenderer=CanvasRenderer.hardware,motionPolicy=MotionPolicy.system):int=
  runner.run(componentApplication(componentInstanceInternal(definition,()),title,width,height).withCanvasRenderer(canvasRenderer).withMotionPolicy(motionPolicy))
proc run*[P,M](definition:ComponentDef[P,M],props:P,title="Leaf",width=640,height=480,
    canvasRenderer=CanvasRenderer.hardware,motionPolicy=MotionPolicy.system):int=
  runner.run(componentApplication(componentInstanceInternal(definition,props),title,width,height).withCanvasRenderer(canvasRenderer).withMotionPolicy(motionPolicy))

type Bindings=object
  entries:Table[string,NimNode]
  animations:HashSet[string]
proc hasKey(slots:Bindings,name:string):bool=slots.entries.hasKey(name)
proc `[]`(slots:Bindings,name:string):NimNode=slots.entries[name]
proc `[]=`(slots:var Bindings,name:string,value:NimNode)=slots.entries[name]=value
proc scoped(names:HashSet[string]):HashSet[string]=
  for name in names:result.incl(name)
proc named(node:NimNode):bool=node.kind in {nnkIdent,nnkSym}
proc stateName(node:NimNode,slots:Bindings,shadow:HashSet[string]):bool=
  node.named and slots.hasKey(node.strVal) and node.strVal notin shadow
proc rootedInState(node:NimNode,slots:Bindings,shadow:HashSet[string]):bool=
  if node.stateName(slots,shadow):return true
  if node.kind in {nnkDotExpr,nnkBracketExpr,nnkDerefExpr} and node.len>0:
    return rootedInState(node[0],slots,shadow)
proc declareNames(node:NimNode,shadow:var HashSet[string])=
  case node.kind
  of nnkIdent,nnkSym:shadow.incl(node.strVal)
  of nnkIdentDefs,nnkVarTuple:
    for i in 0..<node.len-2:declareNames(node[i],shadow)
  of nnkPragmaExpr,nnkPostfix:declareNames(node[^1],shadow)
  else:discard
proc eventProperty(node:NimNode):bool=
  node.kind in {nnkCall,nnkCommand} and node.len>=2 and node[0].named and
    node[0].strVal in ["onClick","onChange","onSubmit","onEnter","onLeave","onDragStart","onDrag","onDragEnd","onDragCancel","onPointerDown","onPointerMove","onPointerUp","onWheel","onKeyDown"] and node[^1].kind==nnkStmtList

proc lower(node,ctx:NimNode,slots:Bindings,shadow:HashSet[string],event:bool,insideCanvas=false):NimNode=
  let insideCanvas = insideCanvas or (node.kind in {nnkCall,nnkCommand} and node.len > 1 and node[0].eqIdent("canvas"))
  if node.kind in {nnkCall,nnkCommand} and node.len>0 and
      node[0].kind==nnkDotExpr and node[0][0].stateName(slots,shadow) and
      node[0][0].strVal in slots.animations and node[0][1].named and
      node[0][1].strVal in ["play","pause","restart","reset","seek"]:
    if not event:error("animation controls require an event handler",node)
    let operation=case node[0][1].strVal
      of "play":bindSym"play"
      of "pause":bindSym"pause"
      of "restart":bindSym"restart"
      of "reset":bindSym"reset"
      else:bindSym"seek"
    result=newCall(operation,slots[node[0][0].strVal])
    for i in 1..<node.len:result.add(lower(node[i],ctx,slots,shadow,event,insideCanvas))
    result.copyLineInfo(node)
    return
  if node.stateName(slots,shadow):
    if event:return newCall(bindSym"readDraft",slots[node.strVal])
    let sample=newCall(bindSym"value",ctx,slots[node.strVal])
    if insideCanvas and node.strVal in slots.animations:
      return newCall(bindSym"canvasTweenValueInternal",sample)
    return sample
  if node.eventProperty:
    if event:error("event declarations belong in view, not inside handlers",node)
    if node.len notin {2,3}:error("an event takes an optional event parameter",node)
    let parameter=if node.len==3:node[1] else:genSym(nskParam,"event")
    if not parameter.named:error("event parameter must be an identifier",parameter)
    var nested=shadow.scoped
    nested.incl(parameter.strVal)
    let handler=newProc(params= @[newEmptyNode(),newIdentDefs(parameter,if insideCanvas: bindSym"CanvasPointerEvent" else: bindSym"Event")],
      body=lower(node[^1],ctx,slots,nested,true,insideCanvas),procType=nnkLambda)
    result=newCall(node[0],newStmtList(handler))
    result.copyLineInfo(node)
    return
  if node.kind==nnkAsgn and node[0].rootedInState(slots,shadow) and
      not node[0].stateName(slots,shadow):
    error("assign a new managed value; in-place field/index writes are not supported",node)
  if node.kind==nnkInfix and node.len==3 and node[0].strVal in ["+=","-=","*=","/=","&="] and
      node[1].rootedInState(slots,shadow) and not node[1].stateName(slots,shadow):
    error("assign a new managed value; in-place field/index writes are not supported",node)
  if node.kind==nnkAsgn and node[0].stateName(slots,shadow):
    if node[0].strVal in slots.animations:error("animation bindings are read-only; use controls",node)
    if not event:error("managed variables can only be assigned in event handlers",node)
    result=newCall(bindSym"writeDraft",slots[node[0].strVal],lower(node[1],ctx,slots,shadow,true,insideCanvas))
    result.copyLineInfo(node)
    return
  if node.kind==nnkInfix and node.len==3 and node[0].strVal in ["+=","-=","*=","/=","&="] and
      node[1].stateName(slots,shadow):
    if node[1].strVal in slots.animations:error("animation bindings are read-only; use controls",node)
    if not event:error("managed variables can only be assigned in event handlers",node)
    let operation=node[0].strVal[0..^2]
    let expression=newTree(nnkInfix,ident(operation),lower(node[1],ctx,slots,shadow,true,insideCanvas),lower(node[2],ctx,slots,shadow,true,insideCanvas))
    result=newCall(bindSym"writeDraft",slots[node[1].strVal],expression)
    result.copyLineInfo(node)
    return
  result=node.copyNimTree()
  case node.kind
  of nnkStmtList:
    var local=shadow.scoped
    for i,child in node:
      if child.kind in {nnkLetSection,nnkVarSection,nnkConstSection}:
        var section=child.copyNimTree()
        for j,definition in child:
          let item=definition.copyNimTree()
          item[^1]=lower(definition[^1],ctx,slots,local,event,insideCanvas)
          section[j]=item
          declareNames(definition,local)
        result[i]=section
      elif child.kind in {nnkProcDef,nnkFuncDef,nnkTemplateDef,nnkIteratorDef,nnkTypeSection}:
        # Nested declarations have their own lexical bindings. Do not silently
        # interpret a state handle as a var parameter or rewrite its type syntax.
        error("put helper declarations outside component view and handlers",child)
      else:result[i]=lower(child,ctx,slots,local,event,insideCanvas)
  of nnkExceptBranch:
    var local=shadow.scoped
    # Exception type/alias syntax is a declaration, not a managed value read.
    for i in 0..<node.len-1:
      let head=node[i]
      if head.kind==nnkInfix and head[0].eqIdent("as"):
        declareNames(head[2],local)
    result[^1]=lower(node[^1],ctx,slots,local,event,insideCanvas)
  of nnkForStmt:
    var local=shadow.scoped
    for i in 0..<node.len-2:declareNames(node[i],local)
    result[^2]=lower(node[^2],ctx,slots,shadow,event,insideCanvas)
    result[^1]=lower(node[^1],ctx,slots,local,event,insideCanvas)
  of nnkCall,nnkCommand:
    # Transition property lists are names, never reads of same-named State.
    if insideCanvas and not event and node.len==2 and node[0].eqIdent("properties") and node[1].kind==nnkStmtList:
      return result
    # `width: fill` is a layout keyword, not a lexical reference. Preserve it
    # for normalizeView; `text fill`, paint fill and handler uses remain state.
    if not event and node.len==2 and node[0].eqIdent("width") and
        node[^1].kind==nnkStmtList and node[^1].len==1 and node[^1][0].eqIdent("fill"):
      return result
    for i,child in node:
      # DSL constructor/property labels are not value references, even when
      # a managed variable happens to be named radius, width, checked, etc.
      if i==0 and not event and node[^1].kind==nnkStmtList:continue
      result[i]=lower(child,ctx,slots,shadow,event,insideCanvas)
  of nnkDotExpr:
    result[0]=lower(node[0],ctx,slots,shadow,event,insideCanvas)
  of nnkExprEqExpr,nnkExprColonExpr:
    result[1]=lower(node[1],ctx,slots,shadow,event,insideCanvas)
  of nnkLambda,nnkDo:
    var local=shadow.scoped
    for parameter in node[3]:
      if parameter.kind==nnkIdentDefs:declareNames(parameter,local)
    result[^1]=lower(node[^1],ctx,slots,local,event,insideCanvas)
  else:
    for i,child in node:result[i]=lower(child,ctx,slots,shadow,event,insideCanvas)

const LayoutProperties=["padding","gap","width","height","align"]
proc normalizeView(node:NimNode):NimNode=
  if node.kind in {nnkLambda,nnkDo}:return node
  result=node.copyNimTree()
  if node.kind in {nnkCall,nnkCommand} and node.len>=2:
    if node[0].eqIdent("canvas"):return node
    if node[0].eqIdent("text"):
      result[1]=newCall(bindSym"displayTextInternal",node[1])
    if node[^1].kind==nnkStmtList:
      var body=newStmtList()
      var styles=newTree(nnkTableConstr)
      var explicitStyles=false
      for child in node[^1]:
        if child.kind in {nnkCall,nnkCommand} and child.len==2 and child[0].named and
            child[^1].kind==nnkStmtList:
          let name=child[0].strVal
          if name=="styles":explicitStyles=true
          if name in LayoutProperties:
            if child[^1].len!=1:error("a layout property takes one value",child)
            var value=child[^1][0]
            if name=="width" and value.eqIdent("fill"):value=newLit("full")
            styles.add(newTree(nnkExprColonExpr,newLit(name),newCall(bindSym"$",value)))
            continue
        body.add(normalizeView(child))
      if styles.len>0:
        if explicitStyles:error("use layout properties or styles, not both on the same node",node)
        body.add(newCall(ident"styles",newStmtList(styles)))
      result[^1]=body
    return
  for i,child in node:result[i]=normalizeView(child)

macro component*(declaration:untyped,arguments:varargs[untyped]):untyped=
  # One public macro distinguishes declarations from existing instance calls.
  # The typed constructor remains available from component_description itself.
  if arguments.len!=1 or arguments[0].kind!=nnkStmtList:
    result=newCall(bindSym"componentInstanceInternal",declaration)
    for argument in arguments:result.add(argument)
    return
  let body=arguments[0]
  var name=declaration
  var props=genSym(nskParam,"props")
  var propsType:NimNode=newTree(nnkTupleTy)
  if declaration.kind in {nnkCall,nnkCommand,nnkObjConstr}:
    if declaration.len!=2 or declaration[1].kind!=nnkExprColonExpr:
      error("component declaration takes one typed props parameter",declaration)
    name=declaration[0]
    props=declaration[1][0]
    propsType=declaration[1][1]
  if name.kind!=nnkIdent:error("component name must be an identifier",name)
  var states:seq[NimNode]
  var animationNames:HashSet[string]
  var view:NimNode
  for section in body:
    if section.kind==nnkCommentStmt:continue
    if section.kind notin {nnkCall,nnkCommand} or section.len!=2 or section[^1].kind!=nnkStmtList:
      error("component contains state:, animation: and view: sections",section)
    if section[0].eqIdent("state") or section[0].eqIdent("animation"):
      for entry in section[^1]:
        if entry.kind==nnkCommentStmt:continue
        if entry.kind!=nnkAsgn or entry[0].kind!=nnkIdent:
          error("state declarations use name = initialValue",entry)
        for existing in states:
          if existing[0].eqIdent(entry[0]):error("duplicate state declaration",entry)
        states.add(entry)
        if section[0].eqIdent("animation"):animationNames.incl(entry[0].strVal)
    elif section[0].eqIdent("view"):
      if view!=nil:error("component needs exactly one view",section)
      view=section[^1]
    else:error("unsupported component section: " & section[0].repr,section)
  if view==nil:error("component needs a view section",body)
  let init=genSym(nskProc,"initialize")
  let initCtx=genSym(nskParam,"mount")
  let renderCtx=genSym(nskParam,"render")
  let model=genSym(nskParam,"model")
  let modelType=genSym(nskType,"Model")
  var initBody=newStmtList()
  var tupleValue=newTree(nnkTupleConstr)
  var slots,initSlots:Bindings
  var finishSetups:seq[(NimNode,NimNode)]
  for i,entry in states:
    let field=ident("slot" & $i)
    let slot=genSym(nskLet,"state")
    if entry[0].strVal in animationNames:
      var spec=entry[1].copyNimTree()
      if spec.kind in {nnkCall,nnkCommand}:
        var filtered=newCall(spec[0])
        var callback:NimNode
        for j in 1..<spec.len:
          let argument=spec[j]
          if argument.kind==nnkExprEqExpr and argument[0].eqIdent("onFinish"):
            if callback!=nil:error("duplicate onFinish",argument)
            callback=argument[1]
          else:filtered.add(argument)
        spec=filtered
        if callback!=nil:finishSetups.add((slot,callback))
      initBody.add(newLetStmt(slot,newCall(bindSym"newAnimationInternal",initCtx,spec)))
      slots.animations.incl(entry[0].strVal)
      initSlots.animations.incl(entry[0].strVal)
    else:
      initBody.add(newLetStmt(entry[0],entry[1]))
      initBody.add(newLetStmt(slot,newCall(bindSym"managedStateInternal",initCtx,entry[0])))
    tupleValue.add(newTree(nnkExprColonExpr,field,slot))
    slots[entry[0].strVal]=newTree(nnkDotExpr,model,field)
    initSlots[entry[0].strVal]=slot
  for setup in finishSetups:
    let callback=lower(setup[1],initCtx,initSlots,initHashSet[string](),true)
    initBody.add(newCall(bindSym"setAnimationFinishInternal",initCtx,setup[0],callback))
  if states.len==0:tupleValue.add(newTree(nnkExprColonExpr,ident"unit",newLit(0)))
  initBody.add(tupleValue)
  let initializer=newProc(init,params= @[ident"auto",newIdentDefs(initCtx,bindSym"MountContext"),newIdentDefs(props,propsType)],body=initBody)
  # A typeof block keeps type symbols in type positions. Passing a bound type
  # symbol to default() inside a generated typeof is misclassified by Nim 2.2.
  let typeMount=genSym(nskVar,"typeMount")
  let typeProps=genSym(nskVar,"typeProps")
  let typeBody=newStmtList(newTree(nnkVarSection,newIdentDefs(typeMount,bindSym"MountContext"),
    newIdentDefs(typeProps,propsType)),newCall(init,typeMount,typeProps))
  let modelExpr=newCall(bindSym"typeof",newBlockStmt(typeBody))
  let lowered=normalizeView(lower(view,renderCtx,slots,initHashSet[string](),false))
  let renderer=newProc(params= @[bindSym"UiDescription",newIdentDefs(renderCtx,bindSym"ComponentContext"),
    newIdentDefs(props,propsType),newIdentDefs(model,modelType)],body=newStmtList(newCall(bindSym"componentView",lowered)),procType=nnkLambda)
  let factory=newTree(nnkBracketExpr,bindSym"defineComponent",propsType,modelType)
  result=newStmtList(initializer,newTree(nnkTypeSection,newTree(nnkTypeDef,modelType,newEmptyNode(),modelExpr)),
    newLetStmt(name,newCall(factory,newLit(name.strVal),init,renderer)))
  result.copyLineInfo(declaration)
