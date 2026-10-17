{.define:leafProtocolProbes.}
import std/[unittest,json,os,options,atomics,strutils]
import leaf/[core,components,widgets,managed_runtime,gpui_bridge,gpui_api,gpui_ffi_v2,gpui_session,host_session,backend]
var workCalls:Atomic[int]
proc work(input:string,ctx:WorkerContext):string {.nimcall,gcsafe.}=
  discard workCalls.fetchAdd(1);"ready"
var state:State[string]
var mounts=0
var ownerDisposed=0
let Owner=defineComponent[int,State[string]]("PumpCompatibilityOwner",
  proc(ctx:MountContext,p:int):State[string]=
    let scope=ctx.taskScope()
    result=ctx.state("loading");state=result
    ctx.onDispose(proc(event:LifecycleContext)=inc ownerDisposed)
    ctx.onMount(proc(event:LifecycleContext)=
      inc mounts
      discard startTask(scope,"load","",work,proc(value:string)=state.set(value))),
  proc(ctx:ComponentContext,p:int,s:State[string]):UiDescription=host(text(ctx.value(s))))
suite "task pump compatibility":
  test "pending query is readonly and closed Runtime has no pending":
    let rt=newRuntime(componentApplication(component(Owner,0),"readonly"))
    try:
      let counters=rt.updateStats();let revision=rt.acceptedRevision
      for i in 0..<5:check rt.taskPumpPending()
      check rt.updateStats()==counters
      check rt.acceptedRevision==revision
      rt.closeRuntime()
      check not rt.taskPumpPending()
    finally:rt.closeRuntime()

  test "ABI1 ready negotiates and metadata never consumes lifecycle or work":
    mounts=0;workCalls.store(0)
    let host=newDesktopBridge(componentApplication(component(Owner,0),"ABI1"),taskPumpSupported=true)
    try:
      for op in ["status","rendering"]:
        discard host.request(%*{"op":op})
      check mounts==0 and workCalls.load()==0
      let ready=host.request(%*{"op":"ready"})
      check ready["capabilities"]["task_pump"].getBool()
      check ready["tasks_pending"].getBool()
      check mounts==0 and workCalls.load()==0
      var updated=false
      for i in 0..<2000:
        let response=host.request(%*{"op":"tasks"})
        if response.hasKey("snapshot"):updated=true
        if not response["tasks_pending"].getBool():break
        sleep(1)
      check state.read()=="ready"
      check updated
      let jsonBefore=snapshotJsonCalls
      let before=host.runtime.updateStats();let revision=host.runtime.acceptedRevision
      let idle=host.request(%*{"op":"tasks"})
      check not idle.hasKey("snapshot")
      check not idle["tasks_pending"].getBool()
      check snapshotJsonCalls==jsonBefore
      check host.runtime.updateStats()==before
      check host.runtime.acceptedRevision==revision
    finally:host.runtime.closeRuntime()

  test "real old production library refuses initial and dynamically mounted task owners":
    let previous=getEnv("LEAF_GPUI_ABI")
    defer:
      if previous.len==0:delEnv("LEAF_GPUI_ABI")
      else:putEnv("LEAF_GPUI_ABI",previous)
    for abi in ["1","2"]:
      putEnv("LEAF_GPUI_ABI",abi)
      let api=loadGpui("/home/jimxl/projects/leaf/target/debug/libleaf_gpui.so")
      check not api.supportsTaskPump()
      workCalls.store(0);mounts=0;ownerDisposed=0
      expect UiError:discard newDesktopBridge(componentApplication(component(Owner,0),"old"),taskPumpSupported=api.supportsTaskPump())
      check mounts==0 and workCalls.load()==0
      check ownerDisposed==1
      ownerDisposed=0
      var show:State[bool]
      let Root=defineComponent[int,State[bool]]("OldDynamicPump",
        proc(ctx:MountContext,p:int):State[bool]=result=ctx.state(false);show=result,
        proc(ctx:ComponentContext,p:int,s:State[bool]):UiDescription=
          if ctx.value(s):component(Owner,0) else:host(button("mount",key="mount",onClick=proc(e:Event)=show.set(true))))
      let host=newDesktopBridge(componentApplication(component(Root,0),"dynamic old"),taskPumpSupported=api.supportsTaskPump())
      try:
        let revision=host.runtime.acceptedRevision
        let response=host.request(%*{"op":"event","id":host.runtime.find("mount").id,"kind":"click"})
        check response.hasKey("error")
        check host.runtime.acceptedRevision==revision
        check not show.read()
        check mounts==0 and workCalls.load()==0
        check ownerDisposed==0
      finally:host.runtime.closeRuntime()

