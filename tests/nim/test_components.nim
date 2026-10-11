import std/[unittest,options]
import leaf/[core,widgets,components,component_description,component_state]
import fixtures/component_first as first
import fixtures/component_second as second
static:doAssert typeof(column(@[])) is Node
var initialized,rendered:int
let Counter=defineComponent[int,State[int]]("Counter",
  proc(ctx:MountContext,props:int):State[int]=
    inc initialized
    ctx.state(props),
  proc(ctx:ComponentContext,props:int,model:State[int]):UiDescription=
    inc rendered
    host(text($ctx.value(model))))
suite "explicit managed component descriptions":
  test "describing a component never initializes or renders it":
    let node=component(Counter,1,key="counter")
    check node.kind==DescriptionKind.component
    check initialized==0 and rendered==0
    let copy=Counter
    check Counter.typeId==copy.typeId
    check first.SameName.typeId!=second.SameName.typeId
  test "typed models read candidate State only through context":
    let store=newStateStore(1)
    let attempt=store.beginAttempt()
    store.setPhase(StatePhase.initializing)
    let description=component(Counter,3,key="counter")
    let model=description.erased.instantiate(newMountContext(store,1))
    store.setPhase(StatePhase.rendering)
    let output=description.erased.render(newComponentContext(store,attempt,1),model)
    check output.hostNode.text=="3"
    store.setPhase(StatePhase.idle)
    store.accept(attempt)
    check initialized==1 and rendered==1
  test "memo preserves type identity and explicit props versions":
    let memoized=memo(Counter,proc(a,b:int):bool=a==b)
    check memoized.typeId==Counter.typeId
    let previous=component(memoized,1,key="same")
    check component(memoized,1,key="same").erased.equalProps(previous.erased)
    check not component(memoized,2,key="same").erased.equalProps(previous.erased)
    let versioned=component(Counter,1,revision=some(7'u64))
    check component(Counter,9,revision=some(7'u64)).erased.equalProps(versioned.erased)
    check not component(Counter,1,revision=some(8'u64)).erased.equalProps(versioned.erased)
  test "duplicate sibling keys reject descriptions before mount":
    expect UiError:
      discard hostShell(column(@[]),@[component(Counter,1,key="same"),component(Counter,2,key="same")])
    let ordinary=host(column(@[text("a"),text("b")]))
    check ordinary.kind==DescriptionKind.host
    check ordinary.children.len==2
