when not defined(windows): {.error: "Animation Host tests require real Windows".}
import std/[unittest, monotimes, times, strutils, atomics, os]
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
  test "animation has no16ms cap while canvas and native text finish then disarm":
    let baseline = canvasResourceCounts()
    let activity = newUiScopeActivity()
    let app = componentApplication(component(NativeAnimation, ()), "Leaf animation timer", 400, 250)
    let rt = newRuntime(guardUiApplication(app,
      proc():uint64=uint64(GetCurrentThreadId()), activity))
    var nativeCalls = systemWin32Calls()
    let getMessage = nativeCalls.getMessage
    let started = getMonoTime()
    var window: Win32Host
    var timerArms, frameCreates, frameArms, frameCloses, frameWaits = 0
    var invalidDue, idleObserved = false
    let createFrame = nativeCalls.createFrameTimer
    let armFrame = nativeCalls.armFrameTimer
    let closeFrame = nativeCalls.closeFrameTimer
    let waitFrame = nativeCalls.waitFrameMessage
    nativeCalls.createFrameTimer = proc(highResolution:bool):HANDLE =
      inc frameCreates
      createFrame(highResolution)
    nativeCalls.armFrameTimer = proc(timer:HANDLE,due100ns:int64):BOOL =
      inc frameArms
      invalidDue=invalidDue or due100ns>=0 or due100ns< -83_334
      armFrame(timer,due100ns)
    nativeCalls.closeFrameTimer = proc(timer:HANDLE):BOOL =
      inc frameCloses
      closeFrame(timer)
    nativeCalls.waitFrameMessage = proc(timer:HANDLE):DWORD =
      inc frameWaits
      waitFrame(timer)
    let arm = nativeCalls.setTimer
    nativeCalls.setTimer = proc(hwnd:HWND,id:UINT_PTR,interval:UINT,callback:TIMERPROC):UINT_PTR =
      if interval == 16: inc timerArms
      arm(hwnd,id,interval,callback)
    proc beforeRead() =
      try:
        # Ordinary read boundary, never WndProc. Watchdog works on both pumps.
        if (getMonoTime()-started).inMilliseconds >= 450:
          idleObserved=idleObserved or (not rt.animationPumpPending and not window.diagnostics.frameClockArmed)
        if (getMonoTime()-started).inMilliseconds >= 700:
          window.requestClose()
      except Exception as error:
        raise newException(UiError,error.msg)
    let peekMessage = nativeCalls.peekMessage
    nativeCalls.getMessage = proc(message:ptr MSG,hwnd:HWND,first,last:UINT):BOOL =
      beforeRead()
      getMessage(message,hwnd,first,last)
    nativeCalls.peekMessage = proc(message:ptr MSG,hwnd:HWND,first,last,remove:UINT):BOOL =
      if remove == PM_REMOVE: beforeRead()
      peekMessage(message,hwnd,first,last,remove)
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
    check timerArms == 0
    check frameCreates == 1
    check frameArms > 0
    check frameWaits > 0
    check frameCloses == 1
    check not invalidDue
    check idleObserved
    check window.diagnostics.frameClockQuality == frameClockHighResolution
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
    proc beforeRead() =
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
      except Exception as error:
        raise newException(UiError,error.msg)
    let peekMessage = calls.peekMessage
    calls.getMessage=proc(message:ptr MSG,hwnd:HWND,first,last:UINT):BOOL=
      beforeRead()
      original(message,hwnd,first,last)
    calls.peekMessage=proc(message:ptr MSG,hwnd:HWND,first,last,remove:UINT):BOOL=
      if remove == PM_REMOVE: beforeRead()
      peekMessage(message,hwnd,first,last,remove)
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