var typedRuntime:Runtime
var typedMode,scopeCalls,cleanupCalls:int
var lateCallbacks:LeafHostCallbacks
var lateContext:pointer
var typedPrepares,typedApplies:int
proc prepare(ctx:pointer,batch:ptr LeafBatch,error:ptr LeafError):int32 {.cdecl.}=
  inc typedPrepares
  0
proc apply(ctx:pointer,error:ptr LeafError):int32 {.cdecl.}=
  inc typedApplies
  0
proc accept(ctx:pointer,revision:uint64) {.cdecl.}=discard
proc discardPrepared(ctx:pointer) {.cdecl.}=discard
proc typedRunImpl(config:ptr LeafConfig,callbacks:ptr LeafHostCallbacks,ctx:pointer,error:ptr LeafError):int32=
  var renderer=LeafRendererApi(struct_size:uint32(sizeof(LeafRendererApi)),abi:2,
    prepare:prepare,apply:apply,accept:accept,`discard`:discardPrepared)
  check callbacks.attach(ctx,addr renderer,nil,error)==0
  if typedMode==2:
    lateCallbacks=callbacks[];lateContext=ctx
    return 0 # Temporary release fallback; deliberately no terminal callback.
  if typedMode==3:lateCallbacks.detach(lateContext)
  check (config.flags and LEAF_CONFIG_TASK_PUMP)!=0
  let metadataStats=typedRuntime.updateStats();let metadataRevision=typedRuntime.acceptedRevision
  let metadataScopes=scopeCalls
  var request=LeafRequest(struct_size:uint32(sizeof(LeafRequest)),session_id:config.session_id)
  var reply=LeafReply(struct_size:uint32(sizeof(LeafReply)))
  for tag in [LEAF_REQUEST_STATUS,LEAF_REQUEST_READY,LEAF_REQUEST_RENDERING]:
    request.tag=uint32(tag);request.scale=1;request.width=200;request.height=200
    check callbacks.request(ctx,addr request,addr reply,error)==0
    check mounts==0 and workCalls.load()==0
    check typedRuntime.updateStats()==metadataStats and typedRuntime.acceptedRevision==metadataRevision
    check scopeCalls==metadataScopes
  request.tag=uint32(LEAF_REQUEST_TASKS)
  for i in 0..<2000:
    check callbacks.request(ctx,addr request,addr reply,error)==0
    if (reply.flags and LEAF_REPLY_TASKS_PENDING)==0:break
    sleep(1)
  check state.read()=="ready"
  check typedPrepares>1 and typedApplies>1
  let before=typedRuntime.updateStats();let revision=typedRuntime.acceptedRevision
  let jsonBefore=snapshotJsonCalls
  let prepareBefore=typedPrepares;let applyBefore=typedApplies
  check callbacks.request(ctx,addr request,addr reply,error)==0
  check reply.rows_len==0 and reply.flags==0
  check typedRuntime.updateStats()==before and typedRuntime.acceptedRevision==revision
  check snapshotJsonCalls==jsonBefore
  check typedPrepares==prepareBefore and typedApplies==applyBefore
  let scopesBefore=scopeCalls
  callbacks.detach(ctx)
  check scopeCalls==scopesBefore
  check cleanupCalls==0
  check not typedRuntime.taskPumpPending()
  0
proc typedRun(config:ptr LeafConfig,callbacks:ptr LeafHostCallbacks,ctx:pointer,error:ptr LeafError):int32 {.cdecl,raises:[].}=
  try:typedRunImpl(config,callbacks,ctx,error)
  except Exception:5
suite "typed task pump ordinary callbacks and detach":
  test "ready tasks terminal detach and temporary stale detach keep distinct lifetimes":
    for temporary in [false,true]:
      mounts=0;workCalls.store(0);scopeCalls=0;cleanupCalls=0
      typedPrepares=0;typedApplies=0
      let Root=defineComponent[int,int]("TypedTaskRoot",
        proc(ctx:MountContext,p:int):int=
          ctx.onDispose(proc(event:LifecycleContext)=inc cleanupCalls);p,
        proc(ctx:ComponentContext,p,m:int):UiDescription=component(Owner,0))
      let execution:ExecutionScope=proc(body:proc() {.closure.})=inc scopeCalls;body()
      typedRuntime=newRuntime(componentApplication(component(Root,0),"typed",executionScope=execution))
      let api=GpuiApi(v2:some(LeafGpuiApiV2(struct_size:uint32(sizeof(LeafGpuiApiV2)),abi:2,
        capabilities:LEAF_CAP_TASK_PUMP,run:typedRun)))
      try:
        if temporary:
          typedMode=2
          let first=openGpuiSession(typedRuntime,api)
          check first.run()==0
          first.close()
          check typedRuntime.taskPumpPending()
          typedMode=3
        else:typedMode=0
        let session=openGpuiSession(typedRuntime,api)
        check session.run()==0
        check cleanupCalls==0
        check not typedRuntime.taskPumpPending()
        typedRuntime.closeRuntime()
        check cleanupCalls==1
      finally:typedRuntime.closeRuntime()

