## Canvas blocks build one immutable typed frame with ordinary Nim control flow.
import std/[macros, tables, options, sugar, sets]
import ./[core, widgets, graphics, canvas_events, animation]

proc canvasTextInternal(value: string): string = value
proc canvasTextInternal[T: SomeInteger|SomeFloat](value: T): string = $value
proc optionalColorInternal(value: Color): Option[Color] = some(color(value))
proc optionalColorInternal(value: string): Option[Color] = some(color(value))
proc optionalColorInternal(value: Option[Color]): Option[Color] =
  if value.isSome: discard color(value.get)
  value
proc requiredColorInternal(value: Option[Color]): Color =
  if value.isNone: raise newException(GraphicsError, "this primitive requires a color")
  value.get

type Properties = Table[string, NimNode]
var canvasLoopDepth {.compileTime.}: int
var canvasLoopNames {.compileTime.}: seq[NimNode]
const EventNames = ["onEnter", "onLeave", "onClick", "onDragStart", "onDrag", "onDragEnd", "onDragCancel",
  "onPointerDown", "onPointerMove", "onPointerUp", "onWheel", "onKeyDown"]
proc property(node: NimNode): bool =
  node.kind in {nnkCall, nnkCommand} and node.len == 2 and
    node[0].kind == nnkIdent and node[1].kind == nnkStmtList
proc split(body: NimNode, allowed: openArray[string], properties: var Properties): NimNode =
  result = newStmtList()
  for statement in body:
    if statement.kind == nnkCommentStmt: continue
    if statement.property and statement[0].strVal in allowed:
      let name = statement[0].strVal
      if name in properties: error("duplicate Canvas property: " & name, statement)
      if statement[1].len != 1: error("Canvas property needs one value", statement)
      properties[name] = statement[1][0]
    else: result.add(statement)
proc required(properties: Properties, name: string, at: NimNode): NimNode =
  if name notin properties: error("missing Canvas property: " & name, at)
  properties[name]
proc value(properties: Properties, name: string, fallback: NimNode): NimNode =
  properties.getOrDefault(name, fallback)
proc colorExpression(expression: NimNode): NimNode =
  if expression.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    try: discard color(expression.strVal)
    except GraphicsError as failure: error(failure.msg, expression)
  newCall(bindSym"optionalColorInternal", expression)
proc paintExpression(properties: Properties, filled: bool): NimNode =
  let fill = if "fill" in properties: colorExpression(properties["fill"])
    elif filled: newCall(bindSym"some", bindSym"CanvasForeground")
    else: newCall(newTree(nnkBracketExpr, bindSym"none", bindSym"Color"))
  let stroke = if "stroke" in properties: colorExpression(properties["stroke"])
    else: newCall(newTree(nnkBracketExpr, bindSym"none", bindSym"Color"))
  newCall(bindSym"paint", fill, stroke, newCall(bindSym"float64", properties.value("strokeWidth", newLit(1.0))))
proc empty(body: NimNode) =
  if body.len != 0: error("unknown property or nested primitive: " & body[0].repr, body[0])

proc pathStatements(body, builder: NimNode): NimNode
proc drawStatements(body, builder: NimNode): NimNode
proc loopNames(node: NimNode): seq[NimNode] =
  if node.kind == nnkIdent and not node.eqIdent("_"): result.add(node)
  else:
    for child in node: result.add(loopNames(child))
var canvasDrivenAliases {.compileTime.}:HashSet[string]
proc control(statement, builder: NimNode, expand: proc(body,builder:NimNode):NimNode): NimNode =
  result = statement.copyNimTree()
  let outerAliases=canvasDrivenAliases
  case statement.kind
  of nnkForStmt, nnkWhileStmt, nnkBlockStmt:
    let loop = statement.kind in {nnkForStmt, nnkWhileStmt}
    let oldNames = canvasLoopNames.len
    if loop: inc canvasLoopDepth
    if statement.kind == nnkForStmt:
      for i in 0..<statement.len-2:
        for name in loopNames(statement[i]):
          canvasLoopNames.add(name)
          canvasDrivenAliases.excl(name.strVal)
    result[^1] = expand(statement[^1], builder)
    canvasLoopNames.setLen(oldNames)
    if loop: dec canvasLoopDepth
  of nnkIfStmt, nnkWhenStmt, nnkCaseStmt:
    for i, branch in statement:
      if branch.kind in {nnkElifBranch, nnkElse, nnkOfBranch}:
        canvasDrivenAliases=outerAliases
        result[i][^1] = expand(branch[^1], builder)
  else: discard
  canvasDrivenAliases=outerAliases
