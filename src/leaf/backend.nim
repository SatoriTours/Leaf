## Backend-neutral native protocol: capabilities, typed update batches, entity
## handles and the synchronous Backend / Host contracts.
##
## This module owns no platform lifecycle, no FFI and no graphics imports. It
## turns the validated typed properties from `styles.nim` into the exact data a
## native backend needs, and declares which of those properties that backend
## can honour. Callbacks, Node references and native pointers never appear here.
import std/[tables, hashes, options, sets, unicode]
import ./[core, styles, list_protocol, navigation_protocol]
# `HostListProps` is a pure owned value; the backend stores the same type the
# host wire uses, without importing `host_protocol` (which would be a cycle).
export list_protocol, navigation_protocol

type
  CapabilityMode* = enum
    ## `compatible` degrades known decorations with a structured issue;
    ## `strict` refuses any undeclared property before mounting.
    compatible, strict

  NodeHandle* = distinct uint64
    ## Opaque, checked entity identity. Never a Nim object address.

  NativeRowBinding* = object
    ## Typed identity of one row root that is a direct child of a virtual list.
    ## A pure owned value: the root handle is the record/op/entity handle, and
    ## `itemIndex` is the list item index, never an active sibling position.
    ## `none` means "does not carry a direct list row", not "delete a subtree".
    listHandle*: NodeHandle
    sourceGeneration*: uint64
    itemIndex*: int
    itemKey*: string

  CapabilityIssue* = object
    nodeId*: string
    property*: string
    reason*: string

  LayoutFeature* = enum
    ## Required layout features. A backend that does not declare one must be
    ## rejected rather than silently approximating it.
    lfGap, lfPadding, lfWidth, lfHeight, lfFlexGrow, lfAlign, lfJustify,
    lfOverflow, lfMinMax, lfFlexShrink

  DecorationFeature* = enum
    ## Purely decorative properties: unknown/undeclared ones may degrade.
    dfColor, dfBackground, dfBorderColor, dfRadius, dfBorderWidth,
    dfOpacity, dfFontSize, dfWeight

  ControlFeature* = enum
    ## Explicit control behaviours a backend must declare. These are required
    ## capabilities: an undeclared one is rejected, never degraded.
    cfInputReset

  BackendCapabilities* = object
    ## Everything a backend explicitly supports. Extended enum values are
    ## listed individually so supporting `justify` never implies `around`.
    kinds*: set[NodeKind]
    layouts*: set[LayoutFeature]
    alignments*: set[Align]
    justifications*: set[Justify]
    overflows*: set[Overflow]
    decorations*: set[DecorationFeature]
    variants*: set[ControlVariant]
    kindVariants*: array[NodeKind, set[ControlVariant]]
      ## Additional variants supported only by a specific control kind.
    controls*: set[ControlFeature]

  MountedEntity* = object
    ## Backend-visible accepted entity. `props` are the complete normalized
    ## properties; `index` is the sibling position in the accepted tree.
    handle*: NodeHandle
    parent*: NodeHandle
    nodeId*: string
    kind*: NodeKind
    props*: NormalizedProps
    navigation*: Option[HostNavigationProps]
    list*: Option[HostListProps]
      ## Complete typed list description; `none` for ordinary controls.
    row*: Option[NativeRowBinding]
      ## Set only on a list's direct row root.
    index*: int

  UpdateKind* = enum
    opCreate, opUpdate, opMove, opRemove

  UpdateOp* = object
    ## A single batch operation. create/update carry complete typed properties;
    ## there is no callback, Node reference or platform pointer. `opRemove` is
    ## authoritative by `handle`; its `index` is historical and must not be
    ## used for sibling positioning.
    kind*: UpdateKind
    handle*: NodeHandle
    parent*: NodeHandle
    index*: int
    nodeId*: string
    nodeKind*: NodeKind
    props*: NormalizedProps
    navigation*: Option[HostNavigationProps]
    list*: Option[HostListProps]
      ## create/update carry the accepted list facts (`none` for ordinary
      ## controls); move/remove never use it.
    row*: Option[NativeRowBinding]
      ## create/update/move carry the row binding of a list row root (`none`
      ## otherwise). The native host consumes this owned sidecar directly.

  RowSlotTable* = Table[NodeHandle, tuple[indexes: HashSet[int],
    keys: HashSet[string]]]
    ## Per-list row slot accounting shared by the host reconciler and the native
    ## adapter, so both gates apply the same uniqueness rule.

  HostChildOrder* = object
    parent*:NodeHandle
    children*:seq[NodeHandle]
  HostAcceptedDelta* = object
    revision*:uint64
    upserts*:seq[MountedEntity]
    removals*:seq[NodeHandle]
    orders*:seq[HostChildOrder]
    issues*:seq[CapabilityIssue]
  UpdateBatch* = object
    revision*: uint64
    ops*: seq[UpdateOp]
    isDelta*:bool
    finalOrders*:seq[HostChildOrder]

  EventSettlement* = object
    ## UI metadata emitted after an event has been handled and the Runtime
    ## scope has fully returned. It carries no Node, callback or native handle
    ## beyond the opaque entity handle.
    sessionId*: uint64
    mountGeneration*: uint64
    bindingGeneration*: uint64
    sequence*: uint64
    revision*: uint64
    handle*: NodeHandle
    props*: NormalizedProps

  Backend* = ref object
    ## Synchronous backend contract. `prepare` must not mutate visible entities;
    ## `restore` remounts the accepted descriptions and rebuilds listener
    ## identity. A1 does not run platform lifecycle.
    capabilities*: BackendCapabilities
    prepare*: proc(batch: UpdateBatch) {.closure.}
    apply*: proc(batch: UpdateBatch) {.closure.}
    discardPrepared*: proc() {.closure.}
    restore*: proc(entities: Table[NodeHandle, MountedEntity]) {.closure.}
    dispose*: proc() {.closure.}
    accepted*: proc(entities: Table[NodeHandle, MountedEntity],
                     revision: uint64) {.closure, raises: [].}
    acceptedDelta*:proc(delta:HostAcceptedDelta) {.closure,raises:[].}
    rebind*: proc(sessionId, mountGeneration: uint64) {.closure.}
    bindingValid*: proc(handle: NodeHandle, bindingGeneration: uint64): bool {.closure.}
    settle*: proc(value: EventSettlement) {.closure.}
    sessionOwner: uint64
    sessionCounter: uint64

  HostContext* = object
    sessionId*: uint64
    mountGeneration*: uint64
    contentWidth*, contentHeight*: float64
    scale*: float64

