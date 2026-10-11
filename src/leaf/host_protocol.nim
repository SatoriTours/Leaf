## Backend-neutral, owned host data. No callbacks or platform objects cross
## this boundary; platform-specific interpretation remains in the adapter.
import std/[options, tables, strutils, math]
import ./[core, styles, backend]
export backend.NodeHandle, backend.NoHandle

const
  EventClickMask* = 1'u32
  EventChangeMask* = 2'u32
  EventSubmitMask* = 4'u32

type
  HostStylePolicy* = enum gpuiCompatible, nativeStrict
  HostHeightMode* {.pure.} = enum uniform, variable
  HostListProps* = object
    sourceGeneration*: uint64
    itemCount*: int
    heightMode*: HostHeightMode
    rowHeight*, estimate*: float64
    overscan*: int
  HostProps* = object
    normalized*: NormalizedProps
    text*, placeholder*: string
    eventMask*: uint32
    list*: Option[HostListProps]
  HostBoundary* = object
    id*: uint64
    root*: NodeHandle
    parent*: uint64
    layout*: LayoutProps
  HostWindow* = object
    title*: string
    width*, height*: int
  HostOpKind* {.pure.} = enum
    create = 1, update, setChildren, remove, boundary, window
  HostOp* = object
    kind*: HostOpKind
    handle*, parent*: NodeHandle
    nodeId*: string
    nodeKind*: NodeKind
    props*: HostProps
    children*: seq[NodeHandle]
    boundary*: HostBoundary
    window*: HostWindow
  HostBatch* = object
    sessionId*, baseRevision*, nextRevision*: uint64
    ops*: seq[HostOp]
  UpdateStats* = object
    componentRenders*, visitedHosts*, normalizedHosts*, indexEdits*: uint64
    ops*, ffiBytes*, snapshotExports*: uint64

proc compatibleNode(node: Node): Node =
  # ABI 1 GPUI ignores unknown attributes and uses permissive widget defaults.
  # Keep that behavior while converting recognized properties once.
  var attrs: Styles
  for name, value in node.attributes:
    case name
    of "variant":
      if node.kind in {NodeKind.button, NodeKind.tag}:
        attrs[name] = if value in ["default", "primary", "danger", "success",
          "warning", "info", "outline", "ghost", "secondary"]: value
          else: "default"
    of "checked":
      if node.kind in {NodeKind.checkbox, NodeKind.toggle}:
        attrs[name] = if value == "true": "true" else: "false"
    of "value":
      if node.kind == NodeKind.progress:
        var number = 0.0
        try: number = parseFloat(value)
        except ValueError: discard
        if classify(number) in {fcNan, fcInf, fcNegInf}: number = 0
        attrs[name] = $clamp(number, 0.0, 100.0)
    of "input_reset_token":
      if node.kind == NodeKind.input: attrs[name] = value
    else: discard
  ui(node.kind, key=node.key, text=node.text, placeholder=node.placeholder,
    disabled=node.disabled, styles=node.styles, attributes=attrs,
    onClick=node.handler(click), onChange=node.handler(change),
    onSubmit=node.handler(submit))

proc normalizeHostProps*(node: Node, policy: HostStylePolicy): HostProps =
  if node == nil: fail("nil host description")
  result.text = node.text
  result.placeholder = node.placeholder
  result.normalized = normalizeProps(if policy == nativeStrict: node else: compatibleNode(node))
  if node.handler(click) != nil: result.eventMask = result.eventMask or EventClickMask
  if node.handler(change) != nil: result.eventMask = result.eventMask or EventChangeMask
  if node.handler(submit) != nil: result.eventMask = result.eventMask or EventSubmitMask
  let source = node.listSource
  if source != nil:
    result.list = some(HostListProps(sourceGeneration: source.generation,
      itemCount: source.len, heightMode: (if source.rowHeight > 0:
        HostHeightMode.uniform else: HostHeightMode.variable),
      rowHeight: source.rowHeight, estimate: source.estimatedHeight,
      overscan: source.overscan))
