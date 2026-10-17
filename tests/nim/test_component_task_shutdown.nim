import std/[unittest,atomics,os]
import leaf/[core,widgets,components,managed_runtime,task_service,task_worker,host_session]
# Run only with -d:leafTask4ForeignCloseProbe --threads:on. The compiler
# must reject this UI-only API call from a Nim worker; never disable analysis.
when defined(leafTask4ForeignCloseProbe):
  proc foreignCloseProbe(value:ptr Runtime) {.thread.}=
    value[].closeRuntime()

var holdWork,startedWork:Atomic[bool]
proc blockingWork(input:string,ctx:WorkerContext):string {.nimcall,gcsafe.}=
  startedWork.store(true)
  while holdWork.load():sleep(1)
  input
var ownerScope:TaskScope
var ownerState:State[int]
var disposed=0
var runtime:Runtime
let Owner=defineComponent[int,State[int]]("ShutdownOwner",
  proc(ctx:MountContext,p:int):State[int]=
    ownerScope=ctx.taskScope()
    result=ctx.state(0);ownerState=result
    ctx.onDispose(proc(event:LifecycleContext)=
      inc disposed
      check ownerState.set(9)==StateWriteResult.disposed
      runtime.closeRuntime()),
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    host(button($ctx.value(s),key="close",onClick=proc(e:Event)=
      s.set(7)
      discard startTask(ownerScope,"pending","",blockingWork,proc(v:string)=discard)
      runtime.closeRuntime()
      check s.set(8)==StateWriteResult.disposed
      expect UiError:discard startTask(ownerScope,"late","",blockingWork,proc(v:string)=discard))))
suite "task runtime two stage shutdown":
  test "busy event close returns before noncooperative work then ordinary close joins exactly once":
    disposed=0;holdWork.store(true);startedWork.store(false)
    runtime=newRuntime(componentApplication(component(Owner,0),"shutdown"))
    let service=runtime.taskServiceInternal()
    try:
      runtime.uiTask(proc()=discard startTask(ownerScope,"running","",blockingWork,proc(v:string)=fail("closed result")))
      discard runtime.pumpTasks()
      for i in 0..<2000:
        if startedWork.load():break
        sleep(1)
      check startedWork.load()
      let revision=runtime.acceptedRevision
      discard runtime.dispatch("close",Event(kind:click))
      check holdWork.load() # close returned while work still held.
      check disposed==0
      check ownerState.set(1)==StateWriteResult.disposed
      check runtime.acceptedRevision==revision
      check service.taskWorkerStatsInternal().reservedTasks==1
      holdWork.store(false)
      runtime.closeRuntime()
      runtime.closeRuntime()
      check disposed==1
      check service.taskWorkerStatsInternal().reservedTasks==0
      check service.taskWorkerStatsInternal().inputBytes==0
      check service.taskWorkerStatsInternal().resultBytes==0
      check service.cleanupPendingInternal()==0
    finally:
      holdWork.store(false)
      runtime.closeRuntime()

  test "refused cleanup scope retains unclaimed cleanup for a later close":
    disposed=0
    var refuse=false
    let execution:ExecutionScope=proc(body:proc() {.closure.})=
      if refuse:fail("cleanup entry")
      body()
    runtime=newRuntime(componentApplication(component(Owner,0),"refuse",executionScope=execution))
    refuse=true
    expect UiError:runtime.closeRuntime()
    check ownerState.set(1)==StateWriteResult.disposed
    check disposed==0
    refuse=false
    runtime.closeRuntime()
    runtime.closeRuntime()
    check disposed==1

