import std/[unittest,atomics,os]
import leaf/[core,widgets,components,managed_runtime,task_service,task_worker]
var releasePage,enteredPage:Atomic[bool]
proc pageWork(input:string,ctx:WorkerContext):string {.nimcall,gcsafe.}=
  enteredPage.store(true)
  while not releasePage.load():sleep(1)
  "done"
var pageScope:TaskScope
var pageState:State[int]
var router:ComponentRouter
var rendersA=0
var retention=cancelOnDeactivate
var lifecycle:seq[string]
let PageA=defineComponent[int,State[int]]("RetentionPageA",
  proc(ctx:MountContext,p:int):State[int]=
    pageScope=ctx.taskScope(retention)
    ctx.onDeactivate(proc(event:LifecycleContext)=lifecycle.add("exit"))
    result=ctx.state(0);pageState=result,
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    inc rendersA
    host(text($ctx.value(s),key="a")))
let Shell=defineComponent[int,int]("RetentionRouter",
  proc(ctx:MountContext,p:int):int=
    router=newComponentRouter(ctx,
      @[Route(name:"a",path:"/",page:"a",view:"main"),Route(name:"b",path:"/b",page:"b",view:"main")],
      @[ComponentPageDefinition(name:"a",views: @["main"],build:proc(view:string):UiDescription=component(PageA,0)),
        ComponentPageDefinition(name:"b",views: @["main"],build:proc(view:string):UiDescription=host(text("b",key="b")))],"/")
    p,
  proc(ctx:ComponentContext,p,m:int):UiDescription=renderPage(ctx,router))
suite "task retained owner delivery":
  test "default cancels on accepted leave while retained policy updates hidden State without render":
    for policy in [cancelOnDeactivate,keepWhileRetained]:
      retention=policy;lifecycle.setLen(0);rendersA=0
      releasePage.store(false);enteredPage.store(false)
      let rt=newRuntime(componentApplication(component(Shell,0),"retention"))
      var calls=0
      try:
        rt.uiTask(proc()=discard startTask(pageScope,"page","",pageWork,proc(v:string)=
          inc calls;lifecycle.add("result");pageState.set(7)))
        discard rt.pumpTasks()
        for i in 0..<2000:
          if enteredPage.load():break
          sleep(1)
        check enteredPage.load()
        rt.uiTask(proc()=discard router.navigate("/b"))
        let before=rendersA
        releasePage.store(true)
        for i in 0..<2000:
          discard rt.pumpTasks()
          if rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0:break
          sleep(1)
        check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0
        check rendersA==before
        if policy==keepWhileRetained:
          check calls==1
          check pageState.read()==7
          check lifecycle == @["exit","result"]
        else:
          check calls==0
          check pageState.read()==0
          check lifecycle == @["exit"]
        rt.uiTask(proc()=discard router.navigate("/"))
        check calls==(if policy==keepWhileRetained:1 else:0)
      finally:
        releasePage.store(true)
        rt.finalizeTaskPoolInternal()

var cycleCalls:Atomic[int]
proc cycleWork(input:string,ctx:WorkerContext):string {.nimcall,gcsafe.}=
  discard cycleCalls.fetchAdd(1)
  input
