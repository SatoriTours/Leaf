import std/[unittest, atomics, os, strutils]
import leaf/[core, widgets, components, managed_runtime, task_service, task_worker, task_contracts]

var started, finished: Atomic[int]
var releaseWork: Atomic[bool]
proc counted(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  discard started.fetchAdd(1)
  input
proc gated(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  discard started.fetchAdd(1)
  while not releaseWork.load(): sleep(1)
  if ctx.cancelled: discard finished.fetchAdd(1)
  input
var scopes: seq[TaskScope]
var savedCtx: MountContext
var seenRetention: TaskRetention
var seenScope: TaskScope
var initMode = 0
let Owner = defineComponent[int, int]("TaskOwner",
  proc(ctx: MountContext, p: int): int =
    savedCtx = ctx
    if initMode == 5: return p
    if initMode == 1:
      ctx.onMount(proc(event: LifecycleContext) =
        seenRetention = event.taskScope.retention
        seenScope = event.taskScope)
    let scope = ctx.taskScope(keepWhileRetained)
    scopes.add(scope)
    if initMode == 2:
      ctx.onMount(proc(event: LifecycleContext) =
        seenRetention = event.taskScope.retention
        seenScope = event.taskScope)
    if initMode == 3: discard ctx.taskScope()
    if initMode == 4: fail("initializer")
    p,
  proc(ctx: ComponentContext, p, m: int): UiDescription = host(text("owner", key="owner")))
proc makeOwner(): Runtime = newRuntime(componentApplication(component(Owner, 0), "owner"))
proc waitStarted(count: int) =
  for i in 0..<2000:
    if started.load() >= count: return
    sleep(1)
  check started.load() >= count

suite "component task scopes and intents":
  test "implicit and explicit scope order has equal cost and final retention":
    var costs: seq[int]
    for mode in [5, 0, 1, 2]:
      initMode = mode
      let rt = makeOwner()
      try:
        discard rt.pumpTasks()
        costs.add(rt.stats.treeBytes)
        if mode in [1,2]:
          check seenRetention == keepWhileRetained
          check seenScope.taskOwnerInternal == scopes[^1].taskOwnerInternal
          check seenScope.taskGenerationInternal == scopes[^1].taskGenerationInternal
          check seenScope.taskDomainInternal == scopes[^1].taskDomainInternal
        expect UiError: discard savedCtx.taskScope()
      finally: rt.finalizeTaskPoolInternal()
    check costs[1] == costs[0]+128
    check costs[2] == costs[3]
    check costs[2] == costs[1]+128
    initMode = 3
    expect UiError: discard makeOwner()
    initMode = 0

  test "failed initializer scopes never alias a later accepted owner":
    initMode = 4
    expect UiError: discard makeOwner()
    let stale = scopes[^1]
    initMode = 0
    let rt = makeOwner()
    try:
      expect UiError:
        rt.uiTask(proc() = discard startTask(stale, "bad", "", counted, proc(v: string) = discard))
    finally: rt.finalizeTaskPoolInternal()

  test "latest accepted key alone executes and start then cancel submits nothing":
    started.store(0)
    let rt = makeOwner()
    let scope = scopes[^1]
    let service = rt.taskServiceInternal()
    try:
      var old, latest, cancelledHandle: TaskHandle
      rt.uiTask(proc() =
        old = startTask(scope, "key", "old", counted, proc(v: string) = discard)
        latest = startTask(scope, "key", "latest", counted, proc(v: string) = discard)
        cancelledHandle = startTask(scope, "cancelled", "", counted, proc(v: string) = discard)
        cancel(cancelledHandle))
      check started.load() == 0
      check not service.taskCurrentInternal(old)
      check service.taskCurrentInternal(latest)
      check not service.taskCurrentInternal(cancelledHandle)
      check service.taskWorkerStatsInternal().reservedTasks == 1
      discard rt.pumpTasks()
      waitStarted(1)
      check started.load() == 1
    finally: rt.finalizeTaskPoolInternal()

  test "access requires matching Runtime UI scope and rejects malformed payloads before intent":
    let rt = makeOwner()
    let scope = scopes[^1]
    let other = makeOwner()
    try:
      expect UiError: discard startTask(scope, "outside", "", counted, proc(v: string) = discard)
      expect UiError: other.uiTask(proc() = discard startTask(scope, "cross", "", counted, proc(v: string) = discard))
      rt.uiTask(proc() =
        for key in ["", repeat("k",257), "\xFF", "\xED\xA0\x80"]:
          expect UiError: discard startTask(scope, key, "", counted, proc(v: string) = discard)
        for size in [0, -1, 1048577]:
          expect UiError: discard startTask(scope, "limit", "", counted, proc(v: string) = discard, maxResultBytes=size)
        expect UiError: discard startTask(scope, "input", repeat('a',1048577), counted, proc(v: string) = discard)
        expect UiError: discard startTask(scope, "nil", "", nil, proc(v: string) = discard)
        expect UiError: discard startTask(scope, "nil", "", counted, nil)
        discard startTask(scope, repeat("界",85)&"a", repeat('a',1048576), counted, proc(v: string) = discard, maxResultBytes=1048576))
      check rt.taskServiceInternal().taskWorkerStatsInternal().inputBytes == 1048576
      var handle:TaskHandle
      rt.uiTask(proc()=handle=startTask(scope,"handle","",counted,proc(v:string)=discard))
      expect UiError:other.uiTask(proc()=cancel(handle))
      check rt.taskServiceInternal().taskCurrentInternal(handle)
    finally:
      other.finalizeTaskPoolInternal()
      rt.finalizeTaskPoolInternal()

  test "64 unsettled tickets remain charged after running cancellation until actual finish":
    started.store(0); finished.store(0); releaseWork.store(false)
    let rt = makeOwner()
    let scope = scopes[^1]
    let service = rt.taskServiceInternal()
    var handles: seq[TaskHandle]
    try:
      rt.uiTask(proc() =
        for i in 0..<64: handles.add(startTask(scope, $i, "x", gated, proc(v: string) = discard)))
      discard rt.pumpTasks()
      waitStarted(2)
      rt.uiTask(proc() =
        for handle in handles: cancel(handle))
      check service.taskWorkerStatsInternal().reservedTasks == 64
      expect UiError:
        rt.uiTask(proc() = discard startTask(scope, "65", "", counted, proc(v: string) = discard))
      check service.taskWorkerStatsInternal().reservedTasks == 64
      releaseWork.store(true)
      for i in 0..<2000:
        discard rt.pumpTasks()
        if service.taskWorkerStatsInternal().reservedTasks == 0: break
        sleep(1)
      check service.taskWorkerStatsInternal().reservedTasks == 0
      check service.taskWorkerStatsInternal().inputBytes == 0
      check service.taskWorkerStatsInternal().resultBytes == 0
      check started.load() == 2
      check finished.load() == 2
      rt.uiTask(proc() =
        for handle in handles: cancel(handle))
    finally:
      releaseWork.store(true)
      rt.finalizeTaskPoolInternal()

  test "input and result reservation aggregate budgets reject atomically":
    for results in [false, true]:
      let rt = makeOwner()
      let scope = scopes[^1]
      let service = rt.taskServiceInternal()
      try:
        rt.uiTask(proc() =
          for i in 0..<8:
            discard startTask(scope, $i, (if results: "" else: repeat('x',1048576)), counted,
              proc(v: string) = discard, maxResultBytes=(if results:1048576 else:1)))
        let before = rt.acceptedRevision
        expect UiError:
          rt.uiTask(proc() = discard startTask(scope, "overflow", (if results:"" else:"x"), counted,
            proc(v: string) = discard, maxResultBytes=1))
        check rt.acceptedRevision == before
        check service.taskWorkerStatsInternal().reservedTasks == 8
        if results: check service.taskWorkerStatsInternal().resultBytes == 8388608
        else: check service.taskWorkerStatsInternal().inputBytes == 8388608
      finally: rt.finalizeTaskPoolInternal()

  test "pending input budget rejects registration without discarding earlier intents":
    let rt=makeOwner()
    let scope=scopes[^1]
    var rejected=false
    try:
      rt.uiTask(proc()=
        for i in 0..<8:
          discard startTask(scope,$i,repeat('x',1048576),counted,proc(v:string)=discard,maxResultBytes=1)
        try:discard startTask(scope,"overflow","x",counted,proc(v:string)=discard,maxResultBytes=1)
        except UiError:rejected=true)
      check rejected
      check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==8
      check rt.taskServiceInternal().taskWorkerStatsInternal().inputBytes==8388608
    finally:rt.finalizeTaskPoolInternal()

  test "many same-key pending replacements retain just the final bounded request":
    started.store(0)
    let rt=makeOwner()
    let scope=scopes[^1]
    try:
      rt.uiTask(proc()=
        for i in 0..<1000:
          discard startTask(scope,"same",$i,counted,proc(v:string)=discard))
      check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==1
      discard rt.pumpTasks()
      waitStarted(1)
      check started.load()==1
    finally:rt.finalizeTaskPoolInternal()

var childScope:TaskScope
var childHandle:TaskHandle
var hide:State[bool]
var featureEnabled=false
var retentionMode=cancelOnDeactivate
var lifecycleCalls=0
let Child=defineComponent[int,int]("TaskChild",
  proc(ctx:MountContext,p:int):int=
    childScope=ctx.taskScope(retentionMode)
    ctx.onMount(proc(event:LifecycleContext)=inc(lifecycleCalls))
    p,
  proc(ctx:ComponentContext,p,m:int):UiDescription=host(text("child",key="child")))
let Parent=defineComponent[int,State[bool]]("TaskParent",
  proc(ctx:MountContext,p:int):State[bool]=
    result=ctx.state(false);hide=result,
  proc(ctx:ComponentContext,p:int,s:State[bool]):UiDescription=
    var children:seq[UiDescription]
    if featureEnabled and not ctx.value(s):children.add(component(Child,0))
    children.add(host(button("remove",key="remove",onClick=proc(e:Event)=
      childHandle=startTask(childScope,"remove","",counted,proc(v:string)=discard)
      s.set(true))))
    hostShell(column(@[]),children))

suite "owner final facts and admission":
  test "owner removed in the same candidate never starts its task and stale scope is rejected":
    started.store(0);featureEnabled=true;retentionMode=cancelOnDeactivate
    let rt=newRuntime(componentApplication(component(Parent,0),"remove"))
    let oldScope=childScope
    try:
      discard rt.dispatch("remove",Event(kind:click))
      check not rt.taskServiceInternal().taskCurrentInternal(childHandle)
      check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0
      discard rt.pumpTasks()
      check started.load()==0
      expect UiError:rt.uiTask(proc()=discard startTask(oldScope,"stale","",counted,proc(v:string)=discard))
      let before=rt.acceptedRevision
      rt.uiTask(proc()=cancel(childHandle))
      check rt.acceptedRevision==before
    finally:rt.finalizeTaskPoolInternal()

  test "unsupported dynamic registration rejects before lifecycle and worker execution":
    featureEnabled=false;lifecycleCalls=0;started.store(0)
    let rt=newRuntime(componentApplication(component(Parent,0),"admission"))
    try:
      rt.configureTaskPumpInternal(false)
      let before=rt.acceptedRevision
      featureEnabled=true
      expect UiError:discard rt.refresh()
      check rt.acceptedRevision==before
      check lifecycleCalls==0
      check started.load()==0
      check rt.taskServiceInternal().taskWorkerStatsInternal().workerStarts==0
      featureEnabled=false
      rt.configureTaskPumpInternal(true)
      featureEnabled=true
      discard rt.refresh()
      check lifecycleCalls==0
      discard rt.pumpTasks()
      check lifecycleCalls==1
    finally:
      featureEnabled=false
      rt.finalizeTaskPoolInternal()

  test "final pool cleanup refuses callback and scope boundaries without joining":
    let rt=makeOwner()
    let scope=scopes[^1]
    try:
      rt.uiTask(proc()=
        discard startTask(scope,"work","",counted,proc(v:string)=discard)
        expect UiError:rt.finalizeTaskPoolInternal())
      for i in 0..<2000:
        if rt.taskServiceInternal().taskWorkerStatsInternal().workerStarts==2:break
        sleep(1)
      check rt.taskServiceInternal().taskWorkerStatsInternal().workerStarts==2
    finally:rt.finalizeTaskPoolInternal()
    check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0
    expect UiError:rt.uiTask(proc()=discard startTask(scope,"closed","",counted,proc(v:string)=discard))

  test "warm owner final inactive facts filter pending work using its final retention":
    for retention in [cancelOnDeactivate,keepWhileRetained]:
      retentionMode=retention;started.store(0)
      let Row=defineComponent[int,int]("TaskWarmRow",
        proc(ctx:MountContext,index:int):int=
          if index==0:childScope=ctx.taskScope(retentionMode)
          index,
        proc(ctx:ComponentContext,index,model:int):UiDescription=host(text($index)))
      let rt=newRuntime(componentApplication(componentList("rows",@["0","1"],
        proc(index:int):UiDescription=component(Row,index),rowHeight=20,overscan=0),"warm"))
      var arm=false
      try:
        discard rt.materialize("rows",0,1)
        rt.setValidator(proc(snapshot:Snapshot)=discard)
        rt.setPreparer(proc(candidate:Runtime)=
          if arm:discard candidate.materialize("rows",1,2))
        arm=true
        rt.uiTask(proc()=childHandle=startTask(childScope,"warm","",counted,proc(v:string)=discard))
        arm=false
        check rt.listStats("rows").warmRows==1
        check rt.snapshot.root.children[0].listIndex==1
        if retention==cancelOnDeactivate:
          check not rt.taskServiceInternal().taskCurrentInternal(childHandle)
          check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0
          expect UiError:rt.uiTask(proc()=discard startTask(childScope,"inactive","",counted,proc(v:string)=discard))
        else:
          check rt.taskServiceInternal().taskCurrentInternal(childHandle)
          rt.uiTask(proc()=discard startTask(childScope,"inactive","",counted,proc(v:string)=discard))
        discard rt.pumpTasks()
        if retention==cancelOnDeactivate:check started.load()==0
        else:waitStarted(2)
      finally:rt.finalizeTaskPoolInternal()

var phaseScope:TaskScope
var phaseState:State[int]
var renderRejected, initRejected, updaterRejected:bool
let Phases=defineComponent[int,State[int]]("TaskPhaseOwner",
  proc(ctx:MountContext,p:int):State[int]=
    phaseScope=ctx.taskScope()
    try:discard startTask(phaseScope,"init","",counted,proc(v:string)=discard)
    except UiError:initRejected=true
    result=ctx.state(0);phaseState=result,
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    try:discard startTask(phaseScope,"render","",counted,proc(v:string)=discard)
    except UiError:renderRejected=true
    host(text($ctx.value(s))))
when compileOption("threads"):
  var foreignRejected:Atomic[bool]
  proc foreignAccess(scope:ptr TaskScope) {.thread.}=
    try:discard startTask(scope[],"foreign","",counted,proc(v:string)=discard)
    except UiError:foreignRejected.store(true)

suite "task phase and identity isolation":
  test "initializer render updater and foreign UI thread are rejected":
    renderRejected=false;initRejected=false;updaterRejected=false
    let rt=newRuntime(componentApplication(component(Phases,0),"phases"))
    try:
      check renderRejected
      check initRejected
      rt.uiTask(proc()=
        phaseState.update(proc(previous:int):int=
          try:discard startTask(phaseScope,"updater","",counted,proc(v:string)=discard)
          except UiError:updaterRejected=true
          previous+1))
      check updaterRejected
      check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0
      when compileOption("threads"):
        # Deliberately borrow a UI scope only to test foreign-thread rejection;
        # UI remains idle until join. No worker payload ever includes this ref.
        foreignRejected.store(false)
        var borrowed=phaseScope
        var thread:Thread[ptr TaskScope]
        createThread(thread,foreignAccess,addr borrowed)
        joinThread(thread)
        check foreignRejected.load()
    finally:rt.finalizeTaskPoolInternal()

var failNewOwner=false
let RetryChild=defineComponent[int,int]("TaskRetryChild",
  proc(ctx:MountContext,p:int):int=
    childScope=ctx.taskScope()
    savedCtx=ctx
    if failNewOwner:fail("failed candidate initializer")
    p,
  proc(ctx:ComponentContext,p,m:int):UiDescription=host(text("retry")))
let RetryParent=defineComponent[int,int]("TaskRetryParent",
  proc(ctx:MountContext,p:int):int=p,
  proc(ctx:ComponentContext,p,m:int):UiDescription=
    if featureEnabled:component(RetryChild,0)
    else:host(text("empty")))
suite "scope generation rollback":
  test "failed dynamic initialization scope and sealed frame cannot be reused in the same Runtime":
    featureEnabled=false;failNewOwner=false
    let rt=newRuntime(componentApplication(component(RetryParent,0),"retry"))
    try:
      featureEnabled=true;failNewOwner=true
      expect UiError:discard rt.refresh()
      let stale=childScope
      let staleCtx=savedCtx
      failNewOwner=false
      discard rt.refresh()
      expect UiError:discard staleCtx.taskScope()
      expect UiError:rt.uiTask(proc()=discard startTask(stale,"stale","",counted,proc(v:string)=discard))
      rt.uiTask(proc()=discard startTask(childScope,"valid","",counted,proc(v:string)=discard))
      check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==1
    finally:
      failNewOwner=false;featureEnabled=false
      rt.finalizeTaskPoolInternal()

suite "lifecycle task admission":
  test "onMount may start a task but its callback pump never submits that new intent":
    started.store(0)
    var resultCallbacks=0
    let MountStart=defineComponent[int,int]("MountStartsTask",
      proc(ctx:MountContext,p:int):int=
        ctx.onMount(proc(event:LifecycleContext)=
          discard startTask(event.taskScope,"mounted","",counted,proc(v:string)=inc(resultCallbacks)))
        p,
      proc(ctx:ComponentContext,p,m:int):UiDescription=host(text("mounted")))
    let rt=newRuntime(componentApplication(component(MountStart,0),"lifecycle"))
    try:
      let before=rt.acceptedRevision
      discard rt.pumpTasks()
      check started.load()==0
      check resultCallbacks==0
      check rt.acceptedRevision==before+1
      check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==1
      discard rt.pumpTasks()
      waitStarted(1)
      check resultCallbacks==0 # Task4 owns completion callbacks.
    finally:rt.finalizeTaskPoolInternal()

suite "accepted latest-wins replacement":
  test "same-key acceptance alone invalidates and cancels the running predecessor":
    started.store(0);finished.store(0);releaseWork.store(false)
    let rt=makeOwner()
    let scope=scopes[^1]
    let service=rt.taskServiceInternal()
    var predecessor,successor:TaskHandle
    try:
      rt.uiTask(proc()=predecessor=startTask(scope,"same","old",gated,proc(v:string)=discard))
      discard rt.pumpTasks()
      waitStarted(1)
      rt.uiTask(proc()=successor=startTask(scope,"same","new",counted,proc(v:string)=discard))
      check not service.taskCurrentInternal(predecessor)
      check service.taskCurrentInternal(successor)
      check service.taskWorkerStatsInternal().reservedTasks==2
      check started.load()==1
      releaseWork.store(true)
      for i in 0..<2000:
        if finished.load()==1:break
        sleep(1)
      check finished.load()==1
      discard rt.pumpTasks()
      waitStarted(2)
      check started.load()==2
    finally:
      releaseWork.store(true)
      rt.finalizeTaskPoolInternal()
