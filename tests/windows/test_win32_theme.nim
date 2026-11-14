when not defined(windows): {.error:"Native theme tests require Windows".}
import ../fixture_app
import std/[unittest,widestrs,strutils,sequtils]
import leaf/[ui_thread,native_layout,native_theme,styles,backend_session]
import leaf/backend as protocol
import leaf/backends/win32/[api,calls,host,backend,skin]
import leaf/ui as standard

proc GetBkColor(dc:HDC):DWORD {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}
proc SetForegroundWindow(w:HWND):BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
var children:seq[HWND]
proc collect(w:HWND,data:LPARAM):BOOL {.stdcall,raises:[].} =
  children.add(w);1
proc text(w:HWND):string =
  let s=newWideCString(4096)
  discard GetWindowTextW(w,cast[WidePtr](unsafeAddr s[0]),4096)
  $s
proc find(parent:HWND,name:string):HWND =
  children.setLen(0);discard EnumChildWindows(parent,collect,0)
  for w in children:
    if text(w)==name:return w
proc selection(w:HWND):tuple[first,last:uint32] =
  discard SendMessageW(w,EM_GETSEL,cast[WPARAM](addr result.first),cast[LPARAM](addr result.last))
proc canvasColor(w:HWND):DWORD =
  # Root uses CLIPCHILDREN and the full-size root child can clip every pixel
  # from its DC. Consume the real CTLCOLOR path instead of GetPixel(CLR_INVALID).
  children.setLen(0);discard EnumChildWindows(w,collect,0)
  let child=children[0]
  let dc=GetDC(w)
  discard SendMessageW(w,0x0138,cast[WPARAM](dc),cast[LPARAM](child))
  result=GetBkColor(dc)
  discard ReleaseDC(w,dc)

type ReactiveBuild=ref object
  build:FixtureBuild
  signal:State[int]
let ReactiveRoot=defineComponent[ReactiveBuild,State[int]]("ReactiveThemeFixture",
  proc(ctx:MountContext,p:ReactiveBuild):State[int] =
    result=ctx.state(0);p.signal=result,
  proc(ctx:ComponentContext,p:ReactiveBuild,signal:State[int]):UiDescription =
    discard ctx.value(signal)
    host(p.build()))

type Fixture=tuple[h:Win32Host,win:Win32Backend,s:BackendSession,runtime:Runtime]
proc mounted(build:FixtureBuild,theme=shadcnLight,calls=systemWin32Calls(),reactive:ReactiveBuild=nil):Fixture =
  let activity=newUiScopeActivity()
  var app=fixtureApplication(build,"Standard runtime theme",560,640)
  if reactive!=nil:
    reactive.build=build
    app=componentApplication(component(ReactiveRoot,reactive),"Standard runtime theme",560,640)
  app=app.withNativeTheme(theme)
  let runtime=newRuntime(guardUiApplication(app,
    proc():uint64=uint64(GetCurrentThreadId()),activity))
  let h=createHost(app.title,DipSize(width:560,height:640),calls,theme)
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

