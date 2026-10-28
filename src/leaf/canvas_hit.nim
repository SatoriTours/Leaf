## Prepared, owned hit metadata. Inputs and results are in Canvas design
## coordinates; the native caller removes DPI/viewBox before querying.
## No application event handlers are invoked here. Paths, text and SDK-specific
## rounded geometry require the renderer's containment query, never a bbox.
import std/[math, options, tables, unicode]
import ./graphics

const MaxCanvasBindings* = MaxCanvasInteractionBindings

type
  HitPolicy* {.pure.} = enum automatic, ignore
  HitBinding* = object
    commandIndex*: int
    key*: string
    policy*: HitPolicy
  GeometryContains* = proc(commandIndex: int, localPosition: Vec2): bool {.closure.}
  HitRouteEntry* = object
    commandIndex*: int
    key*: string
    position*, localPosition*: Vec2
  CanvasHit* = object
    geometryIndex*: int
    canvasPosition*: Vec2
    route*: seq[HitRouteEntry]
  HitNode = object
    commandIndex, parent: int
    key: string
    inverseLocal, inverseParent: Matrix3x2
  HitClip = object
    parent: int
    inverse: Matrix3x2
    bounds: CanvasRect
  HitCandidate = object
    commandIndex, owner, clip: int
    inverse: Matrix3x2
  HitStorage = ref object
    frame: CanvasFrame
    geometryContains: GeometryContains
    nodes: seq[HitNode]
    clips: seq[HitClip]
    candidates: seq[HitCandidate]
    bytes: int
  CanvasHitSnapshot* = object
    owned: HitStorage
  BuildScope = object
    world: Matrix3x2
    inverted: Option[Matrix3x2]
    owner, clip, group: int
    enabled: bool

proc fail(message: string) {.noreturn.} = raise newException(GraphicsError, message)
proc finite(value: float64): bool = classify(value) notin {fcNan, fcInf, fcNegInf}
proc within(p: Vec2, r: CanvasRect): bool =
  r.width > 0 and r.height > 0 and p.x >= r.x and p.y >= r.y and
    p.x <= r.x + r.width and p.y <= r.y + r.height
proc rounded(p: Vec2, r: CanvasRect, radius: float64, strict = false): bool =
  if not within(p, r): return false
  if strict and (p.x <= r.x or p.y <= r.y or p.x >= r.x+r.width or p.y >= r.y+r.height): return false
  if radius <= 0: return true
  let x = max(r.x + radius, min(p.x, r.x + r.width - radius))
  let y = max(r.y + radius, min(p.y, r.y + r.height - radius))
  let distance = (p.x-x)*(p.x-x) + (p.y-y)*(p.y-y)
  if strict: distance < radius*radius else: distance <= radius*radius
proc filled(paint: Paint): bool = paint.fill.isSome and paint.fill.get.a > 0
proc stroked(paint: Paint): bool =
  paint.stroke.isSome and paint.stroke.get.a > 0 and paint.strokeWidth > 0
proc needsRenderer(c: CanvasCommand): bool =
  case c.kind
  of DrawKind.path, DrawKind.text: true
  of DrawKind.rectangle:
    c.radius > min(c.size.x, c.size.y) / 2
  else: false
proc primitiveContains(c: CanvasCommand, p: Vec2): bool =
  let drawing = c.paint
  let half = drawing.strokeWidth / 2
  case c.kind
  of DrawKind.circle:
    if c.radius <= 0: return false
    let d = hypot(p.x-c.center.x, p.y-c.center.y)
    (drawing.filled and d <= c.radius) or
      (drawing.stroked and d <= c.radius+half and d >= max(0.0, c.radius-half))
  of DrawKind.rectangle:
    let origin = c.position
    let size = c.size
    if size.x <= 0 or size.y <= 0: return false
    let r = rectangle(origin.x, origin.y, size.x, size.y)
    if drawing.filled and rounded(p, r, c.radius): return true
    if not drawing.stroked: return false
    let outside = rectangle(r.x-half, r.y-half, r.width+2*half, r.height+2*half)
    # A zero-radius D2D rectangle has mitered, not rounded, outer corners.
    let outerRadius = if c.radius > 0: c.radius+half else: 0.0
    if not rounded(p, outside, outerRadius): return false
    if r.width <= 2*half or r.height <= 2*half: return true
    let inside = rectangle(r.x+half, r.y+half, r.width-2*half, r.height-2*half)
    not rounded(p, inside, max(0.0, c.radius-half), strict = true)
  of DrawKind.line:
    if not drawing.stroked: return false
    let v = c.finish-c.start
    let delta = p-c.start
    let length = hypot(v.x, v.y)
    if length <= 0: return false
    let along = (delta.x*v.x + delta.y*v.y)/length
    along >= 0 and along <= length and abs(delta.x*v.y-delta.y*v.x)/length <= half
  else: fail("renderer geometry query is required for this Canvas command")

