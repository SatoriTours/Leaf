import ../fixture_app
when not defined(windows): {.error: "Real Win32 controls tests require Windows".}
import std/[unittest, tables, options, os, widestrs, strutils]
import leaf/[core, widgets, styles, backend, backend_session, native_layout, ui_thread]
import leaf/backends/win32/[api, calls, host, backend]

type DLLVERSIONINFO = object
  cbSize,major,minor,build,platform: DWORD
proc DllGetVersion(info:ptr DLLVERSIONINFO):int32 {.stdcall,dynlib:"comctl32.dll",importc,raises:[].}
var version=DLLVERSIONINFO(cbSize:DWORD(sizeof(DLLVERSIONINFO)))
doAssert DllGetVersion(addr version)==0 and version.major>=6
var common=INITCOMMONCONTROLSEX(dwSize:DWORD(sizeof(INITCOMMONCONTROLSEX)),dwICC:ICC_PROGRESS_CLASS)
doAssert initControls(addr common)!=0
echo "ACTUAL_COMMON_CONTROLS_MAJOR=",version.major

proc openHost():Win32Host=createHost("Task4 owner",DipSize(width:400,height:300))
proc render():Node=text("中文 😀",key="x")
proc app(scope:ExecutionScope=nil):Application=
  fixtureApplication(render, "Task4", 400, 300, scope)
proc textEntity():MountedEntity=
  MountedEntity(handle:NodeHandle(1),kind:NodeKind.text,props:normalizeProps(text("中文 😀")))

suite "W-STARTUP and W-INSTALL native owner":
  test "startup native owner requires full Scope guard and rejects second claim":
    let h=openHost()
    expect UiError:discard newWin32Backend(h)
    h.setStartupScope(proc():bool=false)
    let win=newWin32Backend(h)
    check win.asBackend==win.asBackend
    expect UiError:discard newWin32Backend(h)
    h.destroyHost()
    check win.diagnostics.liveRoots==0

  test "real measured startup resources stay owned through busy Scope and explicit safe close":
    let h=openHost();let window=h.windowHandle
    var busy=false
    h.setStartupScope(proc():bool=busy)
    let win=newWin32Backend(h)
    let size=win.measureControl(textEntity(),DipSize(width:100,height:100))
    check size.width>0 and size.height>0
    check win.diagnostics.liveFonts>0
    busy=true
    expect UiError:h.destroyHost()
    check IsWindow(window)!=0
    check h.diagnostics.pendingClose
    check win.diagnostics.liveFonts>0
    busy=false
    h.destroyHost()
    check IsWindow(window)==0
    check win.diagnostics.liveFonts==0
    check win.diagnostics.liveRoots==0

  test "observed retained hook install closes only the exact real provisional Session":
    let h=openHost();let window=h.windowHandle
    let activity=newUiScopeActivity()
    var calls,failAt:int
    let primary=newException(ValueError,"Task4 install exit")
    let cause=newException(IOError,"Task4 cause");primary.parent=cause
    let scope:ExecutionScope=proc(body:proc(){.closure.})=
      inc calls
      if failAt!=0 and calls>failAt:raise newException(UiError,"Task4 cleanup entry refused")
      body()
      if calls==failAt:raise primary
    let runtime=newRuntime(guardUiApplication(app(scope),proc():uint64=uint64(GetCurrentThreadId()),activity))
    h.setStartupScope(proc():bool=activity.busy or runtime.installingUpdate or runtime.installingHook)
    let win=newWin32Backend(h)
    failAt=calls+1
    var first:ref CatchableError
    try:discard win.attachWin32Backend(runtime)
    except CatchableError as error:first=error
    check first != nil
    var chain: ref Exception = first
    var sawPrimary = false
    while chain != nil:
      if chain == primary: sawPrimary = true; break
      chain = chain.parent
    check sawPrimary
    check first of ValueError or first.parent == primary
    check runtime.committerOwner == 0
    # A rejected managed attach leaves the caller-owned Host untouched.
    h.destroyHost()
    check runtime.committerOwner==0 and runtime.preparerOwner==0
    check IsWindow(window)==0
    check win.diagnostics.liveRoots==0


