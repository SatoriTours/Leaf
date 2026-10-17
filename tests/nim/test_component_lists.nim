import std/[unittest,tables]
import leaf/[core,widgets,components]
var initializedRows=0
var handles:Table[int,State[int]]
var failAt= -1
let ListRow=defineComponent[int,State[int]]("ListRow",
  proc(ctx:MountContext,p:int):State[int]=
    inc initializedRows
    result=ctx.state(p);handles[p]=result,
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=host(text($ctx.value(s),key="row")))
proc listRoot():UiDescription=
  var keys:seq[string]
  for i in 0..<100000:keys.add($i)
  componentList("items",keys,proc(i:int):UiDescription=
    if i==failAt:fail("row build")
    component(ListRow,i),rowHeight=24,overscan=0)
suite "managed virtual rows":
  test "only viewport initializes, repeats reuse and evictions dispose":
    initializedRows=0;handles.clear();failAt= -1
    let rt=newRuntime(componentApplication(listRoot(),"rows"))
    discard rt.materialize("items",5000,5050)
    check initializedRows==50
    check rt.find("items").children.len==50
    discard rt.materialize("items",5000,5050)
    check initializedRows==50
    let first=handles[5000]
    discard rt.materialize("items",6000,6200,@[5000])
    check first.set(7)==StateWriteResult.queued
    discard rt.flush()
    check first.read()==7
    discard rt.materialize("items",7000,7200)
    check first.set(8)==StateWriteResult.disposed
    check rt.listStats("items").activeRows==200
    check rt.listStats("items").warmRows==0
  test "builder rejection preserves rows revision and State":
    initializedRows=0;handles.clear();failAt= -1
    let rt=newRuntime(componentApplication(listRoot(),"failure"))
    discard rt.materialize("items",10,20)
    let before=rt.acceptedRevision
    failAt=35
    expect UiError:discard rt.materialize("items",30,40)
    check rt.acceptedRevision==before
    check rt.find("items").children[0].listIndex==10
    check handles[10].read()==10
    check handles[30].set(0)==StateWriteResult.disposed
    failAt= -1
var currentList:UiDescription
let ListOwner=defineComponent[int,int]("ListOwner",
  proc(ctx:MountContext,p:int):int=p,
  proc(ctx:ComponentContext,p,m:int):UiDescription=currentList)
suite "list source transactions":
  test "new source rebuilds row owners and failed replacement preserves old rows":
    initializedRows=0;handles.clear();failAt= -1
    currentList=listRoot()
    let rt=newRuntime(componentApplication(component(ListOwner,0),"source"))
    discard rt.materialize("items",10,20)
    let old=handles[10]
    let oldGeneration=rt.find("items").node.listSource.generation
    currentList=listRoot();failAt=15
    let revision=rt.acceptedRevision
    expect UiError:discard rt.refresh()
    check rt.acceptedRevision==revision
    check rt.find("items").node.listSource.generation==oldGeneration
    check old.read()==10
    failAt= -1
    discard rt.refresh()
    check old.set(1)==StateWriteResult.disposed
    check rt.find("items").children.len==10
    check rt.find("items").children[0].listIndex==10
  test "overlapping viewports preserve key State and warm reactivation":
    initializedRows=0;handles.clear()
    let rt=newRuntime(componentApplication(listRoot(),"overlap"))
    discard rt.materialize("items",0,50)
    let state=handles[20]
    state.set(90);discard rt.flush()
    check rt.find("items").children[20].listIndex==20
    discard rt.materialize("items",25,75)
    discard rt.materialize("items",0,50)
    check initializedRows==75
    check state.read()==90
    check rt.find("items").children.len==50
import std/json
import leaf/gpui_bridge
suite "managed ABI 1 list compatibility":
  test "legacy list request exports matching accepted row metadata":
    failAt= -1
    let bridge=newDesktopBridge(componentApplication(listRoot(),"legacy list"))
    let id=bridge.runtime.find("items").id
    let reply=bridge.request(%*{"op":"list","id":id,"first":5000,"finish":5050,"protected":[]})
    check not reply.hasKey("error")
    check bridge.runtime.find("items").children.len==50
    let tree=bridge.runtime.snapshot.toJson()
    check tree["root"]["children"][0]["list_index"].getInt==5000
    check tree["root"]["children"][0]["item_key"].getStr=="5000"

