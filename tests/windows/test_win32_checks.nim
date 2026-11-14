when not defined(windows): {.error:"Native checks require Windows".}
import ../fixture_app
import std/[unittest,widestrs]
import leaf/[ui_thread,native_layout,native_theme,styles,backend_session]
import leaf/backend as protocol
import leaf/backends/win32/[api,host,backend,skin]
import leaf/ui as standard

proc UpdateWindow(w: HWND): BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
proc GetUpdateRect(w:HWND,r:ptr RECT,erase:BOOL):BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
proc ValidateRect(w:HWND,r:ptr RECT):BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
proc SetWindowPos(w,after:HWND,x,y,width,height:int32,flags:UINT):BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
proc GetPixel(dc:HDC,x,y:int32):DWORD {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}
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
proc mounted(build:FixtureBuild,theme:NativeTheme):Fixture =
  let activity=newUiScopeActivity()
  let app=fixtureApplication(build,"Standard checks",480,360).withNativeTheme(theme)
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

suite "shadcn native boolean controls":
  test "Neutral glyphs and caption font do not inherit legacy checkbox painting":
    require not highContrastActive()
    for theme in [shadcnLight,shadcnDark]:
      var invalid=false
      let f=mounted(proc():Node=column(@[
        standard.checkbox("Confirm",false,key="c",invalid=invalid),
        standard.switch("Notify",false,key="s"),
        standard.switch("Compact",true,key="sm",size=UiSize.sm)
      ],styles=style({"padding":"24","gap":"16","width":"full"})),theme)
      try:
        let cb=find(f.h.windowHandle,"Confirm")
        let sw=find(f.h.windowHandle,"Notify")
        let sm=find(f.h.windowHandle,"Compact")
        require cb!=nil and sw!=nil and sm!=nil
        for w in [cb,sw,sm]:
          var r:RECT
          require GetWindowRect(w,addr r)!=0
          check float64(r.right-r.left)/f.h.context.scale>60
          check abs(float64(r.bottom-r.top)/f.h.context.scale-20)<=1
          check (GetWindowLongW(w,GWL_STYLE) and 0xf)==int32(BS_AUTOCHECKBOX)
          var font:LOGFONTW
          require GetObjectW(cast[HGDIOBJ](SendMessageW(w,WM_GETFONT,0,0)),int32(sizeof(font)),addr font)!=0
          check font.lfWeight==500
          discard refreshSkin(w);discard UpdateWindow(w)
        let dc=GetDC(sw)
        require dc!=nil
        # Clear of the unchecked thumb. Hand-derived Neutral track color.
        check GetPixel(dc,26,10)==colorRef(if theme==shadcnLight:0xe5e5e5'u32 else:0x272727'u32)
        discard ReleaseDC(sw,dc)
        let smallDC=GetDC(sm)
        require smallDC!=nil
        check GetPixel(smallDC,17,10)==colorRef(if theme==shadcnLight:0xffffff'u32 else:0x171717'u32)
        check GetPixel(smallDC,25,10)==colorRef(palette(theme).canvas)
        discard ReleaseDC(sm,smallDC)
        invalid=true;discard f.runtime.refresh()
        check find(f.h.windowHandle,"Confirm")==cb
        discard refreshSkin(cb);discard UpdateWindow(cb)
        let errorDC=GetDC(cb)
        require errorDC!=nil
        check GetPixel(errorDC,0,10)==colorRef(palette(theme).danger)
        discard ReleaseDC(cb,errorDC)
      finally:f.close()

  test "accepted and rejected controlled changes preserve HWND and dispatch exactly once":
    for toggle in [false,true]:
      var model=false
      var events=0
      var disabled=false
      var accept=true
      let f=mounted(proc():Node=
        let cb:Callback=proc(e:Event)=
          inc events
          if accept:model=e.checked
        if toggle:standard.switch("Controlled",model,key="control",disabled=disabled,onChange=cb)
        else:standard.checkbox("Controlled",model,key="control",disabled=disabled,onChange=cb),shadcnLight)
      try:
        let w=find(f.h.windowHandle,"Controlled")
        require w!=nil
        discard SendMessageW(w,BM_CLICK,0,0)
        check events==0
        f.s.drainEvents();discard f.runtime.refresh()
        check events==1 and model
        check SendMessageW(w,BM_GETCHECK,0,0)==1
        check find(f.h.windowHandle,"Controlled")==w
        accept=false
        discard SendMessageW(w,BM_CLICK,0,0)
        f.s.drainEvents()
        check events==2 and model
        check SendMessageW(w,BM_GETCHECK,0,0)==1
        disabled=true;discard f.runtime.refresh()
        discard SendMessageW(w,BM_CLICK,0,0)
        f.s.drainEvents()
        check events==2
        check SendMessageW(w,BM_GETCHECK,0,0)==1
        check find(f.h.windowHandle,"Controlled")==w
      finally:f.close()

  test "keyboard focus ring surrounds only the glyph and honors hide-focus":
    for toggle in [false,true]:
      let f=mounted(proc():Node=column(@[
        (if toggle:standard.switch("Focus control",false) else:standard.checkbox("Focus control",false))
      ],styles=style({"padding":"24"})),shadcnLight)
      try:
        let w=find(f.h.windowHandle,"Focus control")
        require w!=nil
        discard SendMessageW(w,0x0128,0x00010002,0)
        discard SetFocus(w);f.win.safeListTurn()
        let ring=f.win.focusAdornmentForTest
        require ring!=nil
        require IsWindowVisible(ring)!=0
        var face,outer:RECT
        require GetWindowRect(w,addr face)!=0
        require GetWindowRect(ring,addr outer)!=0
        check outer.left==face.left-3
        check abs(float64(outer.right-outer.left)-(if toggle:38.0 else:22.0))<=1
        check abs(float64(outer.bottom-outer.top)-(if toggle:24.0 else:22.0))<=1
        check outer.right<face.right
        discard SendMessageW(w,0x0128,0x00010001,0)
        f.win.safeListTurn()
        check IsWindowVisible(ring)==0
      finally:f.close()

  test "shadcn host background erasure never covers a live child glyph":
    for theme in [shadcnLight,shadcnDark]:
      let f=mounted(proc():Node=column(@[
        standard.checkbox("Survives erase",true)
      ],styles=style({"padding":"24"})),theme)
      try:
        let w=find(f.h.windowHandle,"Survives erase")
        require w!=nil
        discard refreshSkin(w);discard UpdateWindow(w)
        let childDC=GetDC(w)
        require childDC!=nil
        let before=GetPixel(childDC,3,8)
        check before==colorRef(if theme==shadcnLight:0x171717'u32 else:0xe5e5e5'u32)
        # USER32 may erase the resized root after children have painted. The
        # root's real DC must exclude its live child windows, not paint over
        # them and leave them blank with no further update region pending.
        let rootDC=GetDC(f.h.windowHandle)
        require rootDC!=nil
        check SendMessageW(f.h.windowHandle,0x0014,cast[WPARAM](rootDC),0)==1
        discard ReleaseDC(f.h.windowHandle,rootDC)
        check GetPixel(childDC,3,8)==before
        discard ReleaseDC(w,childDC)
      finally:f.close()

  test "geometry-only resize invalidates unchanged child text for a fresh paint":
    let f=mounted(proc():Node=column(@[
      text("Resize marker"),standard.checkbox("Resized checkbox",true)
    ],styles=style({"padding":"24","width":"full"})),shadcnDark)
    try:
      let marker=find(f.h.windowHandle,"Resize marker")
      require marker!=nil
      discard refreshSkin(marker);discard UpdateWindow(marker)
      require ValidateRect(marker,nil)!=0
      check GetUpdateRect(marker,nil,0)==0
      var bounds:RECT
      require GetWindowRect(f.h.windowHandle,addr bounds)!=0
      require SetWindowPos(f.h.windowHandle,nil,0,0,420,bounds.bottom-bounds.top,6)!=0
      f.win.safeListTurn()
      # Intrinsic marker geometry did not change. Native copy-bits/region
      # updates of ancestors are not a reliable repaint for this live child.
      check GetUpdateRect(marker,nil,0)!=0
    finally:f.close()
