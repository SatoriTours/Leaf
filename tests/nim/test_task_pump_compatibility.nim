{.define:leafProtocolProbes.}
import std/[unittest,json,os,options,atomics,strutils,osproc,monotimes,times]
import leaf/[core,components,widgets,managed_runtime,gpui_bridge,gpui_api,gpui_ffi_v2,gpui_session,host_session,backend,desktop,checksum,task_service]
proc buildCapabilityFixture(capable: bool): string =
  let directory = FrameworkRoot / "target/ffi-v2"
  createDir(directory)
  let source = directory / (if capable: "final-capable.c" else: "final-legacy.c")
  result = source.changeFileExt("so")
  var fixture = readFile(FrameworkRoot / "tests/ffi/gpui_v2_library.c")
    .replace("../../include/leaf_gpui_v2.h", FrameworkRoot / "include/leaf_gpui_v2.h")
  if capable:
    fixture = fixture.replace("LeafGpuiApiV2 api={sizeof(api),2,0,run};", "LeafGpuiApiV2 api={sizeof(api),2,LEAF_CAP_TASK_PUMP,run};") &
      "\nuint32_t leaf_gpui_task_pump_version(void) {return 1;}\n"
  writeFile(source, fixture)
  doAssert execCmd("gcc -shared -fPIC " & quoteShell(source) & " -o " & quoteShell(result)) == 0

var legacyFixture: string
proc legacyTaskLibrary(): string =
  if legacyFixture.len == 0: legacyFixture = buildCapabilityFixture(false)
  legacyFixture
proc configuredLegacyTaskLibrary(): string =
  result = getEnv("LEAF_TASK5_OLD_LIBRARY")
  if result.len == 0: fail("set LEAF_TASK5_OLD_LIBRARY for the optional real old-library integration")
  if not fileExists(result): fail("configured old GPUI library does not exist: " & result)
  let actual = sha256File(result)
  let expected = getEnv("LEAF_TASK5_OLD_LIBRARY_SHA256")
  if expected.len > 0 and actual != expected: fail("configured old GPUI library SHA256 mismatch")
  if loadGpui(result).supportsTaskPump(): fail("configured old GPUI library unexpectedly supports task pumping")
  echo "OLD_GPUI_LIBRARY_SHA256=", actual

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

  test "buildable old capability library refuses initial and dynamically mounted task owners":
    let previous=getEnv("LEAF_GPUI_ABI")
    defer:
      if previous.len==0:delEnv("LEAF_GPUI_ABI")
      else:putEnv("LEAF_GPUI_ABI",previous)
    for abi in ["1","2"]:
      putEnv("LEAF_GPUI_ABI",abi)
      let api=loadGpui(legacyTaskLibrary())
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

