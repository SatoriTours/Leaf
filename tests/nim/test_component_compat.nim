import std/[unittest,tables]
import leaf/[core,widgets,components,backend,host_session,native_host_adapter,backend_session]
var state:State[int]
let Counter=defineComponent[int,State[int]]("CompatCounter",
  proc(ctx:MountContext,p:int):State[int]=
    result=ctx.state(0);state=result,
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    let n=ctx.value(s)
    host(button($n,key="go",onClick=proc(e:Event)=s.set(n+1))))
suite "managed compatibility":
  test "Snapshot exports cache by accepted revision and validators explicitly export":
    let rt=newRuntime(componentApplication(component(Counter,0),"compat"))
    let before=rt.updateStats()
    discard rt.snapshot;discard rt.snapshot
    check rt.updateStats().snapshotExports-before.snapshotExports==1
    discard rt.dispatch("go",Event(kind:click))
    discard rt.snapshot;discard rt.snapshot
    check rt.updateStats().snapshotExports-before.snapshotExports==2
    rt.setValidator(proc(snapshot:Snapshot)=check snapshot.root!=nil)
    check rt.updateStats().snapshotExports-before.snapshotExports==2
  test "native adapter submits local ops and accepted delta":
    var batches:seq[UpdateBatch]
    var accepted:HostAcceptedDelta
    let backend=Backend(capabilities:fullCapabilities(),
      prepare:proc(b:UpdateBatch)=batches.add(b),apply:proc(b:UpdateBatch)=discard,
      discardPrepared:proc()=discard,restore:proc(e:Table[NodeHandle,MountedEntity])=discard,
      dispose:proc()=discard,
      acceptedDelta:proc(d:HostAcceptedDelta) {.raises:[].}=accepted=d)
    let rt=newRuntime(componentApplication(component(Counter,0),"native"))
    let session=attachHostSession(rt,nativeHostConsumer(backend))
    let exports=rt.updateStats().snapshotExports
    discard rt.dispatch("go",Event(kind:click))
    check batches[^1].ops.len==1
    check batches[^1].ops[0].kind==opUpdate
    check accepted.upserts.len==1
    check rt.updateStats().snapshotExports==exports
    session.close()
  test "legacy accepted metadata receives complete compatibility map":
    var count=0
    let backend=Backend(capabilities:fullCapabilities(),prepare:proc(b:UpdateBatch)=discard,
      apply:proc(b:UpdateBatch)=discard,discardPrepared:proc()=discard,
      restore:proc(e:Table[NodeHandle,MountedEntity])=discard,dispose:proc()=discard,
      accepted:proc(e:Table[NodeHandle,MountedEntity],r:uint64) {.raises:[].}=count=e.len)
    let rt=newRuntime(componentApplication(host(column(@[text("a"),text("b") ])),"legacy"))
    let session=attachHostSession(rt,nativeHostConsumer(backend))
    check count==3
    session.close()
  test "validator candidate exports are cached for subsequent explicit query":
    let rt=newRuntime(componentApplication(component(Counter,0),"validate"))
    rt.setValidator(proc(s:Snapshot)=discard)
    let before=rt.updateStats().snapshotExports
    discard rt.dispatch("go",Event(kind:click))
    check rt.updateStats().snapshotExports==before+1
    discard rt.snapshot
    check rt.updateStats().snapshotExports==before+1
var reverseOrder=false
let Ordered=defineComponent[int,int]("CompatOrdered",
  proc(ctx:MountContext,p:int):int=p,
  proc(ctx:ComponentContext,p,m:int):UiDescription=
    var children:seq[Node]
    for i in 0..<5000:
      let index=if reverseOrder:4999-i else:i
      children.add(text($index,key= $index))
    host(column(children,key="ordered")))
suite "native final sibling order":
  test "reverse 5000 assigns final indices directly":
    reverseOrder=false
    var final:UpdateBatch
    let backend=Backend(capabilities:fullCapabilities(),prepare:proc(b:UpdateBatch)=final=b,
      apply:proc(b:UpdateBatch)=discard,discardPrepared:proc()=discard,
      restore:proc(e:Table[NodeHandle,MountedEntity])=discard,dispose:proc()=discard)
    let rt=newRuntime(componentApplication(component(Ordered,0),"order"))
    let session=attachHostSession(rt,nativeHostConsumer(backend))
    reverseOrder=true
    discard rt.refresh()
    check final.finalOrders.len==1
    check final.finalOrders[0].children.len==5000
    check final.ops.len==5000
    for op in final.ops:check op.kind==opMove
    session.close()

var coloredState:State[int]
let Colored=defineComponent[int,State[int]]("CapabilityCounter",
  proc(ctx:MountContext,p:int):State[int]=
    result=ctx.state(0);coloredState=result,
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    let n=ctx.value(s)
    host(button($n,key="change",styles=(if n==0:default(Styles) else:style({"color":"#ff0000"})),
      onClick=proc(e:Event)=s.set(1))))
suite "managed native capability updates":
  test "strict rejects changed unsupported decorations before backend prepare":
    var prepared=0
    var caps=fullCapabilities();caps.decorations.excl(dfColor)
    let prepare=proc(b:UpdateBatch)=inc prepared
    let backend=Backend(capabilities:caps,prepare:prepare,
      apply:proc(b:UpdateBatch)=discard,discardPrepared:proc()=discard,
      restore:proc(e:Table[NodeHandle,MountedEntity])=discard,dispose:proc()=discard)
    let rt=newRuntime(componentApplication(component(Colored,0),"strict"))
    let session=attachBackend(rt,backend,HostContext(sessionId:91,mountGeneration:1,scale:1,contentWidth:640,contentHeight:480),strict)
    let revision=rt.acceptedRevision
    expect UiError:discard rt.dispatch("change",Event(kind:click))
    check coloredState.read()==0
    check rt.acceptedRevision==revision
    check prepared==1
    session.dispose()
  test "compatible diagnostics publish only on acceptance and deduplicate":
    var reject=true
    var caps=fullCapabilities();caps.decorations.excl(dfColor)
    let prepare=proc(b:UpdateBatch)=
      if reject and b.revision>1:fail("prepare rejected")
    let backend=Backend(capabilities:caps,prepare:prepare,
      apply:proc(b:UpdateBatch)=discard,discardPrepared:proc()=discard,
      restore:proc(e:Table[NodeHandle,MountedEntity])=discard,dispose:proc()=discard)
    let rt=newRuntime(componentApplication(component(Colored,0),"compatible"))
    let session=attachBackend(rt,backend,HostContext(sessionId:92,mountGeneration:1,scale:1,contentWidth:640,contentHeight:480))
    expect UiError:discard rt.dispatch("change",Event(kind:click))
    check session.capabilityIssues.len==0
    reject=false
    let exports=rt.updateStats().snapshotExports
    discard rt.dispatch("change",Event(kind:click))
    check coloredState.read()==1
    check session.capabilityIssues.len==1
    if session.capabilityIssues.len==1:check session.capabilityIssues[0].property=="color"
    coloredState.set(0);discard rt.flush()
    coloredState.set(1);discard rt.flush()
    check session.capabilityIssues.len==1
    check rt.updateStats().snapshotExports==exports
    session.dispose()
