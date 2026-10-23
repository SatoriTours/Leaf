## Owned Unicode top-level Host. WndProc never calls business or disposes a
## Session; all such work runs after native dispatch at an ordinary Nim boundary.
import std/[tables, unicode, math, atomics]
import ../../[core, backend, backend_session, native_layout, windows_dpi]
import ./[api, calls, host_state, host_bridge, navigation_input]
export host_bridge

type
  Win32Host* = ref object
    owner: DWORD
    cookie: uint
    window: HWND
    instance: HINSTANCE
    className: seq[WCHAR]
    ownsClass, rooted, counted: bool
    timer, taskTimer: UINT_PTR
    taskCookie: uint
    sessionToken: uint64
    needsTaskTick, tasksRetired: bool
    cleanupFailure: ref CatchableError
    calls: Win32Calls
    ctx: HostContext
    close: CloseState
    session: BackendSession
    lease: HostBackendLease
    bridge: HostBackendBridge
    startupScope: proc(): bool {.closure, raises: [].}
    scopeBusy: proc(): bool {.closure, raises: [].}
    safeTick: proc() {.closure.}
    dispatchDepth, pumpDepth, tickDepth, releaseDepth: int
    needsTick, retryDeferred: bool
    errorCount: uint64
    pendingError: ref CatchableError
  Win32RunError* = object of RuntimeCleanupError
    ## Caller retries Host first, then ordinary Runtime close; no destructor retry.
    cleanupHost*: Win32Host
  HostDiagnostics* = object
    liveWindows*, liveRoots*: int
    callbackErrors*: uint64
    pendingClose*: bool

var roots {.threadvar.}: Table[uint, Win32Host]
var liveWindowCount {.threadvar.}: int
var nextCookie: Atomic[uint]

proc reserveCookie(): uint =
  ## Process-wide, non-recycled identity even when OS thread ids are reused.
  ## Limit to a 32-bit cookie so every supported pointer width can carry it.
  var previous = nextCookie.load()
  while true:
    if previous >= uint(high(uint32)): fail("Win32 Host identity exhausted")
    let next = previous + 1
    if nextCookie.compareExchange(previous, next): return next

proc ownerCheck(host: Win32Host) =
  if host == nil: fail("Win32 Host is nil")
  if GetCurrentThreadId() != host.owner:
    fail("Win32 Host must run on its owning UI thread")
proc liveCheck(host: Win32Host) =
  host.ownerCheck()
  if host.window == nil or host.close.complete: fail("Win32 Host window is no longer live")
proc setStartupScope*(host: Win32Host, scopeBusy: proc(): bool {.closure, raises: [].}) =
  host.liveCheck()
  if scopeBusy == nil or host.startupScope != nil or host.lease != nil or host.session != nil:
    fail("startup Scope guard must be configured exactly once before resource claim")
  host.startupScope = scopeBusy
proc claimBackendOwner*(host: Win32Host, bridge: HostBackendBridge): HostBackendLease =
  host.liveCheck()
  if host.startupScope == nil: fail("native owner requires a full startup Scope guard")
  if host.lease != nil or host.session != nil: fail("Host already has a native owner")
  if bridge.capture == nil or bridge.invalidate == nil or bridge.nativeTick == nil or
      bridge.localBusy == nil or bridge.resourcesReleased == nil or
      bridge.matchesSession == nil or bridge.closeStartup == nil:
    fail("incomplete native owner bridge")
  result = HostBackendLease()
  host.bridge = bridge
  host.lease = result
proc releaseBackendOwner*(host: Win32Host, lease: HostBackendLease) =
  host.ownerCheck()
  if lease == nil or lease != host.lease: fail("foreign native owner lease")
  if not host.bridge.resourcesReleased() or (host.session != nil and not host.session.disposed):
    fail("native resources or authoritative Session remain live")
  host.lease = nil
  host.bridge = default(HostBackendBridge)
proc backendOwnerActive*(host: Win32Host, lease: HostBackendLease): bool =
  host.ownerCheck()
  lease != nil and host.lease == lease
proc backendOwnerBound*(host: Win32Host, lease: HostBackendLease, session: BackendSession): bool =
  host.ownerCheck()
  host.window != nil and not host.close.pending and lease != nil and host.lease == lease and
    session != nil and host.session == session and not session.closing and
    not session.disposed and host.bridge.matchesSession(session)