suite "busy mount and result close":
  test "onMount and onResult close discard queued State route and task intentions":
    for phase in ["mount","result"]:
      var rt:Runtime
      var scope:TaskScope
      var state:State[int]
      var router:ComponentRouter
      var callbacks,cleanup=0
      proc closeBody()=
        state.set(7)
        discard router.navigate("/b")
        discard startTask(scope,"queued","",blockingWork,proc(v:string)=fail("late task"))
        rt.closeRuntime()
        check state.set(8)==StateWriteResult.disposed
        check router.navigate("/")==StateWriteResult.disposed
        expect UiError:discard startTask(scope,"after","",blockingWork,proc(v:string)=discard)
        inc callbacks
      let Subject=defineComponent[int,State[int]]("BusyClosePhases",
        proc(ctx:MountContext,p:int):State[int]=
          scope=ctx.taskScope()
          router=newComponentRouter(ctx,
            @[Route(name:"a",path:"/",page:"page",view:"a"),Route(name:"b",path:"/b",page:"page",view:"b")],
            @[ComponentPageDefinition(name:"page",views: @["a","b"],build:proc(view:string):UiDescription=host(text(view)))],"/")
          result=ctx.state(0);state=result
          ctx.onMount(proc(event:LifecycleContext)=
            if phase=="mount":closeBody())
          ctx.onDispose(proc(event:LifecycleContext)=inc(cleanup)),
        proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=renderPage(ctx,router))
      holdWork.store(false)
      rt=newRuntime(componentApplication(component(Subject,0),"busy phases"))
      try:
        let service=rt.taskServiceInternal()
        if phase=="result":
          discard rt.pumpTasks()
          rt.uiTask(proc()=discard startTask(scope,"result","",blockingWork,proc(v:string)=closeBody()))
        let revision=rt.acceptedRevision
        for i in 0..<2000:
          discard rt.pumpTasks()
          if callbacks==1:break
          sleep(1)
        check callbacks==1
        check cleanup==0
        check rt.acceptedRevision==revision
        check rt.snapshot.root.node.text=="a"
        check state.set(1)==StateWriteResult.disposed
        discard rt.pumpTasks()
        check callbacks==1
        rt.closeRuntime()
        check cleanup==1
        check service.taskWorkerStatsInternal().reservedTasks==0
      finally:rt.closeRuntime()

  test "pending child dispose is retained before final parent cleanup and recursion is idempotent":
    var rt:Runtime
    var show:State[bool]
    var childState:State[int]
    var order:seq[string]
    let Child=defineComponent[int,int]("ShutdownPendingChild",
      proc(ctx:MountContext,p:int):int=
        childState=ctx.state(0)
        ctx.onDispose(proc(event:LifecycleContext)=
          check childState.set(1)==StateWriteResult.disposed
          check show.set(true)==StateWriteResult.disposed
          order.add("child");rt.closeRuntime());p,
      proc(ctx:ComponentContext,p,m:int):UiDescription=host(text("child")))
    let Parent=defineComponent[int,State[bool]]("ShutdownPendingParent",
      proc(ctx:MountContext,p:int):State[bool]=
        result=ctx.state(true);show=result
        ctx.onDispose(proc(event:LifecycleContext)=order.add("parent")),
      proc(ctx:ComponentContext,p:int,s:State[bool]):UiDescription=
        if ctx.value(s):component(Child,0) else:host(text("empty")))
    rt=newRuntime(componentApplication(component(Parent,0),"pending cleanup"))
    rt.uiTask(proc()=show.set(false))
    rt.closeRuntime();rt.closeRuntime()
    check order == @["child","parent"]

