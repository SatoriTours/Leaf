import std/[unittest,json,os,tempfiles]
import leaf/[core,widgets,gpui_bridge]
suite "Nim GPUI ABI requests":
  test "a failed replacement list preserves successful rows and callbacks":
    var failRows=false
    var clicks=0
    let app=Application(title:"列表恢复",width:640,height:480,render:proc(ctx:BuildContext):Node =
      let broken=failRows
      column(@[
        virtualList("items",@["a","b"],proc(i:int):Node =
          if broken:raise newException(UiError,"replacement failed")
          button("row " & $i,key="row",onClick=proc(e:Event)=inc clicks)),
        button("break",key="break",onClick=proc(e:Event)=failRows=true),
        button("recover",key="recover",onClick=proc(e:Event)=failRows=false)]))
    let host=newDesktopBridge(app)
    let before=host.request(%*{"op":"list","id":"items","first":0,"finish":2,"protected":[]})
    let row=before["rows"][0]["id"].getStr
    let rejected=host.request(%*{"op":"event","id":"break","kind":"click"})
    check rejected.hasKey("error")
    check rejected["snapshot"]==before["snapshot"]
    discard host.request(%*{"op":"event","id":row,"kind":"click"})
    check clicks==1
    let recovered=host.request(%*{"op":"event","id":"recover","kind":"click"})
    check not recovered.hasKey("error")
    check recovered["snapshot"]["root"]["children"][0]["children"].len==2
  test "failed initial list cannot publish watch readiness":
    let directory=createTempDir("leaf-gpui-ready-","")
    defer:removeDir(directory)
    let previous=getEnv("LEAF_WATCH_READY")
    putEnv("LEAF_WATCH_READY",directory/"ready.json")
    defer:
      if previous.len==0:delEnv("LEAF_WATCH_READY")
      else:putEnv("LEAF_WATCH_READY",previous)
    let app=Application(title:"失败",width:640,height:480,render:proc(ctx:BuildContext):Node =
      virtualList("items",@["a"],proc(i:int):Node =
        raise newException(UiError,"initial row failed")))
    let host=newDesktopBridge(app)
    let failed=host.request(%*{"op":"list","id":"items","first":0,"finish":1,"protected":[]})
    check failed["error"].getStr.len>0
    check host.request(%*{"op":"ready"}).hasKey("error")
    check not fileExists(directory/"ready.json")
  test "UTF-8 state, event dispatch and controlled recovery":
    var count=0
    let app=Application(title:"中文",width:640,height:480,render:proc(ctx:BuildContext):Node =
      column(@[text("你好 " & $count,key="label"),button("增加",key="add",onClick=proc(e:Event)=inc count)]))
    let host=newDesktopBridge(app)
    check host.request(%*{"op":"ready"})["snapshot"]["title"].getStr == "中文"
    discard host.request(%*{"op":"event","id":"add","kind":"click","value":""})
    check count==1
    let result=host.request(%*{"op":"event","id":"add","kind":"bad"})
    check result["error"].getStr.len>0
    check count==1
  test "virtual list materializes only requested rows":
    var built=0
    var keys:seq[string]
    for i in 0..<100_000:keys.add($i)
    let app=Application(title:"列表",width:640,height:480,render:proc(ctx:BuildContext):Node =
      virtualList("items",keys,proc(i:int):Node =
        inc built
        text($i),rowHeight=30))
    let host=newDesktopBridge(app)
    let response=host.request(%*{"op":"list","id":"items","first":5000,"finish":5004,"protected":[]})
    check response["rows"].len==4
    check built==4
    check response["rows"][0]["text"].getStr=="5000"
  test "visible rows remain active and focused keys follow source reordering":
    var keys = @["a", "b", "c"]
    var changed = ""
    let app=Application(title:"焦点",width:640,height:480,render:proc(ctx:BuildContext):Node =
      let current=keys
      virtualList("items",current,proc(i:int):Node =
        input(current[i],key="editor",onChange=proc(e:Event)=changed=current[i] & ":" & e.value)))
    let host=newDesktopBridge(app)
    let first=host.request(%*{"op":"list","id":"items","first":0,"finish":1,"protected":[]})
    let id=first["rows"][0]["id"].getStr
    discard host.request(%*{"op":"list","id":"items","first":1,"finish":2,"protected":[0]})
    discard host.request(%*{"op":"event","id":id,"kind":"change","value":"one"})
    check changed=="a:one"
    keys = @["c", "b", "a"]
    discard host.runtime.refresh()
    let response=host.request(%*{"op":"list","id":"items","first":0,"finish":1,"protected":[],
      "protected_keys":[{"key":"a","index":0}]})
    check response["snapshot"]["root"]["children"][1]["item_key"].getStr=="a"
    check response["snapshot"]["root"]["children"][1]["list_index"].getInt==2
    discard host.request(%*{"op":"event","id":id,"kind":"change","value":"two"})
    check changed=="a:two"
  test "controlled callback failure retains the successful value and can recover":
    var value="旧值"
    let app=Application(title:"恢复",width:640,height:480,render:proc(ctx:BuildContext):Node =
      input(value,key="entry",onChange=proc(e:Event) =
        if e.value=="拒绝":raise newException(UiError,"拒绝更新")
        value=e.value))
    let host=newDesktopBridge(app)
    let rejected=host.request(%*{"op":"event","id":"entry","kind":"change","value":"拒绝"})
    check rejected["error"].getStr.len>0
    check rejected["snapshot"]["root"]["text"].getStr=="旧值"
    let accepted=host.request(%*{"op":"event","id":"entry","kind":"change","value":"新值"})
    check not accepted.hasKey("error")
    check accepted["snapshot"]["root"]["text"].getStr=="新值"