suite "round1 public startup boundary":
  test "I2 public desktop preserves old library rejection and transfers one cleanup attempt":
    let previousLibrary=getEnv("LEAF_GPUI_LIBRARY")
    let previousAbi=getEnv("LEAF_GPUI_ABI")
    defer:
      if previousLibrary.len==0:delEnv("LEAF_GPUI_LIBRARY")
      else:putEnv("LEAF_GPUI_LIBRARY",previousLibrary)
      if previousAbi.len==0:delEnv("LEAF_GPUI_ABI")
      else:putEnv("LEAF_GPUI_ABI",previousAbi)
    putEnv("LEAF_GPUI_LIBRARY",legacyTaskLibrary())
    for abi in ["1","2"]:
      putEnv("LEAF_GPUI_ABI",abi)
      for withOut in [false,true]:
        var entries,disposed,entered:int
        var refuse=true
        var owned:State[int]
        workCalls.store(0)
        let execution:ExecutionScope=proc(body:proc())=
          inc entries
          if entries>1 and refuse:fail("round1 cleanup refused")
          body()
        let Root=defineComponent[int,State[int]]("PublicOldLibraryStartup",
          proc(ctx:MountContext,p:int):State[int]=
            result=ctx.state(0);owned=result
            let scope=ctx.taskScope()
            ctx.onMount(proc(event:LifecycleContext)=
              inc entered
              discard startTask(scope,"must-not-start","",work,proc(value:string)=discard))
            ctx.onDispose(proc(event:LifecycleContext)=inc disposed),
          proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s))))
        var caught=""
        var cleanup:Runtime
        let app=componentApplication(component(Root,0),"public old",executionScope=execution)
        try:
          discard (if withOut:runDesktop(app,cleanupOwner=addr cleanup) else:runDesktop(app))
        except GpuiRunError as failure:
          caught=failure.msg
          check failure.exitStatus.isNone
          check failure.parent!=nil and not (failure.parent of GpuiRunError)
          check failure.parent.msg==caught
          if withOut:check cleanup==failure.cleanupRuntime
          else:cleanup=failure.cleanupRuntime
        check "host does not support task pumping" in caught and "rebuild" in caught
        check entries==2 and disposed==0 and entered==0
        check workCalls.load()==0
        check owned.set(1)==StateWriteResult.disposed
        check cleanup!=nil
        if cleanup!=nil:
          refuse=false
          cleanup.closeRuntime();cleanup.closeRuntime()
          check disposed==1 and entered==0
          check workCalls.load()==0
          check owned.set(2)==StateWriteResult.disposed

  test "I3 failed ABI1 constructor transfers a reachable cleanup Runtime for ordinary retry":
    var entries,disposed,entered:int
    var refuse=true
    var owned:State[int]
    let execution:ExecutionScope=proc(body:proc())=
      inc entries
      if entries>1 and refuse:fail("round1 cleanup refused")
      body()
    let Root=defineComponent[int,State[int]]("PublicConstructorRetryOwner",
      proc(ctx:MountContext,p:int):State[int]=
        result=ctx.state(0);owned=result
        ctx.onMount(proc(event:LifecycleContext)=inc entered)
        ctx.onDispose(proc(event:LifecycleContext)=inc disposed),
      proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s))))
    var caught=""
    var cleanup:Runtime
    try:discard newDesktopBridge(componentApplication(component(Root,0),"public constructor",executionScope=execution))
    except UiError as error:
      caught=error.msg
      check error of GpuiRunError
      if error of GpuiRunError:cleanup=cast[ref GpuiRunError](error).cleanupRuntime
    check "rebuild" in caught
    check entries==2 and disposed==0 and entered==0
    check owned.set(1)==StateWriteResult.disposed
    check cleanup!=nil
    if cleanup!=nil:
      refuse=false
      cleanup.closeRuntime()
      cleanup.closeRuntime()
      check disposed==1
      check owned.set(2)==StateWriteResult.disposed

var fix1BuiltStartupLibrary=""
proc fix1StartupLibrary():string=
  if fix1BuiltStartupLibrary.len>0:return fix1BuiltStartupLibrary
  createDir("target/ffi-v2")
  let path=absolutePath("target/ffi-v2/fix1-startup.c")
  let fixture=readFile("tests/ffi/gpui_v2_library.c")
    .replace("../../include/leaf_gpui_v2.h",FrameworkRoot / "include/leaf_gpui_v2.h")
    .replace("LeafGpuiApiV2 api={sizeof(api),2,0,run};","LeafGpuiApiV2 api={sizeof(api),2,LEAF_CAP_TASK_PUMP,run};") &
    "\nuint32_t leaf_gpui_task_pump_version(void) { return 1; }\n"
  writeFile(path,fixture)
  result=absolutePath("target/ffi-v2/fix1-startup.so")
  let code=execCmd("gcc -shared -fPIC " & quoteShell(path) & " -o " & quoteShell(result))
  check code==0
  fix1BuiltStartupLibrary=result

