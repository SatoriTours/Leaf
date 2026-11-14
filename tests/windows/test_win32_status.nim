when not defined(windows): {.error:"Native Field tests require Windows".}
import ../fixture_app
import std/[unittest,widestrs,options]
import leaf/[ui_thread,native_layout,native_theme,styles,backend_session]
import leaf/backend as protocol
import leaf/backends/win32/[api,host,backend,skin]
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

proc UpdateWindow(w:HWND):BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
proc GetPixel(dc:HDC,x,y:int32):DWORD {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}

suite "standard Progress and Kbd native rendering":
  test "progress uses eight-DIP Neutral track and native 0..100 range across updates":
    for theme in [shadcnLight,shadcnDark]:
      var value=0
      let f=mounted(proc():Node=column(@[standard.progress(value,key="progress")],
        styles=style({"padding":"24","width":"full"})),theme)
      try:
        children.setLen(0);discard EnumChildWindows(f.h.windowHandle,collect,0)
        var bar:HWND
        for w in children:
          if standardRole(w)==some(UiRole.progress):bar=w
        require bar!=nil
        var bounds:RECT
        require GetClientRect(bar,addr bounds)!=0
        check bounds.bottom==8
        check SendMessageW(bar,0x0407,1,0)==0
        check SendMessageW(bar,0x0407,0,0)==100
        for n in [0,50,100,0]:
          value=n;discard f.runtime.refresh()
          check SendMessageW(bar,0x0408,0,0)==n
          discard UpdateWindow(bar)
          let dc=GetDC(bar)
          let track=if theme==shadcnLight:0xd1d1d1'u32 else:0x363636'u32
          let fill=if theme==shadcnLight:0x171717'u32 else:0xe5e5e5'u32
          check GetPixel(dc,bounds.right div 4,4)==colorRef(if n>=50:fill else:track)
          check GetPixel(dc,bounds.right*3 div 4,4)==colorRef(if n==100:fill else:track)
          discard ReleaseDC(bar,dc)
      finally:f.close()

  test "Kbd uses 20-DIP min width, 12 medium font, muted face and no activation":
    for theme in [shadcnLight,shadcnDark]:
      let f=mounted(proc():Node=column(@[standard.kbdGroup(@[standard.kbd("K"),standard.kbd("Ctrl")])],
        styles=style({"padding":"24","width":"full"})),theme)
      try:
        let w=find(f.h.windowHandle,"K")
        require w!=nil
        var bounds:RECT
        require GetClientRect(w,addr bounds)!=0
        check bounds.right==20 and bounds.bottom==20
        check (GetWindowLongW(w,GWL_STYLE) and int32(WS_TABSTOP))==0
        var font:LOGFONTW
        require GetObjectW(cast[HGDIOBJ](SendMessageW(w,WM_GETFONT,0,0)),int32(sizeof(font)),addr font)!=0
        check font.lfHeight== -12 and font.lfWeight==500
        discard UpdateWindow(w)
        let dc=GetDC(w)
        check GetPixel(dc,10,2)==colorRef(if theme==shadcnLight:0xf5f5f5'u32 else:0x262626'u32)
        discard ReleaseDC(w,dc)
      finally:f.close()