var coexistHeld: Atomic[bool]
proc coexistWork(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  while coexistHeld.load(): sleep(1)
  input

suite "real task and frame clock coexistence":
  test "task timer does not sample animation and survives animation completion":
    let baseline = canvasResourceCounts()
    coexistHeld.store(true)
    var delivered, frameArms, isolatedActiveChecks, taskTicksAfterAnimation: int
    var taskTimer: UINT_PTR
    var taskArmed, inDispatch, callbackOutsideDispatch, overlapped = false
    var pendingTaskCheck, taskAdvanced, animationEndedWithTask, allIdle, timedOut = false
    var taskValue: string
    let Owner = defineComponent[int, int]("TaskAndAnimation",
      proc(ctx: MountContext, p: int): int =
        ctx.onMount(proc(event: LifecycleContext) =
          discard startTask(event.taskScope, "held", "ready", coexistWork, proc(value: string) =
            inc delivered
            callbackOutsideDispatch = not inDispatch and value == "ready"))
        p,
      proc(ctx: ComponentContext, p, state: int): UiDescription = component(NativeAnimation, ()))
    let activity = newUiScopeActivity()
    let rt = newRuntime(guardUiApplication(
      componentApplication(component(Owner, 0), "Task and animation", 400, 250),
      proc(): uint64 = uint64(GetCurrentThreadId()), activity))
    var window: Win32Host
    var nativeCalls = systemWin32Calls()
    let set = nativeCalls.setTimer
    let kill = nativeCalls.killTimer
    let armFrame = nativeCalls.armFrameTimer
    let dispatch = nativeCalls.dispatchMessage
    let dialog = nativeCalls.dialogMessage
    let wait = nativeCalls.waitFrameMessage
    let get = nativeCalls.getMessage
    let peek = nativeCalls.peekMessage
    let started = getMonoTime()
    nativeCalls.setTimer = proc(hwnd: HWND, id: UINT_PTR, interval: UINT, callback: TIMERPROC): UINT_PTR =
      result = set(hwnd, id, interval, callback)
      if interval == 16 and result != 0:
        taskTimer = result
        taskArmed = true
    nativeCalls.killTimer = proc(hwnd: HWND, id: UINT_PTR): BOOL =
      result = kill(hwnd, id)
      if id == taskTimer and result != 0: taskArmed = false
    nativeCalls.armFrameTimer = proc(timer: HANDLE, due100ns: int64): BOOL =
      inc frameArms
      overlapped = overlapped or taskArmed
      armFrame(timer, due100ns)
    nativeCalls.dialogMessage = proc(hwnd: HWND, message: ptr MSG): BOOL =
      try:
        # IsDialogMessage may itself dispatch WM_TIMER, bypassing dispatchMessage.
        let isTask = message.message == WM_TIMER and message.wParam == WPARAM(taskTimer)
        let active = rt.animationPumpPending
        if isTask and active:
          taskValue = rt.find("x").node.text
          pendingTaskCheck = true
        if isTask and not active: inc taskTicksAfterAnimation
        inDispatch = true
        try: result = dialog(hwnd, message)
        finally: inDispatch = false
      except Exception as error:
        raise newException(UiError, error.msg)
    nativeCalls.dispatchMessage = proc(message: ptr MSG): LRESULT =
      inDispatch = true
      try: result = dispatch(message)
      finally: inDispatch = false
    proc inspectTurn() =
      try:
        # Runs after Host.safeTurn, before the next wait/read or dispatch.
        if pendingTaskCheck:
          inc isolatedActiveChecks
          taskAdvanced = taskAdvanced or rt.find("x").node.text != taskValue
          pendingTaskCheck = false
        let elapsed = (getMonoTime() - started).inMilliseconds
        if elapsed >= 350 and not rt.animationPumpPending and rt.taskPumpPending:
          animationEndedWithTask = taskArmed and not window.diagnostics.frameClockArmed
          coexistHeld.store(false)
        if delivered == 1 and not rt.taskPumpPending and not rt.animationPumpPending:
          allIdle = not taskArmed and not window.diagnostics.frameClockArmed
          window.requestClose()
        if elapsed >= 5000:
          timedOut = true
          coexistHeld.store(false)
          window.requestClose()
      except Exception as error:
        raise newException(UiError, error.msg)
    nativeCalls.waitFrameMessage = proc(timer: HANDLE): DWORD =
      inspectTurn()
      wait(timer)
    nativeCalls.getMessage = proc(message: ptr MSG, hwnd: HWND, first, last: UINT): BOOL =
      inspectTurn()
      get(message, hwnd, first, last)
    nativeCalls.peekMessage = proc(message: ptr MSG, hwnd: HWND, first, last, remove: UINT): BOOL =
      if remove == PM_REMOVE: inspectTurn()
      peek(message, hwnd, first, last, remove)
    window = createHost("Task and animation", DipSize(width: 400, height: 250), nativeCalls)
    window.setStartupScope(proc(): bool = activity.busy or rt.installingUpdate or rt.installingHook)
    let native = newWin32Backend(window, renderer = CanvasRenderer.software)
    let session = native.attachWin32Backend(rt)
    native.bindSession(session)
    window.bindSession(session, proc(): bool = activity.busy)
    window.setSafeTick(proc() = native.safeListTurn())
    try:
      check SetTimer(window.windowHandle, 65002, 25, nil) != 0 # bounded observer, not product idle polling
      check window.pump() == 0
      check not timedOut
      check overlapped
      check frameArms > 0
      check isolatedActiveChecks > 0
      check not taskAdvanced
      check animationEndedWithTask
      check taskTicksAfterAnimation > 0
      check delivered == 1
      check callbackOutsideDispatch
      check rt.find("x").node.text == "100.0"
      check rt.find("finishes").node.text == "1"
      check allIdle
    finally:
      coexistHeld.store(false)
      window.destroyHost()
      rt.closeRuntime()
    check canvasResourceCounts() == baseline
