## Bounded DIP linear layout for native forms (row/column). Pure geometry: no
## platform imports, no Style string parsing and no business render.
##
## The engine implements only the agreed public set: gap/padding, auto/fixed/
## fill dimensions, explicit flex_grow weights, align/justify and hidden
## overflow clipping. It is deliberately not a CSS/Flexbox engine: no shrink,
## no min/max, no wrap, no scroll, no around/evenly.
##
## Measurement contract: `MeasureProc` receives the entity's *effective finite
## local* constraint, not an ancestor's raw size. Preferred/base measurement
## normalizes fixed axes; once width is allocated, that width takes precedence
## when measuring preferred height (including fixed-base + explicit grow).
## Padding is deducted from local content. Preferred extents exclude allocated
## fill/grow/stretch space, while height follows the resolved child widths.
## Both passes share these decisions and cache by effective width/height,
## without including phase in the key. Fixed preferred heights stay declared.
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

  ConstraintPhase = enum
    preferredConstraint, allocatedWidthConstraint

  ContainerPlan = object
    widths: seq[float64]
    heights: seq[float64]
    mainTotal: float64
    preferredMainTotal: float64
    preferredCrossMax: float64

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

proc localConstraint(entity: MountedEntity, available: DipSize,
                     phase: ConstraintPhase): DipSize =
  ## Fixed axes constrain the preferred/base phase. Resolved width is already
  ## authoritative in the height measurement phase; do not undo explicit grow.
  result = available
  let width = entity.props.layout.width
  if phase == preferredConstraint and width.isSome and width.get.kind == dkFixed:
    result.width = width.get.value
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
                      available: DipSize,
                      phase = preferredConstraint): DipSize
proc allocateMain(ctx: var LayoutContext, entity: MountedEntity,
                  contentSize: DipSize): ContainerPlan

proc allocateMain(ctx: var LayoutContext, entity: MountedEntity,
                  contentSize: DipSize): ContainerPlan =
  ## Shared preferred/base and actual allocation decisions. Preferred totals
  ## do not include consumed remainder or cross fill/stretch, but preferred
  ## heights still follow resolved widths, before either pass publishes sizes.
  let horizontal = entity.kind == NodeKind.row
  let props = entity.props.layout
  let gap = props.gap.get(0.0)
  let align = props.align.get(alignStart)
  let children = ctx.children.getOrDefault(entity.handle)
  let count = children.len
  if count == 0: return
  result.widths = newSeq[float64](count)
  result.heights = newSeq[float64](count)
  var bases = newSeq[float64](count)
  var weights = newSeq[float64](count)
  var totalBase = 0.0
  var totalWeight = 0.0

  for index, child in children:
    var weight = 0.0
    if child.props.layout.flexGrow.isSome:
      # An explicit grow value (including 0) always wins; only an absent
      # attribute falls back to the fill default weight of 1.
      weight = child.props.layout.flexGrow.get
    elif isFillMain(child, horizontal):
      weight = 1.0
    weights[index] = weight
    if horizontal:
      # Main axis is width: base from the intrinsic under the content width.
      let childIntrinsic = contentIntrinsic(ctx, child, contentSize)
      bases[index] = mainBase(child, childIntrinsic, true)
    else:
      # Cross axis is width: resolve it (with stretch) before measuring height.
      let preliminary = contentIntrinsic(ctx, child, contentSize)
      result.preferredCrossMax = finite(max(result.preferredCrossMax,
        crossPreferred(child, preliminary, false)))
      var childWidth = resolveChildWidth(child, preliminary, contentSize.width)
      if align == alignStretch and not isFixedCross(child, false):
        childWidth = max(childWidth, contentSize.width)
      result.widths[index] = nonNegative(childWidth)
      let childIntrinsic = contentIntrinsic(ctx, child,
        DipSize(width: result.widths[index], height: contentSize.height),
        allocatedWidthConstraint)
      bases[index] = mainBase(child, childIntrinsic, false)
    totalBase = finite(totalBase + bases[index])
    totalWeight = finite(totalWeight + weight)

  let mainAvailable = mainOf(contentSize, horizontal)
  let gaps = if count > 1: finite(float64(count - 1) * gap) else: 0.0
  result.preferredMainTotal = finite(totalBase + gaps)
  # Negative remainder is not shrunk; the overflow is clipped.
  let remainder = nonNegative(mainAvailable - totalBase - gaps)
  var mainTotal = 0.0
  for index, child in children:
    var childMain = bases[index]
    if totalWeight > 0.0:
      # Normalize before multiplying so an intermediate product cannot overflow.
      childMain = finite(childMain + remainder * (weights[index] / totalWeight))
    let main = nonNegative(childMain)
    if horizontal: result.widths[index] = main else: result.heights[index] = main
    mainTotal = finite(mainTotal + main)
    if index > 0: mainTotal = finite(mainTotal + gap)

  for index, child in children:
    if horizontal:
      # Height follows the final allocated width.
      let finalIntrinsic = contentIntrinsic(ctx, child,
        DipSize(width: result.widths[index], height: contentSize.height),
        allocatedWidthConstraint)
      result.preferredCrossMax = finite(max(result.preferredCrossMax,
        crossPreferred(child, finalIntrinsic, true)))
      var childHeight: float64
      if align == alignStretch and not isFixedCross(child, true):
        # Stretch expands auto/fill but never shrinks intrinsic content.
        childHeight = nonNegative(max(crossPreferred(child, finalIntrinsic, true),
          contentSize.height))
      else:
        childHeight = nonNegative(resolveCross(child, finalIntrinsic,
          contentSize.height, true))
      result.heights[index] = childHeight
  result.mainTotal = mainTotal

