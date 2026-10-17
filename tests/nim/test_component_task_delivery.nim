import std/[unittest,atomics,os,strutils,osproc,streams,unicode]
import leaf/[core,widgets,components,managed_runtime,task_service,task_worker,host_session]
var workCalls:Atomic[int]
proc echoWork(input:string,ctx:WorkerContext):string {.nimcall,gcsafe.}=
  discard workCalls.fetchAdd(1)
  input
proc badWork(input:string,ctx:WorkerContext):string {.nimcall,gcsafe.}=
  raise newException(ValueError,"worker error 界")
proc largeWork(input:string,ctx:WorkerContext):string {.nimcall,gcsafe.}=repeat('x',65)
proc noisyWork(input:string,ctx:WorkerContext):string {.nimcall,gcsafe.}=
  raise newException(ValueError,repeat("界",2000))
type Fixture=ref object
  scope:TaskScope
  state:State[int]
  values:seq[string]
  errors:seq[TaskFailureKind]
proc makeFixture(f:Fixture,execution:ExecutionScope=nil):Runtime=
  let Owner=defineComponent[int,State[int]]("DeliveryOwner",
    proc(ctx:MountContext,p:int):State[int]=
      f.scope=ctx.taskScope();f.state=ctx.state(0);f.state,
    proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s))))
  newRuntime(componentApplication(component(Owner,0),"delivery",executionScope=execution))
proc pumpUntil(rt:Runtime,done:proc():bool {.closure.})=
  for i in 0..<2000:
    discard rt.pumpTasks()
    if done():return
    sleep(1)
  check done()

# A real child process keeps diagnostic capture independent of the test runner.
if paramCount()==1 and paramStr(1)=="--task4-error-log":
  let f=Fixture();let rt=f.makeFixture()
  var claimed=false
  try:
    rt.uiTask(proc()=discard startTask(f.scope,"unhandled","",noisyWork,proc(value:string)=discard))
    for i in 0..<2000:
      let report=rt.pumpTasks()
      if report.delivered==1:
        doAssert report.callbacks==0 and report.failed==0
        claimed=true
        break
      sleep(1)
    doAssert claimed
  finally:rt.closeRuntime()
  quit(0)

suite "task completion claim and ownership":
  test "completion enters its uiTask once and may update State":
    let f=Fixture();let rt=f.makeFixture()
    try:
      rt.uiTask(proc()=discard startTask(f.scope,"echo","new",echoWork,proc(v:string)=
        f.values.add(v);f.state.set(7)))
      rt.pumpUntil(proc():bool=f.values.len==1)
      check f.values == @["new"]
      check f.state.read()==7
      let revision=rt.acceptedRevision
      discard rt.pumpTasks()
      check f.values.len==1
      check rt.acceptedRevision==revision
      check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0
    finally:rt.finalizeTaskPoolInternal()

  test "callback failure consumes completion and rolls back its queued State and intent":
    let f=Fixture();let rt=f.makeFixture()
    var calls=0
    try:
      rt.uiTask(proc()=discard startTask(f.scope,"fail","value",echoWork,proc(v:string)=
        inc calls
        f.state.set(9)
        discard startTask(f.scope,"nested","",echoWork,proc(v:string)=discard)
        expect UiError:discard rt.pumpTasks()
        fail("delivery callback")))
      rt.pumpUntil(proc():bool=calls==1)
      check f.state.read()==0
      for i in 0..<3:discard rt.pumpTasks()
      check calls==1
      check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0
    finally:rt.finalizeTaskPoolInternal()

  test "work failure and result overflow call their error handlers once":
    let f=Fixture();let rt=f.makeFixture()
    try:
      rt.uiTask(proc()=
        discard startTask(f.scope,"error","",badWork,proc(v:string)=f.values.add(v),
          proc(e:TaskFailure)=
            check e.message=="worker error 界"
            f.errors.add(e.kind))
        discard startTask(f.scope,"overflow","",largeWork,proc(v:string)=f.values.add(v),
          proc(e:TaskFailure)=f.errors.add(e.kind),maxResultBytes=64))
      rt.pumpUntil(proc():bool=f.errors.len==2)
      check workFailed in f.errors
      check resultTooLarge in f.errors
      check f.values.len==0
      discard rt.pumpTasks()
      check f.errors.len==2
    finally:rt.finalizeTaskPoolInternal()