suite "owner recreation and bounded resource recovery":
  test "500 replace cancel and destroy rounds restore ticket input and result budgets":
    var show:State[bool]
    var scope:TaskScope
    var childState:State[int]
    var cleanup,results=0
    cycleCalls.store(0)
    let Child=defineComponent[int,int]("CycleTaskChild",
      proc(ctx:MountContext,p:int):int=
        scope=ctx.taskScope()
        childState=ctx.state(0)
        ctx.onDispose(proc(event:LifecycleContext)=inc(cleanup));p,
      proc(ctx:ComponentContext,p,m:int):UiDescription=host(text("child")))
    let Root=defineComponent[int,State[bool]]("CycleTaskRoot",
      proc(ctx:MountContext,p:int):State[bool]=result=ctx.state(false);show=result,
      proc(ctx:ComponentContext,p:int,s:State[bool]):UiDescription=
        if ctx.value(s):component(Child,0) else:host(text("empty")))
    let rt=newRuntime(componentApplication(component(Root,0),"cycles"))
    let service=rt.taskServiceInternal()
    try:
      for round in 0..<500:
        rt.uiTask(proc()=show.set(true))
        rt.uiTask(proc()=
          discard startTask(scope,"same","old",cycleWork,proc(v:string)=inc(results))
          discard startTask(scope,"same","new",cycleWork,proc(v:string)=inc(results))
          let cancelled=startTask(scope,"cancel","",cycleWork,proc(v:string)=inc(results))
          cancel(cancelled))
        if round mod 2==1:
          discard rt.pumpTasks()
          for i in 0..<2000:
            if service.readyTaskCountInternal()==1:break
            sleep(1)
          check service.readyTaskCountInternal()==1
        rt.uiTask(proc()=show.set(false))
        discard rt.pumpTasks()
        check childState.set(1)==StateWriteResult.disposed
        check service.taskWorkerStatsInternal().reservedTasks==0
        check service.taskWorkerStatsInternal().inputBytes==0
        check service.taskWorkerStatsInternal().resultBytes==0
      check results==0
      check cleanup==500
      check cycleCalls.load()==250
    finally:rt.closeRuntime()

  test "changing owner key type or Runtime cannot receive an earlier completion":
    for replacement in ["key","type","runtime"]:
      releasePage.store(false);enteredPage.store(false)
      var scope:TaskScope
      var key="old"
      var other=false
      var received:seq[string]
      let First=defineComponent[int,int]("RecreatedTaskFirst",
        proc(ctx:MountContext,p:int):int=scope=ctx.taskScope(keepWhileRetained);p,
        proc(ctx:ComponentContext,p,m:int):UiDescription=host(text("first")))
      let Second=defineComponent[int,int]("RecreatedTaskSecond",
        proc(ctx:MountContext,p:int):int=scope=ctx.taskScope();p,
        proc(ctx:ComponentContext,p,m:int):UiDescription=host(text("second")))
      let Root=defineComponent[int,int]("RecreatedTaskRoot",
        proc(ctx:MountContext,p:int):int=p,
        proc(ctx:ComponentContext,p,m:int):UiDescription=
          if other:component(Second,0,key=key) else:component(First,0,key=key))
      var rt=newRuntime(componentApplication(component(Root,0),"recreate"))
      let original=rt
      try:
        rt.uiTask(proc()=discard startTask(scope,"key","",pageWork,proc(v:string)=received.add(v)))
        discard rt.pumpTasks()
        for i in 0..<2000:
          if enteredPage.load():break
          sleep(1)
        check enteredPage.load()
        if replacement=="runtime":
          rt.runtimeDriver.retireDeferred()
          rt=newRuntime(componentApplication(component(Root,0),"new runtime"))
        else:
          if replacement=="key":key="new" else:other=true
          discard rt.refresh()
        releasePage.store(true)
        if replacement!="runtime":
          for i in 0..<2000:
            discard rt.pumpTasks()
            if rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0:break
            sleep(1)
        else:check not original.pumpTasks().pending
        check received.len==0
      finally:
        releasePage.store(true)
        original.closeRuntime()
        if rt!=original:rt.closeRuntime()