proc prepareHitSnapshot*(frame: CanvasFrame, bindings: openArray[HitBinding],
    geometryContains: GeometryContains = nil, maxBindings = MaxCanvasBindings,
    maxBytes = MaxCanvasOwnedBytes): CanvasHitSnapshot =
  if frame.isNil: fail("hit snapshot needs an owned Canvas frame")
  if maxBindings <= 0 or maxBindings > MaxCanvasBindings or
      maxBytes <= 0 or maxBytes > MaxCanvasOwnedBytes:
    fail("invalid Canvas hit metadata quota")
  var byCommand = initTable[int, HitBinding]()
  var count, keyBytes: int
  for binding in bindings:
    if binding.commandIndex < 0 or binding.commandIndex >= frame.commandCount or
        byCommand.hasKey(binding.commandIndex): fail("invalid or duplicate hit command index")
    if binding.key.len == 0 and binding.policy != HitPolicy.ignore:
      fail("an interactive Canvas binding needs a stable identity")
    if binding.key.len > 1_048_576 or validateUtf8(binding.key) != -1 or '\0' in binding.key:
      fail("invalid Canvas interaction identity")
    if binding.key.len > 0: inc count
    keyBytes += binding.key.len
    if count > maxBindings: fail("Canvas interaction binding quota exceeded")
    if keyBytes > maxBytes: fail("Canvas hit metadata byte quota exceeded")
    byCommand[binding.commandIndex] = binding
  let data = HitStorage(frame: frame, geometryContains: geometryContains,
    bytes: keyBytes)
  data.bytes += sizeof(data[])
  template reserve(amount: int) =
    if amount > maxBytes-data.bytes or amount > MaxCanvasOwnedBytes-frame.ownedBytes-data.bytes:
      fail("Canvas hit metadata byte quota exceeded")
    data.bytes += amount
  reserve(0)
  let identity = identityMatrix()
  var scopes = @[BuildScope(world: identity, inverted: some(identity), owner: -1,
    clip: -1, group: -1, enabled: true)]
  var siblings = initTable[(int, string), int]()
  var index = 0
  for command in frame.commands:
    let parent = scopes[^1]
    let binding = byCommand.getOrDefault(index, HitBinding(commandIndex: index))
    if command.kind == DrawKind.endGroup:
      if byCommand.hasKey(index): fail("a group end cannot own a Canvas binding")
      scopes.setLen(scopes.len-1)
      inc index
      continue
    let world = if command.kind == DrawKind.beginGroup: parent.world*command.transform else: parent.world
    let inverted = if command.kind == DrawKind.beginGroup: world.inverse else: parent.inverted
    let enabled = parent.enabled and binding.policy != HitPolicy.ignore and inverted.isSome
    var owner = parent.owner
    if binding.key.len > 0:
      let key = (parent.group, binding.key)
      if siblings.hasKey(key): fail("duplicate sibling Canvas interaction identity")
      siblings[key] = index
      if enabled:
        reserve(sizeof(HitNode))
        owner = data.nodes.len
        data.nodes.add(HitNode(commandIndex: index, parent: parent.owner, key: binding.key,
          inverseLocal: inverted.get, inverseParent: parent.inverted.get))
    var clip = parent.clip
    if command.kind == DrawKind.beginGroup:
      if enabled and command.clip.isSome:
        reserve(sizeof(HitClip))
        clip = data.clips.len
        data.clips.add(HitClip(parent: parent.clip, inverse: inverted.get, bounds: command.clip.get))
      scopes.add(BuildScope(world: world, inverted: inverted, owner: owner, clip: clip,
        group: index, enabled: enabled))
    elif enabled and owner >= 0 and (command.paint.filled or command.paint.stroked):
      if geometryContains == nil and command.needsRenderer:
        fail("path, text or SDK-specific rounded geometry needs a renderer containment query")
      reserve(sizeof(HitCandidate))
      data.candidates.add(HitCandidate(commandIndex: index, owner: owner, clip: clip, inverse: inverted.get))
    inc index
  CanvasHitSnapshot(owned: data)

proc ownedBytes*(snapshot: CanvasHitSnapshot): int =
  ## Metadata only; the retained frame is shared and must not be counted twice.
  if snapshot.owned == nil: 0 else: snapshot.owned.bytes
proc target*(hit: CanvasHit): HitRouteEntry = hit.route[0]
proc hitTest*(snapshot: CanvasHitSnapshot, canvasPosition: Vec2): Option[CanvasHit] =
  if snapshot.owned == nil or not finite(canvasPosition.x) or not finite(canvasPosition.y):
    return none(CanvasHit)
  let data = snapshot.owned
  for i in countdown(data.candidates.high, 0):
    let candidate = data.candidates[i]
    var clip = candidate.clip
    var inside = true
    while clip >= 0:
      let region = data.clips[clip]
      if not within(region.inverse.transformPoint(canvasPosition), region.bounds):
        inside = false
        break
      clip = region.parent
    if not inside: continue
    let local = candidate.inverse.transformPoint(canvasPosition)
    if not finite(local.x) or not finite(local.y): continue
    let contains = if data.geometryContains != nil:
      data.geometryContains(candidate.commandIndex, local)
    else: primitiveContains(data.frame.commandAt(candidate.commandIndex), local)
    if not contains: continue
    var hit = CanvasHit(geometryIndex: candidate.commandIndex, canvasPosition: canvasPosition)
    var owner = candidate.owner
    while owner >= 0:
      let node = data.nodes[owner]
      hit.route.add(HitRouteEntry(commandIndex: node.commandIndex, key: node.key,
        position: node.inverseParent.transformPoint(canvasPosition),
        localPosition: node.inverseLocal.transformPoint(canvasPosition)))
      owner = node.parent
    return some(hit)
  none(CanvasHit)


proc needsRendererInternal*(command: CanvasCommand): bool = command.needsRenderer
proc primitiveContainsInternal*(command: CanvasCommand, position: Vec2): bool =
  if command.needsRenderer: fail("complex Canvas geometry requires the renderer")
  primitiveContains(command, position)
