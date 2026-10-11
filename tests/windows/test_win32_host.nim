when not defined(windows): {.error: "Real Win32 Host suite requires Windows".}
import std/[unittest, strutils, typedthreads, widestrs]
import leaf/[core, widgets, backend, backend_session, native_layout, ui_thread, windows_dpi]
import leaf/backends/headless
import leaf/backends/win32/[api, calls, host]

proc abiWnd(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): LRESULT {.stdcall, exportc: "leaf_abi_wnd", raises: [].} = 0
proc abiSubclass(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM, id: UINT_PTR, data: DWORD_PTR): LRESULT {.stdcall, exportc: "leaf_abi_subclass", raises: [].} = 0
{.emit: """
#include "win32_host_abi.h"
LEAF_SIZE(`HWND`, HWND); LEAF_ALIGN(`HWND`, HWND);
LEAF_SIZE(`HANDLE`, HANDLE); LEAF_ALIGN(`HANDLE`, HANDLE);
LEAF_SIZE(`HINSTANCE`, HINSTANCE); LEAF_ALIGN(`HINSTANCE`, HINSTANCE);
LEAF_SIZE(`HMENU`, HMENU); LEAF_ALIGN(`HMENU`, HMENU);
LEAF_SIZE(`DWORD`, DWORD); LEAF_ALIGN(`DWORD`, DWORD);
LEAF_SIZE(`UINT`, UINT); LEAF_ALIGN(`UINT`, UINT);
LEAF_SIZE(`BOOL`, BOOL); LEAF_ALIGN(`BOOL`, BOOL);
LEAF_SIZE(`LONG`, LONG); LEAF_ALIGN(`LONG`, LONG);
LEAF_SIZE(`WCHAR`, WCHAR); LEAF_ALIGN(`WCHAR`, WCHAR);
LEAF_SIZE(`UINT_PTR`, UINT_PTR); LEAF_ALIGN(`UINT_PTR`, UINT_PTR);
LEAF_SIZE(`DWORD_PTR`, DWORD_PTR); LEAF_ALIGN(`DWORD_PTR`, DWORD_PTR);
LEAF_SIZE(`WPARAM`, WPARAM); LEAF_ALIGN(`WPARAM`, WPARAM);
LEAF_SIZE(`LPARAM`, LPARAM); LEAF_ALIGN(`LPARAM`, LPARAM);
LEAF_SIZE(`LRESULT`, LRESULT); LEAF_ALIGN(`LRESULT`, LRESULT);
LEAF_SIZE(`POINT`, POINT); LEAF_ALIGN(`POINT`, POINT);
LEAF_SIZE(`RECT`, RECT); LEAF_ALIGN(`RECT`, RECT);
LEAF_SIZE(`MSG`, MSG); LEAF_ALIGN(`MSG`, MSG);
LEAF_SIZE(`WNDCLASSEXW`, WNDCLASSEXW); LEAF_ALIGN(`WNDCLASSEXW`, WNDCLASSEXW);
LEAF_SIZE(`CREATESTRUCTW`, CREATESTRUCTW); LEAF_ALIGN(`CREATESTRUCTW`, CREATESTRUCTW);
LEAF_FIELD(`POINT`, POINT, x);
LEAF_FIELD(`POINT`, POINT, y);
LEAF_FIELD(`RECT`, RECT, left);
LEAF_FIELD(`RECT`, RECT, top);
LEAF_FIELD(`RECT`, RECT, right);
LEAF_FIELD(`RECT`, RECT, bottom);
LEAF_FIELD(`MSG`, MSG, hwnd);
LEAF_FIELD(`MSG`, MSG, message);
LEAF_FIELD(`MSG`, MSG, wParam);
LEAF_FIELD(`MSG`, MSG, lParam);
LEAF_FIELD(`MSG`, MSG, time);
LEAF_FIELD(`MSG`, MSG, pt);
LEAF_FIELD(`WNDCLASSEXW`, WNDCLASSEXW, cbSize);
LEAF_FIELD(`WNDCLASSEXW`, WNDCLASSEXW, style);
LEAF_FIELD(`WNDCLASSEXW`, WNDCLASSEXW, lpfnWndProc);
LEAF_FIELD(`WNDCLASSEXW`, WNDCLASSEXW, cbClsExtra);
LEAF_FIELD(`WNDCLASSEXW`, WNDCLASSEXW, cbWndExtra);
LEAF_FIELD(`WNDCLASSEXW`, WNDCLASSEXW, hInstance);
LEAF_FIELD(`WNDCLASSEXW`, WNDCLASSEXW, hIcon);
LEAF_FIELD(`WNDCLASSEXW`, WNDCLASSEXW, hCursor);
LEAF_FIELD(`WNDCLASSEXW`, WNDCLASSEXW, hbrBackground);
LEAF_FIELD(`WNDCLASSEXW`, WNDCLASSEXW, lpszMenuName);
LEAF_FIELD(`WNDCLASSEXW`, WNDCLASSEXW, lpszClassName);
LEAF_FIELD(`WNDCLASSEXW`, WNDCLASSEXW, hIconSm);
LEAF_FIELD(`CREATESTRUCTW`, CREATESTRUCTW, lpCreateParams);
LEAF_FIELD(`CREATESTRUCTW`, CREATESTRUCTW, hInstance);
LEAF_FIELD(`CREATESTRUCTW`, CREATESTRUCTW, hMenu);
LEAF_FIELD(`CREATESTRUCTW`, CREATESTRUCTW, hwndParent);
LEAF_FIELD(`CREATESTRUCTW`, CREATESTRUCTW, cy);
LEAF_FIELD(`CREATESTRUCTW`, CREATESTRUCTW, cx);
LEAF_FIELD(`CREATESTRUCTW`, CREATESTRUCTW, y);
LEAF_FIELD(`CREATESTRUCTW`, CREATESTRUCTW, x);
LEAF_FIELD(`CREATESTRUCTW`, CREATESTRUCTW, style);
LEAF_FIELD(`CREATESTRUCTW`, CREATESTRUCTW, lpszName);
LEAF_FIELD(`CREATESTRUCTW`, CREATESTRUCTW, lpszClass);
LEAF_FIELD(`CREATESTRUCTW`, CREATESTRUCTW, dwExStyle);
_Static_assert(__builtin_types_compatible_p(__typeof__(&leaf_abi_wnd), WNDPROC), "WNDPROC ABI");
_Static_assert(__builtin_types_compatible_p(__typeof__(&leaf_abi_subclass), SUBCLASSPROC), "SUBCLASSPROC ABI");
""".}