proc awaitReady(rt:Runtime,count:int)=
  for i in 0..<2000:
    if rt.taskServiceInternal().readyTaskCountInternal()>=count:return
    sleep(1)
  check rt.taskServiceInternal().readyTaskCountInternal()>=count
suite "completion scope gates and pump budgets":
  test "entry refusal retains the completed reservation until a successful claim":
    let f=Fixture()
    var refuse=false
    let execution:ExecutionScope=proc(body:proc() {.closure.})=
      if refuse:fail("completion entry")
      body()
    let rt=f.makeFixture(execution)
    try:
      rt.uiTask(proc()=discard startTask(f.scope,"entry","done",echoWork,proc(v:string)=f.values.add(v)))
      discard rt.pumpTasks();rt.awaitReady(1)
      refuse=true
      let denied=rt.pumpTasks()
      check denied.delivered==0
      check denied.failed==1
      check denied.pending
      check f.values.len==0
      check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==1
      refuse=false
      let allowed=rt.pumpTasks()
      check allowed.delivered==1
      check f.values == @["done"]
      check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0
    finally:
      refuse=false;rt.finalizeTaskPoolInternal()

  test "scope application code replacing the request before body causes the old completion to drop":
    let f=Fixture()
    var rt:Runtime
    var replace=false
    let execution:ExecutionScope=proc(body:proc() {.closure.})=
      if replace:
        replace=false
        rt.uiTask(proc()=discard startTask(f.scope,"same","new",echoWork,proc(v:string)=f.values.add(v)))
      body()
    rt=f.makeFixture(execution)
    try:
      rt.uiTask(proc()=discard startTask(f.scope,"same","old",echoWork,proc(v:string)=f.values.add(v)))
      discard rt.pumpTasks();rt.awaitReady(1)
      replace=true
      let report=rt.pumpTasks()
      check report.dropped==1
      check report.delivered==0
      check f.values.len==0
      rt.pumpUntil(proc():bool=f.values.len==1)
      check f.values == @["new"]
    finally:rt.finalizeTaskPoolInternal()

  test "scope exit failure after acceptance does not replay a consumed completion":
    let f=Fixture()
    var rejectExit=false
    let execution:ExecutionScope=proc(body:proc() {.closure.})=
      body()
      if rejectExit:fail("completion scope exit")
    let rt=f.makeFixture(execution)
    try:
      rt.uiTask(proc()=discard startTask(f.scope,"exit","done",echoWork,proc(v:string)=
        f.values.add(v);f.state.set(7)))
      discard rt.pumpTasks();rt.awaitReady(1)
      let before=rt.acceptedRevision
      rejectExit=true
      let report=rt.pumpTasks()
      rejectExit=false
      check report.delivered==1
      check report.failed==1
      check f.state.read()==7
      check rt.acceptedRevision==before+1
      discard rt.pumpTasks()
      check f.values == @["done"]
    finally:
      rejectExit=false;rt.finalizeTaskPoolInternal()

  test "exact 4ms prevents starting the next callback and does not preempt the first":
    let f=Fixture();let rt=f.makeFixture()
    var clock:int64=0
    try:
      rt.uiTask(proc()=
        for i in 0..<3:
          discard startTask(f.scope,$i,$i,echoWork,proc(v:string)=
            f.values.add(v)
            if f.values.len==1:clock=4_000_000))
      discard rt.pumpTasks();rt.awaitReady(3)
      rt.taskServiceInternal().setTaskClockInternal(proc():int64=clock)
      let first=rt.pumpTasks()
      check first.delivered==1
      check first.pending
      check f.values.len==1
      let second=rt.pumpTasks()
      check second.delivered==2
      check not second.pending
    finally:rt.finalizeTaskPoolInternal()

  test "one mount plus result completions share the same 64-record limit":
    var scope:TaskScope
    var extra=false
    var mounted,results=0
    let Hook=defineComponent[int,int]("BudgetHook",
      proc(ctx:MountContext,p:int):int=
        ctx.onMount(proc(event:LifecycleContext)=inc(mounted));p,
      proc(ctx:ComponentContext,p,m:int):UiDescription=host(text("hook")))
    let Root=defineComponent[int,int]("BudgetRoot",
      proc(ctx:MountContext,p:int):int=scope=ctx.taskScope();p,
      proc(ctx:ComponentContext,p,m:int):UiDescription=
        if extra:hostShell(column(@[]),@[component(Hook,0)])
        else:hostShell(column(@[]),@[]))
    let rt=newRuntime(componentApplication(component(Root,0),"budget"))
    try:
      rt.uiTask(proc()=
        for i in 0..<64:discard startTask(scope,$i,"",echoWork,proc(v:string)=inc(results)))
      discard rt.pumpTasks();rt.awaitReady(64)
      extra=true;discard rt.refresh()
      rt.taskServiceInternal().setTaskClockInternal(proc():int64=0)
      let first=rt.pumpTasks()
      check first.delivered==63
      check first.callbacks==64
      check mounted==1
      check results==63
      check first.pending
      let second=rt.pumpTasks()
      check second.delivered==1
      check not second.pending
    finally:rt.finalizeTaskPoolInternal()

  test "empty pumps preserve every structural counter and revision":
    let f=Fixture();let rt=f.makeFixture()
    try:
      let before=rt.updateStats();let stats=rt.stats;let revision=rt.acceptedRevision
      for i in 0..<5:check not rt.pumpTasks().pending
      check rt.updateStats()==before
      check rt.stats==stats
      check rt.acceptedRevision==revision
    finally:rt.finalizeTaskPoolInternal()

