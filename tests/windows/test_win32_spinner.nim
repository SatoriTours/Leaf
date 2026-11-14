when not defined(windows): {.error:"Native Spinner tests require Windows".}
import leaf
import ../fixture_app
import std/[unittest,widestrs,options]
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
proc mounted(theme=shadcnLight,calls=systemWin32Calls()):Fixture =
  let activity=newUiScopeActivity()
  let app=componentApplication(hostShell(column(@[],styles=style({"padding":"24"})),
    @[standard.spinner(label="Loading",key="shape"),host(standard.input("draft",key="edit"))]),
    "Standard Spinner",480,360).withNativeTheme(theme)
  let runtime=newRuntime(guardUiApplication(app,
    proc():uint64=uint64(GetCurrentThreadId()),activity))
  let h=createHost(app.title,DipSize(width:480,height:360),theme=theme)
  h.setStartupScope(proc():bool=activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win=newWin32Backend(h,calls)
  let s=win.attachWin32Backend(runtime,protocol.strict)
  win.bindSession(s);h.bindSession(s,proc():bool=activity.busy)
  (h,win,s,runtime)
proc mountedPlain(build:FixtureBuild,calls=systemWin32Calls()):Fixture =
  let activity=newUiScopeActivity()
  let app=fixtureApplication(build,"Spinner transactions",480,360).withNativeTheme(shadcnLight)
  let runtime=newRuntime(guardUiApplication(app,
    proc():uint64=uint64(GetCurrentThreadId()),activity))
  let h=createHost(app.title,DipSize(width:480,height:360),theme=shadcnLight)
  h.setStartupScope(proc():bool=activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win=newWin32Backend(h,calls)
  let session=win.attachWin32Backend(runtime,protocol.strict)
  win.bindSession(session);h.bindSession(session,proc():bool=activity.busy)
  (h,win,session,runtime)
proc staticSpinner(name:string):Node =
  core.ui(NodeKind.tag,text=name,key="status",styles=style({"width":"16","height":"16"}),
    attributes=style({"ui_role":"spinner","ui_angle":"0"}))
proc close(f:Fixture) =
  f.h.destroyHost();f.runtime.closeRuntime()
  check f.win.diagnostics.liveWindows==0
  check f.win.diagnostics.liveFonts==0
  check f.win.diagnostics.liveRoots==0
  check f.win.fieldAnnotationCountsForTest==(0,0)
  check f.win.liveProviderCountsForTest==(0,0)

proc UpdateWindow(w:HWND):BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
proc GetPixel(dc:HDC,x,y:int32):DWORD {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}

proc CreateCompatibleDC(dc:HDC):HDC {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}
proc CreateCompatibleBitmap(dc:HDC,w,h:int32):HGDIOBJ {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}
proc DeleteDC(dc:HDC):BOOL {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}

suite "native managed Spinner":
  test "rotation repaints native shape without recreating HWND or setting fonts":
    for theme in [shadcnLight,shadcnDark]:
      var fontSets=0
      let sys=systemWin32Calls()
      var calls=sys
      calls.send=proc(w:HWND,m:UINT,wp:WPARAM,lp:LPARAM):LRESULT=
        if m==WM_SETFONT:inc fontSets
        sys.send(w,m,wp,lp)
      let f=mounted(theme,calls)
      try:
        children.setLen(0);discard EnumChildWindows(f.h.windowHandle,collect,0)
        var shape:HWND
        for w in children:
          if standardRole(w)==some(UiRole.spinner):shape=w
        require shape!=nil
        check f.win.liveProviderCountsForTest==(1,1)
        f.win.safeListTurn()
        let edit=find(f.h.windowHandle,"draft")
        require edit!=nil
        discard SetFocus(edit)
        discard SendMessageW(edit,0x00b1,1,4)
        let font=SendMessageW(edit,WM_GETFONT,0,0)
        var bounds:RECT
        require GetClientRect(shape,addr bounds)!=0
        check bounds.right==16 and bounds.bottom==16
        check (GetWindowLongW(shape,GWL_STYLE) and int32(WS_TABSTOP))==0
        # Render the real WM_PRINTCLIENT path to a private bitmap. This checks
        # arc coverage, not a screenshot/visual-acceptance substitute.
        let screen=GetDC(shape)
        let memory=CreateCompatibleDC(screen)
        let bitmap=CreateCompatibleBitmap(screen,16,16)
        let previous=SelectObject(memory,bitmap)
        discard SendMessageW(shape,0x0318,cast[WPARAM](memory),0)
        let foreground=colorRef(if theme==shadcnLight:0x0a0a0a'u32 else:0xfafafa'u32)
        var ink=0
        for y in 0'i32..<16:
          for x in 0'i32..<16:
            if GetPixel(memory,x,y)==foreground:inc ink
        check ink>30 # a 270-degree two-pixel stroke, not a quarter circle
        discard SelectObject(memory,previous)
        discard DeleteObject(bitmap)
        discard DeleteDC(memory)
        discard ReleaseDC(shape,screen)
        fontSets=0
        for t in [0.0,250.0,500.0]:
          discard f.runtime.pumpAnimations(t)
          discard UpdateWindow(shape)
          check GetFocus()==edit
          check SendMessageW(edit,WM_GETFONT,0,0)==font
          check SendMessageW(edit,0x00b0,0,0)==0x00040001
          check IsWindow(shape)!=0
          check fontSets==0
      finally:f.close()

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
    let f=mountedPlain(proc():Node=column(@[staticSpinner(name)]),calls)
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

  test "removed spinner drains at a safe turn and remount acquires one provider":
    var shown=true
    let f=mountedPlain(proc():Node=column(if shown: @[staticSpinner("Loading")] else: @[]))
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
    let f=mountedPlain(proc():Node=column(@[(if live:staticSpinner("Loading")
      else:core.ui(NodeKind.tag,text="Badge",key="status"))]))
    try:
      let before=find(f.h.windowHandle,"Loading")
      let creates=f.win.diagnostics.creates
      live=false
      expect UiError:discard f.runtime.refresh()
      check f.win.diagnostics.creates==creates
      check find(f.h.windowHandle,"Loading")==before
      check f.win.liveProviderCountsForTest==(1,1)
    finally:f.close()
