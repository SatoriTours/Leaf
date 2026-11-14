when not defined(windows): {.error:"Native catalog tests require Windows".}
import std/[unittest,widestrs]
import leaf
import leaf/[ui_thread,native_layout,native_theme,backend_session]
import leaf/backend as protocol
import leaf/backends/win32/[api,host,backend]
import ../../examples/ui_showcase/catalog_view

var children:seq[HWND]
proc collect(w:HWND,data:LPARAM):BOOL {.stdcall,raises:[].} =
  children.add(w);1
proc find(root:HWND,name:string):HWND =
  children.setLen(0);discard EnumChildWindows(root,collect,0)
  for w in children:
    let s=newWideCString(256)
    discard GetWindowTextW(w,cast[WidePtr](unsafeAddr s[0]),256)
    if $s==name:return w

type Fixture=tuple[h:Win32Host,win:Win32Backend,s:BackendSession,runtime:Runtime]
proc mounted():Fixture =
  let activity=newUiScopeActivity()
  let app=componentApplication(catalogDescription(),"Catalog contracts",480,700).withNativeTheme(shadcnLight)
  let runtime=newRuntime(guardUiApplication(app,proc():uint64=uint64(GetCurrentThreadId()),activity))
  let h=createHost(app.title,DipSize(width:480,height:700),theme=shadcnLight)
  h.setStartupScope(proc():bool=activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win=newWin32Backend(h)
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
proc click(f:Fixture,key:string) =
  discard f.runtime.dispatch(key,Event(kind:EventKind.click));f.win.safeListTurn()
proc insideClient(root:HWND) =
  var client:RECT
  var origin:POINT
  require GetClientRect(root,addr client)!=0
  require ClientToScreen(root,addr origin)!=0
  children.setLen(0);discard EnumChildWindows(root,collect,0)
  for w in children:
    var rect:RECT
    require GetWindowRect(w,addr rect)!=0
    if rect.right>rect.left and rect.bottom>rect.top:
      check rect.left>=origin.x
      check rect.top>=origin.y
      check rect.right<=origin.x+client.right
      check rect.bottom<=origin.y+client.bottom

suite "native catalog integration":
  test "all five pages fit 480 by 700 client and page switches drain providers":
    let f=mounted();defer:f.close()
    var baseline:array[5,int]
    for cycle in 0..<3:
      for index,key in ["nav-form","nav-groups","nav-feedback","nav-empty","nav-animation"]:
        f.click(key)
        insideClient(f.h.windowHandle)
        let live=f.win.diagnostics.liveWindows
        if cycle==0:baseline[index]=live
        else:check live==baseline[index]
        check f.win.liveProviderCountsForTest==(if key in ["nav-feedback","nav-animation"]:(1,1) else:(0,0))
    f.click("catalog-loaded")
    check not f.runtime.animationPumpPending
    check f.win.liveProviderCountsForTest==(0,0)

  test "live theme preserves native EDIT selection and font while page remount preserves value":
    let f=mounted();defer:f.close()
    let edit=find(f.h.windowHandle,"Leaf 用户")
    require edit!=nil
    let font=SendMessageW(edit,WM_GETFONT,0,0)
    discard SendMessageW(edit,EM_SETSEL,1,3)
    f.click("catalog-mode")
    check f.h.nativeTheme==shadcnDark
    check find(f.h.windowHandle,"Leaf 用户")==edit
    check SendMessageW(edit,WM_GETFONT,0,0)==font
    var first,last:uint32
    discard SendMessageW(edit,EM_GETSEL,cast[WPARAM](addr first),cast[LPARAM](addr last))
    check (first,last)==(1'u32,3'u32)
    discard f.runtime.dispatch("catalog-name",Event(kind:EventKind.change,value:"Native draft"))
    f.click("nav-groups");f.click("nav-form")
    check find(f.h.windowHandle,"Native draft")!=nil
