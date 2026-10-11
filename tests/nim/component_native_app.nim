import std/os
import leaf
import leaf/components
type Model=object
  count,submissions:State[int]
  value:State[string]
let Add=defineComponent[State[int],int]("NativeAdd",
  proc(ctx:MountContext,p:State[int]):int=0,
  proc(ctx:ComponentContext,p:State[int],m:int):UiDescription=
    host(button("GPUI Kit → Nim",key="add",onClick=proc(e:Event)=p.update(proc(n:int):int=n+1),
      styles=style({"height":"36","width":"200"}))))
let Main=defineComponent[int,Model]("NativeMain",
  proc(ctx:MountContext,p:int):Model=
    Model(count:ctx.state(0),submissions:ctx.state(0),value:ctx.state("中文输入")),
  proc(ctx:ComponentContext,p:int,m:Model):UiDescription=
    if getEnv("LEAF_TEST_FAIL_LIST")=="1":
      return host(virtualList("items",@["a"],proc(i:int):Node=fail("initial row failed"),
        styles=style({"height":"400","width":"full"})))
    let count=ctx.value(m.count)
    let value=ctx.value(m.value)
    let submissions=ctx.value(m.submissions)
    componentView:
      column:
        styles:{"padding":"24","gap":"12","width":"full","height":"full"}
        input(value,key="entry",onChange=proc(e:Event)=m.value.set(e.value),
          onSubmit=proc(e:Event)=m.submissions.update(proc(n:int):int=n+1),
          styles=style({"height":"36","width":"full"}))
        component(Add,m.count,key="button-boundary")
        text($count & ":" & value & ":" & $submissions,key="status"))
when isMainModule:quit(run(componentApplication(component(Main,0),"Leaf GPUI native smoke")))
