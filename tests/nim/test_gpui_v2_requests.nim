{.define:leafProtocolProbes.}
import std/[unittest, os, osproc, dynlib]
import leaf/[core, widgets, backend, gpui_api, gpui_ffi_v2, gpui_session]
type TestScript=proc(config:ptr LeafConfig,host:ptr LeafHostCallbacks,ctx:pointer,error:ptr LeafError):int32 {.cdecl.}
var rt:Runtime
var scenario:int
proc script(config:ptr LeafConfig,host:ptr LeafHostCallbacks,ctx:pointer,error:ptr LeafError):int32 {.cdecl.}=
  var reply=LeafReply(struct_size:uint32(sizeof(LeafReply)))
  var request=LeafRequest(struct_size:uint32(sizeof(LeafRequest)),session_id:config.session_id)
  if scenario==0:
    let before=rt.stats.renders
    let jsonBefore=snapshotJsonCalls
    for tag in [LEAF_REQUEST_STATUS,LEAF_REQUEST_RENDERING,LEAF_REQUEST_FRAME]:
      request.tag=uint32(tag);request.scale=1;request.width=640;request.height=480
      check host.request(ctx,addr request,addr reply,error)==0
      check reply.accepted_revision==rt.acceptedRevision
      check reply.rows_len==0
    check rt.stats.renders==before
    check snapshotJsonCalls==jsonBefore
    request.tag=uint32(LEAF_REQUEST_EVENT);request.handle=2;request.sequence=1
    request.revision=rt.acceptedRevision;request.generation=1;request.binding_generation=1
    check host.request(ctx,addr request,addr reply,error)==0
  elif scenario==1:
    request.tag=uint32(LEAF_REQUEST_VIEWPORT);request.handle=1
    request.generation=rt.find("items").node.listSource.generation
    request.first=5000;request.finish=5050
    check host.request(ctx,addr request,addr reply,error)==0
    check reply.rows_len==50
  elif scenario==2:
    request.tag=uint32(LEAF_REQUEST_VIEWPORT);request.handle=1
    request.generation=rt.find("items").node.listSource.generation
    request.finish=1
    check host.request(ctx,addr request,addr reply,error)!=0
  elif scenario==3:
    request.tag=uint32(LEAF_REQUEST_VIEWPORT);request.handle=2
    request.generation=rt.find("items").node.listSource.generation
    request.finish=1
    check host.request(ctx,addr request,addr reply,error)==0
    let before=rt.acceptedRevision
    request=LeafRequest(struct_size:uint32(sizeof(LeafRequest)),session_id:config.session_id,
      tag:uint32(LEAF_REQUEST_EVENT),handle:3,sequence:1,revision:before,generation:1,binding_generation:1)
    check host.request(ctx,addr request,addr reply,error)!=0
    check rt.acceptedRevision==before
    check rt.find("items").children.len==1
  0
suite "typed requests keep JSON off the bridge":
  test "metadata is tree free, event callback and viewport are typed":
    createDir("target/ffi-v2")
    let path=absolutePath("target/ffi-v2/REQUESTS.so")
    check execCmd("gcc -shared -fPIC tests/ffi/gpui_v2_library.c -o " & quoteShell(path))==0
    let library=loadLib(path)
    defer:unloadLib(library)
    let setScript=cast[proc(value:TestScript) {.cdecl.}](symAddr(library,"leaf_test_set_script"))
    setScript(script)
    putEnv("LEAF_GPUI_ABI","2")
    defer:delEnv("LEAF_GPUI_ABI")
    let api=loadGpui(path)
    var count=0
    rt=newRuntime(Application(title:"请求",width:640,height:480,render:proc(c:BuildContext):Node=
      column(@[button("click",key="click",onClick=proc(e:Event)=inc count)])))
    scenario=0
    check openGpuiSession(rt,api).run()==0
    check count==1
    var built=0
    var keys:seq[string]
    for i in 0..<100000:keys.add($i)
    rt=newRuntime(Application(title:"列表",width:640,height:480,render:proc(c:BuildContext):Node=
      virtualList("items",keys,proc(i:int):Node=
        inc built
        text($i),rowHeight=30,overscan=0)))
    scenario=1
    check openGpuiSession(rt,api).run()==0
    check built==50
    rt=newRuntime(Application(title:"失败",width:640,height:480,render:proc(c:BuildContext):Node=
      virtualList("items",@["a"],proc(i:int):Node=raise newException(UiError,"row failed"))))
    scenario=2
    let failed=openGpuiSession(rt,api)
    check failed.run()!=0
    check failed.readyCalls==0

    var failRows=false
    rt=newRuntime(Application(title:"replacement",width:640,height:480,render:proc(c:BuildContext):Node=
      let broken=failRows
      column(@[
        virtualList("items",@["a"],proc(i:int):Node=
          if broken:raise newException(UiError,"replacement row failed")
          text("row")),
        button("break",key="break",onClick=proc(e:Event)=failRows=true)])))
    scenario=3
    check openGpuiSession(rt,api).run()!=0
    check failRows
