when not defined(windows): {.error: "Animation Host tests require real Windows".}
import std/[unittest, monotimes, times, strutils]
import leaf
import leaf/[native_layout, ui_thread]
import leaf/backends/win32/[api, calls, host, backend, canvas]

component NativeAnimation:
  state:
    finishes = 0
  animation:
    x = tween(0.0, 100.0, duration=200.ms, autoplay=true,
      onFinish=proc() = finishes += 1)
  view:
    column:
      canvas:
        key: "canvas"
        height: 120
        viewBox: (200, 120)
        circle:
          center: (x + 20, 60)
          radius: 10
          fill: "#5ED5B0"
      text x:
        key: "x"
      text finishes:
        key: "finishes"

suite "real shared animation timer":
  test "one Host timer advances canvas and native text then disarms while idle":
    let baseline = canvasResourceCounts()
    let activity = newUiScopeActivity()
    let app = componentApplication(component(NativeAnimation, ()), "Leaf animation timer", 400, 250)
    let rt = newRuntime(guardUiApplication(app,
      proc():uint64=uint64(GetCurrentThreadId()), activity))
    var nativeCalls = systemWin32Calls()
    let getMessage = nativeCalls.getMessage
    let started = getMonoTime()
    var window: Win32Host
    var timerArms, timerKills = 0
    let arm = nativeCalls.setTimer
    let kill = nativeCalls.killTimer
    nativeCalls.setTimer = proc(hwnd:HWND,id:UINT_PTR,interval:UINT,callback:TIMERPROC):UINT_PTR =
      if interval == 16: inc timerArms
      arm(hwnd,id,interval,callback)
    nativeCalls.killTimer = proc(hwnd:HWND,id:UINT_PTR):BOOL =
      inc timerKills
      kill(hwnd,id)
    nativeCalls.getMessage = proc(message:ptr MSG,hwnd:HWND,first,last:UINT):BOOL =
      # This is the ordinary message-loop seam, never WndProc. A real OS
      # watchdog timer supplies wakeups even against the pre-feature backend.
      if (getMonoTime()-started).inMilliseconds >= 700:
        window.requestClose()
      getMessage(message,hwnd,first,last)
    window = createHost("Leaf animation timer", DipSize(width:400,height:250), nativeCalls)
    window.setStartupScope(proc():bool=activity.busy or rt.installingUpdate or rt.installingHook)
    let native = newWin32Backend(window,renderer=CanvasRenderer.software)
    let session = native.attachWin32Backend(rt)
    native.bindSession(session)
    window.bindSession(session,proc():bool=activity.busy)
    window.setSafeTick(proc()=native.safeListTurn())
    check SetTimer(window.windowHandle, 65000, 25, nil) != 0
    check window.pump() == 0
    check rt.find("x").node.text == "100.0"
    check rt.find("finishes").node.text == "1"
    check not rt.animationPumpPending
    check timerArms == 1
    check timerKills >= 1
    rt.closeRuntime()
    check canvasResourceCounts() == baseline

  test "real minimize freezes shared timer and restore resumes without hidden elapsed":
    let activity=newUiScopeActivity()
    let app=componentApplication(component(NativeAnimation,()),"Leaf animation minimize",400,250)
    let rt=newRuntime(guardUiApplication(app,proc():uint64=uint64(GetCurrentThreadId()),activity))
    var calls=systemWin32Calls()
    let original=calls.getMessage
    let started=getMonoTime()
    var window:Win32Host
    var phase=0
    var frozen=0.0
    var hiddenStable=false
    var resumedWithoutJump=false
    calls.getMessage=proc(message:ptr MSG,hwnd:HWND,first,last:UINT):BOOL=
      try:
        let elapsed=(getMonoTime()-started).inMilliseconds
        if phase==0 and elapsed>=60:
          frozen=parseFloat(rt.find("x").node.text)
          discard ShowWindow(window.windowHandle,6) # SW_MINIMIZE, a real OS window transition.
          phase=1
        elif phase==1 and elapsed>=350:
          hiddenStable=parseFloat(rt.find("x").node.text)==frozen
          discard ShowWindow(window.windowHandle,9) # SW_RESTORE.
          phase=2
        elif phase==2 and elapsed>=390:
          resumedWithoutJump=parseFloat(rt.find("x").node.text)<90.0
          phase=3
        if elapsed>=850:window.requestClose()
        original(message,hwnd,first,last)
      except Exception as error:
        raise newException(UiError,error.msg)
    window=createHost("Leaf animation minimize",DipSize(width:400,height:250),calls)
    window.setStartupScope(proc():bool=activity.busy or rt.installingUpdate or rt.installingHook)
    let native=newWin32Backend(window,renderer=CanvasRenderer.software)
    let session=native.attachWin32Backend(rt)
    native.bindSession(session)
    window.bindSession(session,proc():bool=activity.busy)
    window.setSafeTick(proc()=native.safeListTurn())
    check SetTimer(window.windowHandle,65001,20,nil)!=0
    check window.pump()==0
    check phase==3
    check hiddenStable
    check resumedWithoutJump
    check rt.find("x").node.text=="100.0"
    check rt.find("finishes").node.text=="1"
    rt.closeRuntime()
