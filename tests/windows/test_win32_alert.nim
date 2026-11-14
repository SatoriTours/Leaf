when not defined(windows): {.error:"Native Alert tests require Windows".}
import leaf
import ../fixture_app
import std/[unittest,widestrs]
import leaf/[ui_thread,native_layout,native_theme,styles,backend_session]
import leaf/backend as protocol
import leaf/backends/win32/[api,host,backend,skin,calls]
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
proc mountedPlain(build:FixtureBuild,calls=systemWin32Calls()):Fixture =
  let activity=newUiScopeActivity()
  let app=fixtureApplication(build,"Alert transactions",480,360).withNativeTheme(shadcnLight)
  let runtime=newRuntime(guardUiApplication(app,
    proc():uint64=uint64(GetCurrentThreadId()),activity))
  let h=createHost(app.title,DipSize(width:480,height:360),theme=shadcnLight)
  h.setStartupScope(proc():bool=activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win=newWin32Backend(h,calls)
  let session=win.attachWin32Backend(runtime,protocol.strict)
  win.bindSession(session);h.bindSession(session,proc():bool=activity.busy)
  (h,win,session,runtime)
proc close(f:Fixture) =
  f.h.destroyHost();f.runtime.closeRuntime()
  check f.win.diagnostics.liveWindows==0
  check f.win.diagnostics.liveFonts==0
  check f.win.diagnostics.liveRoots==0
  check f.win.fieldAnnotationCountsForTest==(0,0)
  check f.win.liveProviderCountsForTest==(0,0)


proc CreateCompatibleDC(dc:HDC):HDC {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}
proc CreateCompatibleBitmap(dc:HDC,w,h:int32):HGDIOBJ {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}
proc DeleteDC(dc:HDC):BOOL {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}

suite "native Alert ownership":
  test "failed native apply restores accepted status and retires rejected providers":
    var name="Accepted"
    var failNext=false
    var fired=false
    let sys=systemWin32Calls()
    var calls=sys
    calls.setText=proc(w:HWND,s:WidePtr):BOOL =
      if failNext:
        failNext=false;fired=true;return 0
      sys.setText(w,s)
    let f=mountedPlain(proc():Node=column(@[standard.alert(@[standard.alertTitle(name)])]),calls)
    try:
      f.win.safeListTurn()
      name="Rejected";failNext=true
      expect UiError:discard f.runtime.refresh()
      check fired
      f.win.safeListTurn()
      check find(f.h.windowHandle,"Accepted")!=nil
      check find(f.h.windowHandle,"Rejected")==nil
      check f.win.liveProviderCountsForTest==(1,1)
    finally:f.close()

  test "removed alert drains at a safe turn and remount acquires one provider":
    var shown=true
    let f=mountedPlain(proc():Node=column(if shown: @[standard.alert(@[standard.alertTitle("Loading")],key="status")] else: @[]))
    try:
      f.win.safeListTurn()
      check f.win.liveProviderCountsForTest==(1,1)
      shown=false;discard f.runtime.refresh()
      check f.win.liveProviderCountsForTest.owned==0
      f.win.safeListTurn()
      check f.win.liveProviderCountsForTest==(0,0)
      shown=true;discard f.runtime.refresh();f.win.safeListTurn()
      check f.win.liveProviderCountsForTest==(1,1)
    finally:f.close()

  test "changing a live role on the same key rejects before native mutation":
    var live=true
    let f=mountedPlain(proc():Node=column(@[(if live:standard.alert(@[standard.alertTitle("Loading")],key="status")
      else:core.ui(NodeKind.column,text="Plain",key="status"))]))
    try:
      let before=find(f.h.windowHandle,"Loading")
      let creates=f.win.diagnostics.creates
      live=false
      expect UiError:discard f.runtime.refresh()
      check f.win.diagnostics.creates==creates
      check find(f.h.windowHandle,"Loading")==before
      check f.win.liveProviderCountsForTest==(1,1)
    finally:f.close()

  test "description is measured and alert paints its own rounded surface":
    let f=mountedPlain(proc():Node=column(@[standard.alert(@[
      standard.alertTitle("Title"),standard.alertDescription("A wrapping description with enough text to occupy a visible native line.")],key="notice")],styles=style({"padding":"24","width":"full"})))
    try:
      let root=find(f.h.windowHandle,"Title\nA wrapping description with enough text to occupy a visible native line.")
      let description=find(f.h.windowHandle,"A wrapping description with enough text to occupy a visible native line.")
      require root!=nil and description!=nil
      var bounds:RECT
      require GetClientRect(description,addr bounds)!=0
      check bounds.bottom>=18
      let screen=GetDC(root)
      let memory=CreateCompatibleDC(screen)
      let bitmap=CreateCompatibleBitmap(screen,480,360)
      let old=SelectObject(memory,bitmap)
      var reply:LRESULT
      check skinMessage(shadcnLight,root,0x0318,cast[WPARAM](memory),0,reply)
      discard SelectObject(memory,old);discard DeleteObject(bitmap)
      discard DeleteDC(memory);discard ReleaseDC(root,screen)
    finally:f.close()

  test "variant updates title and description colors without rebuilding controls":
    var danger=false
    let f=mountedPlain(proc():Node=standard.alert(@[standard.alertTitle("Title"),standard.alertDescription("Description")],key="alert",variant=(if danger:UiVariant.destructive else:UiVariant.default)))
    proc ink(w:HWND):DWORD =
      proc GetTextColor(dc:HDC):DWORD {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}
      let dc=GetDC(w)
      discard SendMessageW(GetParent(w),0x0138,cast[WPARAM](dc),cast[LPARAM](w))
      result=GetTextColor(dc)
      discard ReleaseDC(w,dc)
    try:
      let title=find(f.h.windowHandle,"Title")
      let description=find(f.h.windowHandle,"Description")
      require title!=nil and description!=nil
      check ink(title)==colorRef(0x0a0a0a)
      check ink(description)==colorRef(0x737373)
      danger=true;discard f.runtime.refresh()
      check find(f.h.windowHandle,"Title")==title
      check find(f.h.windowHandle,"Description")==description
      check ink(title)==colorRef(palette(shadcnLight).danger)
      check ink(description)!=ink(title)
      check ink(description)!=colorRef(0x737373)
    finally:f.close()

  test "caption changes schedule full custom repaint instead of leaving native GroupBox frame":
    proc GetUpdateRect(w:HWND,r:ptr RECT,erase:BOOL):BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
    proc UpdateWindow(w:HWND):BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
    var title="Before"
    let f=mountedPlain(proc():Node=standard.alert(@[standard.alertTitle(title),standard.alertDescription("Description")]))
    try:
      let alert=find(f.h.windowHandle,"Before\nDescription")
      require alert!=nil
      discard UpdateWindow(alert)
      var dirty:RECT
      require GetUpdateRect(alert,addr dirty,0)==0
      title="After"
      discard f.runtime.refresh()
      check GetUpdateRect(alert,addr dirty,0)!=0
      var client:RECT
      require GetClientRect(alert,addr client)!=0
      check dirty.left==client.left and dirty.top==client.top
      check dirty.right==client.right and dirty.bottom==client.bottom
      check find(f.h.windowHandle,"After\nDescription")==alert
    finally:f.close()
