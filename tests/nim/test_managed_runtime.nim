import std/[unittest,options]
import leaf/[core,widgets,components]
var counter:State[int]
var renders=0
let Counter=defineComponent[int,State[int]]("Counter",
  proc(ctx:MountContext,props:int):State[int]=
    result=ctx.state(0);counter=result,
  proc(ctx:ComponentContext,props:int,model:State[int]):UiDescription=
    inc renders
    let n=ctx.value(model)
    componentView:
      column:
        text($n,key="value")
        button("+",key="increment",onClick=proc(e:Event)=
          for i in 0..<3:model.update(proc(n:int):int=n+1)))
suite "managed local updates":
  test "one component and bounded hosts independent of static siblings":
    for count in [100,1000,5000]:
      var children = @[component(Counter,0,key="counter")]
      for i in 0..<count:children.add(host(text("static",key="s" & $i)))
      let rt=newRuntime(componentApplication(hostShell(column(@[]),children),"managed"))
      let before=rt.updateStats()
      discard rt.dispatch("increment",Event(kind:click))
      let after=rt.updateStats()
      check counter.read()==3
      check after.componentRenders-before.componentRenders==1
      check after.normalizedHosts-before.normalizedHosts<=3
      check after.snapshotExports==before.snapshotExports
      check after.ops-before.ops==1
      check rt.acceptedRevision==2
      check rt.snapshot.root.children[0].children[0].node.text=="3"
  test "headless queues and batch flush once":
    let rt=newRuntime(componentApplication(component(Counter,0),"batch"))
    counter.set(5)
    check counter.read()==0
    check rt.flush()
    check counter.read()==5
    let before=rt.acceptedRevision
    rt.batch(proc()=
      counter.update(proc(n:int):int=n+1)
      counter.update(proc(n:int):int=n+1))
    check rt.acceptedRevision==before+1
    check counter.read()==7
var rowStates:seq[State[int]]
var childRenders=0
var childState:State[int]
var parentState:State[int]
var removeChild=false
var callbackVersion=0
var observedVersion= -1
let Child=defineComponent[int,State[int]]("ManagedChild",
  proc(ctx:MountContext,p:int):State[int]=
    result=ctx.state(p);childState=result;rowStates.add(result),
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    inc childRenders
    let version=callbackVersion
    discard ctx.value(s)
    host(button("same",key="child-button",onClick=proc(e:Event)=observedVersion=version)))
let Parent=defineComponent[int,State[int]]("ManagedParent",
  proc(ctx:MountContext,p:int):State[int]=
    result=ctx.state(0);parentState=result,
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    discard ctx.value(s)
    if removeChild:host(text("removed"))
    else:component(Child,0,key="child"))
var order = @[1,2]
let Rows=defineComponent[int,int]("ManagedRows",
  proc(ctx:MountContext,p:int):int=p,
  proc(ctx:ComponentContext,p,m:int):UiDescription=
    var kids:seq[UiDescription]
    for i in order:kids.add(component(Child,i,key= $i))
    hostShell(column(@[]),kids))
suite "component identity and dirty descendants":
  test "key reorder retains State; changed key remounts":
    order= @[1,2];rowStates.setLen(0)
    let rt=newRuntime(componentApplication(component(Rows,0),"keys"))
    let first=rowStates[0]
    first.set(42);discard rt.flush()
    order= @[2,1];discard rt.refresh()
    check rowStates.len==2
    check first.read()==42
    order= @[2,3];discard rt.refresh()
    check rowStates.len==3
    check first.set(9)==StateWriteResult.disposed
  test "parent and child render once; removed dirty child never renders":
    removeChild=false;childRenders=0
    let rt=newRuntime(componentApplication(component(Parent,0),"parent"))
    parentState.set(1);childState.set(2)
    let before=childRenders
    discard rt.flush()
    check childRenders==before+1
    removeChild=true;parentState.set(2);childState.set(3)
    let count=childRenders
    discard rt.flush()
    check childRenders==count
    check childState.set(1)==StateWriteResult.disposed
  test "memo skip still updates dirty descendant and callback-only ops are empty":
    removeChild=false;callbackVersion=0
    let MemoParent=memo(Parent,proc(a,b:int):bool=true)
    let rt=newRuntime(componentApplication(component(MemoParent,0),"memo"))
    let before=rt.updateStats()
    callbackVersion=4;childState.set(1)
    discard rt.flush()
    let after=rt.updateStats()
    check after.componentRenders-before.componentRenders==1
    check after.ops==before.ops
    check rt.acceptedRevision==2
    discard rt.dispatch("child-button",Event(kind:click))
    check observedVersion==4
  test "controllable UI tasks flush at completion and root invalidation queues":
    let rt=newRuntime(componentApplication(component(Counter,0),"tasks"))
    var scheduled:seq[proc() {.closure.}]
    scheduled.add(proc()=rt.uiTask(proc()=
      counter.set(8)
      check counter.read()==0
      check rt.acceptedRevision==1))
    check counter.read()==0
    scheduled[0]()
    check counter.read()==8
    rt.invalidateRoot()
    check rt.acceptedRevision==2
    discard rt.flush()
    check rt.acceptedRevision==3