proc nativeError(operation: string) {.noreturn.} =
  fail(operation & " failed: Win32 error " & $lastError())
proc wide(value: string): seq[WCHAR] =
  if value.len > MaxStringBytes: fail("Win32 title exceeds string budget")
  if validateUtf8(value) != -1: fail("Win32 title must be UTF-8")
  if '\0' in value: fail("Win32 text must not contain NUL")
  for rune in value.runes:
    let code = int(rune)
    if code <= 0xffff:
      result.add(WCHAR(code))
    else:
      let pair = code - 0x10000
      result.add(WCHAR(0xd800 + (pair shr 10)))
      result.add(WCHAR(0xdc00 + (pair and 0x3ff)))
  if result.len >= int(high(int32)): fail("Win32 UTF16 length overflows")
  result.add(0)
proc finiteSize(value: float64) =
  if classify(value) in {fcNan, fcInf, fcNegInf} or value <= 0:
    fail("Win32 Host content size must be finite and positive")
proc pixelSize(value, scale: float64): int32 =
  let pixels = round(value * scale)
  if classify(pixels) in {fcNan, fcInf, fcNegInf} or pixels > float64(high(int32) - 4096):
    fail("Win32 Host pixel size overflows")
  int32(max(1.0, pixels))
proc recordError(host: Win32Host) =
  inc host.errorCount
proc captureError(host: Win32Host, error: ref CatchableError) =
  host.recordError()
  if host.pendingError == nil: host.pendingError = error
  elif host.pendingError != error: host.pendingError.msg.add("; native secondary: " & error.msg)
proc checkCallback(host: Win32Host) =
  let error = host.pendingError
  host.pendingError = nil
  if error != nil: raise error
proc busy(host: Win32Host): bool =
  if host.dispatchDepth != 0 or host.tickDepth != 0 or host.releaseDepth != 0 or host.pumpDepth > 1:
    return true
  if host.startupScope != nil and host.startupScope(): return true
  if host.lease != nil and host.bridge.localBusy(): return true
  if host.scopeBusy != nil and host.scopeBusy(): return true
  if host.session != nil:
    let runtime = host.session.runtime
    if runtime.installingUpdate or runtime.installingHook: return true
  false
proc currentTaskSession(host: Win32Host): bool =
  host.session != nil and not host.session.disposed and
    host.sessionToken != 0 and host.session.runtime.committerOwner == host.sessionToken and
    (host.lease == nil or host.bridge.matchesSession(host.session))
proc retireTasks(host: Win32Host) =
  # Metadata only. Never enter executionScope, release the pool pin or join here.
  if not host.tasksRetired and host.currentTaskSession():
    let driver = host.session.runtime.runtimeDriver
    if driver != nil: driver.retireDeferred()
    host.tasksRetired = true
proc disarmTaskTick(host: Win32Host) =
  if host.taskTimer != 0:
    if host.calls.killTimer(host.window, host.taskTimer) == 0: nativeError("KillTimer task")
    host.taskTimer = 0
  host.needsTaskTick = false
proc armTaskTick(host: Win32Host) =
  if host.window == nil or host.close.pending or host.close.complete or
      not host.currentTaskSession() or host.session.closing or not host.session.runtime.taskPumpPending():
    host.disarmTaskTick()
    return
  if host.taskTimer == 0:
    let timer = host.calls.setTimer(host.window, host.taskCookie, 16, nil)
    if timer == 0: nativeError("SetTimer task")
    host.taskTimer = timer
    if timer == host.timer: fail("task and close timers must have distinct identities")

proc delayed(host: Win32Host) =
  if host.window == nil or host.timer != 0 or host.close.complete: return
  let timer = host.calls.setTimer(host.window, host.cookie, 30, nil)
  if timer == 0: nativeError("SetTimer")
  host.timer = timer
  host.close.posted = true
proc wake(host: Win32Host) =
  host.needsTick = true
  if host.window == nil or host.close.complete or host.close.posted or host.timer != 0: return
  if host.tickDepth != 0 or host.releaseDepth != 0 or host.pumpDepth > 1 or
      (host.scopeBusy != nil and host.scopeBusy()):
    host.delayed()
    return
  if host.calls.postMessage(host.window, WM_HOST_TICK, 0, 0) == 0: nativeError("PostMessageW")
  host.close.posted = true