suite "transactional window-root shadcn theme":
  test "mode changes preserve EDIT HWND, focus, fonts, selection, undo and scroll":
    require not highContrastActive()
    var mode=UiColorMode.light
    var declared=true
    var name="Native draft"
    var bio=(0..16).toSeq.mapIt("Line " & $it).join("\r\n")
    let originalBio=bio
    var fontSets=0
    let reactive=ReactiveBuild()
    let sys=systemWin32Calls()
    var c=sys
    c.send=proc(w:HWND,m:UINT,wp:WPARAM,lp:LPARAM):LRESULT =
      if m==WM_SETFONT:inc fontSets
      sys.send(w,m,wp,lp)
    let f=mounted(proc():Node =
      let body=column(@[
        standard.field(@[standard.label("Name"),standard.input(name,key="name",
          onChange=proc(e:Event)=
            name=e.value
            discard reactive.signal.update(proc(n:int):int=n+1)),standard.fieldDescription("Name hint")]),
        standard.field(@[standard.label("Biography"),standard.textarea(bio,key="bio",
          onChange=(proc(e:Event)=
            bio=e.value
            discard reactive.signal.update(proc(n:int):int=n+1)),height=96),standard.fieldDescription("Bio hint")]),
        standard.checkbox("Confirm",true,key="check"),standard.switch("Notify",false,key="switch"),
        standard.button("Save",key="save")],key="body",styles=style({"padding":"24","gap":"16","width":"full"}))
      if declared:standard.theme(mode,body,key="theme")
      else:column(@[body],key="theme",styles=style({"width":"full"})),shadcnDark,c,reactive)
    try:
      check f.h.nativeTheme==shadcnLight
      let root=f.h.windowHandle
      let edit=find(root,name)
      let area=find(root,bio)
      require edit!=nil and area!=nil
      let font=SendMessageW(edit,WM_GETFONT,0,0)
      let areaFont=SendMessageW(area,WM_GETFONT,0,0)
      discard SetForegroundWindow(root);discard SetFocus(area)
      for w in [edit,area]:
        discard SendMessageW(w,EM_SETSEL,0,0)
        let prefix=newWideCString("Changed ")
        discard SendMessageW(w,0x00c2,1,cast[LPARAM](unsafeAddr prefix[0]))
      f.win.safeListTurn();discard f.runtime.refresh()
      require name=="Changed Native draft" and bio=="Changed " & originalBio
      require SendMessageW(edit,0x00c6,0,0)!=0 and SendMessageW(area,0x00c6,0,0)!=0
      discard SendMessageW(edit,EM_SETSEL,1,4)
      discard SendMessageW(area,EM_SETSEL,1,4)
      discard SendMessageW(area,0x00b6,0,3) # EM_LINESCROLL
      let scroll=SendMessageW(area,0x00ce,0,0) # EM_GETFIRSTVISIBLELINE
      f.win.safeListTurn()
      let ring=f.win.focusAdornmentForTest
      require ring!=nil
      let before=f.win.diagnostics
      fontSets=0
      for next in [UiColorMode.dark,UiColorMode.light,UiColorMode.dark]:
        mode=next;discard f.runtime.refresh();f.win.safeListTurn()
        check f.h.nativeTheme==(if next==UiColorMode.dark:shadcnDark else:shadcnLight)
        check canvasColor(root)==colorRef(if next==UiColorMode.dark:0x0a0a0a'u32 else:0xffffff'u32)
        check find(root,name)==edit and find(root,bio)==area
        check GetFocus()==area
        check selection(edit)==(1'u32,4'u32) and selection(area)==(1'u32,4'u32)
        check SendMessageW(area,0x00ce,0,0)==scroll
        check SendMessageW(edit,0x00c6,0,0)!=0 and SendMessageW(area,0x00c6,0,0)!=0 # EM_CANUNDO
        check SendMessageW(edit,WM_GETFONT,0,0)==font and SendMessageW(area,WM_GETFONT,0,0)==areaFont
        check fontSets==0
        check f.win.focusAdornmentForTest==ring
        check f.win.diagnostics.creates==before.creates
        check f.win.diagnostics.liveWindows==before.liveWindows
        check f.win.diagnostics.liveFonts==before.liveFonts
        check f.win.fieldAnnotationCountsForTest==(1,2)
      for w in [edit,area]:discard SendMessageW(w,0x0304,0,0) # WM_UNDO
      f.win.safeListTurn();discard f.runtime.refresh()
      check name=="Native draft" and bio==originalBio
      mode=UiColorMode.light;discard f.runtime.refresh()
      check f.h.nativeTheme==shadcnLight
      declared=false;discard f.runtime.refresh()
      check f.h.nativeTheme==shadcnDark
      check find(root,name)==edit and find(root,bio)==area
    finally:f.close()

  test "nested mode rejects before candidate HWND or window theme mutation":
    var nested=false
    let f=mounted(proc():Node =
      var nodes= @[standard.input("Accepted",key="edit")]
      if nested:nodes.add(standard.theme(UiColorMode.light,standard.input("Rejected",key="new")))
      standard.theme(UiColorMode.dark,column(nodes,key="body"),key="theme"))
    try:
      let edit=find(f.h.windowHandle,"Accepted")
      let creates=f.win.diagnostics.creates
      nested=true
      expect UiError:discard f.runtime.refresh()
      check f.win.diagnostics.creates==creates
      check find(f.h.windowHandle,"Accepted")==edit
      check find(f.h.windowHandle,"Rejected")==nil
      check f.h.nativeTheme==shadcnDark
    finally:f.close()

  test "apply failure restores accepted mode instead of retaining rejected colors":
    var mode=UiColorMode.light
    var label="Accepted"
    var failNext=false
    var fired=false
    let sys=systemWin32Calls()
    var c=sys
    c.setText=proc(w:HWND,s:WidePtr):BOOL =
      if failNext:
        failNext=false;fired=true;return 0
      sys.setText(w,s)
    let f=mounted(proc():Node=standard.theme(mode,standard.button(label,key="button"),key="theme"),calls=c)
    try:
      mode=UiColorMode.dark;label="Rejected";failNext=true
      expect UiError:discard f.runtime.refresh()
      check fired
      check f.h.nativeTheme==shadcnLight
      check canvasColor(f.h.windowHandle)==colorRef(0xffffff)
      check find(f.h.windowHandle,"Accepted")!=nil
      check find(f.h.windowHandle,"Rejected")==nil
    finally:f.close()

  test "independent native windows do not share a runtime color mode":
    var mode=UiColorMode.dark
    let a=mounted(proc():Node=standard.theme(mode,standard.input("A"),key="theme"))
    let b=mounted(proc():Node=standard.theme(UiColorMode.light,standard.input("B"),key="theme"))
    try:
      check a.h.nativeTheme==shadcnDark and b.h.nativeTheme==shadcnLight
      mode=UiColorMode.light;discard a.runtime.refresh()
      mode=UiColorMode.dark;discard a.runtime.refresh()
      check a.h.nativeTheme==shadcnDark and b.h.nativeTheme==shadcnLight
    finally:
      b.close();a.close()
