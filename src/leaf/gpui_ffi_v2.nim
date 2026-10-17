## C-compatible ABI 2. Keep in sync with include/leaf_gpui_v2.h.
import std/[options, unicode]
import ./[core, styles, backend, host_protocol]
export host_protocol
const
  LEAF_V2_ABI* = 2'u64
  LEAF_V2_MAX_WIRE_BYTES* = 67108864'u64
  LEAF_V2_MAX_OPS* = 40064'u64
  LEAF_V2_MAX_NODES* = 10000'u64
  LEAF_V2_MAX_DEPTH* = 64'u64
  LEAF_V2_MAX_STRING* = 1048576'u64
  LEAF_V2_MAX_TREE* = 16777216'u64
  LEAF_V2_MAX_LIST* = 100000'u64
  LEAF_P_WIDTH* = 1'u64
  LEAF_P_HEIGHT* = 2'u64
  LEAF_P_GAP* = 4'u64
  LEAF_P_PADDING* = 8'u64
  LEAF_P_FLEX_GROW* = 16'u64
  LEAF_P_FLEX_SHRINK* = 32'u64
  LEAF_P_MIN_WIDTH* = 64'u64
  LEAF_P_MIN_HEIGHT* = 128'u64
  LEAF_P_MAX_WIDTH* = 256'u64
  LEAF_P_MAX_HEIGHT* = 512'u64
  LEAF_P_RADIUS* = 1024'u64
  LEAF_P_BORDER_WIDTH* = 2048'u64
  LEAF_P_OPACITY* = 4096'u64
  LEAF_P_FONT_SIZE* = 8192'u64
  LEAF_P_PROGRESS* = 16384'u64
  LEAF_P_COLOR* = 32768'u64
  LEAF_P_BACKGROUND* = 65536'u64
  LEAF_P_BORDER_COLOR* = 131072'u64
  LEAF_P_ALIGN* = 262144'u64
  LEAF_P_JUSTIFY* = 524288'u64
  LEAF_P_OVERFLOW* = 1048576'u64
  LEAF_P_WEIGHT* = 2097152'u64
  LEAF_P_VARIANT* = 4194304'u64
  LEAF_P_ENABLED* = 8388608'u64
  LEAF_P_CHECKED* = 16777216'u64
  LEAF_P_RESET* = 33554432'u64
  LEAF_P_LIST* = 67108864'u64
  LEAF_STATUS_OK* = 0'u64
  LEAF_STATUS_INVALID* = 1'u64
  LEAF_STATUS_INCOMPATIBLE* = 2'u64
  LEAF_STATUS_STALE* = 3'u64
  LEAF_STATUS_FAULTED* = 4'u64
  LEAF_STATUS_REJECTED* = 5'u64
  LEAF_STATUS_ACCEPTED_SCOPE_ERROR* = 6'u64
  LEAF_OP_CREATE* = 1'u64
  LEAF_OP_UPDATE* = 2'u64
  LEAF_OP_SET_CHILDREN* = 3'u64
  LEAF_OP_REMOVE* = 4'u64
  LEAF_OP_BOUNDARY* = 5'u64
  LEAF_OP_WINDOW* = 6'u64
  LEAF_REQUEST_EVENT* = 1'u64
  LEAF_REQUEST_VIEWPORT* = 2'u64
  LEAF_REQUEST_STATUS* = 3'u64
  LEAF_REQUEST_READY* = 4'u64
  LEAF_REQUEST_LOCATE* = 5'u64
  LEAF_REQUEST_RENDERING* = 6'u64
  LEAF_CAP_TASK_PUMP* = 1'u64
  LEAF_CONFIG_TASK_PUMP* = 2'u64
  LEAF_REPLY_TASKS_PENDING* = 4'u64
  LEAF_REQUEST_TASKS* = 8'u64
  LEAF_REQUEST_FRAME* = 7'u64
