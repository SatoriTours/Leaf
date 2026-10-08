## Bounded DIP linear layout for native forms (row/column). Pure geometry: no
## platform imports, no Style string parsing and no business render.
##
## The engine implements only the agreed public set: gap/padding, auto/fixed/
## fill dimensions, explicit flex_grow weights, align/justify and hidden
## overflow clipping. It is deliberately not a CSS/Flexbox engine: no shrink,
## no min/max, no wrap, no scroll, no around/evenly.
##
## Measurement contract: `MeasureProc` receives the entity's *finite local*
## constraint, not an ancestor's size. A declared fixed axis constrains the
## subtree locally (padding is deducted from the local content); a width
## sensitive leaf is measured again under its final allocated width so auto
## heights and ancestor auto intrinsics follow the real width. Fixed heights
## are never overridden by measurement. Results are cached per
## (handle, effective local width, effective local height) within one layout
## call; a different constraint is measured again.
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

  ConstraintKey = tuple[handle: NodeHandle, width, height: float64]

  LayoutContext = object
    children: Table[NodeHandle, seq[MountedEntity]]
    measure: MeasureProc
    cache: Table[ConstraintKey, DipSize]
    visiting: HashSet[NodeHandle]

proc finite(value: float64): float64 =
  ## Any derived geometry that cannot be represented must fail explicitly
  ## instead of returning Inf/NaN to a caller.
  if classify(value) in {fcNan, fcInf, fcNegInf}:
    fail("layout value is not finite")
  value

proc nonNegative(value: float64): float64 =
  let checked = finite(value)
  if checked < 0.0: 0.0 else: checked

proc mainOf(size: DipSize, horizontal: bool): float64 =
  if horizontal: size.width else: size.height

proc crossOf(size: DipSize, horizontal: bool): float64 =
  if horizontal: size.height else: size.width

proc mainDim(entity: MountedEntity, horizontal: bool): Option[Dimension] =
  if horizontal: entity.props.layout.width else: entity.props.layout.height

proc crossDim(entity: MountedEntity, horizontal: bool): Option[Dimension] =
  if horizontal: entity.props.layout.height else: entity.props.layout.width

proc localConstraint(entity: MountedEntity, available: DipSize): DipSize =
  ## A declared fixed axis is the entity's finite local constraint; other axes
  ## inherit the parent's finite constraint.
  result = available
  let width = entity.props.layout.width
  if width.isSome and width.get.kind == dkFixed: result.width = width.get.value
  let height = entity.props.layout.height
  if height.isSome and height.get.kind == dkFixed: result.height = height.get.value

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

proc resolveChildWidth(entity: MountedEntity, intrinsic: DipSize,
                       available: float64): float64 =
  ## Cross-axis (width) resolution for a child of a column.
  let dim = entity.props.layout.width
  if dim.isNone: return nonNegative(intrinsic.width)
  case dim.get.kind
  of dkFixed: dim.get.value
  of dkFill: available
  of dkAuto: nonNegative(intrinsic.width)

proc isFillMain(entity: MountedEntity, horizontal: bool): bool =
  let dim = mainDim(entity, horizontal)
  dim.isSome and dim.get.kind == dkFill

proc intersect(a, b: DipRect): DipRect =
  let left = finite(max(a.x, b.x))
  let top = finite(max(a.y, b.y))
  let right = finite(min(a.x + a.width, b.x + b.width))
  let bottom = finite(min(a.y + a.height, b.y + b.height))
  DipRect(x: left, y: top, width: nonNegative(right - left),
    height: nonNegative(bottom - top))

proc contentIntrinsic(ctx: var LayoutContext, entity: MountedEntity,
                      available: DipSize): DipSize =
  ## Recursive preferred (intrinsic) size under a finite local constraint.
  ## Leaf sizes come from `measure` once per distinct constraint; container
  ## sizes derive from children, gap and padding. `fill` contributes a 0 main
  ## base, so intrinsic measurement never recurses to infinity.
  let key: ConstraintKey = (entity.handle, available.width, available.height)
  if ctx.cache.hasKey(key): return ctx.cache[key]
  if entity.handle in ctx.visiting: fail("layout cycle detected")
  ctx.visiting.incl(entity.handle)
  if entity.kind in {NodeKind.column, NodeKind.row}:
    let horizontal = entity.kind == NodeKind.row
    let props = entity.props.layout
    let pad = props.padding.get(0.0)
    let gap = props.gap.get(0.0)
    let local = localConstraint(entity, available)
    let childAvailable = DipSize(width: nonNegative(local.width - 2.0 * pad),
      height: nonNegative(local.height - 2.0 * pad))
    var mainTotal = 0.0
    var crossMax = 0.0
    let children = ctx.children.getOrDefault(entity.handle)
    for index, child in children:
      let childIntrinsic = contentIntrinsic(ctx, child, childAvailable)
      mainTotal = finite(mainTotal + mainBase(child, childIntrinsic, horizontal))
      if index > 0: mainTotal = finite(mainTotal + gap)
      crossMax = finite(max(crossMax, crossPreferred(child, childIntrinsic, horizontal)))
    let width = if horizontal: finite(mainTotal + 2.0 * pad) else: finite(crossMax + 2.0 * pad)
    let height = if horizontal: finite(crossMax + 2.0 * pad) else: finite(mainTotal + 2.0 * pad)
    result = DipSize(width: nonNegative(width), height: nonNegative(height))
  else:
    let measured = ctx.measure(entity, available)
    result = DipSize(width: nonNegative(measured.width),
      height: nonNegative(measured.height))
  ctx.visiting.excl(entity.handle)
  ctx.cache[key] = result