suite "closed cleanup dedicated capacity":
  test "40000 pending disposes plus live owners survive scope refusal and drain once":
    var state:State[int]
    var initialized=0
    var seen:seq[int]
    var parentDisposes=0
    var refuse=false
    let Child=defineComponent[int,int]("CleanupCapacityChild",
      proc(ctx:MountContext,p:int):int=
        let identity=initialized
        inc initialized
        seen.add(0)
        ctx.onDispose(proc(event:LifecycleContext)=inc(seen[identity]))
        identity,
      proc(ctx:ComponentContext,p,m:int):UiDescription=host(text($m)))
    let Root=defineComponent[int,State[int]]("CleanupCapacityRoot",
      proc(ctx:MountContext,p:int):State[int]=
        result=ctx.state(0);state=result
        ctx.onDispose(proc(event:LifecycleContext)=inc(parentDisposes)),
      proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
        var children:seq[UiDescription]
        for i in 0..<ctx.value(s):children.add(component(Child,i,key = $i))
        hostShell(column(@[]),children))
    let execution:ExecutionScope=proc(body:proc() {.closure.})=
      if refuse:fail("capacity cleanup scope")
      body()
    let rt=newRuntime(componentApplication(component(Root,0),"cleanup capacity",executionScope=execution))
    let service=rt.taskServiceInternal()
    try:
      for i in 0..<8:
        rt.uiTask(proc()=state.set(5000))
        rt.uiTask(proc()=state.set(0))
      check service.pendingTaskBytesInternal()==40000*128
      rt.uiTask(proc()=state.set(1))
      check initialized==40001
      refuse=true
      expect UiError:rt.closeRuntime()
      check service.cleanupPendingInternal()==40002
      check service.cleanupBytesInternal()==40002*128
      check service.pendingTaskBytesInternal()==0
      check state.set(2)==StateWriteResult.disposed
      expect UiError:rt.closeRuntime()
      check service.cleanupPendingInternal()==40002
      refuse=false
      rt.closeRuntime();rt.closeRuntime()
      check parentDisposes==1
      for count in seen:check count==1
      check service.cleanupPendingInternal()==0
      check service.cleanupBytesInternal()==0
    finally:
      refuse=false;rt.closeRuntime()

suite "public close permission boundaries":
  test "executionScope entry and exit wrappers outside the business body cannot close":
    for phase in ["entry","exit"]:
      var armed=false
      var rejected=false
      let execution:ExecutionScope=proc(body:proc() {.closure.})=
        if armed and phase=="entry":
          try:runtime.closeRuntime()
          except UiError:rejected=true
        body()
        if armed and phase=="exit":
          try:runtime.closeRuntime()
          except UiError:rejected=true
      disposed=0
      runtime=newRuntime(componentApplication(component(Owner,0),"wrapper",executionScope=execution))
      try:
        armed=true
        runtime.uiTask(proc()=discard)
        armed=false
        check rejected
        check ownerState.set(0)==StateWriteResult.queued
        discard runtime.flush()
        check disposed==0
      finally:
        armed=false;runtime.closeRuntime()

  test "render updater host prepare apply and installation reject before mutation":
    var rt:Runtime
    var state:State[int]
    var renderArmed=false
    var rejects=0
    let Subject=defineComponent[int,State[int]]("CloseProtectedPhases",
      proc(ctx:MountContext,p:int):State[int]=result=ctx.state(0);state=result,
      proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
        if renderArmed:
          expect UiError:rt.closeRuntime()
          inc rejects
        host(text($ctx.value(s))))
    rt=newRuntime(componentApplication(component(Subject,0),"protected"))
    let session=attachHostSession(rt,HostConsumer(sessionId:921,
      prepare:proc(batch:HostBatch)=
        expect UiError:rt.closeRuntime()
        inc(rejects),
      apply:proc()=
        expect UiError:rt.closeRuntime()
        inc(rejects),
      accept:proc(revision:uint64) {.raises:[].}=discard,
      discardPrepared:proc() {.raises:[].}=discard))
    try:
      renderArmed=true
      rt.uiTask(proc()=state.update(proc(previous:int):int=
        expect UiError:rt.closeRuntime()
        inc rejects
        previous+1))
      check state.read()==1
      check rejects==6 # installation2 + updater1 + render1 + prepare/apply2.
    finally:
      renderArmed=false;session.close();rt.closeRuntime()

