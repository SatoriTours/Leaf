## Component declarations lower to the existing managed runtime. There is no
## implicit State converter: only lexically bound managed variables are lowered.
import std/[macros, tables, sets, strutils]
import ./[core, component_state, component_description, component_view, view_ast, managed_runtime, runner, graphics, canvas_input, animation, animation_state]

proc displayTextInternal*(value:string):string=value
proc displayTextInternal*[T:SomeInteger|SomeFloat](value:T):string= $value

proc run*[M](definition:ComponentDef[tuple[],M],title="Leaf",width=640,height=480,
    canvasRenderer=CanvasRenderer.hardware,motionPolicy=MotionPolicy.system):int=
  runner.run(componentApplication(componentInstanceInternal(definition,()),title,width,height).withCanvasRenderer(canvasRenderer).withMotionPolicy(motionPolicy))
proc run*[P,M](definition:ComponentDef[P,M],props:P,title="Leaf",width=640,height=480,
    canvasRenderer=CanvasRenderer.hardware,motionPolicy=MotionPolicy.system):int=
  runner.run(componentApplication(componentInstanceInternal(definition,props),title,width,height).withCanvasRenderer(canvasRenderer).withMotionPolicy(motionPolicy))

proc app*[P, M](definition: ComponentDef[P, M], props: P, title = "Leaf",
    width = 640, height = 480, executionScope: ExecutionScope = nil): Application =
  ## Build the same application for desktop, Android factories and headless tests.
  componentApplication(componentInstanceInternal(definition, props), title, width, height, executionScope)

proc app*[M](definition: ComponentDef[tuple[], M], title = "Leaf",
    width = 640, height = 480, executionScope: ExecutionScope = nil): Application =
  app(definition, (), title, width, height, executionScope)

type
  Parameter = object
    name, typ, fallback: NimNode
    model: bool

  Bindings=object
    entries:Table[string,NimNode]
    animations, props:HashSet[string]
proc spelling(node: NimNode): string = nimIdentNormalize(node.strVal)
proc hasKey(slots:Bindings,name:string):bool=slots.entries.hasKey(name)
proc `[]`(slots:Bindings,name:string):NimNode=slots.entries[name]
proc `[]=`(slots:var Bindings,name:string,value:NimNode)=slots.entries[name]=value
proc scoped(names:HashSet[string]):HashSet[string]=
  for name in names:result.incl(name)
proc named(node:NimNode):bool=node.kind in {nnkIdent,nnkSym}
proc stateName(node:NimNode,slots:Bindings,shadow:HashSet[string]):bool=
  node.named and slots.hasKey(node.spelling) and node.spelling notin shadow
proc rootedInState(node:NimNode,slots:Bindings,shadow:HashSet[string]):bool=
  if node.stateName(slots,shadow):return true
  if node.kind in {nnkDotExpr,nnkBracketExpr,nnkDerefExpr,nnkPar} and node.len>0:
    return rootedInState(node[0],slots,shadow)
proc declareNames(node:NimNode,shadow:var HashSet[string])=
  case node.kind
  of nnkIdent,nnkSym:shadow.incl(node.spelling)
  of nnkIdentDefs,nnkVarTuple:
    for i in 0..<node.len-2:declareNames(node[i],shadow)
  of nnkPragmaExpr:declareNames(node[0],shadow)
  of nnkPostfix:declareNames(node[^1],shadow)
  else:discard

# The generated signature travels with the constructor across module imports.
# Lower only its model arguments to a binding; all other expressions stay values.
proc modelSignatureName(node: NimNode): NimNode =
  case node.kind
  of nnkIdent, nnkSym: ident("leafModels_" & node.strVal)
  of nnkDotExpr:
    let member = modelSignatureName(node[1])
    if member == nil: nil else: newDotExpr(node[0], member)
  else: nil

type ModelBindingInternal*[T] = object
  slot*: State[T]
  sample*: T

template modelArgumentInternal(signature, index, label, handle, current: untyped): untyped =
  when declared(signature):
    const models = signature()
    when (label.len > 0 and label in models) or
        (label.len == 0 and index < models.len and models[index].len > 0):
      ModelBindingInternal[typeof(current)](slot: handle, sample: current)
    else:
      current
  else:
    current

const LayoutProperties=["padding","gap","width","height","align"]

proc eventProperty(node:NimNode):bool=
  node.kind in {nnkCall,nnkCommand} and node.len>=2 and node[0].named and
    node[0].strVal in ["onClick","onChange","onSubmit","onEnter","onLeave","onDragStart","onDrag","onDragEnd","onDragCancel","onPointerDown","onPointerMove","onPointerUp","onWheel","onKeyDown"] and node[^1].kind==nnkStmtList