suite "completion report and real host rejection":
  test "normal result error-handler callback-failure and absent-handler reports are distinct":
    for mode in ["result","error","throw","no-handler"]:
      let f=Fixture();let rt=f.makeFixture()
      try:
        var errorHandler:TaskErrorHandler
        if mode=="error":errorHandler=proc(error:TaskFailure)=f.errors.add(error.kind)
        rt.uiTask(proc()=
          discard startTask(f.scope,mode,"value",(if mode in ["error","no-handler"]:badWork else:echoWork),
            proc(v:string)=
              f.values.add(v)
              if mode=="throw":fail("report callback"),
            errorHandler))
        discard rt.pumpTasks();rt.awaitReady(1)
        let report=rt.pumpTasks()
        check report.delivered==1
        check report.callbacks==(if mode=="no-handler":0 else:1)
        check report.failed==(if mode=="throw":1 else:0)
        check report.dropped==0
        check not report.pending
      finally:rt.finalizeTaskPoolInternal()

  test "host prepare and apply failure after callback claim never replay work or queued changes":
    for gate in ["prepare","apply"]:
      workCalls.store(0)
      let f=Fixture();let rt=f.makeFixture()
      var armed=false
      var calls=0
      let session=attachHostSession(rt,HostConsumer(sessionId:910,
        prepare:proc(batch:HostBatch)=
          if armed and gate=="prepare":fail("delivery prepare"),
        apply:proc()=
          if armed and gate=="apply":fail("delivery apply"),
        accept:proc(revision:uint64) {.raises:[].}=discard,
        discardPrepared:proc() {.raises:[].}=discard))
      try:
        rt.uiTask(proc()=discard startTask(f.scope,"original","",echoWork,proc(v:string)=
          inc calls;f.state.set(7)
          discard startTask(f.scope,"nested","",echoWork,proc(v:string)=discard)))
        discard rt.pumpTasks();rt.awaitReady(1)
        let revision=rt.acceptedRevision
        armed=true
        let report=rt.pumpTasks()
        armed=false
        check report.delivered==1
        check report.failed==1
        check calls==1
        check f.state.read()==0
        check rt.acceptedRevision==revision
        check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0
        discard rt.pumpTasks()
        check calls==1
        check workCalls.load()==1
      finally:
        armed=false;session.close();rt.finalizeTaskPoolInternal()