suite "managed row lifecycle":
  test "warm rows deactivate reactivate and evicted State is disposed before cleanup":
    var events: seq[string]
    var rowState: State[int]
    var renders = 0
    let Row = defineComponent[int, State[int]]("LifecycleWarmRow",
      proc(ctx: MountContext, index: int): State[int] =
        result = ctx.state(0)
        if index == 0: rowState = result
        ctx.onMount(proc(event: LifecycleContext) = events.add("mount:" & $index))
        ctx.onActivate(proc(event: LifecycleContext) = events.add("activate:" & $index))
        ctx.onDeactivate(proc(event: LifecycleContext) = events.add("deactivate:" & $index))
        ctx.onDispose(proc(event: LifecycleContext) =
          if index == 0: check rowState.set(1) == StateWriteResult.disposed
          events.add("dispose:" & $index)),
      proc(ctx: ComponentContext, index: int, state: State[int]): UiDescription =
        inc renders
        host(text($ctx.value(state), key = "life-row")))
    var keys: seq[string]
    for i in 0..<400: keys.add($i)
    let root = componentList("life-list", keys,
      proc(index: int): UiDescription = component(Row, index), rowHeight = 20, overscan = 0)
    let runtime = newRuntime(componentApplication(root, "row lifecycle"))
    discard runtime.materialize("life-list", 0, 1)
    discard runtime.pumpTasks()
    check events == @["mount:0"]
    events.setLen(0)
    discard runtime.materialize("life-list", 1, 2)
    discard runtime.pumpTasks()
    check events == @["deactivate:0", "mount:1"]
    let before = renders
    discard rowState.set(7)
    discard runtime.flush()
    check renders == before
    events.setLen(0)
    discard runtime.materialize("life-list", 0, 1)
    discard runtime.pumpTasks()
    check events == @["deactivate:1", "activate:0"]
    check rowState.read() == 7
    events.setLen(0)
    discard runtime.materialize("life-list", 200, 400)
    for i in 0..<20:
      if not runtime.pumpTasks().pending: break
    check events[0..1] == @["dispose:0", "dispose:1"]
    check rowState.set(9) == StateWriteResult.disposed

  test "same candidate created then evicted row never mounts or disposes":
    var events: seq[int]
    var erasedState: State[int]
    let Row = defineComponent[int, State[int]]("LifecycleEphemeralRow",
      proc(ctx: MountContext, index: int): State[int] =
        result = ctx.state(index)
        if index == 0: erasedState = result
        ctx.onMount(proc(event: LifecycleContext) = events.add(index))
        ctx.onDispose(proc(event: LifecycleContext) = events.add(-index-1)),
      proc(ctx: ComponentContext, index: int, state: State[int]): UiDescription = host(text($index)))
    var keys: seq[string]
    for i in 0..200: keys.add($i)
    let runtime = newRuntime(componentApplication(componentList("ephemeral", keys,
      proc(index: int): UiDescription = component(Row, index), rowHeight = 20, overscan = 0), "ephemeral"))
    runtime.setCommitter(proc(accepted, candidate: Runtime) =
      if accepted == nil:
        discard candidate.materialize("ephemeral", 0, 1)
        discard candidate.materialize("ephemeral", 1, 201))
    for i in 0..<20:
      if not runtime.pumpTasks().pending: break
    check events.len == 200
    for i, index in events: check index == i+1
    check erasedState.set(1) == StateWriteResult.disposed

  test "new row retained inactive in the same candidate cannot receive an entering callback":
    var events: seq[string]
    var rowState: State[int]
    var renders0 = 0
    var visible = true
    let Row = defineComponent[int, State[int]]("LifecycleNewInactiveRow",
      proc(ctx: MountContext, index: int): State[int] =
        result = ctx.state(0)
        if index == 0: rowState = result
        ctx.onMount(proc(event: LifecycleContext) = events.add("mount:" & $index))
        ctx.onActivate(proc(event: LifecycleContext) = events.add("activate:" & $index))
        ctx.onDispose(proc(event: LifecycleContext) =
          if index == 0: check rowState.set(99) == StateWriteResult.disposed
          events.add("dispose:" & $index)),
      proc(ctx: ComponentContext, index: int, state: State[int]): UiDescription =
        if index == 0: inc renders0
        host(text($ctx.value(state))))
    let list = componentList("new-inactive", @["0", "1"],
      proc(index: int): UiDescription = component(Row, index), rowHeight = 20, overscan = 0)
    let Root = defineComponent[int, int]("LifecycleNewInactiveRoot",
      proc(ctx: MountContext, props: int): int = 0,
      proc(ctx: ComponentContext, props, model: int): UiDescription =
        if visible: list else: host(text("unmounted")))
    let runtime = newRuntime(componentApplication(component(Root, 0), "new inactive"))
    runtime.setCommitter(proc(accepted, candidate: Runtime) =
      if accepted == nil:
        discard candidate.materialize("new-inactive", 0, 1)
        discard candidate.materialize("new-inactive", 1, 2))
    discard runtime.pumpTasks()
    check events == @["mount:1"]
    check runtime.find("new-inactive").children.len == 1
    check runtime.find("new-inactive").children[0].listIndex == 1
    check runtime.listStats("new-inactive").warmRows == 1
    let count = renders0
    check rowState.set(7) == StateWriteResult.queued
    discard runtime.flush()
    check renders0 == count
    events.setLen(0)
    discard runtime.materialize("new-inactive", 0, 1)
    discard runtime.pumpTasks()
    check events == @["activate:0"]
    check rowState.read() == 7
    events.setLen(0)
    visible = false
    discard runtime.refresh()
    discard runtime.pumpTasks()
    check events == @["dispose:0", "dispose:1"]
    check rowState.set(9) == StateWriteResult.disposed