suite "startup failure disposes accepted owners at ordinary boundary":
  test "ABI1 and typed capability rejection invalidate State and dispose once without entering":
    for typed in [false,true]:
      var owned:State[int]
      var entered,disposed,scopeDepth:int
      let execution:ExecutionScope=proc(body:proc() {.closure.})=
        inc scopeDepth
        try:body()
        finally:dec scopeDepth
      let Root=defineComponent[int,State[int]]("RejectedStartupOwner",
        proc(ctx:MountContext,p:int):State[int]=
          result=ctx.state(0);owned=result
          ctx.onMount(proc(event:LifecycleContext)=inc entered)
          ctx.onActivate(proc(event:LifecycleContext)=inc entered)
          ctx.onDeactivate(proc(event:LifecycleContext)=inc entered)
          ctx.onDispose(proc(event:LifecycleContext)=
            check scopeDepth==1
            inc disposed),
        proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s))))
      let app=componentApplication(component(Root,0),"rejected",executionScope=execution)
      if typed:
        let rt=newRuntime(app)
        let api=GpuiApi(v2:some(LeafGpuiApiV2(struct_size:uint32(sizeof(LeafGpuiApiV2)),abi:2,run:typedRun)))
        var error=""
        try:discard openGpuiSession(rt,api)
        except UiError as failure:error=failure.msg
        check "rebuild" in error
        check disposed==1
        expect UiError:discard owned.read()
        rt.closeRuntime()
      else:
        var error=""
        try:discard newDesktopBridge(app)
        except UiError as failure:error=failure.msg
        check "rebuild" in error
        check disposed==1
        expect UiError:discard owned.read()
      check entered==0
      check disposed==1
      check scopeDepth==0

proc rejectedPrepare(ctx:pointer,batch:ptr LeafBatch,error:ptr LeafError):int32 {.cdecl,raises:[].}=
  5
proc installFailureRun(config:ptr LeafConfig,callbacks:ptr LeafHostCallbacks,ctx:pointer,error:ptr LeafError):int32 {.cdecl,raises:[].}=
  var renderer=LeafRendererApi(struct_size:uint32(sizeof(LeafRendererApi)),abi:2,
    prepare:rejectedPrepare,apply:apply,accept:accept,`discard`:discardPrepared)
  result=callbacks.attach(ctx,addr renderer,nil,error)
  # detach must not enter an application scope even after a failed install.
  callbacks.detach(ctx)

suite "startup install cleanup and retry":
  test "typed installation failure unwinds scope then disposes or leaves only unclaimed cleanup":
    for refuse in [false,true]:
      var owned:State[int]
      var disposed,entered,depth,entries:int
      var rejectCleanup=false
      let execution:ExecutionScope=proc(body:proc() {.closure.})=
        inc entries
        if rejectCleanup:fail("cleanup scope refused")
        inc depth
        try:body()
        finally:
          dec depth
          if refuse and entries==2:rejectCleanup=true
      let Root=defineComponent[int,State[int]]("InstallFailedOwner",
        proc(ctx:MountContext,p:int):State[int]=
          result=ctx.state(0);owned=result
          ctx.onMount(proc(event:LifecycleContext)=inc entered)
          ctx.onDispose(proc(event:LifecycleContext)=
            check depth==1
            inc disposed),
        proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s))))
      let rt=newRuntime(componentApplication(component(Root,0),"install failure",executionScope=execution))
      let api=GpuiApi(v2:some(LeafGpuiApiV2(struct_size:uint32(sizeof(LeafGpuiApiV2)),abi:2,
        capabilities:LEAF_CAP_TASK_PUMP,run:installFailureRun)))
      let session=openGpuiSession(rt,api)
      check session.run()==5
      check depth==0 and entered==0
      check disposed==(if refuse:0 else:1)
      check owned.set(1)==StateWriteResult.disposed
      check not rt.taskPumpPending()
      check entries==3 # initial render, failed installation, one cleanup attempt
      rejectCleanup=false
      rt.closeRuntime()
      rt.closeRuntime()
      check disposed==1

  test "capability rejection preserves original error when cleanup scope refuses then retries":
    var refuse=false
    var disposed,entries:int
    var owned:State[int]
    let execution:ExecutionScope=proc(body:proc() {.closure.})=
      inc entries
      if refuse:fail("cleanup scope refused")
      body()
    let Root=defineComponent[int,State[int]]("CapabilityRetryOwner",
      proc(ctx:MountContext,p:int):State[int]=
        result=ctx.state(0);owned=result
        ctx.onDispose(proc(event:LifecycleContext)=inc disposed),
      proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s))))
    let rt=newRuntime(componentApplication(component(Root,0),"capability retry",executionScope=execution))
    let api=GpuiApi(v2:some(LeafGpuiApiV2(struct_size:uint32(sizeof(LeafGpuiApiV2)),abi:2,run:typedRun)))
    refuse=true
    var original=""
    try:discard openGpuiSession(rt,api)
    except UiError as error:original=error.msg
    check "host does not support task pumping" in original and "rebuild" in original
    check "cleanup scope refused" notin original
    check entries==2 and disposed==0
    check owned.set(1)==StateWriteResult.disposed
    refuse=false
    rt.closeRuntime()
    rt.closeRuntime()
    check disposed==1

