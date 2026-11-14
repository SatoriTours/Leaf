when not defined(windows): {.error:"Native Field tests require Windows".}
import ../fixture_app
import std/[unittest,widestrs]
import leaf/[ui_thread,native_layout,native_theme,styles,backend_session]
import leaf/backend as protocol
import leaf/backends/win32/[api,host,backend]
import leaf/ui as standard

var children:seq[HWND]
proc collect(w:HWND,data:LPARAM):BOOL {.stdcall,raises:[].} =
  children.add(w);1
proc find(parent:HWND,name:string):HWND =
  children.setLen(0)
  discard EnumChildWindows(parent,collect,0)
  for w in children:
    let s=newWideCString(128)
    discard GetWindowTextW(w,cast[WidePtr](unsafeAddr s[0]),128)
    if $s==name:return w

type Fixture=tuple[h:Win32Host,win:Win32Backend,s:BackendSession,runtime:Runtime]
proc mounted(build:FixtureBuild,theme=shadcnLight):Fixture =
  let activity=newUiScopeActivity()
  let app=fixtureApplication(build,"Standard Fields",480,360).withNativeTheme(theme)
  let runtime=newRuntime(guardUiApplication(app,
    proc():uint64=uint64(GetCurrentThreadId()),activity))
  let h=createHost(app.title,DipSize(width:480,height:360),theme=theme)
  h.setStartupScope(proc():bool=activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win=newWin32Backend(h)
  let s=win.attachWin32Backend(runtime,protocol.strict)
  win.bindSession(s);h.bindSession(s,proc():bool=activity.busy)
  (h,win,s,runtime)
proc close(f:Fixture) =
  f.h.destroyHost();f.runtime.closeRuntime()
  check f.win.diagnostics.liveWindows==0
  check f.win.diagnostics.liveFonts==0
  check f.win.diagnostics.liveRoots==0
  check f.win.fieldAnnotationCountsForTest==(0,0)

suite "standard Field native annotation ownership":
  test "dynamic description/error and removed scope preserve EDIT identity/selection":
    for theme in [shadcnLight,shadcnDark]:
      var invalid=false
      var scoped=true
      let f=mounted(proc():Node =
        let nodes = @[
          standard.label("Native label",key="label"),
          standard.input("Native draft",key="edit",invalid=invalid),
          (if invalid:standard.fieldError("Native error",key="message")
           else:standard.fieldDescription("Native hint",key="message"))]
        column(@[(if scoped:standard.field(nodes,key="field") else:column(nodes,key="field"))],
          key="root",styles=style({"padding":"24","width":"full"})),theme)
      try:
        check f.win.fieldAnnotationCountsForTest==(1,1)
        let edit=find(f.h.windowHandle,"Native draft")
        require edit!=nil
        discard SendMessageW(edit,EM_SETSEL,1,4)
        invalid=true;discard f.runtime.refresh()
        check find(f.h.windowHandle,"Native draft")==edit
        check f.win.fieldAnnotationCountsForTest==(1,1)
        var first,last:uint32
        discard SendMessageW(edit,EM_GETSEL,cast[WPARAM](addr first),cast[LPARAM](addr last))
        check first==1 and last==4
        invalid=false;scoped=false;discard f.runtime.refresh()
        check find(f.h.windowHandle,"Native draft")==edit
        check f.win.fieldAnnotationCountsForTest==(1,0)
      finally:f.close()

  test "ambiguous Field is rejected before creating a candidate HWND":
    var ambiguous=false
    let f=mounted(proc():Node =
      var nodes= @[standard.label("Only label"),standard.input("Only draft",key="edit")]
      if ambiguous:nodes.add(standard.input("Extra draft",key="extra"))
      standard.field(nodes,key="field"))
    try:
      let edit=find(f.h.windowHandle,"Only draft")
      let creates=f.win.diagnostics.creates
      ambiguous=true
      expect UiError:discard f.runtime.refresh()
      check f.win.diagnostics.creates==creates
      check find(f.h.windowHandle,"Only draft")==edit
      check find(f.h.windowHandle,"Extra draft")==nil
      check f.win.fieldAnnotationCountsForTest==(1,1)
    finally:f.close()

  test "pages without Field do not acquire annotation services":
    let f=mounted(proc():Node=standard.checkbox("No Field",false))
    try:check f.win.fieldAnnotationCountsForTest==(0,0)
    finally:f.close()