type
  LeafPrepareFn* = proc(ctx: pointer, batch: ptr LeafBatch, error: ptr LeafError): int32 {.cdecl, raises: [].}
  LeafApplyFn* = proc(ctx: pointer, error: ptr LeafError): int32 {.cdecl, raises: [].}
  LeafAcceptFn* = proc(ctx: pointer, revision: uint64) {.cdecl, raises: [].}
  LeafDiscardFn* = proc(ctx: pointer) {.cdecl, raises: [].}
  LeafAttachFn* = proc(ctx: pointer, api: ptr LeafRendererApi, renderer_ctx: pointer, error: ptr LeafError): int32 {.cdecl, raises: [].}
  LeafRequestFn* = proc(ctx: pointer, request: ptr LeafRequest, reply: ptr LeafReply, error: ptr LeafError): int32 {.cdecl, raises: [].}
  LeafDetachFn* = proc(ctx: pointer) {.cdecl, raises: [].}
  LeafRunFn* = proc(config: ptr LeafConfig, callbacks: ptr LeafHostCallbacks, ctx: pointer, error: ptr LeafError): int32 {.cdecl, raises: [].}
  LeafBytes* {.bycopy.} = object
    `ptr`*: ptr uint8
    len*: uint64
  LeafSpan* {.bycopy.} = object
    offset*: uint64
    len*: uint64
  LeafError* {.bycopy.} = object
    `ptr`*: ptr uint8
    capacity*: uint64
    written*: uint64
  LeafDimension* {.bycopy.} = object
    tag*: uint32
    reserved*: uint32
    value*: float64
  LeafProps* {.bycopy.} = object
    present*: uint64
    width*: LeafDimension
    height*: LeafDimension
    numbers*: array[13, float64]
    colors*: array[3, uint32]
    align*: uint32
    justify*: uint32
    overflow*: uint32
    weight*: uint32
    variant*: uint32
    enabled*: uint32
    checked*: uint32
    event_mask*: uint32
    reset_token*: uint64
    text*: LeafSpan
    placeholder*: LeafSpan
    list_generation*: uint64
    list_count*: uint64
    height_mode*: uint32
    overscan*: uint32
    row_height*: float64
    estimate*: float64
  LeafOp* {.bycopy.} = object
    tag*: uint32
    kind*: uint32
    handle*: uint64
    parent*: uint64
    node_id*: LeafSpan
    props*: LeafProps
    children*: LeafSpan
    boundary_id*: uint64
    boundary_parent*: uint64
    width*: uint32
    height*: uint32
  LeafBatch* {.bycopy.} = object
    struct_size*: uint32
    abi*: uint32
    session_id*: uint64
    base_revision*: uint64
    next_revision*: uint64
    ops*: ptr LeafOp
    ops_len*: uint64
    children*: ptr uint64
    children_len*: uint64
    strings*: ptr uint8
    strings_len*: uint64
  LeafProtected* {.bycopy.} = object
    index*: uint64
    key*: LeafBytes
  LeafFrameSample* {.bycopy.} = object
    elapsed_ms*,draw_ms*,rust_prepare_ms*,rust_apply_ms*:float64
    host_renders*:uint64
  LeafRequest* {.bycopy.} = object
    struct_size*: uint32
    tag*: uint32
    session_id*: uint64
    handle*: uint64
    generation*: uint64
    binding_generation*: uint64
    sequence*: uint64
    revision*: uint64
    kind*: uint32
    composition*: uint32
    checked*: uint32
    reserved*: uint32
    first*: uint64
    finish*: uint64
    value*: LeafBytes
    protected_rows*: ptr LeafProtected
    protected_len*: uint64
    scale*: float64
    width*: float64
    height*: float64
  LeafRow* {.bycopy.} = object
    handle*: uint64
    index*: uint64
    key*: LeafBytes
  LeafReply* {.bycopy.} = object
    struct_size*: uint32
    status*: uint32
    accepted_revision*: uint64
    flags*: uint64
    rows*: ptr LeafRow
    rows_len*: uint64
    x*: float64
    y*: float64
    width*: float64
    height*: float64
    value*: LeafBytes
  LeafConfig* {.bycopy.} = object
    struct_size*: uint32
    flags*: uint32
    session_id*: uint64
    width*: uint32
    height*: uint32
    title*: LeafBytes
  LeafRendererApi* {.bycopy.} = object
    struct_size*: uint32
    abi*: uint32
    prepare*: LeafPrepareFn
    apply*: LeafApplyFn
    accept*: LeafAcceptFn
    `discard`*: LeafDiscardFn
  LeafHostCallbacks* {.bycopy.} = object
    struct_size*: uint32
    reserved*: uint32
    attach*: LeafAttachFn
    request*: LeafRequestFn
    detach*: LeafDetachFn
  LeafGpuiApiV2* {.bycopy.} = object
    struct_size*: uint32
    abi*: uint32
    capabilities*: uint64
    run*: LeafRunFn
  OwnedFfiBatch* = object
    header: LeafBatch
    ops: seq[LeafOp]
    children: seq[uint64]
    strings: string

