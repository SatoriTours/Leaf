import std/os
import leaf
import leaf/components
let Counter=defineComponent[int,State[int]]("ListCounter",
  proc(ctx:MountContext,p:int):State[int]=ctx.state(0),
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    host(button("counter:" & $ctx.value(s),key="add",onClick=proc(e:Event)=s.update(proc(n:int):int=n+1),
      styles=style({"height":"36","width":"200"}))))
let Row=defineComponent[int,State[int]]("NativeListRow",
  proc(ctx:MountContext,p:int):State[int]=ctx.state(0),
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    host(button($p & ":" & $ctx.value(s),key="row-" & $p,onClick=proc(e:Event)=s.update(proc(n:int):int=n+1),
      styles=style({"height":"24","width":"200"}))))
var keys:seq[string]
for i in 0..<100000:keys.add($i)
let rows=componentList("items",keys,proc(i:int):UiDescription=
  if getEnv("LEAF_TEST_FAIL_LIST")=="1":fail("initial row failed")
  component(Row,i),estimatedHeight=24,overscan=0,styles=style({"height":"full","width":"full"}))
when isMainModule:
  quit(run(componentApplication(hostShell(column(@[],key="root",styles=style({"height":"full","width":"full"})),
    @[component(Counter,0),rows]),"Leaf GPUI native smoke")))
