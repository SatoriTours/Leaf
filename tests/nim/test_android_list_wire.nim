## Independent field reader for LAV4, including typed list/row metadata.
import std/[unittest, options, tables]
import leaf/[core, backend, native_layout]
import leaf/backends/android/backend as android_backend
import leaf/backends/android/[list_layout, wire]
type Reader=object
  bytes:string
  at:int
proc u32(r:var Reader):uint32 =
  for shift in [0,8,16,24]:
    result=result or (uint32(ord(r.bytes[r.at])) shl shift);inc r.at
proc u64(r:var Reader):uint64 =
  for shift in [0,8,16,24,32,40,48,56]:
    result=result or (uint64(ord(r.bytes[r.at])) shl shift);inc r.at
proc number(r:var Reader):float64=cast[float64](r.u64())
proc string(r:var Reader):string =
  let count=int(r.u32())
  result=r.bytes[r.at..<r.at+count];r.at+=count
proc metadata(count=100,height=24.0):HostListProps =
  HostListProps(sourceGeneration:0x100000001'u64,itemCount:count,
    heightMode:HostHeightMode.uniform,rowHeight:height,estimate:height,overscan:2)
proc measure(e:MountedEntity,s:DipSize):DipSize=DipSize(width:s.width,height:24)
proc makeFrame(count=100,height=24.0,withRow=true):AndroidFrame =
  let p=metadata(count,height)
  var entities:Table[NodeHandle,MountedEntity]
  entities[NodeHandle(1)]=MountedEntity(handle:NodeHandle(1),kind:virtualList,
    nodeId:"list",list:some(p))
  if withRow:
    entities[NodeHandle(10)]=MountedEntity(handle:NodeHandle(10),parent:NodeHandle(1),
      kind:text,nodeId:"row",row:some(NativeRowBinding(listHandle:NodeHandle(1),
        sourceGeneration:p.sourceGeneration,itemIndex:7,itemKey:"key-中文😀")))
  let plan=newAndroidLists().prepareListLayout(entities,DipSize(width:300,height:96),measure,1,1)
  result=AndroidFrame(session:11,mount:12,revision:13,withLists:true,
    boxes:plan.boxes,listProjections:plan.projections)
  for h in [NodeHandle(1),NodeHandle(10)]:
    if not entities.hasKey(h):continue
    let e=entities[h]
    result.ops.add(UpdateOp(kind:opCreate,handle:h,parent:e.parent,index:e.index,
      nodeKind:e.kind,nodeId:e.nodeId,props:e.props,list:e.list,row:e.row))

suite "Android LAV4 list transport":
  test "full typed metadata and geometry preserve 64-bit source and UTF8 row keys":
    var r=Reader(bytes:encodeAndroidFrame(makeFrame()))
    let magic=r.u32()
    check magic==0x3456414c'u32
    if magic!=0x3456414c'u32:fail("LAV4 transport is missing")
    check r.u64()==11 and r.u64()==12 and r.u64()==13
    check r.u32()==2 and r.u32()==2
    for slot in 0..1:
      check r.u32()==0
      check r.u64()==(if slot==0:1'u64 else:10'u64)
      check r.u64()==(if slot==0:0'u64 else:1'u64)
      check r.u32()==0
      check r.u32()==(if slot==0:11'u32 else:2'u32)
      check r.u32()==1 and r.u32()==0
      check r.string()==(if slot==0:"list" else:"row")
      check r.string()=="" and r.string()=="" and r.string()==""
      check r.u32()==0 and r.number()==0
      check r.u32()==(if slot==0:1'u32 else:0'u32)
      if slot==0:
        check r.u64()==0x100000001'u64
        check r.u32()==100 and r.u32()==0
        check r.number()==24 and r.number()==24 and r.u32()==2
      check r.u32()==(if slot==0:0'u32 else:1'u32)
      if slot==1:
        check r.u64()==1 and r.u64()==0x100000001'u64
        check r.u32()==7 and r.string()=="key-中文😀"
    # Exact independent byte fields of the two global DIP boxes.
    check r.u64()==1
    for expected in [0.0,0,300,96,0,0,300,96]:check r.number()==expected
    check r.u64()==10
    for expected in [0.0,168,300,24,0,0,300,96]:check r.number()==expected
    check r.u32()==0 # editor writes
    check r.u32()==1 # list projections
    check r.u64()==1 and r.u64()==0x100000001'u64 and r.u64()==1
    check r.number()==0 and r.number()==2400 and r.number()==96
    check r.u32()==0 and r.u32()==4 and r.u32()==0
    check r.at==r.bytes.len

  test "logical 100k source serializes no height array or unmaterialized rows":
    let bytes=encodeAndroidFrame(makeFrame(100000,1000000,false))
    check bytes.len<512
    # The whole large logical list has just one op, one box and one projection.
    var r=Reader(bytes:bytes)
    let magic=r.u32()
    check magic==0x3456414c'u32
    if magic!=0x3456414c'u32:fail("LAV4 transport is missing")
    discard r.u64();discard r.u64();discard r.u64()
    check r.u32()==1 and r.u32()==1