proc appendText(data: var OwnedFfiBatch, value: string): LeafSpan =
  if value.len > MaxStringBytes or validateUtf8(value) != -1:
    fail("invalid ABI 2 UTF-8 string")
  if value.len > MaxTreeBytes - data.strings.len:
    fail("ABI 2 string arena exceeds description budget")
  result = LeafSpan(offset: uint64(data.strings.len),len: uint64(value.len))
  data.strings.add(value)

proc encodeProps(data: var OwnedFfiBatch, props: HostProps): LeafProps =
  let p = props.normalized
  template number(field, index, mask: untyped) =
    if field.isSome:
      result.present = result.present or mask
      result.numbers[index] = field.get
  template dimension(field, dest, mask: untyped) =
    if field.isSome:
      result.present = result.present or mask
      dest = LeafDimension(tag: uint32(ord(field.get.kind)),value:field.get.value)
  template tag(field, dest, mask: untyped) =
    if field.isSome:
      result.present = result.present or mask
      dest = uint32(ord(field.get))
  template color(field, index, mask: untyped) =
    if field.isSome:
      result.present = result.present or mask
      let c = field.get
      result.colors[index] = (uint32(c.r) shl 24) or (uint32(c.g) shl 16) or
        (uint32(c.b) shl 8) or uint32(c.a)
  dimension(p.layout.width,result.width,LEAF_P_WIDTH)
  dimension(p.layout.height,result.height,LEAF_P_HEIGHT)
  number(p.layout.gap,0,LEAF_P_GAP)
  number(p.layout.padding,1,LEAF_P_PADDING)
  number(p.layout.flexGrow,2,LEAF_P_FLEX_GROW)
  number(p.layout.flexShrink,3,LEAF_P_FLEX_SHRINK)
  number(p.layout.minWidth,4,LEAF_P_MIN_WIDTH)
  number(p.layout.minHeight,5,LEAF_P_MIN_HEIGHT)
  number(p.layout.maxWidth,6,LEAF_P_MAX_WIDTH)
  number(p.layout.maxHeight,7,LEAF_P_MAX_HEIGHT)
  number(p.decoration.radius,8,LEAF_P_RADIUS)
  number(p.decoration.borderWidth,9,LEAF_P_BORDER_WIDTH)
  number(p.decoration.opacity,10,LEAF_P_OPACITY)
  number(p.decoration.fontSize,11,LEAF_P_FONT_SIZE)
  number(p.control.progress,12,LEAF_P_PROGRESS)
  color(p.decoration.color,0,LEAF_P_COLOR)
  color(p.decoration.background,1,LEAF_P_BACKGROUND)
  color(p.decoration.borderColor,2,LEAF_P_BORDER_COLOR)
  tag(p.layout.align,result.align,LEAF_P_ALIGN)
  tag(p.layout.justify,result.justify,LEAF_P_JUSTIFY)
  tag(p.layout.overflow,result.overflow,LEAF_P_OVERFLOW)
  tag(p.decoration.weight,result.weight,LEAF_P_WEIGHT)
  tag(p.control.variant,result.variant,LEAF_P_VARIANT)
  tag(p.control.enabled,result.enabled,LEAF_P_ENABLED)
  tag(p.control.checked,result.checked,LEAF_P_CHECKED)
  if p.control.resetToken.isSome:
    result.present = result.present or LEAF_P_RESET
    result.reset_token = p.control.resetToken.get
  result.event_mask = props.eventMask
  result.text = data.appendText(props.text)
  result.placeholder = data.appendText(props.placeholder)
  if props.list.isSome:
    let list = props.list.get
    if list.itemCount < 0 or list.overscan < 0:
      fail("negative ABI 2 list count")
    result.present = result.present or LEAF_P_LIST
    result.list_generation = list.sourceGeneration
    result.list_count = uint64(list.itemCount)
    result.height_mode = uint32(ord(list.heightMode))
    result.overscan = uint32(list.overscan)
    result.row_height = list.rowHeight
    result.estimate = list.estimate