proc makeHost(c = systemWin32Calls(), title = "Leaf 中文 😀"): Win32Host =
  createHost(title, DipSize(width: 320, height: 200), c)
proc application(render: RenderProc, scope: ExecutionScope = nil): Application =
  Application(title: "Host", width: 320, height: 200, render: render, executionScope: scope)
proc attach(h: Win32Host, render: RenderProc = nil, scope: ExecutionScope = nil): tuple[s: BackendSession, r: RecordingBackend, activity: UiScopeActivity] =
  let activity = newUiScopeActivity()
  var actual = render
  if actual == nil: actual = proc(ctx: BuildContext): Node = text("x", key = "x")
  let runtime = newRuntime(guardUiApplication(application(actual, scope),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let recording = newRecordingBackend(fullCapabilities())
  let session = attachBackend(runtime, recording.backend, h.context)
  h.bindSession(session, proc(): bool = activity.busy)
  (session, recording, activity)
proc watchdog(window: HWND, message: UINT, timer: UINT_PTR, time: DWORD) {.stdcall, raises: [].} =
  discard KillTimer(nil, timer)
  PostQuitMessage(97)
proc boundedPump(h: Win32Host): int =
  ## Test-owned deadline only: a broken product loop yields a FAILED value,
  ## normal tests still exit/clean their real resources without force-kill.
  let timer = SetTimer(nil, 0, 5000, watchdog)
  if timer == 0: fail("test watchdog timer unavailable")
  try: result = h.pump()
  finally: discard KillTimer(nil, timer)

suite "Unicode owned Win32 Host":
  test "Windows header ABI and stdcall callbacks compile and link":
    check sizeof(WCHAR) == 2
    check sizeof(BOOL) == 4
    check sizeof(LPARAM) == sizeof(pointer)

  test "Unicode title actual W roundtrip client content and selected DPI policy":
    let policy = initializeWindowsDpi()
    let h = makeHost()
    let window = h.windowHandle
    defer: h.destroyHost()
    check IsWindow(window) != 0
    let title = "Leaf 中文 😀"
    var buffer = newSeq[WCHAR](int(GetWindowTextLengthW(window)) + 1)
    let count = GetWindowTextW(window, addr buffer[0], int32(buffer.len))
    let expected = newWideCString(title)
    check count == 10 # UTF16: Leaf(4), space, 中文(2), space, emoji(2)
    for i in 0..<int(count): check buffer[i] == uint16(expected[i])
    var rect: RECT
    check GetClientRect(window, addr rect) != 0
    let ctx = h.context
    check ctx.sessionId != 0
    check ctx.contentWidth == float64(rect.right - rect.left) / ctx.scale
    check ctx.contentHeight == float64(rect.bottom - rect.top) / ctx.scale
    check ctx.scale > 0
    check initializeWindowsDpi().awareness == policy.awareness
    check SetWindowPos(window,nil,0,0,420,300,SWP_NOZORDER or SWP_NOACTIVATE) != 0
    check h.context.contentWidth > ctx.contentWidth
    var ticks=0
    h.setSafeTick(proc() = inc ticks)
    let dpi=GetDpiForWindow(window)
    var suggested=RECT(left:10,top:10,right:430,bottom:310)
    discard SendMessageW(window,WM_DPICHANGED,WPARAM(dpi or (dpi shl 16)),cast[LPARAM](addr suggested))
    check ticks==0 # Actual message at current DPI, not multi-display H evidence.
    check h.windowHandle==window
    check h.context.scale==float64(dpi)/96.0

  test "invalid titles and nonfinite sizes rejected before native create":
    var creates = 0
    var c = systemWin32Calls()
    let original = c.createWindow
    c.createWindow = proc(exStyle: DWORD, className,title: WidePtr, style: DWORD, x,y,width,height: int32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: pointer): HWND =
      inc creates
      original(exStyle,className,title,style,x,y,width,height,parent,menu,instance,param)
    for title in ["bad\0title", "\xff", repeat("a", MaxStringBytes+1)]:
      expect UiError: discard makeHost(c,title)
    expect UiError: discard createHost("x",DipSize(width: NaN,height: 10),c)
    check creates == 0

  test "real acquired class root creation refusal unwinds and subsequent create works":
    let anchor = makeHost()
    defer: anchor.destroyHost()
    let baseline = anchor.diagnostics
    var c = systemWin32Calls()
    let original = c.createWindow
    var refused = false
    var observedClass: seq[WCHAR]
    var rootPresent, classPresent: bool
    c.createWindow = proc(exStyle: DWORD, className,title: WidePtr, style: DWORD, x,y,width,height: int32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: pointer): HWND =
      if not refused:
        refused = true
        rootPresent = anchor.diagnostics.liveRoots == baseline.liveRoots + 1
        let chars = cast[ptr UncheckedArray[WCHAR]](className)
        var i = 0
        while chars[i] != 0: observedClass.add(chars[i]); inc i
        observedClass.add(0)
        var info: WNDCLASSEXW
        classPresent = GetClassInfoExW(instance,className,addr info) != 0
        setLastError(8)
        return nil
      original(exStyle,className,title,style,x,y,width,height,parent,menu,instance,param)
    expect UiError: discard makeHost(c)
    check rootPresent
    check classPresent
    check anchor.diagnostics.liveRoots == baseline.liveRoots
    check anchor.diagnostics.liveWindows == baseline.liveWindows
    var info: WNDCLASSEXW
    check GetClassInfoExW(GetModuleHandleW(nil),addr observedClass[0],addr info) == 0
    let next = makeHost(c)
    next.destroyHost()
    check anchor.diagnostics.liveRoots == baseline.liveRoots

  test "wrong Session binding rejects without disposing another lease":
    let h = makeHost()
    defer: h.destroyHost()
    let runtime = newRuntime(application(proc(ctx: BuildContext): Node = text("x",key="x")))
    let recording = newRecordingBackend(fullCapabilities())
    var wrong = h.context
    inc wrong.sessionId
    let session = attachBackend(runtime, recording.backend, wrong)
    expect UiError: h.bindSession(session,proc(): bool = false)
    check not session.disposed
    session.dispose()

  test "two captured events stop after actual WM_CLOSE nested in callback":
    let h = makeHost()
    let baseline = h.diagnostics
    let window = h.windowHandle
    var count = 0
    var session: BackendSession
    var recording: RecordingBackend
    let bound = h.attach(proc(ctx: BuildContext): Node = button("close",key="close",onClick=proc(e: Event) =
      inc count
      discard SendMessageW(window,WM_CLOSE,0,0)
      check session.closing
      check not session.disposed
      check boundedPump(h) == 0
      check IsWindow(window) != 0
      check recording.disposeCalls == 0))
    session = bound.s;recording = bound.r
    let handle = session.handleFor(session.runtime.find("close").id)
    for sequence in [1'u64,2'u64]:
      check session.enqueue(EventEnvelope(session:session.sessionId,mountGeneration:session.mountGeneration,handle:handle,sequence:sequence,source:sourceUser,event:Event(kind:click)))
    h.setSafeTick(proc() = session.drainEvents())
    check boundedPump(h) == 0
    check count == 1
    check session.disposed
    check recording.disposeCalls == 1
    check IsWindow(window) == 0
    check h.diagnostics.liveRoots == baseline.liveRoots-1
    check not session.runtime.eventsFrozen
    h.destroyHost()

  test "Backend apply close and nested pump defer release until candidate publishes":
    let h = makeHost();let window = h.windowHandle
    let bound = h.attach(proc(ctx: BuildContext): Node = button("go",key="go",onClick=proc(e: Event) = discard))
    let original = bound.r.backend.apply
    bound.r.backend.apply = proc(batch: UpdateBatch) =
      original(batch)
      discard SendMessageW(window,WM_CLOSE,0,0)
      check boundedPump(h) == 0
      check not bound.s.disposed
      check bound.r.disposeCalls == 0
      check IsWindow(window) != 0
    h.setSafeTick(proc() = discard bound.s.runtime.dispatch("go",Event(kind:click)))
    check boundedPump(h) == 0
    check bound.s.disposed
    check bound.r.disposeCalls == 1
    check IsWindow(window) == 0

  test "post body original Scope remains busy through nested close pump":
    let h = makeHost();let window = h.windowHandle
    var active = false
    var session: BackendSession
    let originalScope: ExecutionScope = proc(body: proc() {.closure.}) =
      body()
      if active:
        discard SendMessageW(window,WM_CLOSE,0,0)
        check not session.runtime.installingUpdate
        check boundedPump(h) == 0
        check IsWindow(window) != 0
        check not session.disposed
    let bound = h.attach(scope=originalScope);session=bound.s
    active=true
    h.setSafeTick(proc() = discard session.runtime.refresh())
    check boundedPump(h) == 0
    check session.disposed
    check IsWindow(window) == 0

  test "dispose and native destroy failures retry without ordinary tick replay":
    var c = systemWin32Calls()
    let nativeDestroy = c.destroyWindow
    var nativeAttempts = 0
    var sessionRef:BackendSession
    var nativeAfterRelease=true
    c.destroyWindow = proc(window: HWND): BOOL =
      inc nativeAttempts
      nativeAfterRelease = nativeAfterRelease and sessionRef != nil and sessionRef.disposed
      if nativeAttempts == 1: setLastError(5); return 0
      nativeDestroy(window)
    let h = makeHost(c);let window = h.windowHandle
    let bound = h.attach()
    let release = bound.r.backend.dispose
    sessionRef=bound.s
    var aliveOnRejectedDispose=false
    var backendAttempts = 0
    bound.r.backend.dispose = proc() =
      inc backendAttempts
      if backendAttempts == 1:
        aliveOnRejectedDispose=IsWindow(window)!=0 and not bound.s.disposed
        raise newException(UiError,"one dispose failure")
      release()
    var ordinary = 0
    h.setSafeTick(proc() = inc ordinary)
    for i in 0..<3: h.requestClose()
    check boundedPump(h) == 0
    check backendAttempts == 2
    check aliveOnRejectedDispose
    check nativeAfterRelease
    check nativeAttempts == 2
    check bound.r.disposeCalls == 1
    check ordinary == 0
    check bound.s.disposed
    check IsWindow(window) == 0
    check h.diagnostics.callbackErrors >= 2
    h.requestClose();h.destroyHost()

  test "dead HWND class cleanup failure requires explicit retry and is not complete":
    var c = systemWin32Calls();let unregister = c.unregisterClass
    var attempts = 0
    c.unregisterClass = proc(name: WidePtr, instance: HINSTANCE): BOOL =
      inc attempts
      if attempts == 1: setLastError(5); return 0
      unregister(name,instance)
    let h = makeHost(c);let window = h.windowHandle;let bound=h.attach()
    h.requestClose()
    expect UiError: discard boundedPump(h)
    check bound.s.disposed
    check IsWindow(window) == 0
    check h.diagnostics.pendingClose
    h.destroyHost()
    check attempts == 2
    check not h.diagnostics.pendingClose

  test "callback exception is delivered at Nim pump boundary with exact identity":
    let h=makeHost();let bound=h.attach();let window=h.windowHandle
    let cause=newException(IOError,"cause")
    let primary=newException(ValueError,"tick")
    primary.parent=cause
    var actions=0
    h.setSafeTick(proc() = inc actions;raise primary)
    var caught: ref CatchableError
    try: discard boundedPump(h)
    except CatchableError as error: caught=error
    check caught==primary
    check caught.parent==cause
    check actions==1
    check IsWindow(window)!=0
    check h.diagnostics.callbackErrors==1
    h.destroyHost()
    check bound.s.disposed

  test "WndProc native callback error cannot cross ABI and is reported later":
    var c=systemWin32Calls();let native=c.clientRect
    var enabled=false
    let primary=newException(ValueError,"client geometry failure")
    c.clientRect=proc(window: HWND, rect: ptr RECT): BOOL =
      if enabled: enabled=false;raise primary
      native(window,rect)
    let h=makeHost(c);let window=h.windowHandle
    enabled=true
    discard SendMessageW(window,WM_SIZE,0,0) # returns through raises[] ABI
    check h.diagnostics.callbackErrors==1
    var caught: ref CatchableError
    try: discard boundedPump(h)
    except CatchableError as error: caught=error
    check caught==primary
    h.destroyHost()

  test "GetMessage minus one is error and zero quit does not release Session":
    var c=systemWin32Calls()
    c.getMessage=proc(message: ptr MSG, window: HWND, first,last: UINT): BOOL = setLastError(5);-1
    let h=makeHost(c);let bound=h.attach()
    expect UiError: discard boundedPump(h)
    check not bound.s.disposed
    h.destroyHost()
    let other=makeHost();let otherBound=other.attach()
    PostQuitMessage(23)
    check boundedPump(other)==23
    check not otherBound.s.disposed
    other.destroyHost()

  test "WM_QUIT preserves a signed negative exit without releasing Session":
    let h=makeHost();let bound=h.attach()
    PostQuitMessage(-1)
    var returned=0
    var defect:ref Defect
    try: returned=boundedPump(h)
    except Defect as e:defect=e
    check defect==nil
    check returned== -1
    check not bound.s.disposed
    h.destroyHost()

  test "close before bind is pending until real Session is attached":
    let h=makeHost();let window=h.windowHandle
    discard SendMessageW(window,WM_CLOSE,0,0)
    # Busy startup has not yet handed the Host an authoritative Session.
    check h.diagnostics.pendingClose
    let bound=h.attach()
    check bound.s.closing
    check not bound.s.disposed
    check IsWindow(window)!=0
    check boundedPump(h)==0
    check bound.s.disposed
    check IsWindow(window)==0

  test "initial attach post Scope error aborts before explicit unbound Host cleanup":
    let h=makeHost();let window=h.windowHandle
    var reject=false
    let activity=newUiScopeActivity()
    let primary=newException(ValueError,"install post scope")
    let runtime=newRuntime(guardUiApplication(application(proc(ctx:BuildContext):Node=text("x",key="x"),
      proc(body:proc(){.closure.}) =
        body()
        if reject:
          check activity.busy
          discard SendMessageW(window,WM_CLOSE,0,0)
          check boundedPump(h)==0
          check IsWindow(window)!=0
          raise primary),proc():uint64=uint64(GetCurrentThreadId()),activity))
    let recording=newRecordingBackend(fullCapabilities())
    reject=true
    var caught:ref CatchableError
    try: discard attachBackend(runtime,recording.backend,h.context)
    except CatchableError as e:caught=e
    check caught==primary
    check recording.disposed
    check runtime.committerOwner==0
    check not activity.busy
    h.destroyHost()
    check IsWindow(window)==0

  test "actual IsDialogMessage routes Tab between test owned EDIT and BUTTON":
    proc GetFocus():HWND {.stdcall,dynlib:"user32.dll",importc,raises:[].}
    proc SetFocus(window:HWND):HWND {.stdcall,dynlib:"user32.dll",importc,raises:[].}
    var c=systemWin32Calls();let dialog=c.dialogMessage
    var tabHandled=false
    var parent:HWND
    c.dialogMessage=proc(window:HWND,message:ptr MSG):BOOL =
      result=dialog(window,message)
      if message.message==0x0100'u32 and message.wParam==9:
        tabHandled=result!=0
        discard PostMessageW(parent,WM_HOST_TICK,0,0)
    let h=makeHost(c);parent=h.windowHandle
    let bound=h.attach()
    let editClass=newWideCString("EDIT");let buttonClass=newWideCString("BUTTON")
    var edit=CreateWindowExW(0,cast[WidePtr](unsafeAddr editClass[0]),nil,0x50010000'u32,10,10,100,24,parent,nil,GetModuleHandleW(nil),nil)
    var button=CreateWindowExW(0,cast[WidePtr](unsafeAddr buttonClass[0]),nil,0x50010000'u32,10,40,100,24,parent,nil,GetModuleHandleW(nil),nil)
    defer:
      if edit!=nil:discard DestroyWindow(edit)
      if button!=nil:discard DestroyWindow(button)
      h.destroyHost()
    check edit!=nil and button!=nil
    discard SetFocus(edit)
    check GetFocus()==edit
    check PostMessageW(edit,0x0100'u32,9,0)!=0
    var observed=false
    h.setSafeTick(proc() =
      if tabHandled:
        observed=GetFocus()==button
        check DestroyWindow(edit)!=0;edit=nil
        check DestroyWindow(button)!=0;button=nil
        h.requestClose())
    check boundedPump(h)==0
    check tabHandled and observed
    check bound.s.disposed

  test "real one shot retry timer is killed before parent native destruction":
    var c=systemWin32Calls()
    let setTimer=c.setTimer;let killTimer=c.killTimer;let destroy=c.destroyWindow
    var acquired,killed:seq[UINT_PTR]
    var releaseOrder:seq[string]
    c.setTimer=proc(window:HWND,id:UINT_PTR,interval:UINT,callback:TIMERPROC):UINT_PTR =
      result=setTimer(window,id,interval,callback)
      if result!=0:acquired.add(result)
    c.killTimer=proc(window:HWND,id:UINT_PTR):BOOL =
      result=killTimer(window,id)
      if result!=0:killed.add(id);releaseOrder.add("timer")
    c.destroyWindow=proc(window:HWND):BOOL =
      releaseOrder.add("window")
      destroy(window)
    let h=makeHost(c);let bound=h.attach()
    let release=bound.r.backend.dispose
    var first=true
    bound.r.backend.dispose=proc() =
      if first:first=false;raise newException(UiError,"timer retry")
      release()
    h.requestClose()
    check boundedPump(h)==0
    check acquired.len>0
    check acquired==killed
    check releaseOrder[^1]=="window"
    check bound.s.disposed

  test "destroying one host never posts quit for other thread windows and cycles restore baselines":
    let anchor=makeHost();let baseline=anchor.diagnostics
    for i in 0..<10:
      let h=makeHost();let window=h.windowHandle
      var name=newSeq[WCHAR](256)
      check GetClassNameW(window,addr name[0],int32(name.len))>0
      h.destroyHost()
      var cls:WNDCLASSEXW
      check GetClassInfoExW(GetModuleHandleW(nil),addr name[0],addr cls)==0
      check IsWindow(window)==0
      check anchor.diagnostics.liveRoots==baseline.liveRoots
      check anchor.diagnostics.liveWindows==baseline.liveWindows
    let bound=anchor.attach()
    anchor.requestClose()
    check boundedPump(anchor)==0
    check bound.s.disposed

var borrowed: proc() {.closure.}
var workerRejected=false
proc worker() {.thread.} =
  {.cast(gcsafe).}:
    try: borrowed()
    except CatchableError: workerRejected=true
proc onWorker(body: proc() {.closure.}) =
  borrowed=body;workerRejected=false
  var thread: Thread[void]
  createThread(thread,worker);joinThread(thread)
  borrowed=nil

suite "Win32 real thread ownership before Runtime":
  test "real worker rejects initial render dispatch materialize before action or Native factory":
    var transfer=true
    var renders,handlers,rows,factories:int
    let scope: ExecutionScope=proc(body: proc() {.closure.}) =
      if transfer: onWorker(body)
      else: body()
    let activity=newUiScopeActivity()
    let app=guardUiApplication(application(proc(ctx: BuildContext): Node =
      inc renders
      column(@[button("go",key="go",onClick=proc(e: Event) = inc handlers),virtualList("list",@["a"],proc(index:int): Node = (inc rows;text("row",key="row")))],key="root"),scope),proc():uint64=uint64(GetCurrentThreadId()),activity)
    expect UiError:
      discard newRuntime(app)
      inc factories
      discard makeHost()
    check renders==0
    check factories==0
    check workerRejected
    transfer=false
    let runtime=newRuntime(app)
    let previous=renders
    let h=makeHost()
    let recording=newRecordingBackend(fullCapabilities())
    let session=attachBackend(runtime,recording.backend,h.context)
    h.bindSession(session,proc():bool=activity.busy)
    let beforeApply=recording.applyCalls
    let beforeWindows=h.diagnostics.liveWindows
    transfer=true
    expect UiError: discard runtime.dispatch("go",Event(kind:click))
    expect UiError: discard runtime.materialize("list",0,1)
    check handlers==0
    check rows==0
    check renders==previous
    check recording.applyCalls==beforeApply
    check h.diagnostics.liveWindows==beforeWindows
    check not activity.busy
    transfer=false
    h.destroyHost()

  test "wrong owner Host getters and methods do no native call or business":
    let h=makeHost();let bound=h.attach()
    let baseline=h.diagnostics
    onWorker(proc() = discard h.context)
    check workerRejected
    onWorker(proc() = discard h.diagnostics)
    check workerRejected
    onWorker(proc() = h.setSafeTick(proc() = discard))
    check workerRejected
    onWorker(proc() = h.bindSession(bound.s,proc():bool=false))
    check workerRejected
    onWorker(proc() = discard h.windowHandle)
    check workerRejected
    onWorker(proc() = h.requestClose())
    check workerRejected
    onWorker(proc() = h.destroyHost())
    check workerRejected
    onWorker(proc() = discard h.pump())
    check workerRejected
    check h.diagnostics.liveWindows==baseline.liveWindows
    check not bound.s.closing
    check bound.r.disposeCalls==0
    h.destroyHost()
    check h.diagnostics.liveRoots==0
    check h.diagnostics.liveWindows==0


proc verifyNcDestroyFailure(rejectClassOnce: bool) =
  let anchor = makeHost()
  defer: anchor.destroyHost()
  let baseline = anchor.diagnostics
  var c = systemWin32Calls()
  let setData = c.setWindowData
  let nativeDestroy = c.destroyWindow
  let unregister = c.unregisterClass
  let cause = newException(IOError, "NCDESTROY cause")
  let primary = newException(ValueError, "one-shot NCDESTROY setter failure")
  primary.parent = cause
  var armed = false
  var setterThrows, destroys, unregisters: int
  c.setWindowData = proc(window: HWND, index: int32, value: int): int =
    if armed and index == GWLP_USERDATA and value == 0 and setterThrows == 0:
      inc setterThrows
      raise primary
    setData(window, index, value)
  c.destroyWindow = proc(window: HWND): BOOL =
    inc destroys
    nativeDestroy(window)
  c.unregisterClass = proc(name: WidePtr, instance: HINSTANCE): BOOL =
    inc unregisters
    if rejectClassOnce and unregisters == 1:
      setLastError(5)
      return 0
    unregister(name, instance)
  let h = makeHost(c)
  let window = h.windowHandle
  var className = newSeq[WCHAR](256)
  check GetClassNameW(window, addr className[0], int32(className.len)) > 0
  let bound = h.attach()
  var ordinary = 0
  h.setSafeTick(proc() = inc ordinary)
  armed = true
  var first: ref CatchableError
  try: h.destroyHost()
  except CatchableError as error: first = error
  check setterThrows == 1
  check IsWindow(window) == 0
  check bound.s.disposed
  check first == primary
  check first of ValueError
  if first != nil: check first.parent == cause
  if rejectClassOnce:
    check primary.msg.contains("UnregisterClassW")
  check h.diagnostics.liveWindows == baseline.liveWindows
  check h.diagnostics.liveRoots == baseline.liveRoots
  check h.diagnostics.pendingClose
  check h.diagnostics.callbackErrors >= 1
  expect UiError: discard h.windowHandle
  expect UiError: discard h.context
  var copy = h.diagnostics
  copy.pendingClose = false
  check h.diagnostics.pendingClose
  var cls: WNDCLASSEXW
  check (GetClassInfoExW(GetModuleHandleW(nil), addr className[0], addr cls) != 0) == rejectClassOnce
  var second: ref CatchableError
  try: h.destroyHost()
  except CatchableError as error: second = error
  check second == nil
  check not h.diagnostics.pendingClose
  check destroys == 1 # No DestroyWindow call on the dead owned HWND.
  check unregisters == (if rejectClassOnce: 2 else: 1)
  check GetClassInfoExW(GetModuleHandleW(nil), addr className[0], addr cls) == 0
  check h.diagnostics.liveWindows == baseline.liveWindows
  check h.diagnostics.liveRoots == baseline.liveRoots
  check bound.r.disposeCalls == 1
  check ordinary == 0
  h.destroyHost()
  check destroys == 1

suite "Win32 irreversible NCDESTROY cleanup":
  test "NCDESTROY setter exception retires native ownership and preserves primary for retry":
    verifyNcDestroyFailure(false)
  test "NCDESTROY primary keeps class cleanup failure secondary and retries only owned class":
    verifyNcDestroyFailure(true)
