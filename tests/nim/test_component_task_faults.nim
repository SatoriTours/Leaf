import std/[unittest, atomics, os]
when not compileOption("threads"):import std/strutils
import leaf/[core, widgets, components, host_session, task_service, managed_runtime, task_contracts, task_worker]

var calls: Atomic[int]
proc work(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  discard calls.fetchAdd(1)
  input
var scope: TaskScope
var cell: State[int]
var nextHandle: TaskHandle
var failBuild = false
let Subject = defineComponent[int, State[int]]("TaskGateSubject",
  proc(ctx: MountContext, p: int): State[int] =
    scope = ctx.taskScope()
    result = ctx.state(0)
    cell = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    if failBuild: fail("build")
    host(button($ctx.value(s), key="go", onClick=proc(e: Event) =
      s.set(s.read()+1)
      nextHandle = startTask(scope, "key", "new", work, proc(value: string) = discard))))

when not compileOption("threads"):
  if paramCount()==1 and paramStr(1)=="--task-startup-unavailable":
    let rt=newRuntime(componentApplication(component(Subject,0),"startup"))
    var gateCalls=0
    let session=attachHostSession(rt,HostConsumer(sessionId:809,
      prepare:proc(batch:HostBatch)=inc(gateCalls),
      apply:proc()=discard,
      accept:proc(revision:uint64) {.raises:[].}=discard,
      discardPrepared:proc() {.raises:[].}=discard))
    try:
      let before=rt.acceptedRevision
      let beforeGates=gateCalls
      var rejected=false
      try:discard rt.dispatch("go",Event(kind:click))
      except UiError as error:
        rejected=error.msg.contains("--threads:on")
      doAssert rejected
      doAssert cell.read()==0
      doAssert rt.acceptedRevision==before
      doAssert gateCalls==beforeGates
      doAssert not rt.taskServiceInternal().taskCurrentInternal(nextHandle)
      doAssert rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0
      stdout.writeLine("PASS threads-off worker startup rejects before host prepare, State/revision/intent unchanged")
    finally:
      session.close()
      rt.finalizeTaskPoolInternal()
    quit(0)

suite "task intent acceptance gates":
  test "real HostConsumer rejection leaves State revision and worker work unchanged":
    for gate in ["prepare", "apply", "build"]:
      calls.store(0)
      var armed = false
      let rt = newRuntime(componentApplication(component(Subject, 0), "tasks"))
      let service = rt.taskServiceInternal()
      var accepted: uint64
      let session = attachHostSession(rt, HostConsumer(sessionId: 810,
        prepare: proc(batch: HostBatch) =
          if armed and gate == "prepare": fail("prepare"),
        apply: proc() =
          if armed and gate == "apply": fail("apply"),
        accept: proc(revision: uint64) {.raises: [].} = accepted = revision,
        discardPrepared: proc() {.raises: [].} = discard))
      try:
        let before = rt.acceptedRevision
        armed = true
        failBuild = gate == "build"
        expect UiError: discard rt.dispatch("go", Event(kind: click))
        failBuild = false
        check cell.read() == 0
        check rt.acceptedRevision == before
        check accepted == before
        discard rt.pumpTasks()
        check calls.load() == 0
        check not service.taskCurrentInternal(nextHandle)
        check service.taskWorkerStatsInternal().reservedTasks == 0
      finally:
        failBuild = false
        session.close()
        rt.finalizeTaskPoolInternal()

  test "task-only keeps validator prepare apply gates without exporting another Snapshot":
    let rt = newRuntime(componentApplication(component(Subject, 0), "metadata"))
    var validations, preparations, applies: int
    var operationCount = -1
    rt.setValidator(proc(snapshot: Snapshot) = inc validations)
    let session = attachHostSession(rt, HostConsumer(sessionId: 811,
      prepare: proc(batch: HostBatch) =
        inc preparations
        operationCount = batch.ops.len,
      apply: proc() = inc(applies),
      accept: proc(revision: uint64) {.raises: [].} = discard,
      discardPrepared: proc() {.raises: [].} = discard))
    try:
      let before = rt.updateStats()
      let revision = rt.acceptedRevision
      let v = validations
      let p = preparations
      let a = applies
      rt.uiTask(proc() =
        discard startTask(scope, "only", "metadata", work, proc(value: string) = discard))
      check rt.acceptedRevision == revision+1
      check rt.updateStats().componentRenders == before.componentRenders
      check rt.updateStats().snapshotExports == before.snapshotExports
      check validations == v+1
      check preparations == p+1
      check applies == a+1
      check operationCount == 0
      check calls.load() == 0
    finally:
      session.close()
      rt.finalizeTaskPoolInternal()

  test "host hook installation cannot register start or cancel from its application scope":
    let rt = newRuntime(componentApplication(component(Subject, 0), "hook"))
    var handle: TaskHandle
    rt.uiTask(proc() = handle = startTask(scope, "old", "old", work, proc(v: string) = discard))
    var startsRejected, cancelsRejected = false
    try:
      let session = attachHostSession(rt, HostConsumer(sessionId: 812,
        prepare: proc(batch: HostBatch) =
          try: discard startTask(scope, "bad", "", work, proc(v: string) = discard)
          except UiError: startsRejected = true
          try: cancel(handle)
          except UiError: cancelsRejected = true,
        apply: proc() = discard,
        accept: proc(revision: uint64) {.raises: [].} = discard,
        discardPrepared: proc() {.raises: [].} = discard))
      session.close()
      check startsRejected
      check cancelsRejected
      check rt.taskServiceInternal().taskCurrentInternal(handle)
    finally: rt.finalizeTaskPoolInternal()

  test "repeated cancel of an already cancelled handle is a metadata no-op":
    let rt = newRuntime(componentApplication(component(Subject, 0), "cancel"))
    try:
      var handle: TaskHandle
      rt.uiTask(proc() = handle = startTask(scope, "old", "old", work, proc(v: string) = discard))
      rt.uiTask(proc() = cancel(handle))
      let before = rt.acceptedRevision
      rt.uiTask(proc() = cancel(handle))
      check rt.acceptedRevision == before
    finally: rt.finalizeTaskPoolInternal()

var gateName = ""
var gateArmed = false
var oldHandle, replacement: TaskHandle
var router: ComponentRouter
var oldBegan, oldEnded, oldSawCancel, newBegan: Atomic[int]
var finishOld: Atomic[bool]
proc observedWork(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  if input == "old":
    discard oldBegan.fetchAdd(1)
    while not finishOld.load(): sleep(1)
    if ctx.cancelled: discard oldSawCancel.fetchAdd(1)
    discard oldEnded.fetchAdd(1)
  else: discard newBegan.fetchAdd(1)
  input
let Transaction = defineComponent[int, State[int]]("TaskRouteTransaction",
  proc(ctx: MountContext, p: int): State[int] =
    scope = ctx.taskScope()
    router = newComponentRouter(ctx,
      @[Route(name:"a",path:"/",page:"page",view:"a"), Route(name:"b",path:"/b",page:"page",view:"b")],
      @[ComponentPageDefinition(name:"page",views: @["a","b"],
        build:proc(view:string):UiDescription=host(text(view,key="page")))], "/")
    result = ctx.state(0)
    cell = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    if gateArmed and gateName == "build": fail("candidate build")
    hostShell(column(@[]), @[
      renderPage(ctx, router),
      host(button($ctx.value(s), key="go", onClick=proc(e: Event) =
        if gateName == "updater":
          s.update(proc(previous:int):int=fail("updater"))
        else:s.set(1)
        discard router.navigate("/b")
        cancel(oldHandle)
        replacement = startTask(scope, "key", "new", observedWork, proc(v: string) = discard,
          maxResultBytes=(if gateName == "budget":1048576 else:65536))
        if gateName == "body":fail("event body")))]))

proc awaitAtomic(value: var Atomic[int], expected: int) =
  for i in 0..<2000:
    if value.load() >= expected: return
    sleep(1)
  check value.load() >= expected

suite "task State and route failure matrix":
  test "each rejecting gate preserves the running request cancellation State route and revision":
    for gate in ["body", "updater", "build", "validator", "preparer", "prepare", "apply", "scope-entry", "budget"]:
      gateName = gate; gateArmed = false
      oldBegan.store(0); oldEnded.store(0); oldSawCancel.store(0); newBegan.store(0); finishOld.store(false)
      let execution: ExecutionScope = proc(body: proc() {.closure.}) =
        if gateArmed and gateName == "scope-entry": fail("entry")
        body()
      let rt = newRuntime(componentApplication(component(Transaction, 0), "matrix", executionScope=execution))
      let service = rt.taskServiceInternal()
      rt.setValidator(proc(snapshot: Snapshot) =
        if gateArmed and gateName == "validator": fail("validator"))
      rt.setPreparer(proc(candidate: Runtime) =
        if gateArmed and gateName == "preparer": fail("preparer"))
      var consumerRevision: uint64
      let session = attachHostSession(rt, HostConsumer(sessionId:820,
        prepare:proc(batch:HostBatch)=
          if gateArmed and gateName == "prepare":fail("prepare"),
        apply:proc()=
          if gateArmed and gateName == "apply":fail("apply"),
        accept:proc(revision:uint64) {.raises:[].}=consumerRevision=revision,
        discardPrepared:proc() {.raises:[].}=discard))
      try:
        rt.uiTask(proc() =
          oldHandle=startTask(scope,"key","old",observedWork,proc(v:string)=discard)
          if gate == "budget":
            for i in 0..<7:
              discard startTask(scope,"reserved" & $i,"",work,proc(v:string)=discard,maxResultBytes=1048576))
        discard rt.pumpTasks()
        awaitAtomic(oldBegan,1)
        let before = rt.acceptedRevision
        let beforeStats = service.taskWorkerStatsInternal()
        gateArmed=true
        expect UiError:discard rt.dispatch("go",Event(kind:click))
        gateArmed=false
        check cell.read()==0
        check router.currentRoute.path=="/"
        check rt.acceptedRevision==before
        check consumerRevision==before
        check service.taskCurrentInternal(oldHandle)
        check not service.taskCurrentInternal(replacement)
        check service.taskWorkerStatsInternal().reservedTasks==beforeStats.reservedTasks
        check service.taskWorkerStatsInternal().resultBytes==beforeStats.resultBytes
        discard rt.pumpTasks()
        check newBegan.load()==0
        finishOld.store(true)
        awaitAtomic(oldEnded,1)
        check oldSawCancel.load()==0
      finally:
        gateArmed=false;finishOld.store(true)
        session.close()
        rt.finalizeTaskPoolInternal()

  test "accepted scope exit error preserves intents and only a later safe pump starts work":
    gateName="exit";gateArmed=false
    oldBegan.store(0);oldEnded.store(0);oldSawCancel.store(0);newBegan.store(0);finishOld.store(false)
    let execution:ExecutionScope=proc(body:proc() {.closure.})=
      body()
      if gateArmed:fail("scope exit")
    let rt=newRuntime(componentApplication(component(Transaction,0),"exit",executionScope=execution))
    let service=rt.taskServiceInternal()
    var consumerRevision:uint64
    let session=attachHostSession(rt,HostConsumer(sessionId:821,
      prepare:proc(batch:HostBatch)=discard,
      apply:proc()=discard,
      accept:proc(revision:uint64) {.raises:[].}=consumerRevision=revision,
      discardPrepared:proc() {.raises:[].}=discard))
    try:
      rt.uiTask(proc()=oldHandle=startTask(scope,"key","old",observedWork,proc(v:string)=discard))
      discard rt.pumpTasks()
      awaitAtomic(oldBegan,1)
      let before=rt.acceptedRevision
      gateArmed=true
      expect UiError:discard rt.dispatch("go",Event(kind:click))
      gateArmed=false
      check cell.read()==1
      check router.currentRoute.path=="/b"
      check rt.acceptedRevision==before+1
      check consumerRevision==before+1
      check not service.taskCurrentInternal(oldHandle)
      check service.taskCurrentInternal(replacement)
      check newBegan.load()==0
      discard rt.pumpTasks()
      awaitAtomic(newBegan,1)
      finishOld.store(true)
      awaitAtomic(oldEnded,1)
      check oldSawCancel.load()==1
      discard rt.flush()
      check newBegan.load()==1
    finally:
      gateArmed=false;finishOld.store(true)
      session.close()
      rt.finalizeTaskPoolInternal()

suite "metadata snapshot cache and publication":
  test "constructor validator caches its initial Snapshot and actual UI updates invalidate it":
    calls.store(0)
    var latestText=""
    let validator:SnapshotValidator=proc(snapshot:Snapshot)=latestText=snapshot.root.node.text
    let rt=newRuntime(componentApplication(component(Subject,0),"initial"),validator=validator)
    try:
      let initial=rt.updateStats()
      check latestText=="0"
      rt.uiTask(proc()=discard startTask(scope,"metadata","",work,proc(v:string)=discard))
      check rt.updateStats().snapshotExports==initial.snapshotExports
      check latestText=="0"
      rt.uiTask(proc()=cell.set(7))
      check latestText=="7"
      check rt.updateStats().snapshotExports==initial.snapshotExports+1
      check rt.updateStats().componentRenders==initial.componentRenders+1
      check calls.load()==0
    finally:rt.finalizeTaskPoolInternal()

  test "host prepare sees reservations but no submitted work and rejected cancellation leaves old valid":
    let rt=newRuntime(componentApplication(component(Subject,0),"prepared"))
    let service=rt.taskServiceInternal()
    var inspect=false
    var old:TaskHandle
    var observed=false
    let session=attachHostSession(rt,HostConsumer(sessionId:831,
      prepare:proc(batch:HostBatch)=
        if inspect:
          observed=service.taskWorkerStatsInternal().reservedTasks==2 and service.taskWorkerStatsInternal().workCalls==0
          check service.taskCurrentInternal(old)
          expect UiError:discard startTask(scope,"host","",work,proc(v:string)=discard)
          fail("prepare rejects"),
      apply:proc()=discard,
      accept:proc(revision:uint64) {.raises:[].}=discard,
      discardPrepared:proc() {.raises:[].}=discard))
    try:
      rt.uiTask(proc()=old=startTask(scope,"key","old",work,proc(v:string)=discard))
      inspect=true
      expect UiError:rt.uiTask(proc()=
        cancel(old)
        discard startTask(scope,"key","new",work,proc(v:string)=discard))
      check observed
      check service.taskCurrentInternal(old)
      check service.taskWorkerStatsInternal().reservedTasks==1
    finally:
      session.close()
      rt.finalizeTaskPoolInternal()

  test "start then cancel still seals an empty metadata candidate through the host gate":
    let rt=newRuntime(componentApplication(component(Subject,0),"net-empty"))
    var gates=0
    let session=attachHostSession(rt,HostConsumer(sessionId:832,
      prepare:proc(batch:HostBatch)=inc(gates),
      apply:proc()=discard,
      accept:proc(revision:uint64) {.raises:[].}=discard,
      discardPrepared:proc() {.raises:[].}=discard))
    try:
      let before=rt.acceptedRevision
      let previousGates=gates
      rt.uiTask(proc()=
        let handle=startTask(scope,"cancel","",work,proc(v:string)=discard)
        cancel(handle))
      check gates==previousGates+1
      check rt.acceptedRevision==before+1
      check rt.taskServiceInternal().taskWorkerStatsInternal().reservedTasks==0
      let unchanged=rt.acceptedRevision
      rt.uiTask(proc()=discard)
      check rt.acceptedRevision==unchanged
    finally:
      session.close()
      rt.finalizeTaskPoolInternal()