var enumerated:seq[HWND]
proc collect(window:HWND,data:LPARAM):BOOL {.stdcall,raises:[].}=
  enumerated.add(window)
  1
proc descendants(parent:HWND):seq[HWND]=
  enumerated.setLen(0)
  discard EnumChildWindows(parent,collect,0)
  enumerated
proc nativeText(window:HWND):string=
  let size=GetWindowTextLengthW(window)+1
  let value=newWideCString(int(size))
  discard GetWindowTextW(window,cast[WidePtr](unsafeAddr value[0]),size)
  $value
proc nativeClass(window:HWND):string=
  let value=newWideCString(256)
  discard GetClassNameW(window,cast[WidePtr](unsafeAddr value[0]),256)
  $value
proc findText(parent:HWND,value:string):HWND=
  for window in descendants(parent):
    if nativeText(window)==value:return window
proc findClass(parent:HWND,value:string):seq[HWND]=
  for window in descendants(parent):
    if nativeClass(window).toLowerAscii==value.toLowerAscii:result.add(window)
type Fixture=tuple[h:Win32Host,win:Win32Backend,s:BackendSession,runtime:Runtime,activity:UiScopeActivity]
proc mountedApp(app:Application,c:Win32Calls=systemWin32Calls()):Fixture=
  let activity=newUiScopeActivity()
  let runtime=newRuntime(guardUiApplication(app,
    proc():uint64=uint64(GetCurrentThreadId()),activity))
  let h=openHost()
  h.setStartupScope(proc():bool=activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win=newWin32Backend(h,c)
  let session=win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session,proc():bool=activity.busy)
  (h,win,session,runtime,activity)

proc mounted(render:proc():Node,c:Win32Calls=systemWin32Calls()):Fixture=
  let activity=newUiScopeActivity()
  let runtime=newRuntime(guardUiApplication(fixtureApplication(render, "Task4", 400, 300),
    proc():uint64=uint64(GetCurrentThreadId()),activity))
  let h=openHost()
  h.setStartupScope(proc():bool=activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win=newWin32Backend(h,c)
  let session=win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session,proc():bool=activity.busy)
  (h,win,session,runtime,activity)

suite "incremental native layout work":
  test "ten changed fixed leaves do not lay out or touch a thousand native windows":
    var changed = false
    var positions, regions, shows: int
    var c = systemWin32Calls()
    let realPos = c.windowPos
    let realRegion = c.setRegion
    let realShow = c.showWindow
    c.windowPos = proc(w, after: HWND, x,y,width,height: int32, flags: UINT): BOOL =
      inc positions
      realPos(w, after, x,y,width,height,flags)
    c.setRegion = proc(w: HWND, r: HRGN, redraw: BOOL): int32 =
      inc regions
      realRegion(w,r,redraw)
    c.showWindow = proc(w: HWND, command: int32): BOOL =
      inc shows
      realShow(w,command)
    let f = mounted(proc(): Node =
      var children: seq[Node]
      for i in 0..<1000:
        children.add(text((if changed and i < 10: "new " else: "old ") & $i,
          key = "leaf" & $i, styles=style({"width":"80", "height":"1"})))
      column(children, key="root"), c)
    defer: f.h.destroyHost()
    let before = f.win.diagnostics
    positions = 0; regions = 0; shows = 0
    changed = true
    check f.runtime.refresh()
    check f.win.diagnostics.layouts == before.layouts
    check f.win.diagnostics.measures == before.measures
    check f.win.diagnostics.setTexts == before.setTexts + 10
    check positions == 0 and regions == 0 and shows == 0
    for i in 0..<10:
      check findText(f.h.windowHandle, "new " & $i) != nil

  test "identical geometry submits no position region visibility or order calls":
    var positions, regions, shows: int
    var c = systemWin32Calls()
    let realPos = c.windowPos
    let realRegion = c.setRegion
    let realShow = c.showWindow
    c.windowPos = proc(w, after: HWND, x,y,width,height: int32, flags: UINT): BOOL =
      inc positions
      realPos(w,after,x,y,width,height,flags)
    c.setRegion = proc(w: HWND, r: HRGN, redraw: BOOL): int32 =
      inc regions
      realRegion(w,r,redraw)
    c.showWindow = proc(w: HWND, command: int32): BOOL =
      inc shows
      realShow(w,command)
    let f = mounted(proc(): Node =
      column(@[text("stable", key="label"), button("button", key="button")], key="root"), c)
    defer: f.h.destroyHost()
    let ctx = f.h.context
    positions = 0; regions = 0; shows = 0
    f.win.relayout(DipSize(width:ctx.contentWidth, height:ctx.contentHeight), int(ctx.scale * 96))
    check positions == 0 and regions == 0 and shows == 0
    # A real clip change must still be applied, then become quiet again.
    f.win.relayout(DipSize(width:20, height:10), int(ctx.scale * 96))
    check regions > 0
    positions = 0; regions = 0; shows = 0
    f.win.relayout(DipSize(width:20, height:10), int(ctx.scale * 96))
    check positions == 0 and regions == 0 and shows == 0