suite "close Runtime identity and legacy events":
  test "foreign Runtime rejects without closing the owner":
    disposed=0
    runtime=newRuntime(componentApplication(component(Owner,0),"identity owner"))
    let other=newRuntime(componentApplication(host(text("other")),"other"))
    try:
      expect UiError:other.uiTask(proc()=runtime.closeRuntime())
      check ownerState.set(0)==StateWriteResult.queued
      discard runtime.flush()
      check ownerState.set(0)==StateWriteResult.queued
      discard runtime.flush()
      check disposed==0
    finally:
      other.closeRuntime();runtime.closeRuntime()

  test "legacy ordinary event can close and skips its queued rerender":
    var rt:Runtime
    var renders=0
    let app=Application(title:"legacy close",width:200,height:200,
      render:proc(ctx:BuildContext):Node=
        inc renders
        button("close",key="legacy-close",onClick=proc(event:Event)=rt.closeRuntime()))
    rt=newRuntime(app)
    discard rt.dispatch("legacy-close",Event(kind:click))
    check renders==1
    expect UiError:discard rt.dispatch("legacy-close",Event(kind:click))
    rt.closeRuntime()

suite "cleanup claim exact boundary":
  test "cleanup scope wrappers reject recursive close while the actual dispose body is idempotent":
    disposed=0
    var armed=false
    var wrapperRejects=0
    let execution:ExecutionScope=proc(body:proc() {.closure.})=
      if armed:
        expect UiError:runtime.closeRuntime()
        inc wrapperRejects
      body()
      if armed:
        expect UiError:runtime.closeRuntime()
        inc wrapperRejects
    runtime=newRuntime(componentApplication(component(Owner,0),"cleanup wrappers",executionScope=execution))
    armed=true
    runtime.closeRuntime()
    armed=false
    check disposed==1
    check wrapperRejects==2

  test "claimed dispose callback or scope-exit errors do not replay and do not starve siblings":
    for mode in ["callback","exit"]:
      var armed=false
      var calls:seq[string]
      let Child=defineComponent[string,int]("FailingShutdownChild",
        proc(ctx:MountContext,name:string):int=
          ctx.onDispose(proc(event:LifecycleContext)=
            calls.add(name)
            if name=="first" and mode=="callback":fail("cleanup callback"));0,
        proc(ctx:ComponentContext,name:string,m:int):UiDescription=host(text(name)))
      let execution:ExecutionScope=proc(body:proc() {.closure.})=
        body()
        if armed and mode=="exit":fail("cleanup scope exit")
      let rt=newRuntime(componentApplication(hostShell(column(@[]),@[
        component(Child,"first",key="z"),component(Child,"second",key="a")]),"cleanup failures",executionScope=execution))
      armed=true
      rt.closeRuntime()
      armed=false
      rt.closeRuntime()
      check calls == @["first","second"]

  test "host replacement preserves live tasks but terminal retirement stops business delivery":
    disposed=0;holdWork.store(true);startedWork.store(false)
    runtime=newRuntime(componentApplication(component(Owner,0),"host lifetime"))
    proc sink(id:uint64):HostConsumer=
      HostConsumer(sessionId:id,prepare:proc(batch:HostBatch)=discard,
        apply:proc()=discard,accept:proc(revision:uint64) {.raises:[].}=discard,
        discardPrepared:proc() {.raises:[].}=discard)
    let first=attachHostSession(runtime,sink(931))
    var results=0
    try:
      runtime.uiTask(proc()=discard startTask(ownerScope,"live","",blockingWork,proc(v:string)=inc(results)))
      discard runtime.pumpTasks()
      first.close()
      let second=attachHostSession(runtime,sink(932))
      holdWork.store(false)
      for i in 0..<2000:
        discard runtime.pumpTasks()
        if results==1:break
        sleep(1)
      check results==1
      check disposed==0
      check ownerState.set(1)==StateWriteResult.queued
      discard runtime.flush()
      runtime.uiTask(proc()=discard startTask(ownerScope,"retired","",blockingWork,proc(v:string)=inc(results)))
      runtime.runtimeDriver.retireDeferred()
      check not runtime.pumpTasks().pending
      check results==1
      check disposed==0
      check ownerState.set(2)==StateWriteResult.queued # internal retire is metadata only.
      second.close()
      runtime.closeRuntime()
      check ownerState.set(3)==StateWriteResult.disposed
      check disposed==1
    finally:
      holdWork.store(false)
      first.close();runtime.closeRuntime()
