import std/[unittest, os, osproc, options]
import leaf/[core, widgets, gpui_api, gpui_ffi_v2, host_session, gpui_session]
proc app(scope:ExecutionScope=nil):Application =
  Application(title:"会话",width:640,height:480,executionScope:scope,
    render:proc(ctx:BuildContext):Node=text("你好",key="text"))
proc consumer(id:uint64,prepared,applied,accepted,discarded:ptr int):HostConsumer =
  result=HostConsumer(sessionId:id)
  result.prepare=proc(batch:HostBatch)=inc prepared[]
  result.apply=proc()=inc applied[]
  result.accept=proc(revision:uint64) {.raises:[].}=inc accepted[]
  result.discardPrepared=proc() {.raises:[].}=inc discarded[]
suite "typed session installation":
  test "installation accepts only after successful scope exit":
    var p,a,c,d:int
    let rt=newRuntime(app())
    let host=attachHostSession(rt,consumer(10,addr p,addr a,addr c,addr d))
    check p==1 and a==1 and c==1
    check host.revision==rt.acceptedRevision
    host.close()
    check rt.committerOwner==0
  test "scope cleanup failure discards staged install and leaves hook free":
    var reject=false
    let scope:ExecutionScope=proc(body:proc())=
      body()
      if reject:raise newException(UiError,"scope cleanup")
    let rt=newRuntime(app(scope))
    reject=true
    var p,a,c,d:int
    expect UiError:discard attachHostSession(rt,consumer(10,addr p,addr a,addr c,addr d))
    check c==0 and d==1
    check rt.committerOwner==0
  test "old owner cannot remove replacement":
    var p,a,c,d:int
    let rt=newRuntime(app())
    let first=attachHostSession(rt,consumer(10,addr p,addr a,addr c,addr d))
    first.close()
    let next=attachHostSession(rt,consumer(11,addr p,addr a,addr c,addr d))
    first.close()
    check rt.committerOwner!=0
    next.close()
  test "apply rejection keeps accepted graph and runtime revision":
    var reject=false
    var p,a,c,d:int
    let sink=consumer(10,addr p,addr a,addr c,addr d)
    sink.apply=proc()=
      if reject:raise newException(UiError,"apply rejected")
    let rt=newRuntime(app())
    let host=attachHostSession(rt,sink)
    reject=true
    expect UiError:discard rt.refresh()
    check host.revision==rt.acceptedRevision
    check c==1 and d==1
    host.close()
suite "ABI selection and synchronous attach":
  test "old, valid and incompatible library selection":
    let previous=getEnv("LEAF_GPUI_ABI")
    defer:
      if previous.len==0:delEnv("LEAF_GPUI_ABI")
      else:putEnv("LEAF_GPUI_ABI",previous)
    createDir("target/ffi-v2")
    for flavor in ["OLD_ONLY","VALID","INCOMPATIBLE"]:
      let path=absolutePath("target/ffi-v2/" & flavor & ".so")
      check execCmd("gcc -shared -fPIC -D" & flavor & " tests/ffi/gpui_v2_library.c -o " & quoteShell(path))==0
      for selection in ["auto","1","2"]:
        putEnv("LEAF_GPUI_ABI",selection)
        if selection!="1" and (flavor=="INCOMPATIBLE" or (flavor=="OLD_ONLY" and selection=="2")):
          expect UiError:discard loadGpui(path)
        else:
          let api=loadGpui(path)
          check api.abi()==1
          check api.v2.isSome == (selection!="1" and flavor=="VALID")
          if api.v2.isSome:
            let rt=newRuntime(app())
            let session=openGpuiSession(rt,api)
            check session.run()==0
            check session.readyCalls==1
            check rt.committerOwner==0
  test "initial install failure does not publish ready":
    putEnv("LEAF_GPUI_ABI","2")
    defer:delEnv("LEAF_GPUI_ABI")
    let api=loadGpui(absolutePath("target/ffi-v2/VALID.so"))
    var reject=false
    let scope:ExecutionScope=proc(body:proc())=
      body()
      if reject:raise newException(UiError,"install denied")
    let rt=newRuntime(app(scope))
    let session=openGpuiSession(rt,api)
    reject=true
    check session.run()!=0
    check session.readyCalls==0
    check rt.committerOwner==0
  test "terminal detach removes callbacks without entering cleanup scope":
    putEnv("LEAF_GPUI_ABI","2")
    defer:delEnv("LEAF_GPUI_ABI")
    let api=loadGpui(absolutePath("target/ffi-v2/VALID.so"))
    var entries=0
    let scope:ExecutionScope=proc(body:proc())=
      inc entries
      if entries==4:raise newException(UiError,"teardown scope refused")
      body()
    let rt=newRuntime(app(scope))
    let session=openGpuiSession(rt,api)
    check session.run()==0
    check session.readyCalls==1
    check entries==3
    check rt.committerOwner==0
    check not rt.eventsFrozen
    rt.closeRuntime()
    check rt.runtimeClosedInternal
  test "preparer installation failure after host attach closes at the ordinary boundary":
    putEnv("LEAF_GPUI_ABI","2")
    defer:delEnv("LEAF_GPUI_ABI")
    let api=loadGpui(absolutePath("target/ffi-v2/VALID.so"))
    var entries=0
    let scope:ExecutionScope=proc(body:proc())=
      inc entries
      body()
      if entries==3:raise newException(UiError,"preparer scope exit rejected")
    let rt=newRuntime(app(scope))
    let session=openGpuiSession(rt,api)
    check session.run()!=0
    check session.readyCalls==0
    check rt.committerOwner==0
    check rt.runtimeClosedInternal
