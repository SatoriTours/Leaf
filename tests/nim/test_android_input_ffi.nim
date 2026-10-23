import std/[unittest]
import leaf/[core, components, component_description, component_state, widgets, managed_runtime]
import leaf/backends/android/ffi

var sid, eventMount, revision, handle:uint64
var state:State[string]
var calls, effects, resumes, pauses:int
var failEffects:bool
proc read64(data:ptr uint8,offset:int):uint64 {.raises:[].} =
  let bytes=cast[ptr UncheckedArray[uint8]](data)
  for i in 0..7: result=result or uint64(bytes[offset+i]) shl (i*8)
proc command(ctx:pointer,tag:uint32,data:ptr uint8,length:csize_t,
    w,h:cdouble,measured:ptr cdouble):int32 {.cdecl,raises:[].} =
  case tag
  of 1:
    let size=cast[ptr UncheckedArray[cdouble]](measured)
    size[0]=200;size[1]=40
  of 11:
    let size=cast[ptr UncheckedArray[cdouble]](measured)
    size[0]=0;size[1]=0
  of 2:
    if length<48: return 1
    sid=read64(data,4);eventMount=read64(data,12);revision=read64(data,20)
    if handle==0: handle=read64(data,40)
  of 6:
    sid=read64(data,4);eventMount=read64(data,12)
  of 8:
    inc effects
    if failEffects: return 1
  of 9: inc resumes
  of 10: inc pauses
  else: discard
  0
proc app():Application =
  let Page=defineComponent[int,State[string]]("InputAbi",
    proc(ctx:MountContext,p:int):State[string] =
      result=ctx.state("seed");state=result,
    proc(ctx:ComponentContext,p:int,s:State[string]):UiDescription =
      host(input(ctx.value(s),key="editor",onChange=proc(e:Event) =
        inc calls
        if e.value!="reject": discard s.set(e.value))))
  componentApplication(component(Page,0),"ABI",400,600)
proc fact(id,mount,seq:uint64,value:string,gen=1'u64,sidOverride=0'u64):int32 =
  let p=if value.len>0: cast[ptr uint8](unsafeAddr value[0]) else:nil
  leaf_android_input(id,mount,(if sidOverride==0:sid else:sidOverride),eventMount,
    handle,seq,revision,gen,1,p,csize_t(value.len),0,0,0)

suite "Android strict input ABI":
  test "malformed, future, stale and paused facts do not poison the next valid sequence":
    registerAndroidApplication(app)
    var cb=AndroidCallbacks(abiVersion:2,structSize:uint32(sizeof(AndroidCallbacks)),command:command)
    var id,mount:uint64
    check leaf_android_create(addr cb,addr id)==0
    check leaf_android_attach(id,400,600,1,addr mount)==0
    check leaf_android_phase(id,mount,AndroidResume)==0 and resumes==1
    check fact(id,mount,1,"\xC0\x80")==2
    check fact(id,mount,1,"\xED\xA0\x80")==2
    check leaf_android_input(id,mount,sid,eventMount,handle,1,revision,1,1,
      cast[ptr uint8](1),high(csize_t),0,0,0)==3
    check fact(id,mount,1,"foreign",sidOverride=sid+1)==AndroidRejected
    inc revision
    check fact(id,mount,1,"future")==AndroidRejected
    dec revision
    check leaf_android_phase(id,mount,AndroidPause)==0 and pauses==1
    check fact(id,mount,1,"paused")==AndroidRejected
    check leaf_android_phase(id,mount,AndroidTurn)==AndroidRejected and effects==0
    check leaf_android_phase(id,mount,AndroidResume)==0
    check fact(id,mount,1,"中文\0😀")==0
    check leaf_android_phase(id,mount,AndroidTurn)==0
    check calls==1 and state.readAccepted()=="中文\0😀"
    check fact(id,mount,1,"duplicate")==AndroidRejected
    check leaf_android_close(id)==0

  test "a no-diff edit settles through command 8 and native failure freezes further delivery":
    var cb=AndroidCallbacks(abiVersion:2,structSize:uint32(sizeof(AndroidCallbacks)),command:command)
    var id,mount:uint64
    handle=0
    check leaf_android_create(addr cb,addr id)==0
    check leaf_android_attach(id,400,600,1,addr mount)==0
    check leaf_android_phase(id,mount,AndroidResume)==0
    check fact(id,mount,1,"reject")==0
    check leaf_android_phase(id,mount,AndroidTurn)==0 and effects==1
    check state.readAccepted()=="seed"
    failEffects=true
    check fact(id,mount,2,"reject")==0
    discard leaf_android_phase(id,mount,AndroidTurn)
    check effects==2
    check fact(id,mount,3,"unreachable")==AndroidRejected
    check leaf_android_phase(id,mount,AndroidTurn)==AndroidRejected
    failEffects=false
    check leaf_android_close(id)==0