const NoHandle* = NodeHandle(0)

proc reserveSession*(backend: Backend): uint64 =
  ## Claim this instance's resources before mounting. A Backend cannot be
  ## shared by live sessions, including sessions on different Runtimes.
  if backend.sessionOwner != 0: fail("backend already owned by a session")
  inc backend.sessionCounter
  backend.sessionOwner = backend.sessionCounter
  backend.sessionOwner

proc ownsSession*(backend: Backend, owner: uint64): bool =
  owner != 0 and backend.sessionOwner == owner

proc releaseSession*(backend: Backend, owner: uint64) =
  ## Release only after resources have been disposed successfully. A stale
  ## owner cannot release a later session's reservation.
  if backend.ownsSession(owner): backend.sessionOwner = 0

proc `==`*(a, b: NodeHandle): bool {.borrow.}
proc `<`*(a, b: NodeHandle): bool {.borrow.}
proc hash*(handle: NodeHandle): Hash {.borrow.}
proc cmp*(a, b: NodeHandle): int = cmp(uint64(a), uint64(b))
proc `$`*(handle: NodeHandle): string = $uint64(handle)
proc raw*(handle: NodeHandle): uint64 = uint64(handle)

proc rowBindingReason*(binding: NativeRowBinding, meta: HostListProps,
                       parent, root: NodeHandle): string =
  ## "" when one row binding is internally consistent for `parent`/`root`.
  ## Shared by every gate so the shape rules cannot drift.
  if binding.listHandle == NoHandle: return "row binding has no list handle"
  if root == NoHandle: return "row binding has no row root"
  if parent != binding.listHandle:
    return "row root is not a direct child of its list"
  if meta.sourceGeneration != binding.sourceGeneration:
    return "row binding is stale for its list source"
  if binding.itemIndex < 0 or binding.itemIndex >= meta.itemCount:
    return "row index is outside its list source"
  if binding.itemKey.len > MaxStringBytes: return "row key exceeds 1 MiB"
  if validateUtf8(binding.itemKey) != -1: return "row key is not valid UTF-8"
  ""