proc arrange(ctx: var LayoutContext, entity: MountedEntity, rect, clip: DipRect,
             result: var seq[LayoutBox]) =
  result.add LayoutBox(handle: entity.handle, rect: rect, clip: clip)
  if entity.kind notin {NodeKind.column, NodeKind.row}: return
  let horizontal = entity.kind == NodeKind.row
  let props = entity.props.layout
  let pad = props.padding.get(0.0)
  let gap = props.gap.get(0.0)
  let contentRect = DipRect(
    x: finite(rect.x + pad),
    y: finite(rect.y + pad),
    width: nonNegative(rect.width - 2.0 * pad),
    height: nonNegative(rect.height - 2.0 * pad))
  let childClip = intersect(clip, contentRect)
  let children = ctx.children.getOrDefault(entity.handle)
  let count = children.len
  if count == 0: return
  let contentSize = DipSize(width: contentRect.width, height: contentRect.height)

  # Main-axis bases. A row measures width bases under the container content
  # width; a column resolves each child's width first and measures the height
  # base under that width.
  var bases = newSeq[float64](count)
  var weights = newSeq[float64](count)
  var widths = newSeq[float64](count)
  var totalBase = 0.0
  var totalWeight = 0.0
  for index, child in children:
    var childWidth: float64
    if horizontal:
      childWidth = contentSize.width
    else:
      let preliminary = contentIntrinsic(ctx, child, contentSize)
      childWidth = resolveChildWidth(child, preliminary, contentSize.width)
    widths[index] = childWidth
    let childIntrinsic = contentIntrinsic(ctx, child,
      DipSize(width: childWidth, height: contentSize.height))
    bases[index] = mainBase(child, childIntrinsic, horizontal)
    var weight = 0.0
    if child.props.layout.flexGrow.isSome:
      # An explicit grow value (including 0) always wins; only an absent
      # attribute falls back to the fill default weight of 1.
      weight = child.props.layout.flexGrow.get
    elif isFillMain(child, horizontal):
      weight = 1.0
    weights[index] = weight
    totalBase = finite(totalBase + bases[index])
    totalWeight = finite(totalWeight + weight)

  let mainAvailable = mainOf(contentSize, horizontal)
  let gaps = if count > 1: finite(float64(count - 1) * gap) else: 0.0
  # Negative remainder is not shrunk; the overflow is clipped.
  let remainder = nonNegative(mainAvailable - totalBase - gaps)
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

  var cursor = finite((if horizontal: contentRect.x else: contentRect.y) + offset)
  let crossAvailable = crossOf(contentSize, horizontal)
  let align = props.align.get(alignStart)
  for index, child in children:
    var childMain = bases[index]
    if totalWeight > 0.0:
      # Normalize before multiplying so an intermediate product cannot overflow.
      childMain = finite(childMain + remainder * (weights[index] / totalWeight))
    var childWidth, childHeight: float64
    if horizontal:
      childWidth = nonNegative(childMain)
      # Re-measure width-sensitive content under the final allocated width.
      let finalIntrinsic = contentIntrinsic(ctx, child,
        DipSize(width: childWidth, height: contentSize.height))
      if align == alignStretch and not isFixedCross(child, horizontal):
        # Stretch expands auto/fill but never shrinks intrinsic content.
        childHeight = nonNegative(max(crossPreferred(child, finalIntrinsic, true),
          crossAvailable))
      else:
        childHeight = nonNegative(resolveCross(child, finalIntrinsic,
          crossAvailable, true))
    else:
      childWidth = nonNegative(widths[index])
      childHeight = nonNegative(childMain)
    var childRect: DipRect
    if horizontal:
      childRect.x = cursor
      childRect.width = childWidth
      childRect.height = childHeight
      case align
      of alignStart, alignStretch: childRect.y = contentRect.y
      of alignEnd: childRect.y = finite(contentRect.y + crossAvailable - childHeight)
      of alignCenter:
        childRect.y = finite(contentRect.y + (crossAvailable - childHeight) / 2.0)
    else:
      childRect.y = cursor
      childRect.height = childHeight
      childRect.width = childWidth
      case align
      of alignStart, alignStretch: childRect.x = contentRect.x
      of alignEnd: childRect.x = finite(contentRect.x + crossAvailable - childWidth)
      of alignCenter:
        childRect.x = finite(contentRect.x + (crossAvailable - childWidth) / 2.0)
    cursor = finite(cursor + childMain)
    if index < count - 1: cursor = finite(cursor + gap + gapAdd)
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
  let contentSize = DipSize(width: nonNegative(content.width),
    height: nonNegative(content.height))
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

  let rootRect = DipRect(x: 0, y: 0,
    width: nonNegative(resolveRoot(root.props.layout.width, contentSize.width)),
    height: nonNegative(resolveRoot(root.props.layout.height, contentSize.height)))
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