var oldHeld,oldStarted,oldCancelled:Atomic[bool]
proc orderedWork(input:string,ctx:WorkerContext):string {.nimcall,gcsafe.}=
  if input=="old":
    oldStarted.store(true)
    while oldHeld.load():sleep(1)
    oldCancelled.store(ctx.cancelled)
  input
suite "late result generation":
  test "new completion delivers first and the cancelled predecessor later drops with no callback":
    oldHeld.store(true);oldStarted.store(false);oldCancelled.store(false)
    let f=Fixture();let rt=f.makeFixture()
    try:
      rt.uiTask(proc()=discard startTask(f.scope,"same","old",orderedWork,proc(v:string)=f.values.add(v)))
      discard rt.pumpTasks()
      for i in 0..<2000:
        if oldStarted.load():break
        sleep(1)
      check oldStarted.load()
      rt.uiTask(proc()=discard startTask(f.scope,"same","new",orderedWork,proc(v:string)=f.values.add(v)))
      rt.pumpUntil(proc():bool=f.values.len==1)
      check f.values == @["new"]
      check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==1
      oldHeld.store(false);rt.awaitReady(1)
      let stale=rt.pumpTasks()
      check stale.delivered==0
      check stale.callbacks==0
      check stale.failed==0
      check stale.dropped==1
      check oldCancelled.load()
      check f.values == @["new"]
    finally:
      oldHeld.store(false);rt.finalizeTaskPoolInternal()

suite "pump clock exception boundary":
  test "a failing injected clock does not leave the pump or finalizer busy":
    let f=Fixture();let rt=f.makeFixture()
    try:
      rt.taskServiceInternal().setTaskClockInternal(proc():int64=fail("clock fixture"))
      expect UiError:discard rt.pumpTasks()
      rt.taskServiceInternal().setTaskClockInternal(nil)
      check not rt.pumpTasks().pending
    finally:rt.finalizeTaskPoolInternal()

suite "unhandled worker diagnostics":
  test "absent error handler claims work failure and logs bounded complete UTF8":
    let child=startProcess(getAppFilename(),args=["--task4-error-log"],options={})
    let diagnostic=child.errorStream.readAll()
    let output=child.outputStream.readAll()
    let exitCode=child.waitForExit()
    child.close()
    check exitCode==0
    check output.len==0
    let prefix="leaf: task owner=1 request=1: "
    check diagnostic.startsWith(prefix)
    let message=strutils.strip(diagnostic[prefix.len..^1],leading=false,trailing=true,chars={'\n'})
    check message.len<=4096
    check validateUtf8(message) == -1
    check message==repeat("界",1365)

suite "review I3 completed cancellation":
  test "repeated cancellation after completion creates no intent or revision":
    let f=Fixture();let rt=f.makeFixture()
    var handle:TaskHandle
    try:
      rt.uiTask(proc()=handle=startTask(f.scope,"finished","ok",echoWork,proc(v:string)=f.values.add(v)))
      rt.pumpUntil(proc():bool=f.values.len==1)
      let before=rt.acceptedRevision
      rt.uiTask(proc()=
        cancel(handle);cancel(handle)
        check not rt.taskServiceInternal().hasTaskIntents())
      check rt.acceptedRevision==before
      check not rt.taskServiceInternal().hasTaskIntents()
    finally:rt.closeRuntime()