suite "round1 status and retry ownership":
  test "I2 public typed installation status is preserved with out or exception ownership":
    let previousLibrary=getEnv("LEAF_GPUI_LIBRARY");let previousAbi=getEnv("LEAF_GPUI_ABI")
    defer:
      if previousLibrary.len==0:delEnv("LEAF_GPUI_LIBRARY")
      else:putEnv("LEAF_GPUI_LIBRARY",previousLibrary)
      if previousAbi.len==0:delEnv("LEAF_GPUI_ABI")
      else:putEnv("LEAF_GPUI_ABI",previousAbi)
    putEnv("LEAF_GPUI_LIBRARY",fix1StartupLibrary());putEnv("LEAF_GPUI_ABI","2")
    for withOut in [false,true]:
      var entries,disposed,entered:int
      var refuse=true
      var owned:State[int]
      let execution:ExecutionScope=proc(body:proc())=
        inc entries
        if entries==2:fail("round1 installation rejected")
        if entries>2 and refuse:fail("round1 cleanup refused")
        body()
      let Root=defineComponent[int,State[int]]("PublicInstallStatusOwner",
        proc(ctx:MountContext,p:int):State[int]=
          result=ctx.state(0);owned=result
          ctx.onMount(proc(event:LifecycleContext)=inc entered)
          ctx.onDispose(proc(event:LifecycleContext)=inc disposed),
        proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s))))
      let app=componentApplication(component(Root,0),"public status",executionScope=execution)
      var cleanup:Runtime
      var status= -1
      var raised=false
      try:
        status=if withOut:runDesktop(app,cleanupOwner=addr cleanup) else:runDesktop(app)
      except UiError as error:
        raised=true
        if error of GpuiRunError:
          let failure=cast[ref GpuiRunError](error)
          check failure.exitStatus==some(5)
          cleanup=failure.cleanupRuntime
          check failure.parent!=nil
      check raised==not withOut
      if withOut:check status==5
      check entries==3 and disposed==0 and entered==0
      check owned.set(1)==StateWriteResult.disposed
      check cleanup!=nil
      if cleanup!=nil:
        refuse=false
        cleanup.closeRuntime();cleanup.closeRuntime()
        check disposed==1
        check owned.set(2)==StateWriteResult.disposed

  test "I3 direct ABI1 installation rejection transfers owner after one refused cleanup":
    var entries,disposed,entered:int
    var refuse=true
    var owned:State[int]
    let execution:ExecutionScope=proc(body:proc())=
      inc entries
      if entries==2:fail("round1 ABI1 installation rejected")
      if entries>2 and refuse:fail("round1 cleanup refused")
      body()
    let Root=defineComponent[int,State[int]]("PublicAbi1InstallOwner",
      proc(ctx:MountContext,p:int):State[int]=
        result=ctx.state(0);owned=result
        ctx.onMount(proc(event:LifecycleContext)=inc entered)
        ctx.onDispose(proc(event:LifecycleContext)=inc disposed),
      proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s))))
    var cleanup:Runtime
    var caught=""
    try:discard newDesktopBridge(componentApplication(component(Root,0),"ABI1 install",executionScope=execution),taskPumpSupported=true)
    except UiError as error:
      caught=error.msg
      if error of GpuiRunError:
        let failure=cast[ref GpuiRunError](error)
        cleanup=failure.cleanupRuntime
        check failure.exitStatus.isNone
        check failure.parent!=nil and failure.parent.msg==caught
    check caught=="round1 ABI1 installation rejected"
    check entries==3 and disposed==0 and entered==0
    check owned.set(1)==StateWriteResult.disposed
    check cleanup!=nil
    if cleanup!=nil:
      refuse=false
      cleanup.closeRuntime();cleanup.closeRuntime()
      check disposed==1

  test "public successful desktop status zero transfers refused final cleanup for either ABI":
    let previousLibrary=getEnv("LEAF_GPUI_LIBRARY");let previousAbi=getEnv("LEAF_GPUI_ABI")
    defer:
      if previousLibrary.len==0:delEnv("LEAF_GPUI_LIBRARY")
      else:putEnv("LEAF_GPUI_LIBRARY",previousLibrary)
      if previousAbi.len==0:delEnv("LEAF_GPUI_ABI")
      else:putEnv("LEAF_GPUI_ABI",previousAbi)
    putEnv("LEAF_GPUI_LIBRARY",fix1StartupLibrary())
    for abi in ["1","2"]:
      putEnv("LEAF_GPUI_ABI",abi)
      for withOut in [false,true]:
        var entries,disposed,entered:int
        var refuse=true
        var owned:State[int]
        let execution:ExecutionScope=proc(body:proc())=
          inc entries
          if entries>2 and refuse:fail("round1 final cleanup refused")
          body()
        let Root=defineComponent[int,State[int]]("PublicZeroStatusOwner",
          proc(ctx:MountContext,p:int):State[int]=
            result=ctx.state(0);owned=result
            ctx.onMount(proc(event:LifecycleContext)=inc entered)
            ctx.onDispose(proc(event:LifecycleContext)=inc disposed),
          proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s))))
        let app=componentApplication(component(Root,0),"public zero",executionScope=execution)
        var cleanup:Runtime
        var status= -1
        var raised=false
        try:
          status=if withOut:runDesktop(app,cleanupOwner=addr cleanup) else:runDesktop(app)
        except UiError as error:
          raised=true
          if error of GpuiRunError:
            let failure=cast[ref GpuiRunError](error)
            cleanup=failure.cleanupRuntime
            check failure.exitStatus==some(0)
            check failure.parent!=nil
        check raised==not withOut
        if withOut:check status==0
        check entries==3 and disposed==0 and entered==0
        check owned.set(1)==StateWriteResult.disposed
        check cleanup!=nil
        if cleanup!=nil:
          refuse=false
          cleanup.closeRuntime();cleanup.closeRuntime()
          check disposed==1

  test "nonempty cleanup output is rejected before new owner initialization":
    let previousLibrary=getEnv("LEAF_GPUI_LIBRARY");let previousAbi=getEnv("LEAF_GPUI_ABI")
    defer:
      if previousLibrary.len==0:delEnv("LEAF_GPUI_LIBRARY")
      else:putEnv("LEAF_GPUI_LIBRARY",previousLibrary)
      if previousAbi.len==0:delEnv("LEAF_GPUI_ABI")
      else:putEnv("LEAF_GPUI_ABI",previousAbi)
    putEnv("LEAF_GPUI_LIBRARY",fix1StartupLibrary());putEnv("LEAF_GPUI_ABI","1")
    var initialized=0
    var oldState:State[int]
    let Old=defineComponent[int,State[int]]("OldCleanupSlotOwner",
      proc(ctx:MountContext,p:int):State[int]=result=ctx.state(7);oldState=result,
      proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s))))
    let original=newRuntime(componentApplication(component(Old,0),"old owner"))
    var cleanup=original
    let New=defineComponent[int,int]("MustNotInitializeOwner",
      proc(ctx:MountContext,p:int):int=inc initialized;p,
      proc(ctx:ComponentContext,p,m:int):UiDescription=host(text("new")))
    let app=componentApplication(component(New,0),"new owner")
    try:
      expect UiError:discard runDesktop(app,cleanupOwner=addr cleanup)
      check initialized==0
      check cleanup==original
      check oldState.read()==7
    finally:original.closeRuntime()
  test "completed public cleanup keeps integer return and leaves output empty":
    let previousLibrary=getEnv("LEAF_GPUI_LIBRARY");let previousAbi=getEnv("LEAF_GPUI_ABI")
    defer:
      if previousLibrary.len==0:delEnv("LEAF_GPUI_LIBRARY")
      else:putEnv("LEAF_GPUI_LIBRARY",previousLibrary)
      if previousAbi.len==0:delEnv("LEAF_GPUI_ABI")
      else:putEnv("LEAF_GPUI_ABI",previousAbi)
    putEnv("LEAF_GPUI_LIBRARY",fix1StartupLibrary())
    for (abi,status) in [("1",0),("2",0),("2",5)]:
      putEnv("LEAF_GPUI_ABI",abi)
      var entries,disposed,entered:int
      var owned:State[int]
      let execution:ExecutionScope=proc(body:proc())=
        inc entries
        if status==5 and entries==2:fail("round1 installation rejected")
        body()
      let Root=defineComponent[int,State[int]]("CompletedPublicCleanup",
        proc(ctx:MountContext,p:int):State[int]=
          result=ctx.state(0);owned=result
          ctx.onMount(proc(event:LifecycleContext)=inc entered)
          ctx.onDispose(proc(event:LifecycleContext)=inc disposed),
        proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s))))
      var cleanup:Runtime
      check runDesktop(componentApplication(component(Root,0),"completed cleanup",executionScope=execution),cleanupOwner=addr cleanup)==status
      check cleanup==nil
      check entries==3 and disposed==1 and entered==0
      check owned.set(1)==StateWriteResult.disposed