proc reserveRowSlot*(slots: var RowSlotTable, binding: NativeRowBinding): string =
  ## Reserve one (index, key) pair inside its list. Returns "" when it is free,
  ## otherwise the structured reason; shared by both candidate gates.
  var entry = slots.mgetOrPut(binding.listHandle,
    (initHashSet[int](), initHashSet[string]()))
  if binding.itemIndex in entry.indexes: return "duplicate row index in one list"
  if binding.itemKey in entry.keys: return "duplicate row key in one list"
  entry.indexes.incl(binding.itemIndex)
  entry.keys.incl(binding.itemKey)
  slots[binding.listHandle] = entry
  ""

proc fullCapabilities*(): BackendCapabilities =
  ## Capabilities of a backend that supports every A1 property. Backends should
  ## start from this and remove what they cannot honour.
  BackendCapabilities(
    kinds: {column, row, text, button, input, checkbox, toggle, progress, tag,
      separator, spinner, virtualList, navigation},
    layouts: {lfGap, lfPadding, lfWidth, lfHeight, lfFlexGrow, lfAlign,
      lfJustify, lfOverflow, lfMinMax, lfFlexShrink},
    alignments: {alignStart, alignEnd, alignCenter, alignStretch},
    justifications: {justifyStart, justifyEnd, justifyCenter, justifyBetween,
      justifyAround, justifyEvenly},
    overflows: {overflowScroll, overflowHidden, overflowVisible},
    decorations: {dfColor, dfBackground, dfBorderColor, dfRadius, dfBorderWidth,
      dfOpacity, dfFontSize, dfWeight},
    variants: {variantDefault, variantPrimary, variantDanger, variantSuccess,
      variantWarning, variantInfo, variantOutline, variantGhost, variantSecondary},
    controls: {cfInputReset})

proc supportsVariant(capabilities: BackendCapabilities, variant: ControlVariant,
                     kind: Option[NodeKind]): bool =
  variant in capabilities.variants or
    (kind.isSome and variant in capabilities.kindVariants[kind.get])

