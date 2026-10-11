import std/unittest
import leaf/[core,widgets,components,host_session]
var value:State[int]
var ordinary=0
var failRender=false
let Counter=defineComponent[int,State[int]]("CommitCounter",
  proc(ctx:MountContext,p:int):State[int]=
    result=ctx.state(0);value=result,
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    if failRender:fail("render")
    let n=ctx.value(s)
    host(button($n,key="run",onClick=proc(e:Event)=
      inc ordinary;s.update(proc(n:int):int=n+1))))
suite "managed transactional acceptance":
  test "backend failures reject State and retry never replays":
    let rt=newRuntime(componentApplication(component(Counter,0),"test"))
    var reject=true
    let consumer=HostConsumer(sessionId:99,prepare:proc(b:HostBatch)=discard,
      apply:proc()=
        if reject:fail("apply"),
      accept:proc(r:uint64) {.raises:[].}=discard,
      discardPrepared:proc() {.raises:[].}=discard)
    reject=false
    let session=attachHostSession(rt,consumer)
    reject=true
    expect UiError:discard rt.dispatch("run",Event(kind:click))
    check value.read()==0
    check rt.acceptedRevision==1
    reject=false
    discard rt.dispatch("run",Event(kind:click))
    check value.read()==1
    check ordinary==2
    check rt.find("run").node.text=="1"
    session.close()
  test "render rejection and accepted scope cleanup":
    failRender=false
    var cleanup=false
    let scope:ExecutionScope=proc(body:proc() {.closure.})=
      body()
      if cleanup:fail("scope cleanup")
    let rt=newRuntime(componentApplication(component(Counter,0),"scope",executionScope=scope))
    failRender=true
    expect UiError:discard rt.dispatch("run",Event(kind:click))
    check value.read()==0
    failRender=false;cleanup=true
    expect UiError:discard rt.dispatch("run",Event(kind:click))
    check value.read()==1
    check rt.acceptedRevision==2
var grow=false
let Growth=defineComponent[int,int]("GrowthBudget",
  proc(ctx:MountContext,p:int):int=p,
  proc(ctx:ComponentContext,p,m:int):UiDescription=
    var children:seq[UiDescription]
    if grow:
      for i in 0..<10000:children.add(host(text("x")))
    hostShell(column(@[]),children))
suite "managed candidate limits":
  test "local growth cannot bypass aggregate instance budget":
    grow=false
    let rt=newRuntime(componentApplication(component(Growth,0),"limits"))
    grow=true
    rt.invalidateRoot()
    expect UiError:discard rt.flush()
    check rt.acceptedRevision==1
    check rt.snapshot.root.children.len==0
    grow=false
    discard rt.refresh()
    check rt.acceptedRevision==2