suite "W-MAP11 DEFAULT STABLE PREPARE RECOVER SOURCE":
  test "all eleven stock kinds are real Unicode native children with actual state":
    let f=mounted(proc():Node=column(@[row(@[
      text("正文中文 😀",key="text"),tag("标签中文",key="tag",variant="default"),
      button("按钮",key="button",disabled=true),input("输入 😀",key="input",placeholder="提示"),
      checkbox("复选",true,key="check"),switch("开关",false,key="toggle"),
      progress(42,key="progress"),spinner(key="spinner"),separator(key="separator")],key="row")],key="root"))
    defer:f.h.destroyHost()
    let children=descendants(f.h.windowHandle)
    check children.len==11
    check f.win.diagnostics.liveWindows==11
    check f.win.diagnostics.liveSubclasses==11
    check f.win.diagnostics.liveFonts>0
    check findText(f.h.windowHandle,"正文中文 😀")!=nil
    let edits=findClass(f.h.windowHandle,"EDIT");check edits.len==1
    if edits.len==1:
      check nativeText(edits[0])=="输入 😀"
      check SendMessageW(edits[0],WM_GETFONT,0,0)!=0
    let button=findText(f.h.windowHandle,"按钮");check button!=nil
    if button!=nil:check IsWindowEnabled(button)==0
    let checked=findText(f.h.windowHandle,"复选");check checked!=nil
    if checked!=nil:check SendMessageW(checked,BM_GETCHECK,0,0)==1
    let progress=findClass(f.h.windowHandle,"msctls_progress32");check progress.len==2
    var marquee,determinate:int
    for window in progress:
      if (DWORD(GetWindowLongW(window,GWL_STYLE)) and PBS_MARQUEE)!=0:inc marquee
      else:inc determinate;check SendMessageW(window,PBM_GETPOS,0,0)==42
    check marquee==1 and determinate==1

  test "full typed property removal restores native defaults and accepted is metadata only":
    let f=mounted(proc():Node=column(@[
      button("old",key="b",disabled=true),input("oldinput",key="i",placeholder="oldhint",disabled=true),
      checkbox("oldcheck",true,key="c",disabled=true),progress(57,key="p")],key="root"))
    defer:f.h.destroyHost()
    let old=f.s.acceptedEntities
    var next=old
    var batch=UpdateBatch(revision:f.runtime.acceptedRevision+1)
    for handle,e in old:
      if e.kind in {NodeKind.button,NodeKind.input,NodeKind.checkbox,NodeKind.progress}:
        next[handle].props=NormalizedProps()
        batch.ops.add(UpdateOp(kind:opUpdate,handle:handle,parent:e.parent,index:e.index,nodeKind:e.kind,nodeId:e.nodeId,props:NormalizedProps()))
    f.win.asBackend.prepare(batch)
    check nativeText(findText(f.h.windowHandle,"old"))=="old"
    f.win.asBackend.apply(batch)
    let before=f.win.diagnostics
    f.win.asBackend.accepted(next,batch.revision)
    let after=f.win.diagnostics
    check after.creates==before.creates and after.setTexts==before.setTexts and after.layouts==before.layouts
    let edits=findClass(f.h.windowHandle,"EDIT");check edits.len==1
    if edits.len==1:
      check nativeText(edits[0])==""
      check IsWindowEnabled(edits[0])!=0
      let cue=newWideCString(64)
      check SendMessageW(edits[0],EM_GETCUEBANNER,cast[WPARAM](unsafeAddr cue[0]),64)!=0
      check $cue==""
    for window in findClass(f.h.windowHandle,"BUTTON"):
      check nativeText(window)==""
      check IsWindowEnabled(window)!=0
      check SendMessageW(window,BM_GETCHECK,0,0)==0
    for window in findClass(f.h.windowHandle,"msctls_progress32"):
      check SendMessageW(window,PBM_GETPOS,0,0)==0

  test "stable input keeps HWND selection and no text setter across unrelated moves":
    var changed=false
    let f=mounted(proc():Node=
      let a=input("alpha😀",key="a");let b=input("beta",key="b")
      if changed:column(@[b,text("changed",key="label"),a,button("new",key="new")],key="root")
      else:column(@[a,b,text("old",key="label")],key="root"))
    defer:f.h.destroyHost()
    let a=findText(f.h.windowHandle,"alpha😀");let b=findText(f.h.windowHandle,"beta")
    check a!=nil and b!=nil
    let ah=f.s.handleFor(f.runtime.find("a").id)
    if a!=nil:discard SendMessageW(a,EM_SETSEL,1,3)
    let before=f.win.diagnostics
    changed=true
    check f.runtime.refresh()
    check findText(f.h.windowHandle,"alpha😀")==a
    check findText(f.h.windowHandle,"beta")==b
    check f.s.handleFor(f.runtime.find("a").id)==ah
    if a!=nil:check SendMessageW(a,EM_GETSEL,0,0)==LRESULT(1 or (3 shl 16))
    check f.win.diagnostics.creates==before.creates+1
    check f.win.diagnostics.setTexts==before.setTexts+1 # only unrelated label

  test "prepare hidden child never alters old visible text rect font and discard releases it":
    let f=mounted(proc():Node=column(@[text("visible",key="v")],key="root"))
    defer:f.h.destroyHost()
    let existing=findText(f.h.windowHandle,"visible");check existing!=nil
    let old=f.s.acceptedEntities
    let handle=f.s.handleFor(f.runtime.find("v").id)
    let entity=old[handle]
    var rect:RECT;discard GetWindowRect(existing,addr rect)
    let font=SendMessageW(existing,WM_GETFONT,0,0)
    let baseline=f.win.diagnostics
    let batch=UpdateBatch(revision:f.runtime.acceptedRevision+1,ops: @[
      UpdateOp(kind:opUpdate,handle:handle,parent:entity.parent,index:entity.index,nodeKind:entity.kind,props:normalizeProps(text("candidate"))),
      UpdateOp(kind:opCreate,handle:NodeHandle(9000),parent:entity.parent,index:1,nodeKind:NodeKind.text,nodeId:"temporary",props:normalizeProps(text("hidden")))])
    f.win.asBackend.prepare(batch)
    check nativeText(existing)=="visible"
    var actual:RECT;discard GetWindowRect(existing,addr actual)
    check actual==rect
    check SendMessageW(existing,WM_GETFONT,0,0)==font
    let hidden=findText(f.h.windowHandle,"hidden");check hidden!=nil
    if hidden!=nil:check IsWindowVisible(hidden)==0
    check f.win.diagnostics.liveWindows==baseline.liveWindows+1
    f.win.asBackend.discardPrepared()
    check f.win.diagnostics.liveWindows==baseline.liveWindows
    check f.win.diagnostics.liveSubclasses==baseline.liveSubclasses
    check f.win.diagnostics.liveRoots==baseline.liveRoots
    if hidden!=nil:check IsWindow(hidden)==0

  test "real apply second text failure restores accepted without replaying business":
    var fail=false;var setters,actions:int
    var c=systemWin32Calls();let real=c.setText
    c.setText=proc(window:HWND,value:WidePtr):BOOL=
      if fail:
        inc setters
        if setters==2:setLastError(5);return 0
      real(window,value)
    type ApplyModel = object
      a, b: string
    let ApplyRoot=defineComponent[int,State[ApplyModel]]("ApplyRoot",
      proc(ctx:MountContext,p:int):State[ApplyModel]=ctx.state(ApplyModel(a:"old",b:"old")),
      proc(ctx:ComponentContext,p:int,m:State[ApplyModel]):UiDescription=
        let v=ctx.value(m)
        host(column(@[text(v.a&" A",key="a"),text(v.b&" B",key="b"),
          button("go",key="go",onClick=proc(e:Event)=(inc actions;
            discard m.set(ApplyModel(a:"new",b:"new"))))],key="root")))
    let f=mountedApp(componentApplication(component(ApplyRoot,0),"Task4",400,300),c)
    defer:f.h.destroyHost()
    check descendants(f.h.windowHandle).len==4
    let generation=f.s.mountGeneration
    fail=true
    expect UiError:discard f.runtime.dispatch("go",Event(kind:click))
    check actions==1
    check f.s.mountGeneration==generation+1
    check not f.s.faulted
    check findText(f.h.windowHandle,"old A")!=nil
    check findText(f.h.windowHandle,"old B")!=nil
    check f.runtime.find("a").node.text=="old A"

  test "setter A suppresses only itself while actual User B is copied then drained once":
    var a,b:int
    var value="oldA"
    var trigger=false
    var inputWindow,buttonWindow:HWND
    var c=systemWin32Calls();let real=c.setText
    c.setText=proc(window:HWND,text:WidePtr):BOOL=
      if trigger and window==inputWindow:
        trigger=false
        discard SendMessageW(buttonWindow,BM_CLICK,0,0)
      real(window,text)
    let f=mounted(proc():Node=column(@[input(value,key="a",onChange=proc(e:Event)=inc a),
      button("UserB",key="b",onClick=proc(e:Event)=inc b)],key="root"),c)
    defer:f.h.destroyHost()
    inputWindow=findText(f.h.windowHandle,"oldA");buttonWindow=findText(f.h.windowHandle,"UserB")
    check inputWindow!=nil and buttonWindow!=nil
    value="newA";trigger=true
    check f.runtime.refresh()
    check a==0 and b==0
    check f.s.queuedEvents==1
    f.s.drainEvents()
    check a==0 and b==1
    check f.s.queuedEvents==0
    discard SendMessageW(f.h.windowHandle,WM_COMMAND,WPARAM(GetDlgCtrlID(buttonWindow)),0)
    check f.s.queuedEvents==0

  test "explicit reset capability is advertised by the complete input backend":
    let f = mounted(proc(): Node = input("x", key="i", resetToken=1))
    defer: f.h.destroyHost()
    check cfInputReset in f.win.asBackend.capabilities.controls
    check findText(f.h.windowHandle, "x") != nil

