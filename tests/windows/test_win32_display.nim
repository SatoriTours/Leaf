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

suite "standard badge and decorative separator native rendering":
  test "real STATIC badge has 12 DIP medium font, padded pill and no tab stop":
    for theme in [shadcnLight,shadcnDark]:
      var variant=UiVariant.default
      let f=mounted(proc():Node=column(@[standard.badge("A & 中文",key="badge",variant=variant)],
        styles=style({"padding":"24","width":"full"})),theme)
      try:
        let w=find(f.h.windowHandle,"A & 中文")
        require w!=nil
        check f.win.fieldAnnotationCountsForTest==(0,0)
        check (GetWindowLongW(w,GWL_STYLE) and int32(WS_TABSTOP))==0
        var font:LOGFONTW
        require GetObjectW(cast[HGDIOBJ](SendMessageW(w,WM_GETFONT,0,0)),int32(sizeof(font)),addr font)!=0
        check font.lfHeight== -12 and font.lfWeight==500
        var bounds:RECT
        require GetClientRect(w,addr bounds)!=0
        check bounds.bottom==22
        check bounds.right>=65
        discard refreshSkin(w);discard UpdateWindow(w)
        let dc=GetDC(w)
        check GetPixel(dc,bounds.right div 2,2)==colorRef(if theme==shadcnLight:0x171717'u32 else:0xe5e5e5'u32)
        discard ReleaseDC(w,dc)
        variant=UiVariant.outline;discard f.runtime.refresh()
        check find(f.h.windowHandle,"A & 中文")==w
        discard refreshSkin(w);discard UpdateWindow(w)
        let outlined=GetDC(w)
        check GetPixel(outlined,bounds.right div 2,2)==colorRef(if theme==shadcnLight:0xffffff'u32 else:0x0a0a0a'u32)
        discard ReleaseDC(w,outlined)
      finally:f.close()

  test "one-DIP rules use Neutral flat border rather than legacy etched lines":
    for theme in [shadcnLight,shadcnDark]:
      let f=mounted(proc():Node=column(@[standard.separator(),standard.separator(vertical=true,length=32)],
        styles=style({"padding":"24","gap":"16","width":"full"})),theme)
      try:
        children.setLen(0);discard EnumChildWindows(f.h.windowHandle,collect,0)
        let all=children
        var count=0
        for w in all:
          if standardRole(w)!=some(UiRole.separator):continue
          inc count
          var bounds:RECT
          require GetClientRect(w,addr bounds)!=0
          check bounds.bottom==1 or (bounds.right==1 and bounds.bottom==32)
          check (GetWindowLongW(w,GWL_STYLE) and 0x1f)==0 # plain STATIC
          discard refreshSkin(w);discard UpdateWindow(w)
          let dc=GetDC(w)
          check GetPixel(dc,0,0)==colorRef(if theme==shadcnLight:0xe5e5e5'u32 else:0x232323'u32)
          discard ReleaseDC(w,dc)
        check count==2
      finally:f.close()