proc pathStatements(body, builder: NimNode): NimNode =
  result = newStmtList()
  for statement in body:
    if statement.kind in {nnkForStmt, nnkWhileStmt, nnkBlockStmt, nnkIfStmt, nnkWhenStmt, nnkCaseStmt}:
      result.add(control(statement, builder, pathStatements))
    elif statement.kind == nnkIdent and statement.eqIdent("closePath"):
      result.add(newCall(bindSym"closePath", builder))
    elif statement.kind in {nnkCall, nnkCommand} and statement[0].kind == nnkIdent:
      let name = statement[0].strVal
      case name
      of "moveTo", "lineTo":
        if statement.len != 2: error(name & " takes one point", statement)
        let operation = if name == "moveTo": bindSym"moveTo" else: bindSym"lineTo"
        result.add(newCall(operation, builder, newCall(bindSym"point", statement[1])))
      of "curveTo":
        if statement.len != 4: error("curveTo takes two control points and an endpoint", statement)
        let call = newCall(bindSym"curveTo", builder)
        for i in 1..3: call.add(newCall(bindSym"point", statement[i]))
        result.add(call)
      of "closePath":
        if statement.len != 1: error("closePath takes no arguments", statement)
        result.add(newCall(bindSym"closePath", builder))
      else: error("unknown path command: " & name, statement)
    elif statement.kind in {nnkLetSection, nnkVarSection, nnkConstSection, nnkCommentStmt,
        nnkAsgn, nnkDiscardStmt, nnkBreakStmt, nnkContinueStmt, nnkRaiseStmt}:
      result.add(statement)
    else: error("expected a path command or ordinary Nim control flow", statement)
proc eventParts(body: NimNode, handlers: var Properties): NimNode =
  result = newStmtList()
  for statement in body:
    if statement.kind in {nnkCall, nnkCommand} and statement.len >= 2 and
        statement[0].kind == nnkIdent and statement[0].strVal in EventNames and statement[^1].kind == nnkStmtList:
      let name = statement[0].strVal
      if name in handlers: error("duplicate Canvas event: " & name, statement)
      if statement.len notin {2, 3}: error("Canvas event takes one optional parameter", statement)
      let content = statement[^1]
      if content.len == 1 and content[0].kind in {nnkLambda, nnkDo}:
        handlers[name] = content[0]
      else:
        let parameter = if statement.len == 3: statement[1] else: genSym(nskParam, "event")
        if parameter.kind notin {nnkIdent, nnkSym}: error("event parameter must be an identifier", parameter)
        handlers[name] = newProc(params = @[newEmptyNode(), newIdentDefs(parameter, bindSym"CanvasPointerEvent")],
          body = content, procType = nnkLambda)
    else: result.add(statement)
proc hasEvents(node: NimNode): bool =
  if node.kind in {nnkCall, nnkCommand} and node.len > 1 and node[0].kind == nnkIdent and
      node[0].strVal in EventNames and node[^1].kind == nnkStmtList: return true
  for child in node:
    if hasEvents(child): return true
