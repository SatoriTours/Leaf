## Bounded DIP linear layout for native forms (row/column). Pure geometry: no
## platform imports, no Style string parsing and no business render.
##
## The engine implements only the agreed public set: gap/padding, auto/fixed/
## fill dimensions, explicit flex_grow weights, align/justify and hidden
## overflow clipping. It is deliberately not a CSS/Flexbox engine: no shrink,
## no min/max, no wrap, no scroll, no around/evenly.
import std/[tables, sets, algorithm, math, options]
import ./[core, styles, backend]

type
  DipSize* = object
    width*, height*: float64

  DipRect* = object
    x*, y*, width*, height*: float64

  LayoutBox* = object
    ## `rect` is the allocated box; `clip` is the inherited visible region.
    ## A caller must skip entities whose rect lies fully outside the clip
    ## instead of passing out-of-range coordinates to the platform.
    handle*: NodeHandle
    rect*, clip*: DipRect

  MeasureProc* = proc(entity: MountedEntity, available: DipSize): DipSize {.closure.}

  LayoutContext = object
    children: Table[NodeHandle, seq[MountedEntity]]
    measure: MeasureProc
    cache: Table[NodeHandle, DipSize]
    visiting: HashSet[NodeHandle]

proc sanitize(value: float64): float64 =
  if classify(value) in {fcNan, fcInf, fcNegInf}:
    fail("non-finite layout value")
  if value < 0: 0.0 else: value

proc mainOf(size: DipSize, horizontal: bool): float64 =
  if horizontal: size.width else: size.height

proc crossOf(size: DipSize, horizontal: bool): float64 =
  if horizontal: size.height else: size.width

proc mainDim(entity: MountedEntity, horizontal: bool): Option[Dimension] =
  if horizontal: entity.props.layout.width else: entity.props.layout.height

proc crossDim(entity: MountedEntity, horizontal: bool): Option[Dimension] =
  if horizontal: entity.props.layout.height else: entity.props.layout.width

proc mainBase(entity: MountedEntity, intrinsic: DipSize, horizontal: bool): float64 =
  ## fixed -> DIP value, fill -> 0 base, auto -> recursive preferred size.
  let dim = mainDim(entity, horizontal)
  if dim.isNone: return mainOf(intrinsic, horizontal)
  case dim.get.kind
  of dkFixed: dim.get.value
  of dkFill: 0.0
  of dkAuto: mainOf(intrinsic, horizontal)

proc crossPreferred(entity: MountedEntity, intrinsic: DipSize,
                    horizontal: bool): float64 =
  let dim = crossDim(entity, horizontal)
  if dim.isNone: return crossOf(intrinsic, horizontal)
  case dim.get.kind
  of dkFixed: dim.get.value
  of dkAuto, dkFill: crossOf(intrinsic, horizontal)

proc isFixedCross(entity: MountedEntity, horizontal: bool): bool =
  let dim = crossDim(entity, horizontal)
  dim.isSome and dim.get.kind == dkFixed

proc resolveCross(entity: MountedEntity, intrinsic: DipSize, available: float64,
                  horizontal: bool): float64 =
  let dim = crossDim(entity, horizontal)
  if dim.isNone: return crossOf(intrinsic, horizontal)
  case dim.get.kind
  of dkFixed: dim.get.value
  of dkFill: available
  of dkAuto: crossOf(intrinsic, horizontal)

proc isFillMain(entity: MountedEntity, horizontal: bool): bool =
  let dim = mainDim(entity, horizontal)
  dim.isSome and dim.get.kind == dkFill

proc intersect(a, b: DipRect): DipRect =
  let left = max(a.x, b.x)
  let top = max(a.y, b.y)
  let right = min(a.x + a.width, b.x + b.width)
  let bottom = min(a.y + a.height, b.y + b.height)
  DipRect(x: left, y: top, width: max(0.0, right - left),
    height: max(0.0, bottom - top))

