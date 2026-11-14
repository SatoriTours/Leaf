when not defined(windows): {.error:"Native Field tests require Windows".}
import leaf
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
    @[standard.skeleton(160,24,key="shape"),host(standard.input("draft",key="edit"))]),
    "Standard Skeleton",480,360).withNativeTheme(theme)
  let runtime=newRuntime(guardUiApplication(app,
    proc():uint64=uint64(GetCurrentThreadId()),activity))
  let h=createHost(app.title,DipSize(width:480,height:360),theme=theme)
  h.setStartupScope(proc():bool=activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win=newWin32Backend(h,calls)
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

suite "native managed Skeleton":
  test "pulse repaints native shape without recreating HWND or setting fonts":
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
          if standardRole(w)==some(UiRole.skeleton):shape=w
        require shape!=nil
        let edit=find(f.h.windowHandle,"draft")
        require edit!=nil
        discard SetFocus(edit)
        discard SendMessageW(edit,0x00b1,1,4)
        let font=SendMessageW(edit,WM_GETFONT,0,0)
        var bounds:RECT
        require GetClientRect(shape,addr bounds)!=0
        check bounds.right==160 and bounds.bottom==24
        check (GetWindowLongW(shape,GWL_STYLE) and int32(WS_TABSTOP))==0
        fontSets=0
        for t in [0.0,1000.0,2000.0]:
          discard f.runtime.pumpAnimations(t)
          discard UpdateWindow(shape)
          let dc=GetDC(shape)
          let expected=if theme==shadcnLight:
            (if t==1000:0xfafafa'u32 else:0xf5f5f5'u32)
            else:(if t==1000:0x181818'u32 else:0x262626'u32)
          check GetPixel(dc,80,12)==colorRef(expected)
          check GetPixel(dc,0,0)==colorRef(if theme==shadcnLight:0xffffff'u32 else:0x0a0a0a'u32)
          discard ReleaseDC(shape,dc)
          check GetFocus()==edit
          check SendMessageW(edit,WM_GETFONT,0,0)==font
          check SendMessageW(edit,0x00b0,0,0)==0x00040001
          check IsWindow(shape)!=0
          check fontSets==0
      finally:f.close()
