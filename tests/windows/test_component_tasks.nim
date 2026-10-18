when not defined(windows): {.error: "Component task host tests require Windows".}
import std/[unittest, atomics, os, options, strutils, widestrs]
import leaf/[core, widgets, components, backend_session, native_layout]
import leaf/backends/win32 as nativeEntry
import leaf/backends/win32/[api, calls, host, backend]

var started, held: Atomic[bool]
proc work(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  started.store(true)
  while held.load(): sleep(1)
  input
proc deadline(window: HWND, message: UINT, timer: UINT_PTR, time: DWORD) {.stdcall, raises: [].} =
  discard KillTimer(nil, timer)
  PostQuitMessage(97)
proc boundedPump(h: Win32Host): int =
  let timer = SetTimer(nil, 0, 5000, deadline)
  doAssert timer != 0
  try: result = h.pump()
  finally: discard KillTimer(nil, timer)
type Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession]
proc attach(rt: Runtime, c = systemWin32Calls(), blocked: proc(): bool {.closure, raises: [].} = nil): Fixture =
  let h = createHost("Task host", DipSize(width: 400, height: 300), c)
  h.setStartupScope(proc(): bool = rt.installingUpdate or rt.installingHook or (blocked != nil and blocked()))
  let win = newWin32Backend(h, c)
  let s = win.attachWin32Backend(rt)
  win.bindSession(s)
  h.bindSession(s, proc(): bool = blocked != nil and blocked())
  h.setSafeTick(proc() = s.drainEvents())
  (h, win, s)