suite "portable old capability input":
  test "explicit integration rejects a new capable library and a mismatched SHA":
    let previous = getEnv("LEAF_TASK5_OLD_LIBRARY")
    let previousSha = getEnv("LEAF_TASK5_OLD_LIBRARY_SHA256")
    let previousAbi = getEnv("LEAF_GPUI_ABI")
    defer:
      for pair in [("LEAF_TASK5_OLD_LIBRARY", previous), ("LEAF_TASK5_OLD_LIBRARY_SHA256", previousSha), ("LEAF_GPUI_ABI", previousAbi)]:
        if pair[1].len == 0: delEnv(pair[0])
        else: putEnv(pair[0], pair[1])
    putEnv("LEAF_TASK5_OLD_LIBRARY", buildCapabilityFixture(true))
    delEnv("LEAF_TASK5_OLD_LIBRARY_SHA256")
    for abi in ["1", "2"]:
      putEnv("LEAF_GPUI_ABI", abi)
      expect UiError: discard configuredLegacyTaskLibrary()
    putEnv("LEAF_TASK5_OLD_LIBRARY", buildCapabilityFixture(false))
    putEnv("LEAF_TASK5_OLD_LIBRARY_SHA256", repeat('0', 64))
    expect UiError: discard configuredLegacyTaskLibrary()

  test "optional real old library verifies SHA capability and startup rejection for both ABIs":
    if getEnv("LEAF_TASK5_OLD_LIBRARY").len == 0:
      skip()
    else:
      let previousAbi = getEnv("LEAF_GPUI_ABI")
      defer:
        if previousAbi.len == 0: delEnv("LEAF_GPUI_ABI")
        else: putEnv("LEAF_GPUI_ABI", previousAbi)
      for abi in ["1", "2"]:
        putEnv("LEAF_GPUI_ABI", abi)
        let library = configuredLegacyTaskLibrary()
        let api = loadGpui(library)
        check not api.supportsTaskPump()
        ownerDisposed = 0; mounts = 0; workCalls.store(0)
        expect UiError:
          discard newDesktopBridge(componentApplication(component(Owner, 0), "configured old"),
            taskPumpSupported=api.supportsTaskPump())
        check ownerDisposed == 1 and mounts == 0 and workCalls.load() == 0