proc contentIntrinsic(ctx: var LayoutContext, entity: MountedEntity,
                      available: DipSize): DipSize =
  ## Recursive preferred (intrinsic) size. Leaf sizes come from the supplied
  ## measure proc exactly once; container sizes derive from children, gap and
  ## padding. `fill` contributes a 0 main base, so intrinsic measurement never
  ## recurses to infinity.
  if ctx.cache.hasKey(entity.handle): return ctx.cache[entity.handle]
  if entity.handle in ctx.visiting: fail("layout cycle detected")
  ctx.visiting.incl(entity.handle)
  let horizontal = entity.kind == NodeKind.row
  if entity.kind in {NodeKind.column, NodeKind.row}:
    let props = entity.props.layout
    let pad = props.padding.get(0.0)
    let gap = props.gap.get(0.0)
    let childAvailable = DipSize(width: max(0.0, available.width - 2.0 * pad),
      height: max(0.0, available.height - 2.0 * pad))
    var mainTotal = 0.0
    var crossMax = 0.0
    let children = ctx.children.getOrDefault(entity.handle)
    for index, child in children:
      let childIntrinsic = contentIntrinsic(ctx, child, childAvailable)
      mainTotal += mainBase(child, childIntrinsic, horizontal)
      if index > 0: mainTotal += gap
      crossMax = max(crossMax, crossPreferred(child, childIntrinsic, horizontal))
    let width = if horizontal: mainTotal + 2.0 * pad else: crossMax + 2.0 * pad
    let height = if horizontal: crossMax + 2.0 * pad else: mainTotal + 2.0 * pad
    result = DipSize(width: sanitize(width), height: sanitize(height))
  else:
    let measured = ctx.measure(entity, available)
    result = DipSize(width: sanitize(measured.width), height: sanitize(measured.height))
  ctx.visiting.excl(entity.handle)
  ctx.cache[entity.handle] = result

proc arrange(ctx: var LayoutContext, entity: MountedEntity, rect, clip: DipRect,
             result: var seq[LayoutBox]) =
  result.add LayoutBox(handle: entity.handle, rect: rect, clip: clip)
  if entity.kind notin {NodeKind.column, NodeKind.row}: return
  let horizontal = entity.kind == NodeKind.row
  let props = entity.props.layout
  let pad = props.padding.get(0.0)
  let gap = props.gap.get(0.0)
  let contentRect = DipRect(x: rect.x + pad, y: rect.y + pad,
    width: max(0.0, rect.width - 2.0 * pad),
    height: max(0.0, rect.height - 2.0 * pad))
  let childClip = intersect(clip, contentRect)
  let children = ctx.children.getOrDefault(entity.handle)
  let count = children.len
  if count == 0: return
  let contentSize = DipSize(width: contentRect.width, height: contentRect.height)
  var bases = newSeq[float64](count)
  var weights = newSeq[float64](count)
  var totalBase = 0.0
  var totalWeight = 0.0
  for index, child in children:
    let childIntrinsic = contentIntrinsic(ctx, child, contentSize)
    bases[index] = mainBase(child, childIntrinsic, horizontal)
    var weight = 0.0
    let grow = child.props.layout.flexGrow
    if grow.isSome and grow.get > 0.0: weight = grow.get
    elif isFillMain(child, horizontal): weight = 1.0
    weights[index] = weight
    totalBase += bases[index]
    totalWeight += weight

  let mainAvailable = mainOf(contentSize, horizontal)
  let gaps = if count > 1: float64(count - 1) * gap else: 0.0
  # Negative remainder is not shrunk; the overflow is clipped.
  let remainder = max(0.0, mainAvailable - totalBase - gaps)
  let leftover = if totalWeight > 0.0: 0.0 else: remainder

  var offset = 0.0
  var gapAdd = 0.0
  case props.justify.get(justifyStart)
  of justifyStart: discard
  of justifyEnd: offset = leftover
  of justifyCenter: offset = leftover / 2.0
  of justifyBetween:
    if count > 1: gapAdd = leftover / float64(count - 1)
  else: discard

  var cursor = (if horizontal: contentRect.x else: contentRect.y) + offset
  let crossAvailable = crossOf(contentSize, horizontal)
  let align = props.align.get(alignStart)
  for index, child in children:
    var childMain = bases[index]
    if totalWeight > 0.0:
      childMain += remainder * weights[index] / totalWeight
    let childIntrinsic = contentIntrinsic(ctx, child, contentSize)
    var childCross: float64
    if align == alignStretch and not isFixedCross(child, horizontal):
      # Stretch expands auto/fill but never shrinks intrinsic content.
      childCross = max(crossPreferred(child, childIntrinsic, horizontal), crossAvailable)
    else:
      childCross = resolveCross(child, childIntrinsic, crossAvailable, horizontal)
    var childRect: DipRect
    if horizontal:
      childRect.x = cursor
      childRect.width = childMain
      childRect.height = childCross
      case align
      of alignStart, alignStretch: childRect.y = contentRect.y
      of alignEnd: childRect.y = contentRect.y + crossAvailable - childCross
      of alignCenter: childRect.y = contentRect.y + (crossAvailable - childCross) / 2.0
    else:
      childRect.y = cursor
      childRect.height = childMain
      childRect.width = childCross
      case align
      of alignStart, alignStretch: childRect.x = contentRect.x
      of alignEnd: childRect.x = contentRect.x + crossAvailable - childCross
      of alignCenter: childRect.x = contentRect.x + (crossAvailable - childCross) / 2.0
    cursor += childMain
    if index < count - 1: cursor += gap + gapAdd
    arrange(ctx, child, childRect, childClip, result)