proc encodeBatch*(batch: HostBatch): OwnedFfiBatch =
  if batch.ops.len > int(LEAF_V2_MAX_OPS): fail("too many ABI 2 operations")
  # Reject the aggregate child pool before reserving or copying its memory.
  var reserved = uint64(sizeof(LeafBatch)) + uint64(batch.ops.len) * uint64(sizeof(LeafOp))
  for op in batch.ops:
    if op.kind == HostOpKind.setChildren:
      let bytes = uint64(op.children.len) * uint64(sizeof(uint64))
      if bytes > LEAF_V2_MAX_WIRE_BYTES - reserved:
        fail("ABI 2 batch exceeds wire budget")
      reserved += bytes
  # Text has a separate 16 MiB limit; reserve that headroom only as it is used.
  result.header = LeafBatch(struct_size: uint32(sizeof(LeafBatch)),
    abi:uint32(LEAF_V2_ABI),session_id:batch.sessionId,
    base_revision:batch.baseRevision,next_revision:batch.nextRevision)
  result.ops = newSeqOfCap[LeafOp](batch.ops.len)
  for op in batch.ops:
    var encoded = LeafOp(tag:uint32(ord(op.kind)),kind:uint32(ord(op.nodeKind)),
      handle:op.handle.raw,parent:op.parent.raw)
    case op.kind
    of HostOpKind.create, HostOpKind.update:
      encoded.node_id = result.appendText(op.nodeId)
      encoded.props = result.encodeProps(op.props)
    of HostOpKind.setChildren:
      if op.children.len > MaxNodes: fail("too many ABI 2 children")
      encoded.children = LeafSpan(offset:uint64(result.children.len),len:uint64(op.children.len))
      for child in op.children: result.children.add(child.raw)
    of HostOpKind.remove: discard
    of HostOpKind.boundary:
      encoded.boundary_id = op.boundary.id
      encoded.boundary_parent = op.boundary.parent
      encoded.handle = op.boundary.root.raw
      encoded.props = result.encodeProps(HostProps(normalized:NormalizedProps(layout:op.boundary.layout)))
    of HostOpKind.window:
      if op.window.width notin 1..16384 or op.window.height notin 1..16384:
        fail("invalid ABI 2 window size")
      encoded.width = uint32(op.window.width)
      encoded.height = uint32(op.window.height)
      encoded.props.text = result.appendText(op.window.title)
    result.ops.add(encoded)
    if uint64(result.strings.len) > LEAF_V2_MAX_WIRE_BYTES - reserved:
      fail("ABI 2 batch exceeds wire budget")

proc borrow*(data: var OwnedFfiBatch): ptr LeafBatch =
  data.header.ops = if data.ops.len == 0: nil else: addr data.ops[0]
  data.header.ops_len = uint64(data.ops.len)
  data.header.children = if data.children.len == 0: nil else: addr data.children[0]
  data.header.children_len = uint64(data.children.len)
  data.header.strings = if data.strings.len == 0: nil else: cast[ptr uint8](addr data.strings[0])
  data.header.strings_len = uint64(data.strings.len)
  addr data.header

proc wireBytes*(data: OwnedFfiBatch): uint64 =
  uint64(sizeof(LeafBatch) + data.ops.len*sizeof(LeafOp) +
    data.children.len*sizeof(uint64) + data.strings.len)
