{.define:leafProtocolProbes.}
import std/[unittest, os, osproc, dynlib, json, tempfiles, math]
import leaf/[core, widgets, backend, gpui_api, gpui_ffi_v2, gpui_session,components,host_reconcile,managed_runtime,watch_ipc,diagnostics]
type TestScript=proc(config:ptr LeafConfig,host:ptr LeafHostCallbacks,ctx:pointer,error:ptr LeafError):int32 {.cdecl.}
var rt:Runtime
var scenario:int
var watchStatusPath:string
var renderingLog,renderingReceipt,receiptBefore,receiptAfter:string
var renderingStatuses:seq[int32]
var rejectViewportExit:bool
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
  elif scenario==4:
    let id=rt.find("items").id
    request.tag=uint32(LEAF_REQUEST_VIEWPORT)
    request.handle=rt.managedReconciler.handleFor(id).raw
    request.generation=rt.find("items").node.listSource.generation
    request.finish=50
    check host.request(ctx,addr request,addr reply,error)==0
    check reply.rows_len==50
    let keysBefore=sourceKeyReadCalls
    let before=rt.updateStats()
    discard rt.dispatch("counter",Event(kind:click))
    check sourceKeyReadCalls==keysBefore
    check rt.updateStats().componentRenders-before.componentRenders==1
    check rt.updateStats().snapshotExports==before.snapshotExports
    check rt.find("items").children.len==50
  elif scenario==5:
    let before=rt.updateStats()
    request.tag=uint32(LEAF_REQUEST_STATUS)
    for message in ["", "编译失败: expected expression", ""]:
      writeStatus(watchStatusPath,1,message)
      check host.request(ctx,addr request,addr reply,error)==0
      check (reply.flags and 2'u64)!=0
      check reply.value.len==uint64(message.len)
      if reply.value.len>0:
        var actual=newString(int(reply.value.len))
        copyMem(addr actual[0],reply.value.`ptr`,actual.len)
        check actual==message
      check reply.rows_len==0
    check rt.updateStats().componentRenders==before.componentRenders
    check rt.updateStats().snapshotExports==before.snapshotExports
  elif scenario==6:
    request.tag=uint32(LEAF_REQUEST_VIEWPORT);request.handle=1
    request.generation=rt.find("items").node.listSource.generation
    request.finish=1
    let before=rt.acceptedRevision
    rejectViewportExit=true
    check host.request(ctx,addr request,addr reply,error)==int32(LEAF_STATUS_ACCEPTED_SCOPE_ERROR)
    rejectViewportExit=false
    check reply.accepted_revision==before+1
    check reply.rows_len==1
    check rt.find("items").children.len==1
  elif scenario==7:
    request.tag=uint32(LEAF_REQUEST_RENDERING)
    request.scale=1.5;request.width=640;request.height=480
    check host.request(ctx,addr request,addr reply,error)==0
    check host.request(ctx,addr request,addr reply,error)==0
    request.tag=uint32(LEAF_REQUEST_READY)
    check host.request(ctx,addr request,addr reply,error)==0
    receiptBefore=readFile(renderingReceipt)
    request.tag=uint32(LEAF_REQUEST_RENDERING)
    request.width=800;request.height=600
    check host.request(ctx,addr request,addr reply,error)==0
    check host.request(ctx,addr request,addr reply,error)==0
    request.scale=2
    check host.request(ctx,addr request,addr reply,error)==0
    check host.request(ctx,addr request,addr reply,error)==0
    request.tag=uint32(LEAF_REQUEST_FRAME)
    request.scale=3;request.width=900;request.height=700
    check host.request(ctx,addr request,addr reply,error)==0
    receiptAfter=readFile(renderingReceipt)
  elif scenario==8:
    renderingStatuses.setLen(0)
    request.tag=uint32(LEAF_REQUEST_RENDERING)
    request.scale=1;request.width=640;request.height=480
    for invalid in [0.0,NaN,Inf]:
      request.scale=invalid
      renderingStatuses.add(host.request(ctx,addr request,addr reply,error))
    request.scale=1e308;request.width=1e308
    renderingStatuses.add(host.request(ctx,addr request,addr reply,error))
    request.scale=1.5;request.width=640
    renderingStatuses.add(host.request(ctx,addr request,addr reply,error))
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
    built=0
    rt=newRuntime(componentApplication(componentList("items",keys,proc(i:int):UiDescription=
      inc built
      host(text($i)),rowHeight=30,overscan=0),"托管列表"))
    let exports=rt.updateStats().snapshotExports
    check openGpuiSession(rt,api).run()==0
    check built==50
    check rt.updateStats().snapshotExports==exports

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

  test "unrelated counter does not visit a mounted list source":
    let path=absolutePath("target/ffi-v2/REQUESTS.so")
    let library=loadLib(path)
    defer:unloadLib(library)
    cast[proc(value:TestScript) {.cdecl.}](symAddr(library,"leaf_test_set_script"))(script)
    putEnv("LEAF_GPUI_ABI","2")
    defer:delEnv("LEAF_GPUI_ABI")
    let api=loadGpui(path)
    let Counter=defineComponent[int,State[int]]("ListSiblingCounter",
      proc(ctx:MountContext,p:int):State[int]=ctx.state(0),
      proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
        let n=ctx.value(s)
        host(button($n,key="counter",onClick=proc(e:Event)=s.set(n+1))))
    for size in [100,1000,100000]:
      var keys:seq[string]
      for i in 0..<size:keys.add($i)
      let items=componentList("items",keys,proc(i:int):UiDescription=host(text($i)),overscan=0)
      rt=newRuntime(componentApplication(hostShell(column(@[]),@[component(Counter,0),items]),"bounded list update"))
      scenario=4
      check openGpuiSession(rt,api).run()==0

  test "watch status reports compile failure and recovery without a tree":
    let path=absolutePath("target/ffi-v2/REQUESTS.so")
    let library=loadLib(path)
    defer:unloadLib(library)
    cast[proc(value:TestScript) {.cdecl.}](symAddr(library,"leaf_test_set_script"))(script)
    putEnv("LEAF_GPUI_ABI","2")
    watchStatusPath=absolutePath("target/ffi-v2/watch-status.json")
    putEnv("LEAF_WATCH_STATUS",watchStatusPath)
    defer:
      delEnv("LEAF_GPUI_ABI");delEnv("LEAF_WATCH_STATUS")
      removeFile(watchStatusPath)
    rt=newRuntime(componentApplication(host(text("accepted UI")),"watch"))
    scenario=5
    check openGpuiSession(rt,loadGpui(path)).run()==0

  test "accepted viewport scope exit keeps its typed rows without replay":
    let path=absolutePath("target/ffi-v2/REQUESTS.so")
    let library=loadLib(path)
    defer:unloadLib(library)
    cast[proc(value:TestScript) {.cdecl.}](symAddr(library,"leaf_test_set_script"))(script)
    putEnv("LEAF_GPUI_ABI","2")
    defer:delEnv("LEAF_GPUI_ABI")
    let scope:ExecutionScope=proc(body:proc() {.closure.})=
      body()
      if rejectViewportExit:fail("accepted viewport cleanup")
    var built=0
    rt=newRuntime(componentApplication(componentList("items",@["a"],proc(i:int):UiDescription=
      inc built;host(text("accepted")),overscan=0),"scope rows",executionScope=scope))
    scenario=6
    check openGpuiSession(rt,loadGpui(path)).run()!=0
    check built==1

  test "typed rendering logs compatible dimensions once per change without a tree":
    let directory=createTempDir("leaf-typed-rendering-","")
    defer:removeDir(directory)
    renderingLog=directory/"rendering.jsonl"
    renderingReceipt=directory/"ready.json"
    let d=newDiagnostics(logFile=renderingLog)
    defer:d.close()
    let path=absolutePath("target/ffi-v2/REQUESTS.so")
    let library=loadLib(path)
    defer:unloadLib(library)
    cast[proc(value:TestScript) {.cdecl.}](symAddr(library,"leaf_test_set_script"))(script)
    putEnv("LEAF_GPUI_ABI","2")
    let previous=getEnv("LEAF_WATCH_READY")
    putEnv("LEAF_WATCH_READY",renderingReceipt)
    defer:
      delEnv("LEAF_GPUI_ABI")
      if previous.len==0:delEnv("LEAF_WATCH_READY")
      else:putEnv("LEAF_WATCH_READY",previous)
    rt=newRuntime(componentApplication(host(text("accepted UI")),"rendering"),diagnostics=d)
    scenario=7
    let session=openGpuiSession(rt,loadGpui(path))
    let before=rt.updateStats()
    let jsonBefore=snapshotJsonCalls
    check session.run()==0
    check session.readyCalls==2
    check receiptAfter==receiptBefore
    var samples:seq[JsonNode]
    for line in lines(renderingLog):
      let entry=parseJson(line)
      if entry["phase"].getStr=="rendering":
        check entry["status"].getStr=="ok"
        samples.add(entry["details"])
    check samples.len==3
    if samples.len==3:
      for i,expected in [(1.5,640.0,480.0,960.0,720.0,144.0),
          (1.5,800.0,600.0,1200.0,900.0,144.0),(2.0,800.0,600.0,1600.0,1200.0,192.0)]:
        let sample=samples[i]
        check sample.len==4
        check sample["scale_factor"].getFloat==expected[0]
        check sample["logical_size"]["width"].getFloat==expected[1]
        check sample["logical_size"]["height"].getFloat==expected[2]
        check sample["device_size_calculated"]["width"].getFloat==expected[3]
        check sample["device_size_calculated"]["height"].getFloat==expected[4]
        check sample["dpi_from_scale_calculated"].getFloat==expected[5]
    check rt.updateStats().componentRenders==before.componentRenders
    check rt.updateStats().snapshotExports==before.snapshotExports
    check snapshotJsonCalls==jsonBefore

  test "malformed typed rendering cannot poison subsequent readiness":
    let path=absolutePath("target/ffi-v2/REQUESTS.so")
    let library=loadLib(path)
    defer:unloadLib(library)
    cast[proc(value:TestScript) {.cdecl.}](symAddr(library,"leaf_test_set_script"))(script)
    putEnv("LEAF_GPUI_ABI","2")
    defer:delEnv("LEAF_GPUI_ABI")
    rt=newRuntime(componentApplication(host(text("accepted UI")),"invalid rendering"))
    scenario=8
    let session=openGpuiSession(rt,loadGpui(path))
    check session.run()==0
    check session.readyCalls==1
    check renderingStatuses == @[5'i32,5,5,5,0]