proc registerEvents(builder, element: NimNode, handlers: Properties, hitTest: NimNode): NimNode =
  result = newStmtList()
  var mask = 0'u32
  for index, name in EventNames:
    if name in handlers: mask = mask or (1'u32 shl index)
  result.add(newCall(bindSym"registerElementInternal", builder, element, newLit(mask), hitTest))
  for index, name in EventNames:
    if name in handlers:
      let registration = newCall(bindSym"handlerInternal", builder, element,
        newCall(bindSym"PointerEventKind", newLit(index)), handlers[name])
      if canvasLoopNames.len == 0: result.add(registration)
      else:
        let captureCall = newCall(bindSym"capture")
        var captured: seq[string]
        for variable in canvasLoopNames:
          if variable.strVal notin captured:
            captured.add(variable.strVal)
            captureCall.add(variable)
        captureCall.add(newStmtList(registration))
        result.add(captureCall)
proc tweenDriven(node:NimNode):bool=
  if node.kind in {nnkIdent,nnkSym} and node.strVal in canvasDrivenAliases:return true
  if node.kind in {nnkCall,nnkCommand} and node.len>0 and node[0].eqIdent("canvasTweenValueInternal"):return true
  for child in node:
    if tweenDriven(child):return true
proc transitionRegistration(context,element,spec:NimNode,name:string,values:Properties):NimNode=
  if spec==nil:return newStmtList()
  var settings:Properties
  split(spec,["properties","duration","easing"],settings).empty()
  let kind=case name
    of "rect":DrawKind.rectangle
    of "circle":DrawKind.circle
    of "line":DrawKind.line
    of "path":DrawKind.path
    of "text":DrawKind.text
    else:DrawKind.beginGroup
  var selected=supportedCanvasPropertiesInternal(kind)
  if "properties" in settings:
    let list=settings["properties"]
    if list.kind!=nnkBracket:error("transition properties must be a literal list",list)
    selected={}
    for entry in list:
      var found=false
      for property in supportedCanvasPropertiesInternal(kind):
        if entry.kind in {nnkIdent,nnkSym} and entry.eqIdent($property):
          if property in selected:error("duplicate transition property",entry)
          selected.incl(property);found=true
      if not found:error("unsupported transition property for " & name,entry)
  var mask=newNimNode(nnkCurly)
  for property in selected:
    if $property in values and tweenDriven(values[$property]):
      error("a Canvas property cannot be driven by both tween and transition",values[$property])
    mask.add(newDotExpr(bindSym"CanvasProperty",ident($property)))
  newCall(bindSym"transitionInternal",context,element,mask,
    settings.value("duration",newCall(bindSym"ms",newLit(180))),settings.value("easing",bindSym"easeOut"))
proc primitive(node, context: NimNode): NimNode =
  let builder = newCall(bindSym"frameBuilderInternal", context)
  let name = node[0].strVal
  let originalBody = if node[^1].kind == nnkStmtList: node[^1] else: newStmtList()
  var handlers, identityProperties: Properties
  let eventless = eventParts(originalBody, handlers)
  var withoutEvents=newStmtList()
  var transition:NimNode
  for statement in eventless:
    if statement.property and statement[0].eqIdent("transition"):
      if transition!=nil:error("duplicate Canvas transition",statement)
      transition=statement[1]
    else:withoutEvents.add(statement)
  for name in ["onPointerDown", "onPointerMove", "onPointerUp", "onWheel", "onKeyDown"]:
    if name in handlers: error(name & " belongs on the Canvas, not a primitive", node)
  let body = split(withoutEvents, ["key", "hitTest"], identityProperties)
  let interactive = hasEvents(originalBody) or transition!=nil
  if canvasLoopDepth > 0 and interactive and "key" notin identityProperties:
    error("interactive or transitioning Canvas loop entries need a stable key", node)
  let element = genSym(nskLet, "element")
  let identity = newCall(bindSym"elementInternal", context, newLit(node.lineInfo),
    newCall(bindSym"canvasKeyInternal", identityProperties.value("key", newLit(""))),
    newLit("key" in identityProperties), newLit(interactive))
  let positional = node.len - 1 - (if node[^1].kind == nnkStmtList: 1 else: 0)
  if positional != (if name == "text": 1 else: 0): error("unexpected Canvas primitive arguments", node)
  var properties: Properties
  var registration:NimNode
  case name
  of "rect":
    split(body, ["position", "size", "radius", "fill", "stroke", "strokeWidth"], properties).empty()
    result = newCall(bindSym"addRect", builder,
      newCall(bindSym"point", properties.required("position", node)),
      newCall(bindSym"point", properties.required("size", node)),
      newCall(bindSym"float64", properties.value("radius", newLit(0.0))), paintExpression(properties, true))
  of "circle":
    split(body, ["center", "radius", "fill", "stroke", "strokeWidth"], properties).empty()
    result = newCall(bindSym"addCircle", builder,
      newCall(bindSym"point", properties.required("center", node)),
      newCall(bindSym"float64", properties.required("radius", node)), paintExpression(properties, true))
  of "line":
    split(body, ["start", "finish", "stroke", "strokeWidth"], properties).empty()
    result = newCall(bindSym"addLine", builder,
      newCall(bindSym"point", properties.required("start", node)),
      newCall(bindSym"point", properties.required("finish", node)),
      newCall(bindSym"requiredColorInternal", colorExpression(properties.required("stroke", node))),
      newCall(bindSym"float64", properties.value("strokeWidth", newLit(1.0))))
  of "text":
    split(body, ["position", "size", "fill", "font"], properties).empty()
    let fill = colorExpression(properties.value("fill", bindSym"CanvasForeground"))
    result = newCall(bindSym"addText", builder, newCall(bindSym"canvasTextInternal", node[1]),
      newCall(bindSym"point", properties.required("position", node)),
      newCall(bindSym"float64", properties.value("size", newLit(16.0))),
      newCall(bindSym"requiredColorInternal", fill), properties.value("font", newLit("Segoe UI")))
  of "path":
    let commands = split(body, ["fill", "stroke", "strokeWidth", "fillRule", "geometry"], properties)
    if "fill" notin properties and "stroke" notin properties: error("path needs fill or stroke", node)
    if "geometry" in properties:
      if commands.len != 0 or "fillRule" in properties:
        error("sealed geometry cannot be combined with path commands or fillRule", node)
      result = newCall(bindSym"addPath", builder, properties["geometry"], paintExpression(properties, false))
    else:
      let path = genSym(nskLet, "path")
      let rule = properties.value("fillRule", newDotExpr(bindSym"FillRule", ident"nonZero"))
      result = newStmtList(newLetStmt(path, newCall(bindSym"newPathBuilder", rule)))
      result.add(pathStatements(commands, path))
      result.add(newCall(bindSym"addPath", builder, newCall(bindSym"finishPath", path), paintExpression(properties, false)))
      result = newBlockStmt(result)
  of "group":
    let commands = split(body, ["translate", "rotate", "scale", "clip"], properties)
    registration=transitionRegistration(context,element,transition,name,properties)
    let translation=genSym(nskLet,"translation")
    let rotation=genSym(nskLet,"rotation")
    let scaling=genSym(nskLet,"scaling")
    let initial=newStmtList(
      newLetStmt(translation,newCall(bindSym"point",properties.value("translate",newCall(bindSym"vec2",newLit(0),newLit(0))))),
      newLetStmt(rotation,properties.value("rotate",newCall(bindSym"deg",newLit(0)))),
      newLetStmt(scaling,newCall(bindSym"point",properties.value("scale",newCall(bindSym"vec2",newLit(1),newLit(1))))))
    if transition!=nil:
      registration.add(translation);registration.add(rotation);registration.add(scaling)
    let matrix=newCall(bindSym"groupTransform",translation,rotation,scaling)
    let clip = if "clip" in properties: newCall(bindSym"some", newCall(bindSym"rectangle", properties["clip"]))
      else: newCall(newTree(nnkBracketExpr, bindSym"none", bindSym"CanvasRect"))
    result = newStmtList(initial,newCall(bindSym"beginGroup", builder, matrix, clip),registration)
    let oldDepth = canvasLoopDepth
    if "key" in identityProperties: canvasLoopDepth = 0
    let children = drawStatements(commands, context)
    canvasLoopDepth = oldDepth
    result.add(registerEvents(context, element, handlers, identityProperties.value("hitTest", newLit(true))))
    result.add(newCall(bindSym"pushScopeInternal", context, element))
    result.add(newTree(nnkTryStmt, children,
      newTree(nnkFinally, newStmtList(newCall(bindSym"popScopeInternal", context), newCall(bindSym"endGroup", builder)))))
  else: error("unknown Canvas primitive: " & name, node)
  if name != "group":
    registration=transitionRegistration(context,element,transition,name,properties)
    result = newStmtList(result, registration, registerEvents(context, element, handlers, identityProperties.value("hitTest", newLit(true))))
  result = newStmtList(newLetStmt(element, identity), result)
  result.copyLineInfo(node)
proc drawStatements(body, builder: NimNode): NimNode =
  result = newStmtList()
  for statement in body:
    case statement.kind
    of nnkForStmt, nnkWhileStmt, nnkBlockStmt, nnkIfStmt, nnkWhenStmt, nnkCaseStmt:
      result.add(control(statement, builder, drawStatements))
    of nnkCall, nnkCommand:
      if statement[0].kind != nnkIdent: error("expected Canvas primitive", statement)
      result.add(primitive(statement, builder))
    of nnkLetSection, nnkVarSection, nnkConstSection, nnkCommentStmt,
        nnkAsgn, nnkDiscardStmt, nnkBreakStmt, nnkContinueStmt, nnkRaiseStmt:
      if statement.kind in {nnkLetSection,nnkVarSection,nnkConstSection}:
        for definition in statement:
          let driven=tweenDriven(definition[^1])
          for i in 0..<definition.len-2:
            if definition[i].kind in {nnkIdent,nnkSym}:
              canvasDrivenAliases.excl(definition[i].strVal)
              if driven:canvasDrivenAliases.incl(definition[i].strVal)
      elif statement.kind==nnkAsgn and tweenDriven(statement[1]) and statement[0].kind in {nnkIdent,nnkSym}:
        canvasDrivenAliases.incl(statement[0].strVal)
      result.add(statement)
    else: error("expected Canvas primitive or ordinary Nim control flow", statement)

macro canvas*(body: untyped): untyped =
  canvasLoopDepth = 0
  canvasDrivenAliases.clear()
  canvasLoopNames.setLen(0)
  body.expectKind(nnkStmtList)
  var properties: Properties
  var handlers: Properties
  let content = split(eventParts(body, handlers), ["key", "width", "height", "viewBox", "background", "focusable", "accessibleLabel"], properties)
  let viewBox = if "viewBox" in properties: newCall(bindSym"some", newCall(bindSym"point", properties["viewBox"]))
    else: newCall(newTree(nnkBracketExpr, bindSym"none", bindSym"Vec2"))
  let background = properties.value("background", bindSym"CanvasBackground")
  if background.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}: discard colorExpression(background)
  let builder = genSym(nskLet, "canvas")
  result = newStmtList(newLetStmt(builder, newCall(bindSym"newCanvasDslBuilderInternal", viewBox, newCall(bindSym"color", background))))
  result.add(registerEvents(builder, newCall(bindSym"rootElementInternal"), handlers, newLit(true)))
  result.add(drawStatements(content, builder))
  let width = properties.value("width", newLit("full"))
  let widthValue = if width.eqIdent("fill"): newLit("full") else: newCall(bindSym"$", width)
  var styles = newTree(nnkTableConstr, newTree(nnkExprColonExpr, newLit("width"), widthValue))
  if "height" in properties:
    styles.add(newTree(nnkExprColonExpr, newLit("height"), newCall(bindSym"$", properties["height"])))
  result.add(newCall(bindSym"finishCanvasNodeInternal", builder,
    properties.value("key", newLit("")), newCall(bindSym"style", styles),
    properties.value("focusable", newLit(false)), properties.value("accessibleLabel", newLit(""))))
  result = newBlockStmt(result)
  result.copyLineInfo(body)