proc lower(node,ctx:NimNode,slots:Bindings,shadow:HashSet[string],event:bool,insideCanvas=false):NimNode=
  let insideCanvas = insideCanvas or (node.kind in {nnkCall,nnkCommand} and node.len > 1 and node[0].eqIdent("canvas"))
  if node.kind in {nnkCall,nnkCommand} and node.len>0 and
      node[0].kind==nnkDotExpr and node[0][0].stateName(slots,shadow) and
      node[0][0].spelling in slots.animations and node[0][1].named and
      node[0][1].strVal in ["play","pause","restart","reset","seek"]:
    if not event:error("animation controls require an event handler",node)
    let operation=case node[0][1].strVal
      of "play":bindSym"play"
      of "pause":bindSym"pause"
      of "restart":bindSym"restart"
      of "reset":bindSym"reset"
      else:bindSym"seek"
    result=newCall(operation,slots[node[0][0].spelling])
    for i in 1..<node.len:result.add(lower(node[i],ctx,slots,shadow,event,insideCanvas))
    result.copyLineInfo(node)
    return
  if node.stateName(slots,shadow):
    if node.spelling in slots.props: return slots[node.spelling]
    if event:return newCall(bindSym"readDraft",slots[node.spelling])
    let sample=newCall(bindSym"value",ctx,slots[node.spelling])
    if insideCanvas and node.spelling in slots.animations:
      return newCall(bindSym"canvasTweenValueInternal",sample)
    return sample
  if not event and not insideCanvas and node.kind in {nnkCall, nnkCommand} and
      node.len >= 3 and node[0].eqIdent("button") and node[^1].kind == nnkStmtList:
    var properties, actions = newStmtList()
    var legacyClick = false
    for item in node[^1]:
      if item.kind == nnkCommentStmt: continue
      if item.property or (item.kind in {nnkCommand, nnkCall} and item.len == 2 and
          item[0].named and item[0].strVal in LayoutProperties and item[^1].kind == nnkStmtList):
        properties.add(item)
        legacyClick = legacyClick or item[0].eqIdent("onClick")
      else: actions.add(item)
    if actions.len > 0:
      for i in 1..<node.len-1:
        if node[i].kind == nnkExprEqExpr and node[i][0].eqIdent("onClick"): legacyClick = true
      if legacyClick: error("use a button action block or onClick, not both", node)
      properties.add(newCall(ident"onClick", actions))
      let button = node.copyNimTree()
      button[^1] = properties
      return lower(button, ctx, slots, shadow, false)
  if node.eventProperty:
    if event:error("event declarations belong in view, not inside handlers",node)
    if node.len notin {2,3}:error("an event takes an optional event parameter",node)
    let parameter=if node.len==3:node[1] else:genSym(nskParam,"event")
    if not parameter.named:error("event parameter must be an identifier",parameter)
    var nested=shadow.scoped
    nested.incl(parameter.spelling)
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
    if node[0].spelling in slots.props:error("prop is read-only",node)
    if node[0].spelling in slots.animations:error("animation bindings are read-only; use controls",node)
    if not event:error("managed variables can only be assigned in event handlers",node)
    result=newCall(bindSym"writeDraft",slots[node[0].spelling],lower(node[1],ctx,slots,shadow,true,insideCanvas))
    result.copyLineInfo(node)
    return
  if node.kind==nnkInfix and node.len==3 and node[0].strVal in ["+=","-=","*=","/=","&="] and
      node[1].stateName(slots,shadow):
    if node[1].spelling in slots.props:error("prop is read-only",node)
    if node[1].spelling in slots.animations:error("animation bindings are read-only; use controls",node)
    if not event:error("managed variables can only be assigned in event handlers",node)
    let operation=node[0].strVal[0..^2]
    let expression=newTree(nnkInfix,ident(operation),lower(node[1],ctx,slots,shadow,true,insideCanvas),lower(node[2],ctx,slots,shadow,true,insideCanvas))
    result=newCall(bindSym"writeDraft",slots[node[1].spelling],expression)
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
  of nnkBlockStmt, nnkBlockExpr:
    # A block label is a declaration and may share a spelling with a binding.
    result[^1]=lower(node[^1],ctx,slots,shadow,event,insideCanvas)
  of nnkBreakStmt, nnkContinueStmt:
    discard
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
    let signature = if not event and not insideCanvas: modelSignatureName(node[0]) else: nil
    for i,child in node:
      # The callee and argument labels are not value references.
      if i == 0 and not event and node[^1].kind == nnkStmtList: continue
      let argument = if child.kind == nnkExprEqExpr: child[1] else: child
      if i > 0 and signature != nil and argument.stateName(slots,shadow) and
          argument.spelling notin slots.props and argument.spelling notin slots.animations:
        let label = if child.kind == nnkExprEqExpr: child[0].spelling else: ""
        let sample = lower(argument,ctx,slots,shadow,false)
        let binding = newCall(bindSym"modelArgumentInternal",signature,newLit(i-1),
          newLit(label),slots[argument.spelling],sample)
        binding.copyLineInfo(argument)
        if child.kind == nnkExprEqExpr: result[i][1] = binding
        else: result[i] = binding
      else:
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

