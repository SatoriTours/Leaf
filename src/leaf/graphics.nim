## Owned, backend-neutral Canvas values. Builders are mutable only until sealed;
## frames expose no writable command, path, string or collection storage.
import std/[math, options, unicode, strutils, sets]
export options

const
  CanvasEventMask* = (1'u32 shl 12)-1
  MaxCanvasInteractionBindings* = 10_000
  MaxCanvasCommands* = 100_000
  MaxCanvasPathSegments* = 250_000
  MaxCanvasFrameBytes* = 16 * 1024 * 1024
  MaxCanvasDepth* = 64
  MaxCanvasOwnedBytes* = 64 * 1024 * 1024
  MaxCanvasAxisPixels* = 16_384
  MaxCanvasPixels* = 32_000_000

type
  GraphicsError* = object of CatchableError
  Vec2* = object
    x*, y*: float64
  Color* = object
    r*, g*, b*, a*: float32
  Degrees* = distinct float64
  Matrix3x2* = object
    xx*, yx*, xy*, yy*, dx*, dy*: float64
  CanvasRect* = object
    x*, y*, width*, height*: float64
  CanvasRenderer* {.pure.} = enum hardware, software
  FillRule* {.pure.} = enum nonZero, evenOdd
  PathSegmentKind* {.pure.} = enum moveTo, lineTo, curveTo, closePath
  PathSegment* = object
    kind*: PathSegmentKind
    first*, second*, third*: Vec2
  PathData* = object
    owned: PathStorage
  PathStorage = ref object
    data: seq[PathSegment]
    rule: FillRule
  PathBuilder* = ref object
    data: seq[PathSegment]
    rule: FillRule
    open, sealed: bool
  Paint* = object
    fill*, stroke*: Option[Color]
    strokeWidth*: float64
  DrawKind* {.pure.} = enum rectangle, circle, line, path, text, beginGroup, endGroup
  CanvasCommand* = object
    drawing: Paint
    radiusValue: float64
    case drawKind: DrawKind
    of DrawKind.rectangle: rectangleValue: CanvasRect
    of DrawKind.circle: centerValue: Vec2
    of DrawKind.line: startValue, finishValue: Vec2
    of DrawKind.path: pathValue: PathData
    of DrawKind.text:
      textValue, fontValue: string
      originValue: Vec2
      fontSizeValue: float64
    of DrawKind.beginGroup:
      matrixValue: Matrix3x2
      clipValue: Option[CanvasRect]
    of DrawKind.endGroup: discard
  CanvasLimits* = object
    maxCommands*, maxPathSegments*, maxBytes*, maxDepth*: int
  CanvasProperty* {.pure.} = enum position, center, size, radius, fill, stroke, strokeWidth, translate, rotate, scale
  CanvasTransitionDefinition* = object
    commandIndex*: int
    identity*: string
    properties*: set[CanvasProperty]
    durationMs*: float64
    easingId*: int
    translation*, scaling*: Vec2
    rotation*: Degrees
  CanvasInteraction* = object
    commandIndex*: int
    key*, parentIdentity*: string
    eventMask*: uint32
    hitTest*: bool
  CanvasFrame* = object
    owned: CanvasStorage
  CanvasStorage = ref object
    data: seq[CanvasCommand]
    interactions: seq[CanvasInteraction]
    transitions: seq[CanvasTransitionDefinition]
    designSize: Option[Vec2]
    clearColor: Color
    focusEnabled: bool
    bytes, segments: int
  CanvasBuilder* = ref object
    data: seq[CanvasCommand]
    interactions: seq[CanvasInteraction]
    transitions: seq[CanvasTransitionDefinition]
    transitionKeys: HashSet[string]
    designSize: Option[Vec2]
    clearColor: Color
    limits: CanvasLimits
    focusEnabled: bool
    bytes, segments, depth, bindingCount: int
    identityKeys: HashSet[string]
    sealed: bool

const
  CanvasForeground* = Color(r: 0.12, g: 0.14, b: 0.16, a: 1)
  CanvasBackground* = Color(r: 1, g: 1, b: 1, a: 1)
  DefaultCanvasLimits* = CanvasLimits(maxCommands: MaxCanvasCommands,
    maxPathSegments: MaxCanvasPathSegments, maxBytes: MaxCanvasFrameBytes,
    maxDepth: MaxCanvasDepth)

proc graphicsFail(message: string) {.noreturn.} = raise newException(GraphicsError, message)
proc finite(value: float64): bool {.inline.} =
  # Ordered comparisons reject NaN/infinities but retain signed zero and
  # subnormals, without computing a complete FloatClass on every coordinate.
  value > NegInf and value < Inf
proc valid(value: Vec2) =
  if not finite(value.x) or not finite(value.y): graphicsFail("Canvas coordinates must be finite")
proc nonnegative(value: float64) =
  if not finite(value) or value < 0: graphicsFail("Canvas dimensions must be finite and nonnegative")
proc positiveSize(value: Vec2) =
  valid(value)
  if value.x <= 0 or value.y <= 0: graphicsFail("Canvas dimensions must be positive")
proc valid(value: Color) =
  for channel in [value.r, value.g, value.b, value.a]:
    if not finite(channel) or channel < 0 or channel > 1: graphicsFail("Canvas color channel is outside 0..1")
proc valid(value: CanvasRect) =
  valid(Vec2(x: value.x, y: value.y))
  nonnegative(value.width); nonnegative(value.height)
proc valid(value: Matrix3x2) =
  for item in [value.xx, value.yx, value.xy, value.yy, value.dx, value.dy]:
    if not finite(item): graphicsFail("Canvas transform must be finite")
proc valid(value: Paint) =
  if value.fill.isSome: valid(value.fill.get)
  if value.stroke.isSome: valid(value.stroke.get)
  nonnegative(value.strokeWidth)
  if value.fill.isNone and value.stroke.isNone: graphicsFail("a shape needs fill or stroke")

proc vec2*[X, Y: SomeNumber](x: X, y: Y): Vec2 = Vec2(x: float64(x), y: float64(y))
proc point*[X, Y: SomeNumber](value: tuple[x: X, y: Y]): Vec2 = vec2(value.x, value.y)
proc point*(value: Vec2): Vec2 = value
proc `+`*(a, b: Vec2): Vec2 = vec2(a.x + b.x, a.y + b.y)
proc `-`*(a, b: Vec2): Vec2 = vec2(a.x - b.x, a.y - b.y)
proc `*`*(a: Vec2, scale: SomeNumber): Vec2 = vec2(a.x * float64(scale), a.y * float64(scale))
proc `/`*(a: Vec2, scale: SomeNumber): Vec2 = vec2(a.x / float64(scale), a.y / float64(scale))
proc deg*(value: SomeNumber): Degrees = Degrees(value)
proc radians*(value: Degrees): float64 = float64(value) * PI / 180.0
proc color*(value: string): Color =
  if value.len notin [7, 9] or value[0] != '#': graphicsFail("color must be #RRGGBB or #RRGGBBAA")
  for c in value[1..^1]:
    if c notin {'0'..'9', 'A'..'F', 'a'..'f'}: graphicsFail("invalid hexadecimal color")
  result = Color(r: float32(parseHexInt(value[1..2])) / 255,
    g: float32(parseHexInt(value[3..4])) / 255,
    b: float32(parseHexInt(value[5..6])) / 255, a: 1)
  if value.len == 9: result.a = float32(parseHexInt(value[7..8])) / 255
proc color*(value: Color): Color =
  valid(value)
  value
proc rectangle*[X, Y, W, H: SomeNumber](x: X, y: Y, width: W, height: H): CanvasRect =
  result = CanvasRect(x: float64(x), y: float64(y), width: float64(width), height: float64(height))
  valid(result)
proc rectangle*[X, Y, W, H: SomeNumber](value: tuple[x: X, y: Y, width: W, height: H]): CanvasRect =
  rectangle(value.x, value.y, value.width, value.height)
proc rectangle*(value: CanvasRect): CanvasRect =
  valid(value)
  value
proc paint*(fill = some(CanvasForeground), stroke = none(Color), strokeWidth = 1.0): Paint =
  Paint(fill: fill, stroke: stroke, strokeWidth: strokeWidth)
proc identityMatrix*(): Matrix3x2 = Matrix3x2(xx: 1, yy: 1)
proc transformPoint*(matrix: Matrix3x2, value: Vec2): Vec2 =
  vec2(matrix.xx * value.x + matrix.xy * value.y + matrix.dx,
    matrix.yx * value.x + matrix.yy * value.y + matrix.dy)
proc transformVector*(matrix: Matrix3x2, value: Vec2): Vec2 =
  vec2(matrix.xx * value.x + matrix.xy * value.y, matrix.yx * value.x + matrix.yy * value.y)
proc `*`*(a, b: Matrix3x2): Matrix3x2 =
  ## a*b applies b first, then a. This also defines nested group order.
  Matrix3x2(xx: a.xx*b.xx + a.xy*b.yx, xy: a.xx*b.xy + a.xy*b.yy,
    yx: a.yx*b.xx + a.yy*b.yx, yy: a.yx*b.xy + a.yy*b.yy,
    dx: a.xx*b.dx + a.xy*b.dy + a.dx, dy: a.yx*b.dx + a.yy*b.dy + a.dy)
proc inverse*(matrix: Matrix3x2): Option[Matrix3x2] =
  let determinant = matrix.xx*matrix.yy - matrix.xy*matrix.yx
  if determinant == 0 or not finite(determinant): return none(Matrix3x2)
  let value = Matrix3x2(xx: matrix.yy/determinant, xy: -matrix.xy/determinant,
    yx: -matrix.yx/determinant, yy: matrix.xx/determinant,
    dx: (matrix.xy*matrix.dy - matrix.yy*matrix.dx)/determinant,
    dy: (matrix.yx*matrix.dx - matrix.xx*matrix.dy)/determinant)
  for item in [value.xx, value.yx, value.xy, value.yy, value.dx, value.dy]:
    if not finite(item): return none(Matrix3x2)
  some(value)
proc groupTransform*(translate = vec2(0, 0), rotate = 0.deg, scale = vec2(1, 1)): Matrix3x2 =
  valid(translate); valid(scale)
  let angle = rotate.radians
  if not finite(angle): graphicsFail("Canvas angle must be finite")
  result = Matrix3x2(xx: cos(angle)*scale.x, xy: -sin(angle)*scale.y,
    yx: sin(angle)*scale.x, yy: cos(angle)*scale.y, dx: translate.x, dy: translate.y)
  valid(result)
proc canvasTransform*(viewBox: Option[Vec2], viewport: Vec2): Matrix3x2 =
  positiveSize(viewport)
  if viewBox.isNone: return identityMatrix()
  let box = viewBox.get
  positiveSize(box)
  let scale = min(viewport.x/box.x, viewport.y/box.y)
  groupTransform(translate = vec2((viewport.x-box.x*scale)/2, (viewport.y-box.y*scale)/2), scale = vec2(scale, scale))

proc newPathBuilder*(rule = FillRule.nonZero): PathBuilder = PathBuilder(rule: rule)
proc writable(builder: PathBuilder) =
  if builder == nil or builder.sealed: graphicsFail("path builder is sealed or missing")
  if builder.data.len >= MaxCanvasPathSegments: graphicsFail("Canvas path segment quota exceeded")
proc moveTo*(builder: PathBuilder, position: Vec2) =
  builder.writable(); valid(position)
  builder.data.add(PathSegment(kind: PathSegmentKind.moveTo, first: position))
  builder.open = true
proc lineTo*(builder: PathBuilder, position: Vec2) =
  builder.writable(); valid(position)
  if not builder.open: graphicsFail("lineTo requires an open path figure")
  builder.data.add(PathSegment(kind: PathSegmentKind.lineTo, first: position))
proc curveTo*(builder: PathBuilder, first, second, finish: Vec2) =
  builder.writable(); valid(first); valid(second); valid(finish)
  if not builder.open: graphicsFail("curveTo requires an open path figure")
  builder.data.add(PathSegment(kind: PathSegmentKind.curveTo, first: first, second: second, third: finish))
proc closePath*(builder: PathBuilder) =
  builder.writable()
  if not builder.open: graphicsFail("closePath requires an open path figure")
  builder.data.add(PathSegment(kind: PathSegmentKind.closePath))
  builder.open = false
proc finishPath*(builder: PathBuilder): PathData =
  if builder == nil or builder.sealed: graphicsFail("path builder is sealed or missing")
  if builder.data.len == 0: graphicsFail("Canvas path is empty")
  result = PathData(owned: PathStorage(data: move(builder.data), rule: builder.rule))
  builder.sealed = true
proc isNil*(path: PathData): bool = path.owned.isNil
proc fillRule*(path: PathData): FillRule = path.owned.rule
proc segmentCount*(path: PathData): int = (if path.isNil: 0 else: path.owned.data.len)
iterator segments*(path: PathData): PathSegment =
  if not path.isNil:
    for segment in path.owned.data: yield segment
proc `==`*(a, b: PathData): bool =
  if a.isNil or b.isNil: return a.isNil and b.isNil
  a.owned.rule == b.owned.rule and a.owned.data == b.owned.data

proc newCanvasBuilder*(viewBox = none(Vec2), background = CanvasBackground,
    limits = DefaultCanvasLimits): CanvasBuilder =
  if viewBox.isSome: positiveSize(viewBox.get)
  valid(background)
  if limits.maxCommands <= 0 or limits.maxCommands > MaxCanvasCommands or
      limits.maxPathSegments <= 0 or limits.maxPathSegments > MaxCanvasPathSegments or
      limits.maxBytes <= 0 or limits.maxBytes > MaxCanvasFrameBytes or
      limits.maxDepth <= 0 or limits.maxDepth > MaxCanvasDepth:
    graphicsFail("Canvas limits must be positive and cannot exceed framework quotas")
  CanvasBuilder(designSize: viewBox, clearColor: background, limits: limits)
proc writable(builder: CanvasBuilder) =
  if builder == nil or builder.sealed: graphicsFail("Canvas builder is sealed or missing")
proc append(builder: CanvasBuilder, command: sink CanvasCommand, extraBytes = 0, segments = 0, reserve = 0) =
  builder.writable()
  let bytes = sizeof(CanvasCommand) + extraBytes
  # Every open scope reserves its matching end command. finally can close a
  # scope after a quota exception without masking the original error.
  let closing = builder.depth + reserve
  if builder.data.len >= builder.limits.maxCommands - closing: graphicsFail("Canvas command quota exceeded")
  if bytes > builder.limits.maxBytes - builder.bytes - closing*sizeof(CanvasCommand):
    graphicsFail("Canvas owned frame byte quota exceeded")
  if segments > builder.limits.maxPathSegments - builder.segments: graphicsFail("Canvas path segment quota exceeded")
  builder.data.add(command)
  builder.bytes += bytes
  builder.segments += segments
proc addRect*(builder: CanvasBuilder, position, size: Vec2, radius = 0.0, paint = paint()) =
  valid(position); valid(size); nonnegative(size.x); nonnegative(size.y)
  nonnegative(radius); valid(paint)
  builder.append(CanvasCommand(drawKind: DrawKind.rectangle, drawing: paint, radiusValue: radius,
    rectangleValue: rectangle(position.x, position.y, size.x, size.y)))
proc addCircle*(builder: CanvasBuilder, center: Vec2, radius: float64, paint = paint()) =
  valid(center); nonnegative(radius); valid(paint)
  builder.append(CanvasCommand(drawKind: DrawKind.circle, drawing: paint, radiusValue: radius, centerValue: center))
proc addLine*(builder: CanvasBuilder, start, finish: Vec2, stroke: Color, strokeWidth = 1.0) =
  valid(start); valid(finish)
  let drawing = paint(fill = none(Color), stroke = some(stroke), strokeWidth = strokeWidth)
  valid(drawing)
  builder.append(CanvasCommand(drawKind: DrawKind.line, drawing: drawing, startValue: start, finishValue: finish))
proc addPath*(builder: CanvasBuilder, geometry: PathData, paint = paint(fill = none(Color))) =
  if geometry.isNil or geometry.segmentCount == 0: graphicsFail("Canvas path is missing or empty")
  valid(paint)
  builder.append(CanvasCommand(drawKind: DrawKind.path, drawing: paint, pathValue: geometry),
    geometry.segmentCount * sizeof(PathSegment), geometry.segmentCount)
proc addText*(builder: CanvasBuilder, text: string, position: Vec2, size = 16.0,
    fill = CanvasForeground, font = "Segoe UI") =
  valid(position); valid(fill)
  if not finite(size) or size <= 0: graphicsFail("Canvas font size must be finite and positive")
  for value in [text, font]:
    if value.len > 1_048_576 or validateUtf8(value) != -1 or '\0' in value:
      graphicsFail("Canvas text must be bounded, valid UTF-8 without NUL")
  if font.len == 0: graphicsFail("Canvas font family is empty")
  builder.append(CanvasCommand(drawKind: DrawKind.text, drawing: paint(fill = some(fill)),
    textValue: text, fontValue: font, originValue: position, fontSizeValue: size), text.len + font.len)
proc beginGroup*(builder: CanvasBuilder, transform = identityMatrix(), clip = none(CanvasRect)) =
  builder.writable(); valid(transform)
  if clip.isSome: valid(clip.get)
  if builder.depth >= builder.limits.maxDepth: graphicsFail("Canvas group depth quota exceeded")
  builder.append(CanvasCommand(drawKind: DrawKind.beginGroup, matrixValue: transform, clipValue: clip), reserve = 1)
  inc builder.depth
proc endGroup*(builder: CanvasBuilder) =
  builder.writable()
  if builder.depth == 0: graphicsFail("Canvas group has no matching begin")
  dec builder.depth
  builder.append(CanvasCommand(drawKind: DrawKind.endGroup))
proc setFocusableInternal*(builder: CanvasBuilder, enabled: bool) =
  builder.writable()
  builder.focusEnabled = enabled
proc finishFrame*(builder: CanvasBuilder): CanvasFrame =
  builder.writable()
  if builder.depth != 0: graphicsFail("Canvas has an unclosed group")
  result = CanvasFrame(owned: CanvasStorage(data: move(builder.data), designSize: builder.designSize,
    clearColor: builder.clearColor, focusEnabled: builder.focusEnabled, bytes: builder.bytes, segments: builder.segments,
    interactions: move(builder.interactions), transitions: move(builder.transitions)))
  builder.sealed = true
proc isNil*(frame: CanvasFrame): bool = frame.owned.isNil
proc commandCount*(frame: CanvasFrame): int = (if frame.isNil: 0 else: frame.owned.data.len)
proc pathSegmentCount*(frame: CanvasFrame): int = (if frame.isNil: 0 else: frame.owned.segments)
proc ownedBytes*(frame: CanvasFrame): int = (if frame.isNil: 0 else: frame.owned.bytes)
proc viewBox*(frame: CanvasFrame): Option[Vec2] = frame.owned.designSize
proc background*(frame: CanvasFrame): Color = frame.owned.clearColor
proc focusable*(frame: CanvasFrame): bool = not frame.isNil and frame.owned.focusEnabled
iterator commands*(frame: CanvasFrame): CanvasCommand =
  if not frame.isNil:
    for command in frame.owned.data: yield command
proc kind*(command: CanvasCommand): DrawKind = command.drawKind
proc paint*(command: CanvasCommand): Paint = command.drawing
proc position*(command: CanvasCommand): Vec2 =
  case command.drawKind
  of DrawKind.rectangle: vec2(command.rectangleValue.x, command.rectangleValue.y)
  of DrawKind.text: command.originValue
  else: graphicsFail("command does not have a position")
proc size*(command: CanvasCommand): Vec2 =
  if command.drawKind != DrawKind.rectangle: graphicsFail("command does not have a size")
  vec2(command.rectangleValue.width, command.rectangleValue.height)
proc radius*(command: CanvasCommand): float64 = command.radiusValue
proc center*(command: CanvasCommand): Vec2 = command.centerValue
proc start*(command: CanvasCommand): Vec2 = command.startValue
proc finish*(command: CanvasCommand): Vec2 = command.finishValue
proc path*(command: CanvasCommand): PathData = command.pathValue
proc text*(command: CanvasCommand): string = command.textValue
proc font*(command: CanvasCommand): string = command.fontValue
proc fontSize*(command: CanvasCommand): float64 = command.fontSizeValue
proc transform*(command: CanvasCommand): Matrix3x2 = command.matrixValue
proc clip*(command: CanvasCommand): Option[CanvasRect] = command.clipValue
proc `==`*(a, b: CanvasCommand): bool =
  if a.drawKind != b.drawKind or a.drawing != b.drawing or a.radiusValue != b.radiusValue: return false
  case a.drawKind
  of DrawKind.rectangle: a.rectangleValue == b.rectangleValue
  of DrawKind.circle: a.centerValue == b.centerValue
  of DrawKind.line: a.startValue == b.startValue and a.finishValue == b.finishValue
  of DrawKind.path: a.pathValue == b.pathValue
  of DrawKind.text: a.textValue == b.textValue and a.fontValue == b.fontValue and
    a.originValue == b.originValue and a.fontSizeValue == b.fontSizeValue
  of DrawKind.beginGroup: a.matrixValue == b.matrixValue and a.clipValue == b.clipValue
  of DrawKind.endGroup: true
proc `==`*(a,b:Degrees):bool {.borrow.}
proc `==`*(a, b: CanvasFrame): bool =
  if a.isNil or b.isNil: return a.isNil and b.isNil
  a.owned.focusEnabled == b.owned.focusEnabled and a.owned.designSize == b.owned.designSize and a.owned.clearColor == b.owned.clearColor and a.owned.data == b.owned.data and a.owned.interactions == b.owned.interactions and a.owned.transitions == b.owned.transitions

proc commandAt*(frame: CanvasFrame, index: int): CanvasCommand =
  ## A value copy preserves sealed storage while allowing indexed hit queries.
  if frame.isNil or index < 0 or index >= frame.commandCount:
    graphicsFail("Canvas command index is outside the frame")
  frame.owned.data[index]


proc commandCount*(builder: CanvasBuilder): int =
  builder.writable()
  builder.data.len
proc addInteractionInternal*(builder: CanvasBuilder, entry: CanvasInteraction) =
  builder.writable()
  if entry.commandIndex < -1 or entry.commandIndex >= builder.data.len or
      (entry.commandIndex >= 0 and builder.data[entry.commandIndex].kind == DrawKind.endGroup) or
      (builder.interactions.len > 0 and entry.commandIndex <= builder.interactions[^1].commandIndex):
    graphicsFail("invalid Canvas interaction command order")
  if entry.key.len == 0 or entry.key.len > 1_048_576 or validateUtf8(entry.key) != -1 or '\0' in entry.key:
    graphicsFail("invalid Canvas interaction identity")
  if (entry.eventMask and not CanvasEventMask) != 0: graphicsFail("unknown Canvas event mask")
  if entry.eventMask != 0 and builder.bindingCount >= MaxCanvasInteractionBindings:
    graphicsFail("Canvas interaction binding quota exceeded")
  if entry.key in builder.identityKeys: graphicsFail("duplicate Canvas interaction identity")
  if entry.parentIdentity.len > 1_048_576 or validateUtf8(entry.parentIdentity) != -1 or '\0' in entry.parentIdentity:
    graphicsFail("invalid Canvas structural parent identity")
  let bytes = sizeof(CanvasInteraction) + entry.key.len + entry.parentIdentity.len
  if bytes > builder.limits.maxBytes-builder.bytes-builder.depth*sizeof(CanvasCommand):
    graphicsFail("Canvas interaction metadata byte quota exceeded")
  builder.identityKeys.incl(entry.key)
  builder.interactions.add(entry)
  if entry.eventMask != 0: inc builder.bindingCount
  builder.bytes += bytes
iterator interactions*(frame: CanvasFrame): CanvasInteraction =
  if not frame.isNil:
    for entry in frame.owned.interactions: yield entry

proc canvasTweenValueInternal*[T](value:T):T=value
proc supportedCanvasPropertiesInternal*(kind:DrawKind):set[CanvasProperty]=
  case kind
  of DrawKind.rectangle:{CanvasProperty.position,CanvasProperty.size,CanvasProperty.radius,CanvasProperty.fill,CanvasProperty.stroke,CanvasProperty.strokeWidth}
  of DrawKind.circle:{CanvasProperty.center,CanvasProperty.radius,CanvasProperty.fill,CanvasProperty.stroke,CanvasProperty.strokeWidth}
  of DrawKind.line:{CanvasProperty.stroke,CanvasProperty.strokeWidth}
  of DrawKind.path:{CanvasProperty.fill,CanvasProperty.stroke,CanvasProperty.strokeWidth}
  of DrawKind.text:{CanvasProperty.position,CanvasProperty.fill}
  of DrawKind.beginGroup:{CanvasProperty.translate,CanvasProperty.rotate,CanvasProperty.scale}
  of DrawKind.endGroup:{}
proc addTransitionInternal*(builder:CanvasBuilder,definition:CanvasTransitionDefinition)=
  builder.writable()
  if definition.commandIndex<0 or definition.commandIndex>=builder.data.len:
    graphicsFail("invalid Canvas transition command index")
  if definition.identity.len==0 or definition.identity.len>1_048_576 or
      validateUtf8(definition.identity) != -1 or '\0' in definition.identity:
    graphicsFail("invalid Canvas transition identity")
  if definition.identity in builder.transitionKeys:graphicsFail("duplicate Canvas transition identity")
  if not (definition.properties<=supportedCanvasPropertiesInternal(builder.data[definition.commandIndex].kind)):
    graphicsFail("unsupported Canvas transition property")
  nonnegative(definition.durationMs)
  if definition.easingId notin 0..3:graphicsFail("invalid Canvas easing")
  valid(definition.translation);valid(definition.scaling)
  if not finite(float64(definition.rotation)):graphicsFail("invalid Canvas rotation")
  let bytes=sizeof(CanvasTransitionDefinition)+definition.identity.len
  if bytes>builder.limits.maxBytes-builder.bytes-builder.depth*sizeof(CanvasCommand):
    graphicsFail("Canvas transition metadata byte quota exceeded")
  builder.transitionKeys.incl(definition.identity)
  builder.transitions.add(definition)
  builder.bytes+=bytes
iterator transitionDefinitionsInternal*(frame:CanvasFrame):CanvasTransitionDefinition=
  if not frame.isNil:
    for definition in frame.owned.transitions:yield definition

proc withCanvasScalarInternal*(command:CanvasCommand,property:CanvasProperty,value:float64):CanvasCommand=
  result=command
  case property
  of CanvasProperty.radius:
    nonnegative(value)
    if command.kind notin {DrawKind.rectangle,DrawKind.circle}:graphicsFail("invalid radius property")
    result.radiusValue=value
  of CanvasProperty.strokeWidth:
    nonnegative(value);result.drawing.strokeWidth=value
  else:graphicsFail("not a scalar Canvas property")
proc withCanvasVectorInternal*(command:CanvasCommand,property:CanvasProperty,value:Vec2):CanvasCommand=
  valid(value);result=command
  case property
  of CanvasProperty.position:
    case command.kind
    of DrawKind.rectangle:result.rectangleValue.x=value.x;result.rectangleValue.y=value.y
    of DrawKind.text:result.originValue=value
    else:graphicsFail("invalid position property")
  of CanvasProperty.center:
    if command.kind!=DrawKind.circle:graphicsFail("invalid center property")
    result.centerValue=value
  of CanvasProperty.size:
    if command.kind!=DrawKind.rectangle:graphicsFail("invalid size property")
    nonnegative(value.x);nonnegative(value.y)
    result.rectangleValue.width=value.x;result.rectangleValue.height=value.y
  else:graphicsFail("not a vector Canvas property")
proc withCanvasColorInternal*(command:CanvasCommand,property:CanvasProperty,value:Color):CanvasCommand=
  valid(value);result=command
  case property
  of CanvasProperty.fill:result.drawing.fill=some(value)
  of CanvasProperty.stroke:result.drawing.stroke=some(value)
  else:graphicsFail("not a color Canvas property")
proc withCanvasTransformInternal*(command:CanvasCommand,translation:Vec2,rotation:Degrees,scaling:Vec2):CanvasCommand=
  if command.kind!=DrawKind.beginGroup:graphicsFail("not a Canvas group")
  result=command
  result.matrixValue=groupTransform(translation,rotation,scaling)
  valid(result.matrixValue)
proc replaceCanvasCommandsInternal*(frame:CanvasFrame,commands:seq[CanvasCommand]):CanvasFrame=
  ## Re-seal through the normal finite-value/shape/depth/byte validators.
  ## Geometry, target metadata and bindings remain owned immutable values.
  if commands.len!=frame.commandCount:graphicsFail("presentation command count changed")
  let builder=newCanvasBuilder(frame.viewBox,frame.background)
  builder.setFocusableInternal(frame.focusable)
  for i,command in commands:
    if command.kind!=frame.commandAt(i).kind:graphicsFail("presentation command kind changed")
    case command.kind
    of DrawKind.rectangle:builder.addRect(command.position,command.size,command.radius,command.paint)
    of DrawKind.circle:builder.addCircle(command.center,command.radius,command.paint)
    of DrawKind.line:builder.addLine(command.start,command.finish,command.paint.stroke.get,command.paint.strokeWidth)
    of DrawKind.path:builder.addPath(command.path,command.paint)
    of DrawKind.text:builder.addText(command.text,command.position,command.fontSize,command.paint.fill.get,command.font)
    of DrawKind.beginGroup:builder.beginGroup(command.transform,command.clip)
    of DrawKind.endGroup:builder.endGroup()
  for entry in frame.interactions:builder.addInteractionInternal(entry)
  for definition in frame.transitionDefinitionsInternal:builder.addTransitionInternal(definition)
  builder.finishFrame()
