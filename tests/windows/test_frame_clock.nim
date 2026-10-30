when not defined(windows): {.error: "Frame clock tests require real Windows".}
import std/[unittest, monotimes, times]
import leaf
import leaf/[native_layout, ui_thread]
import leaf/backends/win32/[api, calls, host, backend, canvas]

proc setLastError(code: DWORD) {.stdcall, dynlib: "kernel32.dll", importc: "SetLastError", raises: [].}

component ClockLifetime:
  animation:
    x = tween(0.0, 100.0, duration=3000.ms, autoplay=true)
  view:
    text x:
      key: "value"

type Fixture = object
  window: Win32Host
  runtime: Runtime

proc start(calls: Win32Calls): Fixture =
  let activity = newUiScopeActivity()
  let app = componentApplication(component(ClockLifetime, ()), "Leaf frame clock lifetime", 300, 180)
  let rt = newRuntime(guardUiApplication(app, proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let window = createHost("Leaf frame clock lifetime", DipSize(width:300, height:180), calls)
  window.setStartupScope(proc():bool = activity.busy or rt.installingUpdate or rt.installingHook)
  let native = newWin32Backend(window, renderer=CanvasRenderer.software)
  let session = native.attachWin32Backend(rt)
  native.bindSession(session)
  window.bindSession(session, proc():bool = activity.busy)
  window.setSafeTick(proc() = native.safeListTurn())
  Fixture(window:window, runtime:rt)

suite "real one-shot frame clock ownership":
  test "unsupported high-resolution capability is explicit and uses a real compatibility handle":
    let baseline = canvasResourceCounts()
    var nativeCalls = systemWin32Calls()
    let create = nativeCalls.createFrameTimer
    var highAttempts, compatibilityAttempts = 0
    nativeCalls.createFrameTimer = proc(highResolution:bool):HANDLE =
      if highResolution:
        inc highAttempts
        setLastError(87)
        return nil
      inc compatibilityAttempts
      create(false)
    let f = start(nativeCalls)
    try:
      check highAttempts == 1
      check compatibilityAttempts == 1
      check f.window.diagnostics.frameClockQuality == frameClockCompatibility
      check f.window.diagnostics.frameClockArmed
    finally:
      f.window.destroyHost()
      f.runtime.closeRuntime()
    check canvasResourceCounts() == baseline

  test "cancel and close failures preserve ownership for explicit cleanup retry":
    let baseline = canvasResourceCounts()
    var nativeCalls = systemWin32Calls()
    let cancel = nativeCalls.cancelFrameTimer
    let close = nativeCalls.closeFrameTimer
    var cancelAttempts, closeAttempts = 0
    nativeCalls.cancelFrameTimer = proc(timer:HANDLE):BOOL =
      inc cancelAttempts
      if cancelAttempts == 1:
        setLastError(8)
        return 0
      cancel(timer)
    nativeCalls.closeFrameTimer = proc(timer:HANDLE):BOOL =
      inc closeAttempts
      if closeAttempts == 1:
        setLastError(8)
        return 0
      close(timer)
    let f = start(nativeCalls)
    try:
      expect UiError: f.window.destroyHost()
      check f.window.diagnostics.frameClockArmed
      check closeAttempts == 0
      expect UiError: f.window.destroyHost()
      check not f.window.diagnostics.frameClockArmed
      check closeAttempts == 1
      f.window.destroyHost()
      check cancelAttempts == 2
      check closeAttempts == 2
      check f.window.diagnostics.liveWindows == 0
    finally:
      f.window.destroyHost()
      f.runtime.closeRuntime()
    check canvasResourceCounts() == baseline

  test "nested pump never blocks on the frame handle or advances the animation":
    var nativeCalls = systemWin32Calls()
    let wait = nativeCalls.waitFrameMessage
    var waits = 0
    nativeCalls.waitFrameMessage = proc(timer:HANDLE):DWORD =
      inc waits
      wait(timer)
    let activity = newUiScopeActivity()
    var busy = false
    let app = componentApplication(component(ClockLifetime, ()), "Leaf nested frame clock", 300, 180)
    let rt = newRuntime(guardUiApplication(app, proc():uint64=uint64(GetCurrentThreadId()),activity))
    let window = createHost("Leaf nested frame clock",DipSize(width:300,height:180),nativeCalls)
    window.setStartupScope(proc():bool=busy or activity.busy or rt.installingUpdate or rt.installingHook)
    let native = newWin32Backend(window,renderer=CanvasRenderer.software)
    let session = native.attachWin32Backend(rt)
    native.bindSession(session)
    window.bindSession(session,proc():bool=busy or activity.busy)
    window.setSafeTick(proc()=native.safeListTurn())
    let value = rt.find("value").node.text
    try:
      busy = true
      check window.pump() == 0
      check waits == 0
      check rt.find("value").node.text == value
    finally:
      busy = false
      window.destroyHost()
      rt.closeRuntime()

  test "input-availability wake without a queued message never enters blocking GetMessage":
    var nativeCalls = systemWin32Calls()
    let wait = nativeCalls.waitFrameMessage
    let getMessage = nativeCalls.getMessage
    var window: Win32Host
    var forced, emptyRead = false
    var activeBlockingReads = 0
    let started = getMonoTime()
    nativeCalls.waitFrameMessage = proc(timer:HANDLE):DWORD =
      if not forced:
        forced = true
        var message: MSG
        for i in 0..<64:
          if PeekMessageW(addr message,nil,0,0,PM_REMOVE)==0: break
          discard TranslateMessage(addr message)
          discard DispatchMessageW(addr message)
        return 1 # Documented system/sent-message wake need not leave queued input.
      wait(timer)
    nativeCalls.getMessage = proc(message:ptr MSG,hwnd:HWND,first,last:UINT):BOOL =
      if window.diagnostics.frameClockArmed:
        inc activeBlockingReads
        var pending: MSG
        if PeekMessageW(addr pending,nil,0,0,0)==0:
          emptyRead = true
          # Fail deterministically instead of hanging the old blocking path.
          discard PostMessageW(window.windowHandle,0,0,0)
      if (getMonoTime()-started).inMilliseconds>=200: window.requestClose()
      getMessage(message,hwnd,first,last)
    let peekMessage = nativeCalls.peekMessage
    nativeCalls.peekMessage = proc(message:ptr MSG,hwnd:HWND,first,last,remove:UINT):BOOL =
      if remove == PM_REMOVE and (getMonoTime()-started).inMilliseconds>=200:
        window.requestClose()
      peekMessage(message,hwnd,first,last,remove)
    let f = start(nativeCalls)
    window = f.window
    try:
      check SetTimer(window.windowHandle,65013,25,nil)!=0
      check window.pump()==0
      check forced
      check not emptyRead
      check activeBlockingReads == 0
    finally:
      window.destroyHost()
      f.runtime.closeRuntime()