suite "initially idle managed bridge capabilities":
  test "ABI1 event mounts task owner after successful idle ready":
    var show:State[bool]
    mounts=0;workCalls.store(0)
    let Root=defineComponent[int,State[bool]]("IdleDynamicPump",
      proc(ctx:MountContext,p:int):State[bool]=result=ctx.state(false);show=result,
      proc(ctx:ComponentContext,p:int,s:State[bool]):UiDescription=
        if ctx.value(s):component(Owner,0) else:host(button("mount",key="mount",onClick=proc(e:Event)=show.set(true))))
    let bridge=newDesktopBridge(componentApplication(component(Root,0),"idle dynamic"),taskPumpSupported=true)
    try:
      let ready=bridge.request(%*{"op":"ready"})
      check ready["capabilities"]["task_pump"].getBool()
      check not ready["tasks_pending"].getBool()
      let response=bridge.request(%*{"op":"event","id":bridge.runtime.find("mount").id,"kind":"click"})
      check response["tasks_pending"].getBool()
      check mounts==0 and workCalls.load()==0
      for i in 0..<2000:
        let tick=bridge.request(%*{"op":"tasks"})
        if not tick["tasks_pending"].getBool():break
        sleep(1)
      check state.read()=="ready"
      check mounts==1 and workCalls.load()==1
    finally:bridge.runtime.closeRuntime()

var dynamicRuntime:Runtime
var dynamicShow:State[bool]
var dynamicSupported=false
proc dynamicRunImpl(config:ptr LeafConfig,callbacks:ptr LeafHostCallbacks,ctx:pointer,error:ptr LeafError):int32=
  var renderer=LeafRendererApi(struct_size:uint32(sizeof(LeafRendererApi)),abi:2,
    prepare:prepare,apply:apply,accept:accept,`discard`:discardPrepared)
  check ((config.flags and LEAF_CONFIG_TASK_PUMP)!=0)==dynamicSupported
  check callbacks.attach(ctx,addr renderer,nil,error)==0
  var reply=LeafReply(struct_size:uint32(sizeof(LeafReply)))
  var request=LeafRequest(struct_size:uint32(sizeof(LeafRequest)),session_id:config.session_id,tag:uint32(LEAF_REQUEST_READY))
  check callbacks.request(ctx,addr request,addr reply,error)==0
  check (reply.flags and LEAF_REPLY_TASKS_PENDING)==0
  let before=dynamicRuntime.acceptedRevision
  request.tag=uint32(LEAF_REQUEST_EVENT)
  request.handle=dynamicRuntime.managedReconciler.handleFor(dynamicRuntime.find("mount").id).raw
  request.kind=uint32(ord(click));request.sequence=1;request.revision=before
  request.generation=1;request.binding_generation=1
  let status=callbacks.request(ctx,addr request,addr reply,error)
  if dynamicSupported:
    check status==0
    check (reply.flags and LEAF_REPLY_TASKS_PENDING)!=0
    request.tag=uint32(LEAF_REQUEST_TASKS)
    for i in 0..<2000:
      check callbacks.request(ctx,addr request,addr reply,error)==0
      if (reply.flags and LEAF_REPLY_TASKS_PENDING)==0:break
      sleep(1)
    check state.read()=="ready"
    check mounts==1 and workCalls.load()==1
  else:
    check status==int32(LEAF_STATUS_REJECTED)
    check dynamicRuntime.acceptedRevision==before
    check not dynamicShow.read()
    check mounts==0 and workCalls.load()==0
  callbacks.detach(ctx)
  0