proc parseParameter(section: NimNode): Parameter =
  if section.len != 3 or not section[1].named or section[^1].kind != nnkStmtList or section[^1].len != 1:
    error("use model name: Type or prop name: Type = defaultValue", section)
  result.name = section[1]
  result.model = section[0].eqIdent("model")
  result.typ = section[^1][0]
  result.fallback = newEmptyNode()
  if result.typ.kind == nnkAsgn:
    if result.model: error("model parameters cannot have defaults", section)
    result.fallback = result.typ[1]
    result.typ = result.typ[0]
  if result.name.eqIdent("key"): error("key is reserved for component identity", section)

proc publicName(name: NimNode): NimNode = newTree(nnkPostfix, ident"*", name)

proc parameterType(param: Parameter): NimNode =
  if param.model: newTree(nnkBracketExpr, bindSym"ModelBindingInternal", param.typ)
  else: param.typ

proc instanceFormals(parameters: seq[Parameter], returns: NimNode): seq[NimNode] =
  result = @[returns]
  for param in parameters:
    result.add(newIdentDefs(param.name, param.parameterType, param.fallback))
  result.add(newIdentDefs(ident"key", bindSym"string", newLit("")))

proc modelSignature(name: NimNode, parameters: seq[Parameter], exported: bool): NimNode =
  let signature = modelSignatureName(name)
  let declaration = if exported: publicName(signature) else: signature
  var names = newTree(nnkBracket)
  for param in parameters:
    names.add(newLit(if param.model: param.name.spelling else: ""))
  newProc(declaration, @[ident"untyped"], newStmtList(names), nnkTemplateDef)

proc instanceFactory(name, definition: NimNode, parameters: seq[Parameter],
    exported: bool, declareSignature: bool): NimNode =
  var values = newTree(nnkTupleConstr)
  for param in parameters:
    values.add(newTree(nnkExprColonExpr, param.name, param.name))
  let callable = if exported: publicName(name) else: name
  result = newStmtList()
  if declareSignature:
    result.add(modelSignature(name, parameters, exported))
  result.add(newProc(callable, instanceFormals(parameters, bindSym"UiDescription"),
    newStmtList(newCall(bindSym"componentInstanceInternal", definition, values, ident"key"))))

proc instanceName(name: NimNode): NimNode =
  ident(name.strVal[0].toLowerAscii & name.strVal[1..^1])