proc contentIntrinsic(ctx: var LayoutContext, entity: MountedEntity,
                      available: DipSize, phase: ConstraintPhase): DipSize =
  ## Recursive preferred (intrinsic) size under the effective local constraint.
  ## Leaf sizes come from `measure` once per effective constraint; container
  ## sizes use the plan's preferred totals, never its allocated extents. Fill
  ## contributes a 0 main base, while width-sensitive height uses actual width.
  let effective = localConstraint(entity, available, phase)
  let key: ConstraintKey = (entity.handle, effective.width, effective.height)
  if ctx.cache.hasKey(key): return ctx.cache[key]
  if entity.handle in ctx.visiting: fail("layout cycle detected")
  ctx.visiting.incl(entity.handle)
  if entity.kind in {NodeKind.column, NodeKind.row, NodeKind.navigation}:
    let horizontal = entity.kind == NodeKind.row
    let pad = entity.props.layout.padding.get(0.0)
    let contentSize = DipSize(width: nonNegative(effective.width - 2.0 * pad),
      height: nonNegative(effective.height - 2.0 * pad))
    let plan = allocateMain(ctx, entity, contentSize)
    let mainExtent = finite(plan.preferredMainTotal + 2.0 * pad)
    let crossExtent = finite(plan.preferredCrossMax + 2.0 * pad)
    if horizontal:
      result = DipSize(width: nonNegative(mainExtent), height: nonNegative(crossExtent))
    else:
      result = DipSize(width: nonNegative(crossExtent), height: nonNegative(mainExtent))
  elif entity.props.layout.width.isSome and
      entity.props.layout.width.get.kind == dkFixed and
      entity.props.layout.height.isSome and
      entity.props.layout.height.get.kind == dkFixed:
    # Neither intrinsic axis participates in allocation. Do not acquire native
    # measurement resources for content that cannot change the preferred size.
    result = DipSize(width: nonNegative(effective.width),
      height: nonNegative(effective.height))
  else:
    let measured = ctx.measure(entity, effective)
    result = DipSize(width: nonNegative(measured.width),
      height: nonNegative(measured.height))
  ctx.visiting.excl(entity.handle)
  ctx.cache[key] = result

proc arrange(ctx: var LayoutContext, entity: MountedEntity, rect, clip: DipRect,
             result: var seq[LayoutBox]) =
  result.add LayoutBox(handle: entity.handle, rect: rect, clip: clip)
  if entity.kind notin {NodeKind.column, NodeKind.row, NodeKind.navigation}: return
  let horizontal = entity.kind == NodeKind.row
  let props = entity.props.layout
  let pad = props.padding.get(0.0)
  let gap = props.gap.get(0.0)
  let align = props.align.get(alignStart)
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
  let plan = allocateMain(ctx, entity, contentSize)

  let mainAvailable = mainOf(contentSize, horizontal)
  let leftover = nonNegative(mainAvailable - plan.mainTotal)
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
  for index, child in children:
    let childWidth = plan.widths[index]
    let childHeight = plan.heights[index]
    let childMain = if horizontal: childWidth else: childHeight
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

