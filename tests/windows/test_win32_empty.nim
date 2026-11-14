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

proc GetTextColor(dc:HDC):DWORD {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}

suite "standard Empty native layout and stock text":
  test "Empty text centers and wraps with 18 medium title and 14 regular hint":
    for theme in [shadcnLight,shadcnDark]:
      let description="Long native description wraps into multiple lines within the narrow available width."
      let f=mounted(proc():Node=standard.empty(@[standard.emptyHeader(@[
        standard.emptyTitle("No items",key="title"),standard.emptyDescription(description,key="description")]),
        standard.emptyContent(@[standard.button("Create",key="create")])]),theme)
      try:
        let title=find(f.h.windowHandle,"No items")
        let hint=find(f.h.windowHandle,description)
        let button=find(f.h.windowHandle,"Create")
        require title!=nil and hint!=nil and button!=nil
        for w in [title,hint]:
          check (GetWindowLongW(w,GWL_STYLE) and 0x1f)==1 # SS_CENTER
          check (GetWindowLongW(w,GWL_STYLE) and int32(WS_TABSTOP))==0
          var font:LOGFONTW
          require GetObjectW(cast[HGDIOBJ](SendMessageW(w,WM_GETFONT,0,0)),int32(sizeof(font)),addr font)!=0
          check font.lfHeight==(if w==title: -18 else: -14)
          check font.lfWeight==(if w==title:500 else:400)
        var tr,hr,br:RECT
        require GetWindowRect(title,addr tr)!=0 and GetWindowRect(hint,addr hr)!=0 and GetWindowRect(button,addr br)!=0
        check hr.bottom-hr.top>20
        check abs((br.left+br.right)-(tr.left+tr.right))<=2
        let dc=GetDC(hint)
        discard SendMessageW(GetParent(hint),0x0138,cast[WPARAM](dc),cast[LPARAM](hint))
        check GetTextColor(dc)==colorRef(if theme==shadcnLight:0x737373'u32 else:0xa1a1a1'u32)
        discard ReleaseDC(hint,dc)
      finally:f.close()

  test "same STATIC updates centering and font role without retaining Empty style":
    var emptyStyle=true
    let f=mounted(proc():Node=column(@[
      (if emptyStyle:standard.emptyTitle("Stable text",key="title")
       else:standard.label("Stable text",key="title"))],styles=style({"width":"full"})))
    try:
      let w=find(f.h.windowHandle,"Stable text")
      require w!=nil
      check (GetWindowLongW(w,GWL_STYLE) and 0x1f)==1
      emptyStyle=false;discard f.runtime.refresh()
      check find(f.h.windowHandle,"Stable text")==w
      check (GetWindowLongW(w,GWL_STYLE) and 0x1f)==0
      emptyStyle=true;discard f.runtime.refresh()
      check find(f.h.windowHandle,"Stable text")==w
      check (GetWindowLongW(w,GWL_STYLE) and 0x1f)==1
    finally:f.close()

proc UpdateWindow(w:HWND):BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
proc GetPixel(dc:HDC,x,y:int32):DWORD {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}
proc paintTree(root:HWND) =
  discard UpdateWindow(root)
  children.setLen(0);discard EnumChildWindows(root,collect,0)
  let owned=children
  for w in owned:discard UpdateWindow(w)

suite "content-driven Card size repaint":
  test "growth clears old rounded bottom corners without a screenshot redraw":
    for theme in [shadcnLight,shadcnDark]:
      var height=80
      let f=mounted(proc():Node=column(@[standard.card(@[
        column(@[],styles=style({"height": $height,"width":"full"}))],key="card")],
        styles=style({"padding":"24","width":"full"})),theme)
      try:
        paintTree(f.h.windowHandle)
        children.setLen(0);discard EnumChildWindows(f.h.windowHandle,collect,0)
        var card:HWND
        for w in children:
          if standardRole(w)==some(UiRole.card):card=w
        require card!=nil
        var oldBounds:RECT
        require GetClientRect(card,addr oldBounds)!=0
        let before=GetDC(card)
        let oldCorner=GetPixel(before,8,oldBounds.bottom-2)
        discard ReleaseDC(card,before)
        height=100;discard f.runtime.refresh()
        # Consume only invalidation generated by normal application updates.
        paintTree(f.h.windowHandle)
        let after=GetDC(card)
        check GetPixel(after,8,oldBounds.bottom-2)==colorRef(if theme==shadcnDark:0x171717'u32 else:0xffffff'u32)
        check GetPixel(after,0,oldBounds.bottom-2)==colorRef(if theme==shadcnDark:0x2e2e2e'u32 else:0xe5e5e5'u32)
        discard ReleaseDC(card,after)
        echo "CARD.OldCorner=",oldCorner," Height=",oldBounds.bottom
      finally:f.close()
