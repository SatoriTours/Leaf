when not defined(windows): {.error:"Native Field tests require Windows".}
import ../fixture_app
import std/[unittest,widestrs,options]
import leaf/[core,ui_thread,native_layout,native_theme,styles,backend_session]
import leaf/backend as protocol
import leaf/backends/win32/[api,host,backend,skin,row_pool]
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

proc GetWindowDC(w:HWND):HDC {.stdcall,dynlib:"user32.dll",importc,raises:[].}

suite "native single-line input group":
  test "native groups share one frame and addons focus the same EDIT":
    for theme in [shadcnLight,shadcnDark]:
      var invalid=false
      let f=mounted(proc():Node=column(@[standard.inputGroup(
        standard.input("draft",key="editor",invalid=invalid),prefix="https://",suffix=".dev",
        key="group",label="Address")],styles=style({"padding":"24","width":"full"})),theme)
      try:
        let group=find(f.h.windowHandle,"Address")
        let edit=find(f.h.windowHandle,"draft")
        let prefix=find(f.h.windowHandle,"https://")
        require group!=nil and edit!=nil and prefix!=nil
        var cls:array[64,WCHAR]
        discard GetClassNameW(group,addr cls[0],64)
        check cls[0]==WCHAR(ord('B'))
        check (GetWindowLongW(group,GWL_STYLE) and 0xf)==7
        check (GetWindowLongW(GetParent(prefix),GWL_STYLE) and 0xf)==7
        check GetParent(edit)==group
        for target in [group,GetParent(prefix)]:
          var rect:RECT
          require GetWindowRect(target,addr rect)!=0
          let point=LPARAM(((rect.top+rect.bottom) div 2) shl 16) or LPARAM((rect.left+3) and 0xffff)
          check SendMessageW(target,0x0084,0,point)==1 # HTCLIENT must reach the real skin route.

        var bounds:RECT
        require GetClientRect(group,addr bounds)!=0
        check bounds.bottom==36
        discard refreshSkin(edit);discard UpdateWindow(edit)
        let dc=GetWindowDC(edit)
        # EDIT keeps native client/caret, but no independent rounded frame.
        check GetPixel(dc,0,17)==colorRef(if theme==shadcnLight:0xffffff'u32 else:0x151515'u32)
        discard ReleaseDC(edit,dc)
        discard SendMessageW(prefix,0x0201,1,0)
        check GetFocus()==edit
        discard SendMessageW(edit,EM_SETSEL,1,4)
        let font=SendMessageW(edit,WM_GETFONT,0,0)
        discard refreshSkin(group);discard UpdateWindow(group)
        let beforeDc=GetDC(group);let before=GetPixel(beforeDc,0,18)
        discard ReleaseDC(group,beforeDc)
        invalid=true;discard f.runtime.refresh()
        discard UpdateWindow(group)
        let afterDc=GetDC(group);let after=GetPixel(afterDc,0,18)
        discard ReleaseDC(group,afterDc)
        require before!=0xffffffff'u32 and after!=0xffffffff'u32
        check before!=after
        check find(f.h.windowHandle,"draft")==edit
        check SendMessageW(edit,WM_GETFONT,0,0)==font
        var first,last:uint32
        discard SendMessageW(edit,EM_GETSEL,cast[WPARAM](addr first),cast[LPARAM](addr last))
        check first==1 and last==4
      finally:f.close()

  test "orphan addon rejection happens before any candidate HWND allocation":
    var orphan=false
    let f=mounted(proc():Node =
      if orphan:core.ui(NodeKind.row,attributes=style({"ui_role":"inputGroupAddon"}))
      else:standard.inputGroup(standard.input("draft"),prefix="https://",key="group"))
    try:
      let creates=f.win.diagnostics.creates
      orphan=true
      expect UiError:discard f.runtime.refresh()
      check f.win.diagnostics.creates==creates
      check find(f.h.windowHandle,"draft")!=nil
    finally:f.close()

  test "outer focus ring composites over the surrounding surface, not the tinted group":
    for invalid in [false,true]:
      let f=mounted(proc():Node=column(@[
        standard.inputGroup(standard.input("grouped",invalid=invalid),prefix="https://"),
        standard.input("standalone",invalid=invalid)],styles=style({"padding":"24","gap":"24"})),shadcnDark)
      try:
        check standardFocusColor(shadcnDark,find(f.h.windowHandle,"grouped"))==
          standardFocusColor(shadcnDark,find(f.h.windowHandle,"standalone"))
      finally:f.close()

  test "invalid update repaints curved border pixels owned by the text addon":
    var invalid=false
    let f=mounted(proc():Node=column(@[standard.inputGroup(standard.input("draft",invalid=invalid),
      prefix="https://",key="group")],styles=style({"padding":"24","width":"full"})))
    try:
      let addon=GetParent(find(f.h.windowHandle,"https://"))
      discard refreshSkin(addon);discard UpdateWindow(addon)
      let dc=GetDC(addon)
      var borderPixels:seq[tuple[x,y:int32]]
      for x in 0'i32..6:
        for y in 0'i32..6:
          if GetPixel(dc,x,y)==colorRef(0xe5e5e5):borderPixels.add((x,y))
      discard ReleaseDC(addon,dc)
      require borderPixels.len>0
      invalid=true;discard f.runtime.refresh()
      discard UpdateWindow(addon)
      let after=GetDC(addon)
      for point in borderPixels:
        check GetPixel(after,point.x,point.y)!=colorRef(0xe5e5e5)
      discard ReleaseDC(addon,after)
    finally:f.close()