proc buildChildren(ctx: var LayoutContext,
                   entities: Table[NodeHandle, MountedEntity]) =
  ## One sibling index for a whole layout pass: never rebuilt per row.
  for entity in entities.values:
    ctx.children.mgetOrPut(entity.parent, @[]).add(entity)
  var parents: seq[NodeHandle]
  for parent in ctx.children.keys: parents.add(parent)
  for parent in parents:
    ctx.children[parent].sort(proc(a, b: MountedEntity): int = cmp(a.index, b.index))

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
  ctx.buildChildren(entities)

  let rootRect = DipRect(x: 0, y: 0,
    width: nonNegative(resolveRoot(root.props.layout.width, contentSize.width)),
    height: nonNegative(resolveRoot(root.props.layout.height, contentSize.height)))
  let rootClip = DipRect(x: 0, y: 0, width: contentSize.width,
    height: contentSize.height)
  var boxes: seq[LayoutBox]
  arrange(ctx, root, rootRect, rootClip, boxes)
  boxes

type
  LayoutScope* = object
    ## Reusable layout context for repeated subtree calls (for example one
    ## native row per list viewport). The sibling index, the handle index and
    ## the measurement cache are built once, so laying out many rows never
    ## rebuilds or rescans the whole entity table. Callers own the scope; a
    ## changed entity table needs a new one. This is an internal reuse seam, not
    ## a second layout engine.
    ctx: LayoutContext
    byHandle: Table[NodeHandle, MountedEntity]

proc initLayoutScope*(entities: Table[NodeHandle, MountedEntity],
                      measure: MeasureProc): LayoutScope =
  if measure == nil: fail("layout scope requires a measure proc")
  result.ctx.measure = measure
  result.ctx.buildChildren(entities)
  for entity in entities.values: result.byHandle[entity.handle] = entity

proc findEntity(scope: LayoutScope, root: NodeHandle): MountedEntity =
  ## O(1) lookup in the scope's own handle index; no per-row rescan.
  if root == NoHandle: return
  scope.byHandle.getOrDefault(root)

proc measureSubtree*(scope: var LayoutScope, root: NodeHandle,
                     available: DipSize): DipSize =
  ## Preferred size of one accepted subtree inside a finite local constraint.
  ## The root does not have to be the table root and its parent is irrelevant.
  let node = scope.findEntity(root)
  if node.handle == NoHandle: fail("layout subtree root is not in the table")
  let size = DipSize(width: nonNegative(available.width),
    height: nonNegative(available.height))
  result = contentIntrinsic(scope.ctx, node, size)
  # A subtree root has no parent to apply its declared fixed extents, so honour
  # them here exactly like `layoutTree` does for the table root.
  let width = node.props.layout.width
  if width.isSome and width.get.kind == dkFixed:
    result.width = nonNegative(width.get.value)
  let height = node.props.layout.height
  if height.isSome and height.get.kind == dkFixed:
    result.height = nonNegative(height.get.value)

proc validateRect(rect: DipRect, what: string) =
  ## Subtree geometry inputs must be finite and non-negative; finite negative
  ## offsets stay legal because scrolled-out boxes are clipped, not rejected.
  for value in [rect.x, rect.y, rect.width, rect.height]:
    if classify(value) in {fcNan, fcInf, fcNegInf}:
      fail(what & " is not finite")
  if rect.width < 0.0 or rect.height < 0.0:
    fail(what & " extent is negative")

proc layoutSubtree*(scope: var LayoutScope, root: NodeHandle, rect,
                    clip: DipRect): seq[LayoutBox] =
  ## Lay out one accepted subtree into `rect`, clipped by `clip`. The root needs
  ## no parentless identity, so a list row or a nested list can be laid out as
  ## its own finite viewport without re-rooting the accepted tree.
  validateRect(rect, "layout rect")
  validateRect(clip, "layout clip")
  let node = scope.findEntity(root)
  if node.handle == NoHandle: fail("layout subtree root is not in the table")
  var boxes: seq[LayoutBox]
  arrange(scope.ctx, node, rect, clip, boxes)
  boxes

proc measureSubtree*(entities: Table[NodeHandle, MountedEntity], root: NodeHandle,
                     available: DipSize, measure: MeasureProc): DipSize =
  ## Convenience wrapper: builds one scope for a single subtree measurement.
  var scope = initLayoutScope(entities, measure)
  scope.measureSubtree(root, available)

proc layoutSubtree*(entities: Table[NodeHandle, MountedEntity], root: NodeHandle,
                    rect, clip: DipRect, measure: MeasureProc): seq[LayoutBox] =
  ## Convenience wrapper: builds one scope for a single subtree layout.
  var scope = initLayoutScope(entities, measure)
  scope.layoutSubtree(root, rect, clip)

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