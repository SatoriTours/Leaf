import leaf
import std/os
var count=0
var value="中文输入"
var submissions=0
let app=Application(title:"Leaf GPUI native smoke",width:640,height:480,render:proc(ctx:BuildContext):Node =
  if getEnv("LEAF_TEST_FAIL_LIST")=="1":
    return virtualList("items",@["a"],proc(i:int):Node =
      raise newException(UiError,"initial row failed"),
      styles=style({"height":"400","width":"full"}))
  column(@[
    input(value,key="entry",onChange=proc(e:Event)=value=e.value,
      onSubmit=(proc(e:Event)=inc submissions),styles=style({"height":"36","width":"full"})),
    button("GPUI Kit → Nim",key="add",onClick=(proc(e:Event)=inc count),styles=style({"height":"36","width":"200"})),
    text($count & ":" & value & ":" & $submissions,key="status")
  ],styles=style({"padding":"24","gap":"12","width":"full","height":"full"})))
when isMainModule:quit(run(app))