var childWindows: seq[HWND]
proc collectChild(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  childWindows.add(window)
  1
proc hasNativeText(h: Win32Host, text: string): bool =
  childWindows.setLen(0)
  discard EnumChildWindows(h.windowHandle, collectChild, 0)
  for window in childWindows:
    let n = GetWindowTextLengthW(window) + 1
    let wide = newWideCString(int(n))
    discard GetWindowTextW(window, cast[WidePtr](unsafeAddr wide[0]), n)
    if $wide == text: return true

proc ownerApp(done: proc(s: State[int]) {.closure.}, dispose: proc() {.closure.} = nil): Application =
  let Owner = defineComponent[int, State[int]]("Win32TaskOwner",
    proc(ctx: MountContext, p: int): State[int] =
      let state = ctx.state(0)
      ctx.onMount(proc(e: LifecycleContext) =
        discard startTask(e.taskScope, "work", "ready", work, proc(v: string) = done(state)))
      if dispose != nil: ctx.onDispose(proc(e: LifecycleContext) = dispose())
      state,
    proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription = host(text($ctx.value(s), key = "value")))
  componentApplication(component(Owner, 0), "Task host", width = 400, height = 300)

suite "Win32 ordinary task turns":
  test "real timer delivers without input and commits native tree outside dispatch":
    held.store(false); started.store(false)
    var inDispatch = false
    var callbacks = 0
    var c = systemWin32Calls()
    let dispatch = c.dispatchMessage
    c.dispatchMessage = proc(msg: ptr MSG): LRESULT =
      inDispatch = true
      try: result = dispatch(msg)
      finally: inDispatch = false
    let rt = newRuntime(ownerApp(proc(s: State[int]) =
      check not inDispatch
      inc callbacks
      discard s.set(7)
      PostQuitMessage(0)))
    let f = attach(rt, c)
    try:
      let exports = rt.updateStats().snapshotExports
      check f.h.boundedPump() == 0
      check callbacks == 1
      check rt.find("value").node.text == "7"
      check f.h.hasNativeText("7")
      check rt.updateStats().snapshotExports == exports
    finally:
      f.h.destroyHost()
      rt.closeRuntime()

  test "busy nested dispatch preserves task wake until ordinary turn":
    held.store(false)
    var blocked = false
    var callbacks = 0
    let rt = newRuntime(ownerApp(proc(s: State[int]) =
      inc callbacks
      PostQuitMessage(0)))
    let f = attach(rt, blocked = proc(): bool = blocked)
    try:
      blocked = true
      discard SendMessageW(f.h.windowHandle, WM_HOST_TASK_TICK, 0, 0)
      discard f.h.pump() # nested/nonblocking; cannot claim lifecycle or completion
      check callbacks == 0
      blocked = false
      check f.h.boundedPump() == 0
      check callbacks == 1
    finally:
      blocked = false
      f.h.destroyHost()
      rt.closeRuntime()

  test "native installation callback cannot claim lifecycle or completion in nested pump":
    held.store(false); started.store(false)
    var h: Win32Host
    var delivered, hookEntries: int
    var attachingNative = false
    let rt = newRuntime(ownerApp(proc(s: State[int]) =
      inc delivered
      PostQuitMessage(0)))
    var c = systemWin32Calls()
    let create = c.createWindow
    c.createWindow = proc(exStyle: DWORD, className, title: WidePtr, style: DWORD,
        x, y, width, height: int32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: pointer): HWND =
      if attachingNative:
        inc hookEntries
        # installingHook belongs to the isolated candidate; the accepted
        # Runtime keeps installingUpdate through prepare/apply and scope exit.
        if not rt.installingUpdate: fail("native installation lost update protection")
        if rt.committerOwner != 0: fail("committer published during native installation")
        try: discard h.pump()
        except Exception as error: fail("nested installation pump: " & error.msg)
        if started.load(): fail("worker started during native installation")
        if delivered != 0: fail("delivery during native installation")
      create(exStyle, className, title, style, x, y, width, height, parent, menu, instance, param)
    h = createHost("hook tasks", DipSize(width: 400, height: 300), c)
    h.setStartupScope(proc(): bool = rt.installingHook or rt.installingUpdate)
    let win = newWin32Backend(h, c)
    var session: BackendSession
    attachingNative = true
    try: session = win.attachWin32Backend(rt)
    finally: attachingNative = false
    win.bindSession(session)
    h.bindSession(session, proc(): bool = false)
    h.setSafeTick(proc() = session.drainEvents())
    try:
      check hookEntries > 0
      check h.boundedPump() == 0
      check delivered == 1
    finally:
      h.destroyHost()
      rt.closeRuntime()

  test "initially idle host mounts a task later and arms its own timer":
    held.store(false)
    var show: State[bool]
    var callbacks, taskArms: int
    var c = systemWin32Calls()
    let realSetTimer = c.setTimer
    c.setTimer = proc(w: HWND, id: UINT_PTR, interval: UINT, cb: TIMERPROC): UINT_PTR =
      if interval == 16: inc taskArms
      realSetTimer(w, id, interval, cb)
    let Child = defineComponent[int, int]("LateTask",
      proc(ctx: MountContext, p: int): int =
        ctx.onMount(proc(e: LifecycleContext) =
          discard startTask(e.taskScope, "late", "", work, proc(v: string) =
            inc callbacks
            PostQuitMessage(0)))
        p,
      proc(ctx: ComponentContext, p, s: int): UiDescription = host(text("child")))
    let Parent = defineComponent[int, State[bool]]("InitiallyIdle",
      proc(ctx: MountContext, p: int): State[bool] =
        show = ctx.state(false)
        show,
      proc(ctx: ComponentContext, p: int, s: State[bool]): UiDescription =
        if ctx.value(s): component(Child, 0)
        else: host(text("idle")))
    let rt = newRuntime(componentApplication(component(Parent, 0), "late"))
    let f = attach(rt, c)
    var turns = 0
    f.h.setSafeTick(proc() =
      inc turns
      if turns == 1:
        check taskArms == 0
        rt.uiTask(proc() = discard show.set(true)))
    try:
      check f.h.boundedPump() == 0
      check callbacks == 1
      check taskArms >= 1
    finally:
      f.h.destroyHost()
      rt.closeRuntime()

  test "terminal host release cancels held work without joining and ordinary close disposes once":
    held.store(true); started.store(false)
    var delivered, disposed: int
    let rt = newRuntime(ownerApp((proc(s: State[int]) = inc delivered), (proc() = inc disposed)))
    var h: Win32Host
    var c = systemWin32Calls()
    let dispatch = c.dispatchMessage
    c.dispatchMessage = proc(msg: ptr MSG): LRESULT =
      result = dispatch(msg)
      if started.load(): h.requestClose()
    let f = attach(rt, c)
    h = f.h
    try:
      check f.h.boundedPump() == 0
      check started.load()
      check held.load() # Host cleanup returned before noncooperative worker exit.
      check not rt.taskPumpPending()
      check disposed == 0
      check f.win.diagnostics.liveRoots == 0
      held.store(false)
      rt.closeRuntime()
      check delivered == 0
      check disposed == 1
      rt.closeRuntime()
      check disposed == 1
    finally:
      held.store(false)
      f.h.destroyHost()
      rt.closeRuntime()

  test "temporary session disposal and late old Host close preserve replacement tasks":
    held.store(false)
    var delivered = 0
    let rt = newRuntime(ownerApp(proc(s: State[int]) =
      inc delivered
      PostQuitMessage(0)))
    let old = attach(rt)
    old.s.dispose() # temporary detach, does not retire Runtime
    let current = attach(rt)
    try:
      old.h.destroyHost() # stale Host cannot cancel replacement owner
      check current.h.boundedPump() == 0
      check delivered == 1
    finally:
      old.h.destroyHost()
      current.h.destroyHost()
      rt.closeRuntime()

# A real thread timer fires from GetMessage, after ordinary startup turns. Its
# metadata-only callback refuses the next ordinary cleanup scope and sends quit.
var publicRefuse = false
var publicStatus: int32
var publicState: State[int]
proc refuseAndQuit(window: HWND, message: UINT, timer: UINT_PTR, time: DWORD) {.stdcall, raises: [].} =
  discard KillTimer(nil, timer)
  publicRefuse = true
  PostQuitMessage(publicStatus)
proc quitNormally(window: HWND, message: UINT, timer: UINT_PTR, time: DWORD) {.stdcall, raises: [].} =
  discard KillTimer(nil, timer)
  PostQuitMessage(publicStatus)
proc cleanupApp(dispose: proc() {.closure.}): Application =
  let Owner = defineComponent[int, int]("NativeCleanupOwner",
    proc(ctx: MountContext, p: int): int =
      publicState = ctx.state(0)
      ctx.onDispose(proc(e: LifecycleContext) = dispose())
      p,
    proc(ctx: ComponentContext, p, s: int): UiDescription = host(text("cleanup")))
  result = componentApplication(component(Owner, 0), "cleanup")
  result.executionScope = proc(body: proc() {.closure.}) =
    # Native hook uninstall is allowed. Refuse only after ordinary close has
    # invalidated State, so this exercises Runtime failure after Host release.
    if publicRefuse:
      var invalid = false
      try: discard publicState.read()
      except UiError: invalid = true
      if invalid: fail("native final scope")
    body()

suite "Win32 task and close scheduling":
  test "independent pending timers cancel before close retry and never claim tasks":
    held.store(false)
    var taskId, closeId: UINT_PTR
    var destroys, delivered: int
    var hostWindow: HWND
    var childDestroys: seq[HWND]
    var blocked = false
    var c = systemWin32Calls()
    let setTimer = c.setTimer
    let destroy = c.destroyWindow
    c.setTimer = proc(w: HWND, id: UINT_PTR, interval: UINT, cb: TIMERPROC): UINT_PTR =
      result = setTimer(w, id, interval, cb)
      if interval == 16: taskId = result
      if interval == 30: closeId = result
    c.destroyWindow = proc(w: HWND): BOOL =
      if w == hostWindow:
        inc destroys
        if destroys == 1: setLastError(5); return 0
      else:
        childDestroys.add(w)
      destroy(w)
    let rt = newRuntime(ownerApp(proc(s: State[int]) = inc delivered))
    let f = attach(rt, c, proc(): bool = blocked)
    hostWindow = f.h.windowHandle
    childWindows.setLen(0)
    discard EnumChildWindows(hostWindow, collectChild, 0)
    var expectedChildren: seq[HWND]
    for child in childWindows: expectedChildren.add(child)
    childDestroys.setLen(0) # Only count teardown, not temporary prepare probes.
    try:
      check expectedChildren.len > 0
      blocked = true
      discard SendMessageW(f.h.windowHandle, WM_HOST_TICK, 0, 0)
      f.h.requestClose()
      check taskId != 0
      check closeId != 0
      check taskId != closeId
      discard SendMessageW(f.h.windowHandle, WM_TIMER, taskId, 0)
      discard f.h.pump()
      check delivered == 0
      check destroys == 0
      blocked = false
      check f.h.boundedPump() == 0
      check destroys == 2 # One refused Host destruction, then one real retry.
      check childDestroys.len == expectedChildren.len
      for child in expectedChildren:
        var attempts = 0
        for destroyed in childDestroys:
          if destroyed == child: inc attempts
        check attempts == 1
      check f.win.diagnostics.liveWindows == 0
      check f.win.diagnostics.liveSubclasses == 0
      check f.win.diagnostics.liveRoots == 0
      check delivered == 0
    finally:
      blocked = false
      f.h.destroyHost()
      rt.closeRuntime()

  test "an idle task message does not export render or revise the tree":
    publicRefuse = false
    let rt = newRuntime(cleanupApp(proc() = discard))
    let f = attach(rt)
    try:
      PostQuitMessage(0)
      check f.h.pump() == 0 # settle accepted mount and the initial ordinary turn
      let before = rt.updateStats()
      let revision = rt.acceptedRevision
      discard SendMessageW(f.h.windowHandle, WM_HOST_TASK_TICK, 0, 0)
      PostQuitMessage(0)
      check f.h.pump() == 0
      let after = rt.updateStats()
      check after.snapshotExports == before.snapshotExports
      check after == before
      check rt.acceptedRevision == revision
    finally:
      f.h.destroyHost()
      rt.closeRuntime()

suite "public native cleanup ownership":
  test "nonempty output is refused before new Runtime and preserves old owner":
    let rt = newRuntime(Application(title: "existing", width: 400, height: 300,
      render: proc(ctx: BuildContext): Node = text("old")))
    var owner = rt
    var renders = 0
    try:
      var rejected = false
      try:
        discard runNative(Application(title: "new", width: 400, height: 300,
          render: proc(ctx: BuildContext): Node =
            inc renders
            raise newException(UiError, "unexpected new Runtime construction")), cleanupOwner = addr owner)
      except UiError as error:
        rejected = true
        check error.msg.contains("cleanup owner slot must be empty")
      check rejected
      check owner == rt
      check renders == 0
      check rt.snapshot.root.node.text == "old"
    finally: rt.closeRuntime()

  test "ordinary successful status return closes accepted Runtime exactly once":
    for status in [0, 31]:
      publicRefuse = false; publicStatus = int32(status)
      var disposed = 0
      let timer = SetTimer(nil, 0, 10, quitNormally)
      doAssert timer != 0
      try:
        check runNative(cleanupApp(proc() = inc disposed)) == status
        check disposed == 1
        check publicState.set(1) == StateWriteResult.disposed
      finally: discard KillTimer(nil, timer)

  test "status zero and nonzero preserve Runtime output after refused final scope":
    for status in [0, 23]:
      publicRefuse = false; publicStatus = int32(status)
      var disposed = 0
      let app = cleanupApp(proc() = inc disposed)
      let timer = SetTimer(nil, 0, 10, refuseAndQuit)
      doAssert timer != 0
      var owner: Runtime
      try:
        check runNative(app, cleanupOwner = addr owner) == status
        check owner != nil
        check disposed == 0
        check publicState.set(1) == StateWriteResult.disposed
        publicRefuse = false
        owner.closeRuntime()
        check disposed == 1
      finally:
        discard KillTimer(nil, timer)
        publicRefuse = false
        if owner != nil: owner.closeRuntime()

  test "default cleanup error exposes status and reachable Runtime":
    publicRefuse = false; publicStatus = 0
    let timer = SetTimer(nil, 0, 10, refuseAndQuit)
    doAssert timer != 0
    var failure: ref Win32RunError
    try:
      discard runNative(cleanupApp(proc() = discard))
      check false
    except Win32RunError as error:
      failure = error
      check error.exitStatus == some(0)
      check error.cleanupHost == nil
      check error.cleanupRuntime != nil
      check error.msg.contains("native final scope")
      check error.parent != nil
    finally:
      discard KillTimer(nil, timer)
      publicRefuse = false
      if failure != nil and failure.cleanupRuntime != nil: failure.cleanupRuntime.closeRuntime()

  test "creation rejection keeps primary and refused Runtime cleanup reachable":
    publicRefuse = false
    var disposed = 0
    var app = cleanupApp(proc() = inc disposed)
    app.title = "bad\0title"
    app.executionScope = proc(body: proc() {.closure.}) =
      if publicRefuse: fail("cleanup refused")
      body()
      publicRefuse = true
    var owner: Runtime
    try:
      discard runNative(app, cleanupOwner = addr owner)
      check false
    except Win32RunError as error:
      check error.msg.contains("NUL")
      check error.parent != nil
      check error.exitStatus.isNone
      check error.cleanupHost == nil
      check error.cleanupRuntime == owner
      check owner != nil
      check publicState.set(1) == StateWriteResult.disposed
      check disposed == 0
    finally:
      publicRefuse = false
      if owner != nil: owner.closeRuntime()
    check disposed == 1

  test "installation scope rejection does not hide original error or lose cleanup owner":
    publicRefuse = false
    var disposed = 0
    let cause = newException(IOError, "installation cause")
    let primary = newException(ValueError, "native installation scope")
    primary.parent = cause
    var app = cleanupApp(proc() = inc disposed)
    app.executionScope = proc(body: proc() {.closure.}) =
      if publicRefuse: raise primary
      body()
      publicRefuse = true
    var failure: ref Win32RunError
    try:
      discard runNative(app)
      check false
    except Win32RunError as error:
      failure = error
      check error.msg.startsWith("native installation scope")
      check error.msg.contains("body invoked 0")
      check error.parent == primary
      if error.parent != nil: check error.parent of ValueError
      check primary.parent == cause
      check error.exitStatus.isNone
      check error.cleanupHost == nil
      check error.cleanupRuntime != nil
      check disposed == 0
      check publicState.set(1) == StateWriteResult.disposed
    finally:
      publicRefuse = false
      if failure != nil and failure.cleanupRuntime != nil: failure.cleanupRuntime.closeRuntime()
    check disposed == 1

# Test-owned CBT hook refuses actual USER32 destruction, exercising the public
# entry without exposing any production failure injection or call-table option.
type
  TestHook = pointer
  TestHookProc = proc(code: int32, wp: WPARAM, lp: LPARAM): LRESULT {.stdcall, raises: [].}
proc SetWindowsHookExW(id: int32, callback: TestHookProc, instance: HINSTANCE, thread: DWORD): TestHook {.stdcall, importc, header: "<windows.h>".}
proc UnhookWindowsHookEx(hook: TestHook): BOOL {.stdcall, importc, header: "<windows.h>".}
proc CallNextHookEx(hook: TestHook, code: int32, wp: WPARAM, lp: LPARAM): LRESULT {.stdcall, importc, header: "<windows.h>".}
proc FindWindowW(className, title: WidePtr): HWND {.stdcall, importc, header: "<windows.h>".}
var closeInsidePump = false
var rejectDestroy = false
var rejectedDestroys = 0
proc vetoDestroy(code: int32, wp: WPARAM, lp: LPARAM): LRESULT {.stdcall, raises: [].} =
  if code == 4 and rejectDestroy: # HCBT_DESTROYWND
    inc rejectedDestroys
    return 1
  CallNextHookEx(nil, code, wp, lp)
proc quitWithHostFailure(window: HWND, message: UINT, timer: UINT_PTR, time: DWORD) {.stdcall, raises: [].} =
  discard KillTimer(nil, timer)
  rejectDestroy = true
  if closeInsidePump:
    var title = [WCHAR(99), WCHAR(108), WCHAR(101), WCHAR(97), WCHAR(110), WCHAR(117), WCHAR(112), WCHAR(0)]
    let window = FindWindowW(nil, addr title[0])
    discard SendMessageW(window, WM_CLOSE, 0, 0)
  PostQuitMessage(19)
suite "public native retained Host owner":
  test "live Host cleanup failure throws both owners even with Runtime output":
    for fromPump in [false, true]:
      publicRefuse = false; rejectDestroy = false; rejectedDestroys = 0
      closeInsidePump = fromPump
      let hook = SetWindowsHookExW(5, vetoDestroy, nil, GetCurrentThreadId()) # WH_CBT
      doAssert hook != nil
      let timer = SetTimer(nil, 0, 10, quitWithHostFailure)
      doAssert timer != 0
      var owner: Runtime
      var failure: ref Win32RunError
      var disposed = 0
      try:
        discard runNative(cleanupApp(proc() = inc disposed), cleanupOwner = addr owner)
        check false
      except Win32RunError as error:
        failure = error
        check error.exitStatus == some(19)
        check error.parent != nil
        check error.cleanupHost != nil
        check error.cleanupHost.windowHandle != nil
        check error.cleanupRuntime == owner
        check owner != nil
        check disposed == 0
        check rejectedDestroys == 1 # no immediate outer retry of this attempt
      finally:
        discard KillTimer(nil, timer)
        rejectDestroy = false
        discard UnhookWindowsHookEx(hook)
        if failure != nil:
          if failure.cleanupHost != nil: failure.cleanupHost.destroyHost()
          if failure.cleanupRuntime != nil: failure.cleanupRuntime.closeRuntime()
      check disposed == 1
