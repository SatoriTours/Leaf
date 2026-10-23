## Real HWND and message contract. SendMessage is controlled native input,
## not a claim of physical keyboard/IME or animated transition coverage.
when not defined(windows):
  {.error: "Win32 component navigation requires Windows".}

import std/[unittest, tables, options, widestrs]
import leaf/[core, components, component_description, backend, backend_session,
  native_layout, ui_thread, widgets, styles]
import leaf/backends/win32/[api, calls, host, backend]

const
  SysKeyDown = 0x0104'u32
  AppCommand = 0x0319'u32
  LeftKey = 0x25'u
  AltContext = LPARAM(1 shl 29)
  PreviousDown = LPARAM(1 shl 30)
  BrowserBack = LPARAM(1 shl 16)

type
  Model = ref object
    router: ComponentRouter
    state: array[3, State[int]]
    initialized: array[3, int]
    disposed: int
  Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession,
    runtime: Runtime, model: Model, activity: UiScopeActivity]

var enumerated: seq[HWND]
proc collect(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  enumerated.add(window)
  1
proc descendants(parent: HWND): seq[HWND] =
  enumerated.setLen(0)
  discard EnumChildWindows(parent, collect, 0)
  enumerated
proc nativeText(window: HWND): string =
  let size = GetWindowTextLengthW(window) + 1
  let value = newWideCString(int(size))
  discard GetWindowTextW(window, cast[WidePtr](unsafeAddr value[0]), size)
  $value
proc findText(parent: HWND, value: string): HWND =
  for window in descendants(parent):
    if nativeText(window) == value: return window

proc application(model: Model): Application =
  let names = ["首页 中文😀", "详情 中文😀", "第三页 中文😀"]
  let Page = defineComponent[int, State[int]]("WindowsNavigationPage",
    proc(ctx: MountContext, index: int): State[int] =
      inc model.initialized[index]
      result = ctx.state(0)
      model.state[index] = result,
    proc(ctx: ComponentContext, index: int, state: State[int]): UiDescription =
      host(column(@[
        text(names[index] & " 状态=" & $ctx.value(state), key = "content"),
        input("editor", key = "editor"),
        button("增加状态", key = "increment", onClick = proc(e: Event) =
          discard state.update(proc(value: int): int = value + 1))], key = "page")))
  let Root = defineComponent[int, int]("WindowsNavigationRoot",
    proc(ctx: MountContext, props: int): int =
      ctx.onDispose(proc(e: LifecycleContext) = inc model.disposed)
      model.router = newComponentRouter(ctx, @[
        Route(name: "home", path: "/", page: "home", view: "main"),
        Route(name: "detail", path: "/detail", page: "detail", view: "main"),
        Route(name: "third", path: "/third", page: "third", view: "main")], @[
        ComponentPageDefinition(name: "home", views: @["main"],
          build: proc(view: string): UiDescription = component(Page, 0)),
        ComponentPageDefinition(name: "detail", views: @["main"],
          build: proc(view: string): UiDescription = component(Page, 1)),
        ComponentPageDefinition(name: "third", views: @["main"],
          build: proc(view: string): UiDescription = component(Page, 2))])
      0,
    proc(ctx: ComponentContext, props, state: int): UiDescription =
      hostShell(ui(NodeKind.column, key = "shell"), @[
        host(text("depth=" & $ctx.history(model.router).len, key = "depth")),
        renderNavigation(ctx, model.router, key = "navigation")]))
  componentApplication(component(Root, 0), "Windows navigation", 480, 320)

proc mounted(c: Win32Calls = systemWin32Calls()): Fixture =
  let model = Model()
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(model.application(),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("Windows navigation", DipSize(width: 480, height: 320))
  h.setStartupScope(proc(): bool =
    activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win = newWin32Backend(h, c)
  let session = win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime, model, activity)

proc remounted(f: Fixture): Fixture =
  let h = createHost("Windows navigation remount", DipSize(width: 480, height: 320))
  h.setStartupScope(proc(): bool =
    f.activity.busy or f.runtime.installingUpdate or f.runtime.installingHook)
  let win = newWin32Backend(h)
  let session = win.attachWin32Backend(f.runtime)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = f.activity.busy)
  (h, win, session, f.runtime, f.model, f.activity)

proc nav(f: Fixture): MountedEntity =
  for entity in f.s.acceptedEntities.values:
    if entity.kind == NodeKind.navigation: return entity
  fail("accepted navigation entity is missing")

proc runTurn(f: Fixture, body: proc()) =
  f.h.setSafeTick(proc() =
    try: body()
    finally: f.h.requestClose())
  check f.h.pump() == 0
  # Native Host disposal detaches the Session. The fixture separately owns the
  # retained Runtime and must explicitly close it at this terminal boundary.
  f.runtime.closeRuntime()
  check f.model.disposed == 1

proc push(f: Fixture, route: string) =
  discard f.model.router.push(route)
  check f.runtime.flush()

proc altLeft(window: HWND, repeat = false) =
  discard SendMessageW(window, SysKeyDown, LeftKey,
    AltContext or LPARAM(1) or (if repeat: PreviousDown else: LPARAM(0)))

suite "Win32 component navigation native contract":
  test "one real navigation HWND retains identity on a history-only update":
    let f = mounted()
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      let before = f.nav()
      let label = findText(f.h.windowHandle, "首页 中文😀 状态=0")
      require label != nil
      let container = GetParent(GetParent(label))
      require container != nil
      check container != f.h.windowHandle
      check IsWindow(container) != 0
      var rect: RECT
      check GetClientRect(container, addr rect) != 0
      check rect.right > 0 and rect.bottom > 0
      f.push("home")
      let after = f.nav()
      check after.handle == before.handle
      check after.navigation.isSome
      check after.navigation.get.depth == 2
      check after.navigation.get.previousEntryId == before.navigation.get.currentEntryId
      check GetParent(GetParent(findText(f.h.windowHandle, "首页 中文😀 状态=0"))) == container
      check f.model.initialized[0] == 1)

  test "child Alt-Left queues one ordinary back and ignores held-key repeats":
    let f = mounted()
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      discard f.model.state[0].set(7)
      check f.runtime.flush()
      f.push("detail")
      let child = findText(f.h.windowHandle, "editor")
      require child != nil
      altLeft(child)
      altLeft(child, repeat = true)
      check f.model.router.history.len == 2
      f.win.safeListTurn()
      check f.model.router.history.len == 1
      check findText(f.h.windowHandle, "首页 中文😀 状态=7") != nil
      check f.model.initialized == [1, 1, 0]
      altLeft(f.h.windowHandle)
      f.win.safeListTurn()
      check f.model.router.history.len == 1)

  test "composition messages preserve the current editor until composition ends":
    let f = mounted()
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.push("detail")
      let child = findText(f.h.windowHandle, "editor")
      require child != nil
      discard SendMessageW(child, WM_IME_STARTCOMPOSITION, 0, 0)
      altLeft(child)
      f.win.safeListTurn()
      check f.model.router.history.len == 2
      check IsWindow(child) != 0
      check f.s.pendingNavigation == 0
      discard SendMessageW(child, WM_IME_ENDCOMPOSITION, 0, 0)
      f.win.safeListTurn()
      altLeft(child)
      f.win.safeListTurn()
      check f.model.router.history.len == 1)

  test "setter reentry captures the accepted history and is stale after publication":
    var reenter = false
    var callbacks = 0
    var pendingDuringSetter = 0
    var session: BackendSession
    var owner: HWND
    var c = systemWin32Calls()
    let real = c.setText
    c.setText = proc(window: HWND, value: WidePtr): BOOL =
      if reenter:
        reenter = false
        inc callbacks
        altLeft(owner)
        pendingDuringSetter = session.pendingNavigation
      real(window, value)
    let f = mounted(c)
    defer: f.h.destroyHost()
    owner = f.h.windowHandle
    session = f.s
    runTurn(f, proc() =
      f.push("detail")
      reenter = true
      f.push("third")
      check callbacks == 1
      check pendingDuringSetter == 1
      check f.model.router.history.len == 3
      f.win.safeListTurn()
      check f.model.router.history.len == 3
      altLeft(owner)
      f.win.safeListTurn()
      check f.model.router.history.len == 2)

  test "request identities survive a new Backend on the same retained Runtime":
    let f = mounted()
    defer: f.h.destroyHost()
    f.h.setSafeTick(proc() =
      f.push("detail")
      altLeft(f.h.windowHandle)
      f.win.safeListTurn()
      check f.model.router.history.len == 1
      discard f.model.state[0].set(9)
      check f.runtime.flush()
      f.push("detail")
      # Host close is terminal for its currently bound Runtime. Explicitly
      # detach first so this test retains the Runtime for a fresh Backend.
      f.s.dispose()
      check not f.runtime.runtimeClosedInternal
      f.h.requestClose())
    check f.h.pump() == 0
    check f.s.disposed
    check not f.runtime.runtimeClosedInternal
    check f.model.disposed == 0
    let g = f.remounted()
    defer: g.h.destroyHost()
    runTurn(g, proc() =
      check not g.runtime.runtimeClosedInternal
      check g.model.router.history.len == 2
      altLeft(g.h.windowHandle)
      check g.s.pendingNavigation == 1
      g.win.safeListTurn()
      check g.s.pendingNavigation == 0
      check g.model.router.history.len == 1
      check findText(g.h.windowHandle, "首页 中文😀 状态=9") != nil
      check g.model.initialized == [1, 1, 0])

  test "full and delta preparation reject malformed metadata before creating windows":
    let f = mounted()
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      let navigation = f.nav()
      var page: MountedEntity
      var shell: MountedEntity
      for entity in f.s.acceptedEntities.values:
        if entity.parent == navigation.handle: page = entity
        if entity.handle == navigation.parent: shell = entity
      require page.handle != NoHandle
      require shell.handle != NoHandle
      for delta in [false, true]:
        for mode in 0..5:
          var batch = UpdateBatch(revision: f.runtime.acceptedRevision + 1, isDelta: delta)
          var changed = navigation
          case mode
          of 0: changed.navigation = none(HostNavigationProps)
          of 1:
            changed = shell
            changed.navigation = navigation.navigation
          of 2:
            var metadata = navigation.navigation.get
            metadata.historyRevision = 0
            changed.navigation = some(metadata)
          of 3:
            batch.ops.add(UpdateOp(kind: opRemove, handle: page.handle))
          of 4:
            batch.ops.add(UpdateOp(kind: opCreate, handle: NodeHandle(99999),
              parent: navigation.handle, index: 1, nodeKind: NodeKind.text,
              nodeId: page.nodeId, props: normalizeProps(text("extra"))))
          of 5:
            changed = shell
            changed.props.control.hasBack = true
          else: discard
          if mode notin {3, 4}:
            batch.ops.add(UpdateOp(kind: opUpdate, handle: changed.handle,
              props: changed.props, list: changed.list, row: changed.row,
              navigation: changed.navigation))
          let creates = f.win.diagnostics.creates
          expect UiError: f.win.asBackend.prepare(batch)
          check f.win.diagnostics.creates == creates
          f.win.asBackend.discardPrepared()
      check f.nav() == navigation
      check findText(f.h.windowHandle, "首页 中文😀 状态=0") != nil)

  test "stale history discards queued back and the Host accepts a fresh command":
    let f = mounted()
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.push("detail")
      altLeft(f.h.windowHandle)
      check f.model.router.history.len == 2
      f.push("third")
      f.win.safeListTurn()
      check f.model.router.history.len == 3
      check SendMessageW(f.h.windowHandle, AppCommand,
        cast[WPARAM](f.h.windowHandle), BrowserBack) == 1
      check f.model.router.history.len == 3
      f.win.safeListTurn()
      check f.model.router.history.len == 2
      check findText(f.h.windowHandle, "详情 中文😀 状态=0") != nil)

  test "failed native pop restores history and consumes the request without idle retry":
    var inject = false
    var injected = 0
    var c = systemWin32Calls()
    let real = c.setText
    c.setText = proc(window: HWND, value: WidePtr): BOOL =
      if inject:
        inject = false
        inc injected
        setLastError(1234)
        return 0
      real(window, value)
    let f = mounted(c)
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.push("detail")
      let accepted = f.nav().navigation
      let generation = f.s.mountGeneration
      inject = true
      altLeft(f.h.windowHandle)
      # BackendSession records dispatch failure and consumes this event; the
      # native turn itself does not promise to rethrow the business failure.
      f.win.safeListTurn()
      check injected == 1
      check f.model.router.history.len == 2
      check f.nav().navigation == accepted
      check f.s.mountGeneration > generation
      check not f.s.faulted
      check findText(f.h.windowHandle, "详情 中文😀 状态=0") != nil
      f.win.safeListTurn()
      check f.model.router.history.len == 2
      altLeft(f.h.windowHandle)
      f.win.safeListTurn()
      check f.model.router.history.len == 1)