suite "Win32 resource failures and bounded native measurement":
  test "partial hidden prepare failure releases its actual HWND and subclass":
    let h = openHost()
    defer: h.destroyHost()
    h.setStartupScope(proc(): bool = false)
    var c = systemWin32Calls()
    let real = c.setSubclass
    var number = 0
    c.setSubclass = proc(window: HWND, callback: SUBCLASSPROC, id: UINT_PTR, data: DWORD_PTR): BOOL =
      inc number
      if number == 2: setLastError(5); return 0
      real(window, callback, id, data)
    let win = newWin32Backend(h, c)
    let runtime = newRuntime(fixtureApplication(proc(): Node = column(@[input("x")], key="root"), "failure", 400, 300))
    expect UiError: discard win.attachWin32Backend(runtime)
    check win.diagnostics.liveWindows == 0
    check win.diagnostics.liveSubclasses == 0
    check win.diagnostics.liveFonts == 0

  test "native child destruction failure retains ownership and supports an exact retry":
    var fail = false
    var c = systemWin32Calls()
    let real = c.destroyWindow
    c.destroyWindow = proc(window: HWND): BOOL =
      if fail: setLastError(5); return 0
      real(window)
    let f = mounted(proc(): Node = input("retained", key="i"), c)
    let window = findText(f.h.windowHandle, "retained")
    fail = true
    expect UiError: f.h.destroyHost()
    check IsWindow(window) != 0
    check not f.s.disposed
    check f.win.diagnostics.liveWindows == 1
    fail = false
    f.h.destroyHost()
    check IsWindow(window) == 0
    check f.win.diagnostics.liveWindows == 0
    check f.win.diagnostics.liveFonts == 0

  test "same local text constraints use native measure cache and narrow text wraps":
    let h = openHost()
    defer: h.destroyHost()
    h.setStartupScope(proc(): bool = false)
    let win = newWin32Backend(h)
    var entity = textEntity()
    entity.props = normalizeProps(text("some longer native text that must wrap across several lines"))
    let wide = win.measureControl(entity, DipSize(width: 350, height: 200))
    let before = win.diagnostics.measures
    check win.measureControl(entity, DipSize(width: 350, height: 200)) == wide
    check win.diagnostics.measures == before
    let narrow = win.measureControl(entity, DipSize(width: 80, height: 200))
    check narrow.height > wide.height
    check win.diagnostics.measures == before + 1

  test "theme font invalidation relayout preserves editor HWND and never renders business":
    var renders = 0
    let f = mounted(proc(): Node =
      inc renders
      column(@[input("stable font", key="i")], key="root"))
    defer: f.h.destroyHost()
    let window = findText(f.h.windowHandle, "stable font")
    let before = renders
    discard SendMessageW(f.h.windowHandle, WM_THEMECHANGED, 0, 0)
    f.h.setSafeTick(proc() =
      check renders == before
      check findText(f.h.windowHandle, "stable font") == window
      check f.win.diagnostics.liveFonts == 1
      f.h.requestClose())
    check f.h.pump() == 0

  test "input intrinsic size includes placeholder and twenty average characters":
    let h = openHost()
    defer: h.destroyHost()
    h.setStartupScope(proc(): bool = false)
    let win = newWin32Backend(h)
    var entity = textEntity()
    entity.kind = NodeKind.input
    entity.props = normalizeProps(input("", placeholder="x"))
    let small = win.measureControl(entity, DipSize(width: 1000, height: 100))
    entity.props = normalizeProps(input("", placeholder="a substantially longer placeholder containing 中文 and many more visible characters"))
    let large = win.measureControl(entity, DipSize(width: 1000, height: 100))
    check large.width > small.width
    check large.height == small.height

  test "checkbox intrinsic measurement uses the current native theme":
    let h = openHost()
    defer: h.destroyHost()
    h.setStartupScope(proc(): bool = false)
    var c = systemWin32Calls()
    let realOpen = c.openTheme
    var opened = 0
    c.openTheme = proc(window: HWND, classList: WidePtr, dpi: UINT): HTHEME =
      inc opened
      realOpen(window, classList, dpi)
    let win = newWin32Backend(h, c)
    var entity = textEntity()
    entity.kind = NodeKind.checkbox
    entity.props = normalizeProps(checkbox("中文 native", false))
    let measured = win.measureControl(entity, DipSize(width: 500, height: 100))
    check measured.width > 0 and measured.height > 0
    check opened == 1

  test "failed nested child release never destroys its ancestor and retries cleanly":
    var c = systemWin32Calls()
    let realDestroy = c.destroyWindow
    var selected: HWND
    var once = true
    c.destroyWindow = proc(window: HWND): BOOL =
      if window == selected and once:
        once = false
        setLastError(5)
        return 0
      realDestroy(window)
    let f = mounted(proc(): Node = column(@[input("child", key="i")], key="root"), c)
    selected = findText(f.h.windowHandle, "child")
    let parent = GetParent(selected)
    expect UiError: f.h.destroyHost()
    check IsWindow(selected) != 0
    check IsWindow(parent) != 0
    check not f.s.disposed
    f.h.destroyHost()
    check f.s.disposed
    check f.win.diagnostics.liveWindows == 0
    check f.win.diagnostics.liveSubclasses == 0
    check f.win.diagnostics.liveRoots == 0

  test "fully clipped cumulative positions never overflow platform coordinates":
    var children: seq[Node]
    for i in 0..<2200:
      children.add(text("x", key = $i, styles=style({"width":"1000000"})))
    let f = mounted(proc(): Node = row(children, key="root"))
    defer: f.h.destroyHost()
    check f.win.diagnostics.liveWindows == children.len + 1
    for dpi in [96, 144, 192]:
      f.win.relayout(DipSize(width: 400, height: 300), dpi)
    check f.win.diagnostics.liveWindows == children.len + 1

  test "region transfer exception and cleanup failure retain owned GDI for retry":
    let h = openHost()
    defer: h.destroyHost()
    h.setStartupScope(proc(): bool = false)
    var c = systemWin32Calls()
    let realRegion = c.rectRegion
    let realDelete = c.deleteObject
    var regions: seq[HRGN]
    var failDelete = true
    c.rectRegion = proc(left,top,right,bottom: int32): HRGN =
      result = realRegion(left,top,right,bottom)
      regions.add(result)
    c.setRegion = proc(window: HWND, region: HRGN, redraw: BOOL): int32 =
      raise newException(UiError, "region-transfer-primary")
    c.deleteObject = proc(obj: HGDIOBJ): BOOL =
      for region in regions:
        if cast[pointer](obj) == cast[pointer](region) and failDelete:
          setLastError(5)
          return 0
      realDelete(obj)
    let win = newWin32Backend(h, c)
    let runtime = newRuntime(fixtureApplication(proc(): Node = input("x"), "region", 400, 300))
    try:
      discard win.attachWin32Backend(runtime)
      check false
    except UiError as error:
      check "region-transfer-primary" in error.msg
    check regions.len == 1
    check GetObjectType(cast[HGDIOBJ](regions[0])) != 0
    failDelete = false
    h.destroyHost()
    check GetObjectType(cast[HGDIOBJ](regions[0])) == 0
    check win.diagnostics.liveRoots == 0

  test "diagnostics include a retained hidden measurement window until cleanup succeeds":
    let h = openHost()
    defer: h.destroyHost()
    h.setStartupScope(proc(): bool = false)
    var c = systemWin32Calls()
    let realDestroy = c.destroyWindow
    var reject = true
    c.destroyWindow = proc(window: HWND): BOOL =
      if reject:
        reject = false
        setLastError(5)
        return 0
      realDestroy(window)
    let win = newWin32Backend(h, c)
    let entity = MountedEntity(handle: NodeHandle(1), kind: NodeKind.input,
      props: normalizeProps(input("value", placeholder="hint")))
    expect UiError: discard win.measureControl(entity, DipSize(width: 400, height: 300))
    check descendants(h.windowHandle).len == 1
    check win.diagnostics.liveWindows == 1
    discard win.measureControl(entity, DipSize(width: 400, height: 300))
    check descendants(h.windowHandle).len == 0
    check win.diagnostics.liveWindows == 0
    h.destroyHost()
    check win.diagnostics.liveFonts == 0 and win.diagnostics.liveRoots == 0