proc checkTypedCapabilities*(nodeId:string,kind:NodeKind,props:NormalizedProps,capabilities:BackendCapabilities,mode=compatible):seq[CapabilityIssue]=
  var issues: seq[CapabilityIssue]

  proc report(nodeId, property, reason: string) =
    if mode == strict:
      fail("backend capability rejected " & property & " on " & nodeId & ": " & reason)
    issues.add(CapabilityIssue(nodeId: nodeId, property: property, reason: reason))

  if kind notin capabilities.kinds:
    fail("backend does not support control " & kind.kindName & ": " & nodeId)

  template requireLayout(feature: LayoutFeature, property: string) =
    if feature notin capabilities.layouts:
      fail("backend does not support required layout " & property & ": " & nodeId)

  if props.layout.gap.isSome: requireLayout(lfGap, "gap")
  if props.layout.padding.isSome: requireLayout(lfPadding, "padding")
  if props.layout.width.isSome: requireLayout(lfWidth, "width")
  if props.layout.height.isSome: requireLayout(lfHeight, "height")
  if props.layout.flexGrow.isSome: requireLayout(lfFlexGrow, "flex_grow")
  if props.layout.align.isSome: requireLayout(lfAlign, "align")
  if props.layout.justify.isSome: requireLayout(lfJustify, "justify")
  if props.layout.overflow.isSome: requireLayout(lfOverflow, "overflow")
  if props.layout.minWidth.isSome or props.layout.minHeight.isSome or
      props.layout.maxWidth.isSome or props.layout.maxHeight.isSome:
    requireLayout(lfMinMax, "min/max")
  if props.layout.flexShrink.isSome: requireLayout(lfFlexShrink, "flex_shrink")

  if props.layout.align.isSome and props.layout.align.get notin capabilities.alignments:
    fail("backend does not support alignment " & $props.layout.align.get & ": " & nodeId)
  if props.layout.justify.isSome and
      props.layout.justify.get notin capabilities.justifications:
    fail("backend does not support justification " &
      $props.layout.justify.get & ": " & nodeId)
  if props.layout.overflow.isSome and
      props.layout.overflow.get notin capabilities.overflows:
    fail("backend does not support overflow " & $props.layout.overflow.get & ": " & nodeId)

  if props.decoration.color.isSome and dfColor notin capabilities.decorations:
    report(nodeId, "color", "decoration not supported")
  if props.decoration.background.isSome and dfBackground notin capabilities.decorations:
    report(nodeId, "background", "decoration not supported")
  if props.decoration.borderColor.isSome and dfBorderColor notin capabilities.decorations:
    report(nodeId, "border_color", "decoration not supported")
  if props.decoration.radius.isSome and dfRadius notin capabilities.decorations:
    report(nodeId, "radius", "decoration not supported")
  if props.decoration.borderWidth.isSome and dfBorderWidth notin capabilities.decorations:
    report(nodeId, "border_width", "decoration not supported")
  if props.decoration.opacity.isSome and dfOpacity notin capabilities.decorations:
    report(nodeId, "opacity", "decoration not supported")
  if props.decoration.fontSize.isSome and dfFontSize notin capabilities.decorations:
    report(nodeId, "font_size", "decoration not supported")
  if props.decoration.weight.isSome and dfWeight notin capabilities.decorations:
    report(nodeId, "weight", "decoration not supported")
  if props.control.variant.isSome and
      not supportsVariant(capabilities, props.control.variant.get, some(kind)):
    report(nodeId, "variant", "variant not supported")
  # Required control behaviour: never degraded, even in compatible mode.
  if props.control.resetToken.isSome and props.control.resetToken.get != 0 and
      cfInputReset notin capabilities.controls:
    fail("backend does not support input reset token: " & nodeId)

  issues

proc checkCapabilities*(root: MountedNode, capabilities: BackendCapabilities,
                        mode = compatible): seq[CapabilityIssue] =
  ## Validate a mounted tree against a backend's declared capabilities.
  ## Missing required controls, required layout, extended enum values and
  ## min/max/flex_shrink are always `UiError`. Undeclared decorations and
  ## variants return structured issues in `compatible` and raise in `strict`.
  var issues: seq[CapabilityIssue]

  proc visit(mounted:MountedNode)=
    issues.add(checkTypedCapabilities(mounted.id,mounted.node.kind,normalizeProps(mounted.node),capabilities,mode))
    for child in mounted.children: visit(child)

  visit(root)
  issues

proc effectiveProps*(capabilities: BackendCapabilities,
                     props: NormalizedProps,
                     kind = none(NodeKind)): NormalizedProps =
  ## Typed capability adapter: remove decorations and variants this backend did
  ## not declare, so each backend applies its own effective properties without
  ## re-parsing strings. Required layout is left untouched and must already
  ## have passed `checkCapabilities`. Omitted kind retains the legacy global-only
  ## filtering contract; native adapters pass the real kind for scoped variants.
  result = props
  if dfColor notin capabilities.decorations: result.decoration.color = none(Rgba)
  if dfBackground notin capabilities.decorations: result.decoration.background = none(Rgba)
  if dfBorderColor notin capabilities.decorations: result.decoration.borderColor = none(Rgba)
  if dfRadius notin capabilities.decorations: result.decoration.radius = none(float64)
  if dfBorderWidth notin capabilities.decorations: result.decoration.borderWidth = none(float64)
  if dfOpacity notin capabilities.decorations: result.decoration.opacity = none(float64)
  if dfFontSize notin capabilities.decorations: result.decoration.fontSize = none(float64)
  if dfWeight notin capabilities.decorations: result.decoration.weight = none(FontWeight)
  if result.control.variant.isSome and
      not supportsVariant(capabilities, result.control.variant.get, kind):
    result.control.variant = none(ControlVariant)
