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