suite "retained router and row cleanup":
  test "router unmount disposes its retained page and drops a late completion":
    retention=keepWhileRetained
    releasePage.store(false);enteredPage.store(false)
    var visible=true
    var results=0
    let Root=defineComponent[int,int]("UnmountTaskRouter",
      proc(ctx:MountContext,p:int):int=p,
      proc(ctx:ComponentContext,p,m:int):UiDescription=
        if visible:component(Shell,0) else:host(text("empty")))
    let rt=newRuntime(componentApplication(component(Root,0),"unmount router"))
    try:
      rt.uiTask(proc()=discard startTask(pageScope,"old","",pageWork,proc(v:string)=inc(results)))
      discard rt.pumpTasks()
      for i in 0..<2000:
        if enteredPage.load():break
        sleep(1)
      check enteredPage.load()
      rt.uiTask(proc()=discard router.navigate("/b"))
      visible=false;discard rt.refresh()
      check pageState.set(1)==StateWriteResult.disposed
      releasePage.store(true)
      for i in 0..<2000:
        discard rt.pumpTasks()
        if rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0:break
        sleep(1)
      check results==0
      visible=true;discard rt.refresh()
      check pageState.read()==0
    finally:
      releasePage.store(true);rt.closeRuntime()

  test "a different list item at the same index cannot receive the earlier row result":
    var keys = @["old"]
    var scope:TaskScope
    var state:State[int]
    var values:seq[string]
    releasePage.store(false);enteredPage.store(false)
    let Row=defineComponent[int,int]("ReuseTaskRow",
      proc(ctx:MountContext,p:int):int=
        scope=ctx.taskScope(keepWhileRetained);state=ctx.state(0);p,
      proc(ctx:ComponentContext,p,m:int):UiDescription=host(text($p)))
    let Root=defineComponent[int,int]("ReuseTaskList",
      proc(ctx:MountContext,p:int):int=p,
      proc(ctx:ComponentContext,p,m:int):UiDescription=
        componentList("reuse",keys,proc(index:int):UiDescription=component(Row,index),rowHeight=20,overscan=0))
    let rt=newRuntime(componentApplication(component(Root,0),"row reuse"))
    try:
      discard rt.materialize("reuse",0,1)
      let oldState=state
      rt.uiTask(proc()=discard startTask(scope,"same","",pageWork,proc(v:string)=values.add("old")))
      discard rt.pumpTasks()
      for i in 0..<2000:
        if enteredPage.load():break
        sleep(1)
      check enteredPage.load()
      keys = @["new"]
      discard rt.refresh()
      discard rt.materialize("reuse",0,1)
      check oldState.set(1)==StateWriteResult.disposed
      rt.uiTask(proc()=discard startTask(scope,"same","new",cycleWork,proc(v:string)=values.add(v)))
      releasePage.store(true)
      for i in 0..<2000:
        discard rt.pumpTasks()
        if rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0:break
        sleep(1)
      check values == @["new"]
      check state.read()==0
    finally:
      releasePage.store(true);rt.closeRuntime()

  test "final close includes warm rows and retained hidden pages with all State already disposed":
    retention=keepWhileRetained
    var rt:Runtime
    var rowStates:seq[State[int]]
    var order:seq[string]
    let Row=defineComponent[int,State[int]]("ClosingWarmRow",
      proc(ctx:MountContext,p:int):State[int]=
        result=ctx.state(p);rowStates.add(result)
        ctx.onDispose(proc(event:LifecycleContext)=
          for state in rowStates:check state.set(1)==StateWriteResult.disposed
          check pageState.set(1)==StateWriteResult.disposed
          order.add("row" & $p)),
      proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s))))
    let Root=defineComponent[int,int]("ClosingRetainedAndWarm",
      proc(ctx:MountContext,p:int):int=
        ctx.onDispose(proc(event:LifecycleContext)=order.add("root"));p,
      proc(ctx:ComponentContext,p,m:int):UiDescription=
        hostShell(column(@[]),@[component(Shell,0),componentList("warm",@["0","1"],
          proc(index:int):UiDescription=component(Row,index),rowHeight=20,overscan=0)]))
    rt=newRuntime(componentApplication(component(Root,0),"close warm retained"))
    discard rt.materialize("warm",0,1)
    discard rt.materialize("warm",1,2)
    rt.uiTask(proc()=discard router.navigate("/b"))
    rt.closeRuntime()
    check "row0" in order
    check "row1" in order
    check order[^1]=="root"

suite "review I1 bounded lifecycle storage":
  test "refused live enters do not retain consumed exit-only or mixed storage":
    for mixed in [false,true]:
      var generation:State[int]
      var allow=0
      var disposes=0
      let Enter=defineComponent[int,int]("BlockedStorageEnter",
        proc(ctx:MountContext,p:int):int=
          ctx.onMount(proc(event:LifecycleContext)=discard);p,
        proc(ctx:ComponentContext,p,m:int):UiDescription=host(text("enter")))
      let Exit=defineComponent[int,int]("ConsumedStorageExit",
        proc(ctx:MountContext,p:int):int=
          ctx.onDispose(proc(event:LifecycleContext)=inc disposes);p,
        proc(ctx:ComponentContext,p,m:int):UiDescription=host(text("exit")))
      let Root=defineComponent[int,State[int]]("BoundedStorageRoot",
        proc(ctx:MountContext,p:int):State[int]=result=ctx.state(0);generation=result,
        proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
          let current=ctx.value(s)
          var children = @[component(Enter,0,key="blocked")]
          if mixed:
            for i in 1..current:children.add(component(Enter,i,key="enter-" & $i))
          for i in 0..<32:children.add(component(Exit,i,key="exit-" & $current & "-" & $i))
          hostShell(column(@[]),children))
      let execution:ExecutionScope=proc(body:proc() {.closure.})=
        if allow==0:fail("retain effective enter")
        if allow>0:dec allow
        body()
      allow = -1
      let rt=newRuntime(componentApplication(component(Root,0),"storage",executionScope=execution))
      let service=rt.taskServiceInternal()
      try:
        service.setTaskClockInternal(proc():int64=0)
        for round in 1..64:
          allow = -1
          rt.uiTask(proc()=generation.set(round))
          allow=32
          let report=rt.pumpTasks()
          check report.callbacks==32
          check report.failed==1
          check disposes==round*32
          let pending=if mixed:round+1 else:1
          check service.pendingTaskBytesInternal()==pending*128
          let storage=service.lifecycleStorageInternal()
          check storage.slots==pending
          check storage.batches<=pending
        allow = -1
        rt.closeRuntime()
        check service.lifecycleStorageInternal()==(batches:0,slots:0)
        check disposes==65*32
      finally:
        allow = -1;rt.closeRuntime()