proc componentDeclaration(declaration, body: NimNode, inherited: seq[Parameter] = @[],
    callName: NimNode = nil, exportImplementation = false): NimNode =
  var name=declaration
  var props=genSym(nskParam,"props")
  var propsType:NimNode=newTree(nnkTupleTy)
  if declaration.kind in {nnkCall,nnkCommand,nnkObjConstr}:
    if declaration.len!=2 or declaration[1].kind!=nnkExprColonExpr:
      error("component declaration takes one typed props parameter",declaration)
    name=declaration[0]
    props=declaration[1][0]
    propsType=declaration[1][1]
  var exported = false
  if name.kind == nnkPostfix and name[0].eqIdent("*"):
    exported = true
    name = name[1]
  if name.kind!=nnkIdent:error("component name must be an identifier",name)
  var parameters = inherited
  var seen: HashSet[string]
  for param in parameters: seen.incl(param.name.spelling)
  var states:seq[NimNode]
  var animationNames:HashSet[string]
  var view:NimNode
  for section in body:
    if section.kind==nnkCommentStmt:continue
    if section.kind in {nnkCall, nnkCommand} and section.len > 0 and
        (section[0].eqIdent("model") or section[0].eqIdent("prop")):
      if inherited.len > 0 or callName != nil:
        error("parameters of an implementation are declared by its contract", section)
      if declaration.kind in {nnkCall, nnkCommand, nnkObjConstr}:
        error("use either typed props or model/prop declarations, not both", section)
      let param = parseParameter(section)
      if param.name.spelling in seen: error("duplicate component binding", param.name)
      seen.incl(param.name.spelling)
      parameters.add(param)
      continue
    if section.kind notin {nnkCall,nnkCommand} or section.len!=2 or section[^1].kind!=nnkStmtList:
      error("component contains model, prop, state:, animation: and view: declarations",section)
    if section[0].eqIdent("state") or section[0].eqIdent("animation"):
      for entry in section[^1]:
        if entry.kind==nnkCommentStmt:continue
        if entry.kind!=nnkAsgn or entry[0].kind!=nnkIdent:
          error("state declarations use name = initialValue",entry)
        states.add(entry)
        if section[0].eqIdent("animation"):animationNames.incl(entry[0].spelling)
    elif section[0].eqIdent("view"):
      if view!=nil:error("component needs exactly one view",section)
      view=section[^1]
    else:error("unsupported component section: " & section[0].repr,section)
  if view==nil:error("component needs a view section",body)
  for entry in states:
    if entry[0].spelling in seen: error("duplicate component binding", entry)
    seen.incl(entry[0].spelling)
  if parameters.len > 0:
    propsType = newTree(nnkTupleTy)
    for param in parameters:
      propsType.add(newIdentDefs(param.name, param.parameterType))
  let initProps = if props.kind == nnkSym: genSym(nskParam,"mountProps") else: props
  let init=genSym(nskProc,"initialize")
  let initCtx=genSym(nskParam,"mount")
  let renderCtx=genSym(nskParam,"render")
  let model=genSym(nskParam,"model")
  let modelType=genSym(nskType,"Model")
  var initBody=newStmtList()
  var tupleValue=newTree(nnkTupleConstr)
  var slots,initSlots:Bindings
  var finishSetups:seq[(NimNode,NimNode)]
  for param in parameters:
    let access = newDotExpr(props, param.name)
    let initialAccess = newDotExpr(initProps, param.name)
    slots[param.name.spelling] = if param.model: newDotExpr(access, ident"slot") else: access
    initSlots[param.name.spelling] = if param.model: newDotExpr(initialAccess, ident"slot") else: initialAccess
    if param.model:
      initBody.add(newLetStmt(param.name, newDotExpr(initialAccess, ident"sample")))
    else:
      slots.props.incl(param.name.spelling)
      initSlots.props.incl(param.name.spelling)
      initBody.add(newLetStmt(param.name, initialAccess))
  for i,entry in states:
    let field=ident("slot" & $i)
    let slot=genSym(nskLet,"state")
    if entry[0].spelling in animationNames:
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
      slots.animations.incl(entry[0].spelling)
      initSlots.animations.incl(entry[0].spelling)
    else:
      initBody.add(newLetStmt(entry[0],entry[1]))
      initBody.add(newLetStmt(slot,newCall(bindSym"managedStateInternal",initCtx,entry[0])))
    tupleValue.add(newTree(nnkExprColonExpr,field,slot))
    slots[entry[0].spelling]=newTree(nnkDotExpr,model,field)
    initSlots[entry[0].spelling]=slot
  for setup in finishSetups:
    let callback=lower(setup[1],initCtx,initSlots,initHashSet[string](),true)
    initBody.add(newCall(bindSym"setAnimationFinishInternal",initCtx,setup[0],callback))
  if states.len==0:tupleValue.add(newTree(nnkExprColonExpr,ident"unit",newLit(0)))
  initBody.add(tupleValue)
  let initializer=newProc(init,params= @[ident"auto",newIdentDefs(initCtx,bindSym"MountContext"),newIdentDefs(initProps,propsType)],body=initBody)
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
  let definition = if callName != nil: genSym(nskLet, name.strVal)
    elif exported: publicName(name)
    else: name
  let identity = if callName == nil: name.strVal else: callName.strVal
  result=newStmtList(initializer,newTree(nnkTypeSection,newTree(nnkTypeDef,modelType,newEmptyNode(),modelExpr)),
    newLetStmt(definition,newCall(factory,newLit(identity),init,renderer)))
  if callName != nil or parameters.len > 0:
    let callable = if callName != nil: callName
      else: instanceName(name)
    result.add(instanceFactory(callable,if callName != nil: definition else: name,
      parameters, exported or exportImplementation, declareSignature = callName == nil))
  result.copyLineInfo(declaration)