proc dynamicRun(config:ptr LeafConfig,callbacks:ptr LeafHostCallbacks,ctx:pointer,error:ptr LeafError):int32 {.cdecl,raises:[].}=
  try:dynamicRunImpl(config,callbacks,ctx,error)
  except Exception:5
suite "typed initially idle capability binding and headless default":
  test "typed idle Runtime binds host capability and rejects or delivers later event mount":
    for supported in [false,true]:
      dynamicSupported=supported;mounts=0;workCalls.store(0)
      let Root=defineComponent[int,State[bool]]("TypedIdleDynamicPump",
        proc(ctx:MountContext,p:int):State[bool]=result=ctx.state(false);dynamicShow=result,
        proc(ctx:ComponentContext,p:int,s:State[bool]):UiDescription=
          if ctx.value(s):component(Owner,0) else:host(button("mount",key="mount",onClick=proc(e:Event)=dynamicShow.set(true))))
      dynamicRuntime=newRuntime(componentApplication(component(Root,0),"typed dynamic"))
      let api=GpuiApi(v2:some(LeafGpuiApiV2(struct_size:uint32(sizeof(LeafGpuiApiV2)),abi:2,
        capabilities:(if supported:LEAF_CAP_TASK_PUMP else:0),run:dynamicRun)))
      try:
        let session=openGpuiSession(dynamicRuntime,api)
        check session.run()==0
      finally:dynamicRuntime.closeRuntime()

  test "plain HostConsumer preserves default headless capability and explicit pumping":
    mounts=0;workCalls.store(0)
    let rt=newRuntime(componentApplication(component(Owner,0),"headless consumer"))
    let sink=HostConsumer(sessionId:900)
    sink.prepare=proc(batch:HostBatch)=discard
    sink.apply=proc()=discard
    sink.accept=proc(revision:uint64) {.raises:[].}=discard
    sink.discardPrepared=proc() {.raises:[].}=discard
    let session=attachHostSession(rt,sink)
    try:
      check mounts==0 and workCalls.load()==0
      for i in 0..<2000:
        let report=rt.pumpTasks()
        if not report.pending:break
        sleep(1)
      check state.read()=="ready"
    finally:
      session.close()
      rt.closeRuntime()

suite "ABI1 task failure metadata":
  test "failed task callback reports failure without fabricating an idle Snapshot":
    let Root=defineComponent[int,int]("Abi1FailedTaskCallback",
      proc(ctx:MountContext,p:int):int=
        ctx.onMount(proc(event:LifecycleContext)=fail("mount rejected"));p,
      proc(ctx:ComponentContext,p,m:int):UiDescription=host(text("failed callback")))
    let bridge=newDesktopBridge(componentApplication(component(Root,0),"task failure"),taskPumpSupported=true)
    try:
      discard bridge.request(%*{"op":"ready"})
      let before=snapshotJsonCalls
      let reply=bridge.request(%*{"op":"tasks"})
      check reply.hasKey("error")
      check not reply.hasKey("snapshot")
      check snapshotJsonCalls==before
    finally:bridge.runtime.closeRuntime()

suite "loaded new library negotiation":
  test "current worktree library exposes both task capabilities and legacy applications decline them":
    let path=getEnv("LEAF_TASK5_NEW_LIBRARY",FrameworkRoot / "target/debug" / GpuiLibraryName)
    if not fileExists(path):
      skip()
    else:
      let previous=getEnv("LEAF_GPUI_ABI")
      defer:
        if previous.len==0:delEnv("LEAF_GPUI_ABI")
        else:putEnv("LEAF_GPUI_ABI",previous)
      for abi in ["1","2"]:
        putEnv("LEAF_GPUI_ABI",abi)
        let api=loadGpui(path)
        check api.supportsTaskPump()
        if abi=="1":check api.taskPumpVersion()!=0
        else:check (api.v2.get.capabilities and LEAF_CAP_TASK_PUMP)!=0
        let app=Application(title:"legacy",width:200,height:200,render:proc(ctx:BuildContext):Node=text("old app"))
        let bridge=newDesktopBridge(app,taskPumpSupported=api.supportsTaskPump())
        try:
          let ready=bridge.request(%*{"op":"ready"})
          check not ready["capabilities"]["task_pump"].getBool()
          check not ready["tasks_pending"].getBool()
          let denied=bridge.request(%*{"op":"tasks"})
          check denied.hasKey("error")
        finally:bridge.runtime.closeRuntime()