proc resolveRoot(dim: Option[Dimension], available: float64): float64 =
  ## The root occupies the finite content area; only an explicit fixed size
  ## overrides it. auto/fill never recurse to an unbounded size.
  if dim.isNone: return available
  if dim.get.kind == dkFixed: dim.get.value else: available

proc layoutTree*(entities: Table[NodeHandle, MountedEntity], content: DipSize,
                 measure: MeasureProc): seq[LayoutBox] =
  ## Lay out the accepted entity tree inside a finite content area. Returns a
  ## pre-order sequence (parent before children) of allocated boxes.
  if measure == nil: fail("layoutTree requires a measure proc")
  let contentSize = DipSize(width: sanitize(content.width),
    height: sanitize(content.height))
  var root: MountedEntity
  var found = false
  for entity in entities.values:
    if entity.parent == NoHandle:
      if found: fail("layout requires a single root entity")
      root = entity
      found = true
  if not found: fail("layout requires a root entity")

  var ctx = LayoutContext(measure: measure)
  for entity in entities.values:
    ctx.children.mgetOrPut(entity.parent, @[]).add(entity)
  var parents: seq[NodeHandle]
  for parent in ctx.children.keys: parents.add(parent)
  for parent in parents:
    ctx.children[parent].sort(proc(a, b: MountedEntity): int = cmp(a.index, b.index))

  let intrinsic = contentIntrinsic(ctx, root, contentSize)
  let rootRect = DipRect(x: 0, y: 0,
    width: sanitize(resolveRoot(root.props.layout.width, contentSize.width)),
    height: sanitize(resolveRoot(root.props.layout.height, contentSize.height)))
  let rootClip = DipRect(x: 0, y: 0, width: contentSize.width,
    height: contentSize.height)
  var boxes: seq[LayoutBox]
  arrange(ctx, root, rootRect, rootClip, boxes)
  boxes

proc dipToPixel(value: float64, dpi: int): int =
  if classify(value) in {fcNan, fcInf, fcNegInf}: fail("non-finite pixel edge")
  let scaled = value * float64(dpi) / 96.0
  if scaled < float64(low(int32)) or scaled > float64(high(int32)):
    fail("pixel edge out of range")
  int(round(scaled))

proc pixelEdges*(rect: DipRect, dpi: int): tuple[left, top, right, bottom: int] =
  ## Shared-boundary rounding: the right/bottom edges round the summed extent,
  ## so adjacent boxes never accumulate a rounding gap.
  if dpi <= 0: fail("invalid dpi")
  result.left = dipToPixel(rect.x, dpi)
  result.top = dipToPixel(rect.y, dpi)
  result.right = dipToPixel(rect.x + rect.width, dpi)
  result.bottom = dipToPixel(rect.y + rect.height, dpi)