macro component*(declaration:untyped,arguments:varargs[untyped]):untyped=
  # Keep the existing typed instance constructor as well as declarations.
  if arguments.len == 2 and arguments[0].eqIdent("exported") and arguments[1].kind == nnkStmtList:
    return componentDeclaration(publicName(declaration), arguments[1])
  if arguments.len!=1 or arguments[0].kind!=nnkStmtList:
    result=newCall(bindSym"componentInstanceInternal",declaration)
    for argument in arguments:result.add(argument)
  else:
    result = componentDeclaration(declaration, arguments[0])

const declarationPlatform =
  when defined(leafHeadlessOnly): "headless"
  elif defined(android): "android"
  elif defined(windows): "windows"
  elif defined(ios): "ios"
  elif defined(macosx): "macos"
  elif defined(linux): "linux"
  else: "unknown"

proc implementationName(name, target: string): NimNode =
  ident("leafImpl_" & nimIdentNormalize(name) & "_" & target)

macro implementInternal(name: static[string], specification, platform,
    exported, body: untyped): untyped =
  let target = platform.strVal
  if target notin ["shared", "headless", "windows", "android", "linux", "macos", "ios"]:
    error("unknown implementation platform: " & target, platform)
  if target != "shared" and target != declarationPlatform:
    return newStmtList()
  var parameters: seq[Parameter]
  for param in specification:
    parameters.add(Parameter(name: ident(param[1].strVal), typ: param[2],
      model: param[0].eqIdent("model"),
      fallback: if param.len == 4: param[3] else: newEmptyNode()))
  componentDeclaration(ident(name), body, parameters, implementationName(name, target),
    exported.eqIdent("true"))

macro contract*(declaration: untyped, arguments: varargs[untyped]): untyped =
  let exported = arguments.len == 2 and arguments[0].eqIdent("exported")
  if not declaration.named or arguments.len != (if exported: 2 else: 1) or
      arguments[^1].kind != nnkStmtList:
    error("use contract Name: or contract Name, exported:", declaration)
  var parameters: seq[Parameter]
  var seen: HashSet[string]
  let specification = newTree(nnkTupleConstr)
  for section in arguments[^1]:
    if section.kind == nnkCommentStmt: continue
    if section.kind notin {nnkCall, nnkCommand} or section.len < 2 or
        not (section[0].eqIdent("model") or section[0].eqIdent("prop")):
      error("a contract declares only model and prop parameters", section)
    let param = parseParameter(section)
    if param.name.spelling in seen: error("duplicate contract binding", section)
    seen.incl(param.name.spelling)
    parameters.add(param)
    let entry = newCall(section[0], param.name, param.typ)
    if param.fallback.kind != nnkEmpty: entry.add(param.fallback)
    specification.add(entry)
  let platform = genSym(nskParam, "platform")
  let body = genSym(nskParam, "body")
  let definition = if exported: publicName(declaration) else: declaration
  let spec = newProc(definition,
    @[ident"untyped", newIdentDefs(platform, ident"untyped"), newIdentDefs(body, ident"untyped")],
    newStmtList(newCall(bindSym"implementInternal", newLit(declaration.strVal), specification,
      platform, ident($exported), body)), nnkTemplateDef)

  let override = implementationName(declaration.strVal, declarationPlatform)
  let shared = implementationName(declaration.strVal, "shared")
  let overrideCall = newCall(override)
  let sharedCall = newCall(shared)
  for param in parameters:
    overrideCall.add(param.name)
    sharedCall.add(param.name)
  overrideCall.add(ident"key")
  sharedCall.add(ident"key")
  let diagnostic = newLit("no implementation of Leaf contract " & declaration.strVal &
    " for " & declarationPlatform & " (import a platform or shared implementation)")
  let choices = quote do:
    when declared(`override`):
      `overrideCall`
    elif declared(`shared`):
      `sharedCall`
    else:
      {.error: `diagnostic`.}
  # Look up implementations in the consuming module without a mutable registry
  # or a platform-dependent branch in the running application.
  let dispatch = newStmtList(newTree(nnkMixinStmt, override, shared), choices)
  let name = instanceName(declaration)
  result = newStmtList(spec, modelSignature(name, parameters, exported),
    newProc(if exported: publicName(name) else: name,
      instanceFormals(parameters, bindSym"UiDescription"), dispatch, nnkTemplateDef))

macro implement*(declaration: untyped, arguments: varargs[untyped]): untyped =
  let target = if arguments.len == 1: ident"shared"
    elif arguments.len == 2 and arguments[0].kind == nnkExprEqExpr and
        arguments[0][0].eqIdent("platform") and arguments[0][1].named: arguments[0][1]
    else: error("use implement Name: or implement Name, platform = target:", declaration); nil
  if arguments[^1].kind != nnkStmtList: error("an implementation requires a body", declaration)
  newCall(declaration, target, arguments[^1])
