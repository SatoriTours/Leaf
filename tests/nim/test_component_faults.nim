import std/[unittest,tables]
import leaf/[core,widgets,components,backend,host_session,native_host_adapter]
var cell:State[int]
var callbacks=0
var badBuild=false
let FaultCounter=defineComponent[int,State[int]]("FaultCounter",
  proc(ctx:MountContext,p:int):State[int]=
    result=ctx.state(0);cell=result,
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    if badBuild:fail("candidate build")
    let n=ctx.value(s)
    host(button($n,key="go",onClick=proc(e:Event)=
      inc callbacks;s.update(proc(n:int):int=n+1))))
type Fault=enum none,build,prepare,apply,scopeEntry,scopeExit,closeAfterPrepare,closeAfterApply
suite "managed cross-language commit failures":
  test "rejections preserve State Runtime and consumer revisions without replay":
    for fault in [build,prepare,apply,scopeEntry,closeAfterPrepare,closeAfterApply]:
      badBuild=false;callbacks=0
      var active=none
      let scope:ExecutionScope=proc(body:proc() {.closure.})=
        if active==scopeEntry:fail("scope entry")
        body()
      let rt=newRuntime(componentApplication(component(FaultCounter,0),"fault",executionScope=scope))
      var storeRevision,pendingRevision:uint64
      var session:HostSession
      let sink=HostConsumer(sessionId:71,
        prepare:proc(b:HostBatch)=
          pendingRevision=b.nextRevision
          if active==prepare:fail("prepare")
          if active==closeAfterPrepare:session.requestClose(),
        apply:proc()=
          if active==apply:fail("apply")
          if active==closeAfterApply:session.requestClose(),
        accept:proc(r:uint64) {.raises:[].}=storeRevision=r,
        discardPrepared:proc() {.raises:[].}=pendingRevision=0)
      session=attachHostSession(rt,sink)
      let before=rt.acceptedRevision
      active=fault;badBuild=fault==build
      expect UiError:discard rt.dispatch("go",Event(kind:click))
      check rt.acceptedRevision==before
      check storeRevision==before
      check cell.read()==0
      badBuild=false;active=none
      session.close()
      let calls=callbacks
      discard rt.flush()
      check cell.read()==0
      check callbacks==calls
  test "accepted scope cleanup error advances all revisions once":
    badBuild=false;callbacks=0
    var rejectExit=false
    let scope:ExecutionScope=proc(body:proc() {.closure.})=
      body()
      if rejectExit:fail("scope exit after acceptance")
    let rt=newRuntime(componentApplication(component(FaultCounter,0),"scope",executionScope=scope))
    var storeRevision:uint64
    let session=attachHostSession(rt,HostConsumer(sessionId:72,prepare:proc(b:HostBatch)=discard,
      apply:proc()=discard,accept:proc(r:uint64) {.raises:[].}=storeRevision=r,
      discardPrepared:proc() {.raises:[].}=discard))
    rejectExit=true
    expect UiError:discard rt.dispatch("go",Event(kind:click))
    check storeRevision==rt.acceptedRevision
    check cell.read()==1
    check callbacks==1
    rejectExit=false
    discard rt.flush()
    check callbacks==1
    check cell.read()==1
    session.close()
  test "stale sequence generation and retired session never execute callback":
    badBuild=false;callbacks=0
    let rt=newRuntime(componentApplication(component(FaultCounter,0),"stale"))
    let session=attachHostSession(rt,HostConsumer(sessionId:73,prepare:proc(b:HostBatch)=discard,
      apply:proc()=discard,accept:proc(r:uint64) {.raises:[].}=discard,
      discardPrepared:proc() {.raises:[].}=discard))
    let handle=session.handleFor(rt.find("go").id)
    check session.dispatch(handle,1,rt.acceptedRevision,1,1,Event(kind:click))
    check not session.dispatch(handle,1,rt.acceptedRevision,1,1,Event(kind:click))
    check not session.dispatch(handle,2,rt.acceptedRevision,0,1,Event(kind:click))
    check not session.dispatch(handle,2,rt.acceptedRevision+1,1,1,Event(kind:click))
    session.close()
    check not session.dispatch(handle,3,rt.acceptedRevision,1,1,Event(kind:click))
    check callbacks==1
  test "restore failure freezes subsequent business callbacks":
    badBuild=false;callbacks=0
    var reject=false
    let rt=newRuntime(componentApplication(component(FaultCounter,0),"restore"))
    let b=Backend(capabilities:fullCapabilities(),prepare:proc(batch:UpdateBatch)=discard,
      apply:proc(batch:UpdateBatch)=
        if reject:fail("apply failed"),
      restore:proc(e:Table[NodeHandle,MountedEntity])=fail("restore failed"),
      discardPrepared:proc()=discard,dispose:proc()=discard)
    let session=attachHostSession(rt,nativeHostConsumer(b,onFault=proc(reason:string) {.raises:[].}=rt.freezeEvents(reason)))
    let before=rt.acceptedRevision
    reject=true
    expect UiError:discard rt.dispatch("go",Event(kind:click))
    check rt.acceptedRevision==before
    check cell.read()==0
    let callsBeforeFreeze=callbacks
    expect UiError:discard rt.dispatch("go",Event(kind:click))
    check callbacks==callsBeforeFreeze
    session.close()
var retainedContext:ComponentContext
let RetainContext=defineComponent[int,State[int]]("RetainedContext",
  proc(ctx:MountContext,p:int):State[int]=ctx.state(0),
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    retainedContext=ctx
    let n=ctx.value(s)
    host(button($n,key="queue",onClick=proc(e:Event)=s.set(n+1))))
suite "commit reentrancy":
  test "retained context cannot invalidate during backend apply":
    let rt=newRuntime(componentApplication(component(RetainContext,0),"reentrant"))
    var inspect=false
    let session=attachHostSession(rt,HostConsumer(sessionId:74,prepare:proc(b:HostBatch)=discard,
      apply:proc()=
        if inspect:
          expect UiError:retainedContext.invalidate(),
      accept:proc(r:uint64) {.raises:[].}=discard,
      discardPrepared:proc() {.raises:[].}=discard))
    inspect=true
    discard rt.dispatch("queue",Event(kind:click))
    session.close()