proc intent(host: Win32Host) =
  host.close.requestClose()
  if host.session != nil: host.session.requestClose()
  host.wake()
proc geometry(host: Win32Host) =
  var rect: RECT
  if host.calls.clientRect(host.window, addr rect) == 0: nativeError("GetClientRect")
  let dpi = host.calls.dpi(host.window)
  if dpi == 0: nativeError("GetDpiForWindow")
  host.ctx.scale = float64(dpi) / 96.0
  host.ctx.contentWidth = float64(max(0'i64, int64(rect.right) - int64(rect.left))) / host.ctx.scale
  host.ctx.contentHeight = float64(max(0'i64, int64(rect.bottom) - int64(rect.top))) / host.ctx.scale

proc windowProc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): LRESULT {.stdcall, raises: [].} =
  var host: Win32Host
  try:
    var cookie = cast[uint](GetWindowLongPtrW(window, GWLP_USERDATA))
    if message == WM_NCCREATE:
      let creation = cast[ptr CREATESTRUCTW](lp)
      if creation == nil: return 0
      cookie = cast[uint](creation.lpCreateParams)
    if cookie == 0 or not roots.hasKey(cookie):
      return DefWindowProcW(window, message, wp, lp)
    host = roots[cookie]
    if message == WM_NCCREATE:
      if host.window != nil or not host.rooted: return 0
    elif host.window != window:
      return DefWindowProcW(window, message, wp, lp)
    host.ownerCheck()
    inc host.dispatchDepth
    try:
      case message
      of WM_NCCREATE:
        setLastError(0)
        let previous = host.calls.setWindowData(window, GWLP_USERDATA, cast[int](cookie))
        if previous == 0 and lastError() != 0: nativeError("SetWindowLongPtrW")
        host.window = window
        host.counted = true
        inc liveWindowCount
        # Preserve default non-client/window-name initialization after binding.
        return host.calls.defWindowProc(window, message, wp, lp)
      of WM_CLOSE:
        host.intent()
        return 0
      of WM_SIZE:
        host.geometry()
        if host.lease != nil: host.bridge.invalidate(host.ctx, {geometryChanged})
        host.wake()
        return 0
      of WM_DPICHANGED:
        if lp != 0:
          let rect = cast[ptr RECT](lp)[]
          let width = int64(rect.right) - int64(rect.left)
          let height = int64(rect.bottom) - int64(rect.top)
          if width <= 0 or height <= 0 or width > high(int32) or height > high(int32):
            fail("WM_DPICHANGED suggested bounds overflow")
          if host.calls.windowPos(window, nil, rect.left, rect.top, int32(width), int32(height),
                                  SWP_NOZORDER or SWP_NOACTIVATE) == 0:
            nativeError("SetWindowPos")
        host.geometry()
        if host.lease != nil: host.bridge.invalidate(host.ctx, {geometryChanged, fontChanged, themeChanged})
        host.wake()
        return 0
      of WM_SETTINGCHANGE, WM_THEMECHANGED:
        if host.lease != nil: host.bridge.invalidate(host.ctx, {fontChanged, themeChanged})
        host.wake()
      of WM_COMMAND, BackSysKeyDown, BackAppCommand:
        if host.lease != nil and host.session != nil and not host.close.pending and
            host.bridge.matchesSession(host.session) and host.bridge.capture(window, message, wp, lp):
          host.wake()
          return if message == BackAppCommand: 1 else: 0
      of WM_HOST_TICK:
        host.close.posted = host.timer != 0
        host.needsTick = true
        return 0
      of WM_HOST_TASK_TICK:
        host.needsTaskTick = true
        return 0
      of WM_TIMER:
        if host.taskTimer != 0 and wp == host.taskTimer:
          # Periodic timer survives a busy/nested turn; only ordinary code disarms.
          host.needsTaskTick = true
          return 0
        if host.timer != 0 and wp == host.timer:
          if host.calls.killTimer(window, host.timer) == 0: nativeError("KillTimer")
          host.timer = 0
          host.close.posted = false
          host.retryDeferred = false
          host.needsTick = true
          return 0
      of WM_NCDESTROY:
        try:
          discard host.calls.setWindowData(window, GWLP_USERDATA, 0)
        finally:
          # Native lifetime has ended even if the optional userdata clear throws.
          # Never retain/retry a dead HWND or expose it through a borrowed getter.
          host.window = nil
          host.timer = 0 # USER32 has destroyed this window's remaining timers.
          host.taskTimer = 0
          if host.counted:
            dec liveWindowCount
            host.counted = false
          if host.rooted:
            roots.del(cookie)
            host.rooted = false
      else: discard
      return host.calls.defWindowProc(window, message, wp, lp)
    finally:
      dec host.dispatchDepth
  except CatchableError as error:
    if host != nil: host.captureError(error)
    # CatchableError never crosses this ABI. Defects are not claimed recoverable.
    return 0

proc nativeCleanup(host: Win32Host) =
  var cleanupError: ref CatchableError
  try:
    host.disarmTaskTick()
    if host.timer != 0:
      if host.calls.killTimer(host.window, host.timer) == 0: nativeError("KillTimer")
      host.timer = 0
    if host.window != nil:
      if host.calls.destroyWindow(host.window) == 0: nativeError("DestroyWindow")
      if host.window != nil: fail("DestroyWindow did not release the owned native window")
    if host.rooted:
      roots.del(host.cookie)
      host.rooted = false
    if host.ownsClass:
      if host.calls.unregisterClass(addr host.className[0], host.instance) == 0:
        nativeError("UnregisterClassW")
      host.ownsClass = false
  except CatchableError as error:
    cleanupError = error
  # A synchronous native callback may have failed during DestroyWindow. Finish
  # the remaining cleanup attempt, then report that exact primary at this Nim
  # boundary. Failed class ownership remains available for explicit owner retry.
  let callbackError = host.pendingError
  host.pendingError = nil
  if callbackError != nil:
    if cleanupError != nil and cleanupError != callbackError:
      callbackError.msg.add("; Host cleanup secondary: " & cleanupError.msg)
    raise callbackError
  if cleanupError != nil: raise cleanupError

proc finish(host: Win32Host) =
  # Only called after actual Session disposal plus all native resources released.
  host.safeTick = nil
  host.scopeBusy = nil
  host.session = nil
  host.startupScope = nil
  host.bridge = default(HostBackendBridge)
  host.calls = default(Win32Calls)
  host.needsTick = false
  host.needsTaskTick = false
  host.cleanupFailure = nil
  host.close.closeSucceeded()

proc release(host: Win32Host) =
  inc host.releaseDepth
  try:
    host.retireTasks()
    host.disarmTaskTick()
    if host.session != nil:
      host.session.dispose()
      if not host.session.disposed: fail("Session release did not complete")
    elif host.lease != nil:
      host.bridge.closeStartup()
    if host.lease != nil: host.releaseBackendOwner(host.lease)
    host.nativeCleanup()
    host.finish()
  finally:
    dec host.releaseDepth

proc safeTurn(host: Win32Host) =
  host.checkCallback()
  if host.close.pending:
    host.retireTasks()
    try: host.disarmTaskTick()
    except CatchableError as error:
      host.cleanupFailure = error
      host.close.closeFailed()
      raise error
  if host.close.complete or host.busy(): return
  var primary: ref CatchableError
  if not host.close.pending and host.lease != nil: host.bridge.nativeTick()
  if not host.close.pending and host.needsTick and host.session != nil and host.safeTick != nil and
      (host.lease == nil or host.bridge.matchesSession(host.session)):
    host.needsTick = false
    inc host.tickDepth
    try:
      host.safeTick()
      if host.session!=nil and host.session.runtime.runtimeDriver!=nil:discard host.session.runtime.flush()
    except CatchableError as error:
      host.recordError()
      primary = error
    finally: dec host.tickDepth
  if not host.close.pending and host.currentTaskSession() and not host.session.closing:
    if host.needsTaskTick or host.session.runtime.taskPumpPending():
      host.needsTaskTick = false
      inc host.tickDepth
      try:
        discard host.session.runtime.pumpTasks()
      except CatchableError as error:
        host.recordError()
        if primary == nil: primary = error
        else: primary.msg.add("; task secondary: " & error.msg)
      finally: dec host.tickDepth
    if not host.close.pending: host.armTaskTick()
  else:
    host.disarmTaskTick()
  if not host.close.pending and host.lease != nil and not host.busy(): host.bridge.nativeTick()
  if host.close.pending and (host.session != nil or host.lease != nil) and not host.busy() and not host.retryDeferred:
    try:
      host.release()
    except CatchableError as error:
      host.recordError()
      host.close.closeFailed()
      host.cleanupFailure = error
      host.retryDeferred = true
      if primary != nil: primary.msg.add("; close secondary: " & error.msg)
      # A dead HWND cannot schedule a timer. Owner must explicitly retry cleanup.
      if host.window == nil:
        if primary != nil: raise primary
        raise error
      try: host.delayed()
      except CatchableError as secondary:
        error.msg.add("; retry scheduling: " & secondary.msg)
        if primary != nil: raise primary
        raise error
  if primary != nil: raise primary

proc createHost*(title: string, size: DipSize,
                 calls: Win32Calls = systemWin32Calls()): Win32Host =
  let owner = GetCurrentThreadId()
  let titleW = wide(title)
  finiteSize(size.width); finiteSize(size.height)
  # Preserve a host's chosen awareness; this precedes all HWND acquisition.
  let dpiPolicy = initializeWindowsDpi()
  if dpiPolicy.status == "failed": fail("Windows DPI initialization failed: " & $dpiPolicy.errorCode)
  let dpi = calls.systemDpi()
  if dpi == 0: nativeError("GetDpiForSystem")
  let scale = float64(dpi) / 96.0
  var bounds = RECT(right: pixelSize(size.width, scale), bottom: pixelSize(size.height, scale))
  if calls.adjustRect(addr bounds, WS_OVERLAPPEDWINDOW, 0, 0, dpi) == 0:
    nativeError("AdjustWindowRectExForDpi")
  let width = int64(bounds.right) - int64(bounds.left)
  let height = int64(bounds.bottom) - int64(bounds.top)
  if width <= 0 or height <= 0 or width > high(int32) or height > high(int32):
    fail("Win32 Host frame size overflows")
  let cookie = reserveCookie()
  let host = Win32Host(owner: owner, cookie: cookie, taskCookie: reserveCookie(), calls: calls)
  host.className = wide("LeafHost-" & $owner & "-" & $cookie)
  host.ctx = HostContext(sessionId: uint64(cookie),
                         mountGeneration: 1, scale: scale)
  host.instance = GetModuleHandleW(nil)
  if host.instance == nil: nativeError("GetModuleHandleW")
  try:
    var cls = WNDCLASSEXW(cbSize: UINT(sizeof(WNDCLASSEXW)), style: 3,
      lpfnWndProc: windowProc, hInstance: host.instance,
      hbrBackground: cast[HBRUSH](6), lpszClassName: addr host.className[0])
    if host.calls.registerClass(addr cls) == 0: nativeError("RegisterClassExW")
    host.ownsClass = true
    roots[host.cookie] = host
    host.rooted = true
    let window = host.calls.createWindow(0, addr host.className[0], unsafeAddr titleW[0],
      WS_OVERLAPPEDWINDOW, 0, 0, int32(width), int32(height), nil, nil,
      host.instance, cast[pointer](host.cookie))
    host.checkCallback()
    if window == nil: nativeError("CreateWindowExW")
    if window != host.window: fail("native window did not bind its Host identity")
    host.geometry()
    if host.ctx.contentWidth <= 0 or host.ctx.contentHeight <= 0:
      fail("new Win32 Host has no content")
    discard host.calls.showWindow(window, SW_SHOW)
    host.checkCallback()
    result = host
  except CatchableError as primary:
    try: host.nativeCleanup()
    except CatchableError as secondary:
      primary.msg.add("; Host cleanup secondary: " & secondary.msg)
      let failure = newException(Win32RunError, primary.msg)
      failure.parent = primary
      failure.cleanupHost = host
      raise failure
    raise primary

proc context*(host: Win32Host): HostContext =
  host.liveCheck()
  result = host.ctx
  if host.session != nil: result.mountGeneration = host.session.mountGeneration
proc windowHandle*(host: Win32Host): HWND =
  ## Borrowed owner/live-checked parent handle. Never transfer or destroy it.
  host.liveCheck()
  host.window
proc diagnostics*(host: Win32Host): HostDiagnostics =
  host.ownerCheck()
  HostDiagnostics(liveWindows: liveWindowCount, liveRoots: roots.len,
    callbackErrors: host.errorCount, pendingClose: host.close.pending)
proc bindSession*(host: Win32Host, session: BackendSession,
                  scopeBusy: proc(): bool {.closure, raises: [].}) =
  host.liveCheck()
  if session == nil or scopeBusy == nil: fail("Host binding requires Session and scope activity")
  if host.session != nil: fail("Host already has a Session binding")
  if session.disposed or session.sessionId != host.ctx.sessionId:
    fail("Session is disposed or belongs to another Host context")
  if host.lease != nil and not host.bridge.matchesSession(session):
    fail("Session does not match native owner binding")
  session.runtime.configureTaskPumpInternal(true)
  host.session = session
  host.sessionToken = session.runtime.committerOwner
  host.scopeBusy = scopeBusy
  if host.close.pending: session.requestClose()
  host.armTaskTick()
  host.wake()
proc setSafeTick*(host: Win32Host, tick: proc() {.closure.}) =
  host.liveCheck()
  host.safeTick = tick
  if tick != nil: host.wake()
proc requestClose*(host: Win32Host) =
  host.ownerCheck()
  if host.close.complete: return
  host.intent()
proc destroyHost*(host: Win32Host) =
  host.ownerCheck()
  if host.close.complete: return
  host.close.requestClose()
  if host.session != nil: host.session.requestClose()
  host.retryDeferred = false
  try:
    host.retireTasks()
    host.disarmTaskTick()
    if host.busy(): fail("Win32 Host release is busy; retry after the full UI scope")
    host.release()
  except CatchableError as error:
    host.recordError()
    host.close.closeFailed()
    host.cleanupFailure = error
    raise error

proc resourcesReleasedInternal*(host: Win32Host): bool =
  host.ownerCheck()
  host.close.complete
proc cleanupFailureInternal*(host: Win32Host): ref CatchableError =
  host.ownerCheck()
  host.cleanupFailure

proc dispatch(host: Win32Host, message: var MSG) =
  inc host.dispatchDepth
  try:
    if host.window == nil or host.calls.dialogMessage(host.window, addr message) == 0:
      discard host.calls.translateMessage(addr message)
      discard host.calls.dispatchMessage(addr message)
  finally: dec host.dispatchDepth
  host.checkCallback()

proc pump*(host: Win32Host): int =
  host.ownerCheck()
  host.checkCallback()
  if host.close.complete: return 0
  let nested = host.pumpDepth != 0 or host.busy() or
    (host.session == nil and host.lease == nil and host.close.pending)
  inc host.pumpDepth
  var primary: ref CatchableError
  try:
    var message: MSG
    if nested:
      # No blocking nested GetMessage, and no business/close release in this path.
      for i in 0..<64:
        if host.calls.peekMessage(addr message, nil, 0, 0, PM_REMOVE) == 0: break
        if message.message == WM_QUIT:
          PostQuitMessage(cast[int32](message.wParam))
          return int(cast[int32](message.wParam))
        host.dispatch(message)
      return 0
    host.safeTurn()
    while not host.close.complete:
      if host.window == nil:
        fail("Host native cleanup is incomplete; call destroyHost to retry")
      if host.session == nil and host.lease == nil and host.close.pending: return 0
      let status = host.calls.getMessage(addr message, nil, 0, 0)
      if status == -1: nativeError("GetMessageW")
      if status == 0: return int(cast[int32](message.wParam))
      host.dispatch(message)
      host.safeTurn()
    return 0
  except CatchableError as error:
    primary = error
    raise error
  finally:
    dec host.pumpDepth
    if host.pumpDepth == 0 and host.close.pending and not host.close.complete and
        host.window != nil and (host.session != nil or host.lease != nil):
      try: host.delayed()
      except CatchableError as secondary:
        host.recordError()
        if primary != nil: primary.msg.add("; pump scheduling secondary: " & secondary.msg)
        else: raise secondary
