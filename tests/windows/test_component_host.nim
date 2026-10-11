when not defined(windows): {.error: "Real component host test requires Windows".}
import std/unittest
import leaf/[core,widgets,components,backend_session,native_layout,ui_thread]
import leaf/backends/win32/[api,host,backend]
let Counter=defineComponent[int,State[int]]("WindowsComponent",
  proc(ctx:MountContext,p:int):State[int]=ctx.state(0),
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    let n=ctx.value(s)
    host(button($n,key="go",onClick=proc(e:Event)=s.set(n+1))))
suite "real Win32 managed host":
  test "local commit and owner disposal preserve component State":
    let activity=newUiScopeActivity()
    let rt=newRuntime(guardUiApplication(componentApplication(component(Counter,0),"组件",width=400,height=300),
      proc():uint64=uint64(GetCurrentThreadId()),activity))
    let h=createHost("组件",DipSize(width:400,height:300))
    h.setStartupScope(proc():bool=activity.busy or rt.installingUpdate)
    let win=newWin32Backend(h)
    discard win.attachWin32Backend(rt)
    let before=rt.updateStats()
    check rt.dispatch("go",Event(kind:click))
    check rt.find("go").node.text=="1"
    check rt.updateStats().snapshotExports==before.snapshotExports
    h.destroyHost()
    check rt.committerOwner==0
    check win.diagnostics.liveRoots==0