var holdOtherWorker: Atomic[bool]
proc heldWork(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  while holdOtherWorker.load(): sleep(1)
  input
suite "task error envelope with actual workers":
  test "claimed error and a refused unclaimed delivery preserve pending without snapshots or replay":
    var first, other: int
    var refuseEntry, failExit: bool
    let execution: ExecutionScope = proc(body: proc()) =
      if refuseEntry: fail("delivery scope entry refused")
      body()
      if failExit: fail("delivery scope exit refused")
    let Root = defineComponent[int, int]("ErrorEnvelopeWorkers",
      proc(ctx: MountContext, p: int): int =
        let scope = ctx.taskScope()
        ctx.onMount(proc(e: LifecycleContext) =
          discard startTask(scope, "first", "first", work, proc(value: string) =
            inc first
            failExit = true)
          discard startTask(scope, "other", "other", heldWork, proc(value: string) = inc other))
        p,
      proc(ctx: ComponentContext, p, m: int): UiDescription = host(text("unchanged")))
    holdOtherWorker.store(true)
    let host = newDesktopBridge(componentApplication(component(Root, 0), "error envelope", executionScope=execution),
      taskPumpSupported=true)
    try:
      discard host.request(%*{"op":"ready"})
      discard host.request(%*{"op":"tasks"}) # accepted mount submits both actual workers
      let deadline = getMonoTime() + initDuration(seconds=5)
      while first == 0:
        let response = host.request(%*{"op":"tasks"})
        if first == 1:
          check response.hasKey("error")
          check response["tasks_pending"].getBool()
          check not response.hasKey("snapshot")
        doAssert getMonoTime() < deadline
        sleep(1)
      check first == 1 and other == 0
      failExit = false
      holdOtherWorker.store(false)
      let service = host.runtime.taskServiceInternal()
      while service.readyTaskCountInternal() == 0:
        doAssert getMonoTime() < deadline
        sleep(1)
      refuseEntry = true
      let refused = host.request(%*{"op":"tasks"})
      check refused.hasKey("error") and refused["tasks_pending"].getBool()
      check not refused.hasKey("snapshot")
      check first == 1 and other == 0
      refuseEntry = false
      let recovered = host.request(%*{"op":"tasks"})
      check not recovered.hasKey("error") and not recovered["tasks_pending"].getBool()
      check not recovered.hasKey("snapshot")
      check first == 1 and other == 1
    finally:
      holdOtherWorker.store(false); refuseEntry=false; failExit=false
      host.runtime.closeRuntime()
