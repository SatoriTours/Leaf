import leaf
import leaf/components
let Counter=defineComponent[int,State[int]]("ExampleCounter",
  proc(ctx:MountContext,initial:int):State[int]=ctx.state(initial),
  proc(ctx:ComponentContext,initial:int,count:State[int]):UiDescription=
    let n=ctx.value(count)
    componentView:
      column:
        styles:{"padding":"24","gap":"12","width":"full","height":"full"}
        button("增加",key="add",onClick=proc(e:Event)=count.update(proc(value:int):int=value+1))
        text($n,key="status")
        button("重置",key="reset",onClick=proc(e:Event)=count.set(0)))
proc counterApplication*():Application=
  componentApplication(component(Counter,0),"Leaf 组件计数器")
when isMainModule:quit(run(counterApplication()))
