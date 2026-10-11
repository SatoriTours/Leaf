import std/unittest
import leaf/[core, gpui_ffi_v2]
suite "GPUI ABI 2 ownership":
  test "empty batch owns its buffers and keeps revision":
    var data = encodeBatch(HostBatch(sessionId:1,baseRevision:2,nextRevision:3))
    let raw = data.borrow()
    check raw.abi == 2
    check raw.session_id == 1
    check raw.base_revision == 2
    check raw.next_revision == 3
    check raw.ops_len == 0
    check raw.ops == nil

{.compile: "../ffi/gpui_v2_callback.c".}
proc leaf_test_prepare_call(api: ptr LeafRendererApi, ctx:pointer):int32 {.importc,cdecl.}
proc countPrepare(ctx:pointer, batch:ptr LeafBatch,error:ptr LeafError):int32 {.cdecl.} =
  if ctx == nil or batch != nil or error != nil: return 1
  cast[ptr int](ctx)[] += 7
  0

suite "GPUI ABI 2 callback and data ownership":
  test "C invokes Nim prepare with the same calling convention":
    var count=0
    var api=LeafRendererApi(struct_size:uint32(sizeof(LeafRendererApi)),abi:2,prepare:countPrepare)
    check leaf_test_prepare_call(addr api, addr count) == 0
    check count == 7
  test "UTF-8 arena owns a copy after source properties are changed":
    var batch=HostBatch(sessionId:1,nextRevision:1,ops: @[])
    batch.ops.add(HostOp(kind:HostOpKind.create,nodeKind:NodeKind.text,
      handle:NodeHandle(1),nodeId:"中文",props:HostProps(text:"你好")))
    var encoded=encodeBatch(batch)
    batch.ops[0].props.text[0]='!'
    let raw=encoded.borrow()
    let op=cast[ptr UncheckedArray[LeafOp]](raw.ops)[0]
    let bytes=cast[ptr UncheckedArray[uint8]](raw.strings)
    var copied=newString(int(op.props.text.len))
    for i in 0..<copied.len:copied[i]=char(bytes[int(op.props.text.offset)+i])
    check copied == "你好"
    check op.props.text.len == 6
  test "aggregate child arena is bounded before encoding":
    var batch = HostBatch(sessionId: 1, nextRevision: 1)
    let children = newSeq[NodeHandle](10000)
    for i in 0..<1000:
      batch.ops.add(HostOp(kind: HostOpKind.setChildren,
        handle: NodeHandle(uint64(i+1)), children: children))
    expect UiError:
      discard encodeBatch(batch)
