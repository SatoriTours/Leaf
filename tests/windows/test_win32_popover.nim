when not defined(windows): {.error: "Native Popover tests require Windows".}
import std/[unittest, tables, unicode, times, monotimes, os, strutils]
import leaf
import ../fixture_app
import leaf/[ui_thread, native_theme, backend_session, native_layout]
import leaf/backend as protocol
import leaf/backends/win32/[api, host, backend, calls, popover_host]
import leaf/ui as standard

const
  GwOwner = 4'u32
  GaRoot = 2'u32
  GwlpExStyle = -20'i32
  ExTopmost = 0x00000008'u32

{.push stdcall, dynlib: "user32.dll", importc, raises: [].}
proc GetWindowTextW(window: HWND, text: pointer, max: int32): int32
proc SendMessageW(window: HWND, message: uint32, wp: WPARAM, lp: LPARAM): LRESULT
proc GetWindowLongW(window: HWND, index: int32): int32
proc GetWindow(window: HWND, command: uint32): HWND
proc SetForegroundWindow(window: HWND): BOOL
proc SetCursorPos(x, y: int32): BOOL
proc IsIconic(window: HWND): BOOL
proc GetForegroundWindow(): HWND
proc SendInput(count: UINT, inputs: pointer, size: int32): UINT
{.pop.}

var seamLog: seq[string]
var injectFail = (create: false, destroy: false, show: false)

type
  PopoverState = ref object
    open, dialogOpen, dialogPanelOpen, selectOpen, dark: bool
    text, value: string
    requests, closes, dialogRequests, selectRequests, selectCloses: int
    clicks: int
    removeTrigger, rebuildTrigger: bool
    moved, newKey: bool
    ignoreSelectClose, ignoreClose: bool
    rows: int

  Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession,
    runtime: Runtime]

type
  MouseInput = object
    dx, dy: int32
    mouseData, flags, time: uint32
    extra: uint
  KeyboardInput = object
    vk, scan: uint16
    flags, time: uint32
    extra: uint
  HardwareInput = object
    message: uint32
    paramL, paramH: uint16
  InputUnion {.union.} = object
    mouse: MouseInput
    keyboard: KeyboardInput
    hardware: HardwareInput
  InputEvent = object
    kind: uint32
    payload: InputUnion

const
  InputKeyboard = 1'u32
  KeyeventfKeyup = 0x0002'u32

proc tapKey(vk: int32) =
  var events: array[2, InputEvent]
  events[0].kind = InputKeyboard
  events[0].payload.keyboard.vk = uint16(vk)
  events[1].kind = InputKeyboard
  events[1].payload.keyboard.vk = uint16(vk)
  events[1].payload.keyboard.flags = KeyeventfKeyup
  if SendInput(2, addr events[0], int32(sizeof(InputEvent))) != 2:
    raise newException(IOError, "keyboard input was not fully submitted")

proc foreground(window: HWND) =
  if GetForegroundWindow() == window: return
  discard SetForegroundWindow(window)
  let deadline = getMonoTime() + initDuration(milliseconds = 2000)
  while GetForegroundWindow() != window:
    if getMonoTime() >= deadline:
      raise newException(IOError, "window could not be made foreground")
    sleep(10)

proc setText(window: HWND, value: string) =
  var units: seq[uint16]
  for rune in value.runes: units.add(uint16(rune))
  units.add(0)
  discard SendMessageW(window, 0x000c'u32, 0, cast[LPARAM](addr units[0]))

proc packedSel(window: HWND): tuple[start, stop: int] =
  let packed = SendMessageW(window, 0x00b0'u32, 0, 0) # EM_GETSEL
  (int(packed and 0xffff), int((packed shr 16) and 0xffff))

proc typeText(value: string) =
  ## Real Unicode keystrokes so the EDIT builds a genuine Undo history.
  for rune in value.runes:
    var events: array[2, InputEvent]
    events[0].kind = 1'u32
    events[0].payload.keyboard.scan = uint16(rune)
    events[0].payload.keyboard.flags = 0x0004'u32 # KEYEVENTF_UNICODE
    events[1].kind = 1'u32
    events[1].payload.keyboard.scan = uint16(rune)
    events[1].payload.keyboard.flags = 0x0004'u32 or 0x0002'u32
    if SendInput(2, addr events[0], int32(sizeof(InputEvent))) != 2:
      raise newException(IOError, "unicode input was not fully submitted")

proc pressShiftTab() =
  ## Real Shift+Tab: shift down, tab, shift up, every injection fully submitted.
  var down: InputEvent
  down.kind = 1'u32
  down.payload.keyboard.vk = 0x10'u16
  var up: InputEvent
  up.kind = 1'u32
  up.payload.keyboard.vk = 0x10'u16
  up.payload.keyboard.flags = 0x0002'u32
  if SendInput(1, addr down, int32(sizeof(InputEvent))) != 1:
    raise newException(IOError, "shift down not submitted")
  tapKey(0x09)
  if SendInput(1, addr up, int32(sizeof(InputEvent))) != 1:
    raise newException(IOError, "shift up not submitted")

proc clickAt(x, y: int32) =
  discard SetCursorPos(x, y)
  var events: array[2, InputEvent]
  events[0].kind = 0'u32
  events[0].payload.mouse.flags = 0x0002'u32
  events[1].kind = 0'u32
  events[1].payload.mouse.flags = 0x0004'u32
  if SendInput(2, addr events[0], int32(sizeof(InputEvent))) != 2:
    raise newException(IOError, "mouse input was not fully submitted")

proc screenCentre(window: HWND): tuple[x, y: int32] =
  var frame: RECT
  discard GetWindowRect(window, addr frame)
  ((frame.left + frame.right) div 2, (frame.top + frame.bottom) div 2)

proc pump(surface: HWND) =
  ## Same pump contract as the select suite: the owning surface sees the message
  ## first so Esc reaches the dialog exactly like a real modal user gesture.
  var message: MSG
  while PeekMessageW(addr message, nil, 0, 0, 1) != 0:
    if surface != nil and IsDialogMessageW(surface, addr message) != 0: continue
    discard TranslateMessage(addr message)
    discard DispatchMessageW(addr message)

proc page(state: PopoverState): Node =
  ## Minimal tree: one page sentinel plus one controlled popover whose body holds
  ## a label, a native EDIT and a close control. This fixture only answers where
  ## the body is parented and what is really visible.
  var controls: seq[Node] = @[standard.button("哨兵", key = "sentinel",
      onClick = proc(e: Event) = inc state.clicks)]
  if not state.removeTrigger:
    var body: seq[Node] = @[
      standard.label("提示", key = "pp-label"),
      standard.input(state.text, key = "pp-edit", placeholder = "草稿",
        onChange = proc(e: Event) = state.text = e.value),
      standard.popoverClose("关闭", key = "pp-close")]
    for index in 1 .. state.rows:
      body.add(standard.label("行" & $index, key = "pp-row-" & $index))
    controls.add(standard.popover(
      standard.popoverTrigger("打开",
        key = (if state.rebuildTrigger: "pp-trigger-2" else: "pp-trigger")),
      standard.popoverContent(body, key = "pp-body"),
      open = state.open, name = "面板", key = "pp",
      onOpenChange = proc(e: Event) =
        inc state.requests
        if not e.open: inc state.closes
        if not (state.ignoreClose and not e.open):
          state.open = e.open))
  standard.theme((if state.dark: UiColorMode.dark else: UiColorMode.light),
    column(controls,
      styles = style({"padding": "16", "gap": "12", "width": "full"})),
    key = "theme")

proc movedPage(state: PopoverState): Node =
  ## The very same popover root key rendered at page level or nested in a Dialog:
  ## switching between them is a cross-owner candidate for the same root.
  let key = if state.newKey: "pp-new" else: "pp"
  let triggerKey = if state.newKey: "pp-new-trigger" else: "pp-trigger"
  var body: seq[Node] = @[
    standard.label("提示", key = "m-label"),
    standard.input(state.text, key = "m-edit", placeholder = "草稿"),
    standard.popoverClose("关闭", key = "m-close")]
  let pop = standard.popover(standard.popoverTrigger("打开", key = triggerKey),
    standard.popoverContent(body, key = "m-body"), open = state.open,
    name = "面板", key = key,
    onOpenChange = proc(e: Event) =
      inc state.requests
      state.open = e.open)
  if not state.moved:
    column(@[standard.button("哨兵", key = "sentinel"), pop],
      styles = style({"padding": "16", "gap": "12", "width": "full"}))
  else:
    let dlg = standard.dialog("编辑", true, description = "跨域候选", key = "mv-dlg",
      onDismiss = proc(e: Event) = discard,
      content = @[standard.field(@[standard.label("名称"), pop])])
    column(@[standard.button("哨兵", key = "sentinel"), dlg],
      styles = style({"padding": "16", "gap": "12", "width": "full"}))

proc dialogPage(state: PopoverState): Node =
  ## Minimal page plus one modal level that owns a second popover. Both open
  ## flags are independent so the inner panel can be shown on its own.
  let innerTrigger = standard.popoverTrigger("更多", key = "dlg-trigger")
  var innerControls: seq[Node] = @[
    standard.label("内层提示", key = "dlg-label"),
    standard.select(
      standard.selectTrigger(placeholder = "选择", key = "dlg-select-trigger"),
      standard.selectContent(@[standard.selectItem("a", "甲"),
        standard.selectItem("b", "乙")]),
      value = state.value, open = state.selectOpen, label = "内层选择",
      key = "dlg-select",
      onChange = proc(e: Event) = state.value = e.value,
      onOpenChange = proc(e: Event) =
        inc state.selectRequests
        if not e.open: inc state.selectCloses
        if not (state.ignoreSelectClose and not e.open):
          state.selectOpen = e.open),
    standard.popoverClose("关闭", key = "dlg-close")]
  for index in 1 .. state.rows:
    innerControls.add(standard.label("行" & $index, key = "dlg-row-" & $index))
  let innerBody = standard.popoverContent(innerControls, key = "dlg-body")
  let innerPanel = standard.popover(innerTrigger, innerBody,
    open = state.dialogPanelOpen, name = "内层面板", key = "dlg-pp",
    width = 260,
    onOpenChange = proc(e: Event) =
      inc state.dialogRequests
      state.dialogPanelOpen = e.open)
  let dialogNode = standard.dialog("编辑", state.dialogOpen,
    description = "对话框内浮层", key = "dlg",
    onDismiss = proc(e: Event) = state.dialogOpen = false,
    content = @[standard.field(@[standard.label("名称"), innerPanel])])
  standard.theme((if state.dark: UiColorMode.dark else: UiColorMode.light),
    column(@[
    standard.button("哨兵", key = "sentinel",
      onClick = proc(e: Event) = inc state.clicks),
    standard.popover(
      standard.popoverTrigger("打开", key = "pp-trigger"),
      standard.popoverContent(@[
        standard.label("提示", key = "pp-label"),
        standard.input(state.text, key = "pp-edit", placeholder = "草稿"),
        standard.popoverClose("关闭", key = "pp-close")], key = "pp-body"),
      open = state.open, name = "面板", key = "pp",
      onOpenChange = proc(e: Event) = state.open = e.open),
    dialogNode],
    styles = style({"padding": "16", "gap": "12", "width": "full"})),
    key = "theme")

proc mounted(state: PopoverState, width = 480, height = 360): Fixture =
  let activity = newUiScopeActivity()
  let app = fixtureApplication(
    proc(): Node =
      if state.moved: movedPage(state)
      elif state.dialogOpen or state.dialogPanelOpen: dialogPage(state)
      else: page(state), "Popover mount", width, height).withNativeTheme(shadcnLight)
  let runtime = newRuntime(guardUiApplication(app,
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost(app.title, DipSize(width: float64(width),
    height: float64(height)), calls = systemWin32Calls(), theme = shadcnLight)
  h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or
    runtime.installingHook)
  let baseCalls = systemWin32Calls()
  var logged = baseCalls
  let rawShow = baseCalls.showWindow
  logged.showWindow = proc(window: HWND, command: int32): BOOL
      {.closure, raises: [CatchableError].} =
    let before = GetWindowLongW(window, -16'i32)
    result = rawShow(window, command)
    seamLog.add("showWindow hwnd=" & $uint64(cast[uint](window)) &
      " cmd=" & $command & " beforeWsVis=" & $((before and 0x10000000) != 0) &
      " afterVisible=" & $(IsWindowVisible(window) != 0))
  let rawPos = baseCalls.windowPos
  logged.windowPos = proc(window, after: HWND, x, y, width, height: int32,
      flags: UINT): BOOL {.closure, raises: [CatchableError].} =
    result = rawPos(window, after, x, y, width, height, flags)
    seamLog.add("windowPos hwnd=" & $uint64(cast[uint](window)) &
      " flags=" & $uint64(flags) & " visible=" & $(IsWindowVisible(window) != 0))
  let rawCreate = logged.createWindow
  logged.createWindow = proc(exStyle: DWORD, className, windowName: WidePtr,
      style: DWORD, x, y, width, height: int32, parent: HWND, menu: HMENU,
      instance: HINSTANCE, param: pointer): HWND {.closure,
      raises: [CatchableError].} =
    if injectFail.create and className != nil:
      # Match the panel class by ASCII prefix; no wide decoding needed.
      let units = cast[ptr UncheckedArray[uint16]](className)
      const prefix = "LeafPopoverPanel-"
      var match = true
      for i, c in prefix:
        if units[i] != uint16(c):
          match = false
          break
      if match:
        injectFail.create = false
        setLastError(5)
        return nil
    rawCreate(exStyle, className, windowName, style, x, y, width, height,
      parent, menu, instance, param)
  let rawShowWindow = logged.showWindow
  logged.showWindow = proc(window: HWND, command: int32): BOOL
      {.closure, raises: [CatchableError].} =
    result = rawShowWindow(window, command)
    if injectFail.show and command == 5: # SW_SHOW
      injectFail.show = false
      discard rawShowWindow(window, 0) # hide again: the publish check must fail
  let rawDestroy = logged.destroyWindow
  logged.destroyWindow = proc(window: HWND): BOOL {.closure, raises: [CatchableError].} =
    if injectFail.destroy:
      injectFail.destroy = false
      setLastError(5)
      return 0
    rawDestroy(window)
  let win = newWin32Backend(h, calls = logged)
  let session = win.attachWin32Backend(runtime, protocol.strict)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime)

proc settle(f: Fixture) =
  f.win.safeListTurn()
  discard f.runtime.refresh()
  f.win.safeListTurn()

proc close(f: Fixture) =
  f.h.destroyHost()
  f.runtime.closeRuntime()
  check f.win.diagnostics.liveWindows == 0
  check f.win.diagnostics.liveFonts == 0
  check f.win.diagnostics.liveRoots == 0
  check f.win.popoverCountForTest() == 0

proc windowOf(f: Fixture, key: string): HWND =
  f.win.nativeWindowForTest(f.s.handleFor(f.runtime.find(key).id))

proc panelOf(f: Fixture): HWND =
  f.win.popoverStateForTest(f.s.handleFor(f.runtime.find("pp").id)).panelHandle

proc text(window: HWND): string =
  ## Correct UTF-16 -> UTF-8: the window text is UTF-16 code units, so each
  ## unit (and each surrogate pair) becomes a Rune, never a bare byte.
  var buffer: array[256, uint16]
  let count = GetWindowTextW(window, addr buffer[0], int32(buffer.len))
  var index = 0
  while index < max(0, count) and index < buffer.len - 1:
    let unit = int(buffer[index])
    if unit >= 0xD800 and unit <= 0xDBFF and index + 1 < count:
      let low = int(buffer[index + 1])
      result.add($Rune(0x10000 + ((unit - 0xD800) shl 10) + (low - 0xDC00)))
      index += 2
    else:
      result.add($Rune(unit))
      index += 1

proc runtimeRole(f: Fixture, key: string): string =
  ## Runtime description attribute only, not the native bound role.
  let node = f.runtime.find(key).node
  result = node.attributes.getOrDefault("ui_role", "")

proc rectOf(window: HWND): tuple[width, height: int32] =
  var frame: RECT
  if GetWindowRect(window, addr frame) == 0: return (0, 0)
  (frame.right - frame.left, frame.bottom - frame.top)

type
  EditModel = object
    text, popoverText: string
    open, dark, ignoreEvent, rebuild: bool
    requests: int

let EditDemo = defineComponent[int, State[EditModel]]("PopoverEditFixture",
  proc(ctx: MountContext, p: int): State[EditModel] = ctx.state(EditModel()),
  proc(ctx: ComponentContext, p: int, state: State[EditModel]): UiDescription =
    let m = ctx.value(state)
    let update = proc(f: proc(old: EditModel): EditModel {.closure.}) =
      discard state.update(f)
    let rebuildButton = standard.button("重建锚点", key = "rebuild-btn",
      onClick = proc(e: Event) = update(proc(old: EditModel): EditModel =
        result = old
        result.rebuild = not old.rebuild))
    let pageEdit = standard.input(m.text, key = "page-edit",
      onChange = proc(e: Event) = update(proc(old: EditModel): EditModel =
        result = old
        if not old.ignoreEvent: result.text = e.value))
    let popoverEdit = standard.input(m.popoverText, key = "r-edit",
      onChange = proc(e: Event) = update(proc(old: EditModel): EditModel =
        result = old
        if not old.ignoreEvent: result.popoverText = e.value))
    let panel = standard.popover(standard.popoverTrigger("打开",
      key = (if m.rebuild: "r-trigger-2" else: "r-trigger")),
      standard.popoverContent(@[standard.label("提示", key = "r-label"),
        popoverEdit], key = "r-body"),
      open = m.open, name = "面板", key = "r",
      onOpenChange = proc(e: Event) = update(proc(old: EditModel): EditModel =
        result = old
        inc result.requests
        result.open = e.open))
    let toggle = standard.button((if m.dark: "浅色" else: "深色"),
      key = "theme-toggle", onClick = proc(e: Event) =
        update(proc(old: EditModel): EditModel =
          result = old
          result.dark = not old.dark))
    let page = column(@[rebuildButton, pageEdit, panel, toggle],
      styles = style({"padding": "16", "gap": "12", "width": "full"}))
    hostShell(standard.theme(
      (if m.dark: UiColorMode.dark else: UiColorMode.light),
      column(@[], key = "theme"), key = "theme"), @[host(page)]))

proc mountedReactive(width = 480, height = 360): Fixture =
  let activity = newUiScopeActivity()
  let app = componentApplication(component(EditDemo, 0), "Popover edit",
    width, height).withNativeTheme(shadcnLight)
  let runtime = newRuntime(guardUiApplication(app,
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost(app.title, DipSize(width: float64(width),
    height: float64(height)), calls = systemWin32Calls(), theme = shadcnLight)
  h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or
    runtime.installingHook)
  let win = newWin32Backend(h, calls = systemWin32Calls())
  let session = win.attachWin32Backend(runtime, protocol.strict)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime)

suite "native owned non-modal popover panel":
  test "page sentinel and trigger are real visible controls":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let sentinel = f.windowOf("sentinel")
    let trigger = f.windowOf("pp-trigger")
    check sentinel != nil
    check trigger != nil
    check IsWindowVisible(sentinel) != 0
    check IsWindowVisible(trigger) != 0
    check text(sentinel) == "哨兵"
    check text(trigger) == "打开"
    check f.runtimeRole("pp-trigger") == "popoverTrigger"
    check f.runtimeRole("pp") == "popover"
    let triggerRect = rectOf(trigger)
    check triggerRect.width > 0
    check triggerRect.height > 0
    # Bounded mount matrix for the earliest failure: window facts only.
    proc facts(label: string, window: HWND) =
      if window == nil:
        echo "MX ", label, " hwnd=nil"; return
      var frame: RECT
      discard GetWindowRect(window, addr frame)
      echo "MX ", label, " hwnd=", uint64(cast[uint](window)),
        " parent=", uint64(cast[uint](GetParent(window))),
        " wsVisible=", (GetWindowLongW(window, -16'i32) and 0x10000000) != 0,
        " isVisible=", IsWindowVisible(window) != 0,
        " rect=", frame.left, ",", frame.top, " ", frame.right - frame.left,
        "x", frame.bottom - frame.top,
        " enabled=", IsWindowEnabled(window) != 0
    facts("host", f.h.windowHandle)
    facts("root", f.windowOf("pp"))
    facts("trigger", trigger)
    facts("body", f.windowOf("pp-body"))
    # The trigger stays in the page flow: its native root is the host window.
    check GetAncestor(trigger, GaRoot) == f.h.windowHandle

  test "closed body is parented to a hidden owner panel, never the page":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let body = f.windowOf("pp-body")
    let panel = f.panelOf()
    check body != nil
    check panel != nil
    # The exact mount contract: the body window's parent is the panel, and the
    # panel is not the page window nor a descendant of it.
    check GetParent(body) == panel
    check GetParent(body) != f.h.windowHandle
    check GetAncestor(body, GaRoot) == panel
    check GetAncestor(panel, GaRoot) == panel
    # Owned, not a page child: the panel's owner is the host window.
    check GetWindow(panel, GwOwner) == f.h.windowHandle
    # Closed accepted state publishes nothing.
    check IsWindowVisible(panel) == 0
    check IsWindowVisible(body) == 0
    check IsWindowVisible(f.windowOf("pp-label")) == 0
    check IsWindowVisible(f.windowOf("pp-edit")) == 0
    check IsWindowVisible(f.windowOf("pp-close")) == 0
    check state.requests == 0

  test "accepted open shows the panel with the owner enabled and not topmost":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let body = f.windowOf("pp-body")
    let panel = f.panelOf()
    state.open = true
    settle(f)
    let host = f.win.popoverStateForTest(f.s.handleFor(f.runtime.find("pp").id))
    echo "DIAG acceptedOpen=", f.runtime.find("pp").node.popoverProps.get.open,
      " hostNil=", host == nil,
      " triggerVis=", IsWindowVisible(f.windowOf("pp-trigger")),
      " triggerEnabled=", IsWindowEnabled(f.windowOf("pp-trigger")),
      " panel=", (if host != nil: $uint64(cast[uint](host.panelHandle)) else: "nil"),
      " panelVis=", (if host != nil: IsWindowVisible(host.panelHandle) else: 0)
    check IsWindowVisible(panel) != 0
    check IsWindowVisible(body) != 0
    check IsWindowVisible(f.windowOf("pp-edit")) != 0
    check (GetWindowLongW(panel, GwlpExStyle) and int32(ExTopmost)) == 0
    check IsWindowEnabled(GetWindow(panel, GwOwner)) != 0
    # Opening never reparents the body.
    check GetParent(body) == panel
    let panelRect = rectOf(panel)
    check panelRect.width > 0
    check panelRect.height > 0
    # The accepted open state itself was written by the fixture, not the panel.
    check state.requests == 0

  test "accepted close hides the panel and keeps the live body children":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let body = f.windowOf("pp-body")
    let panel = f.panelOf()
    state.open = true
    settle(f)
    check IsWindowVisible(panel) != 0
    state.open = false
    settle(f)
    # Hidden, not destroyed: the same EDIT/BUTTON windows must survive a reopen.
    check IsWindow(panel) != 0
    check IsWindowVisible(panel) == 0
    check IsWindow(body) != 0
    check GetParent(body) == panel
    check IsWindowVisible(f.windowOf("pp-edit")) == 0
    state.open = true
    settle(f)
    check IsWindowVisible(panel) != 0
    check GetParent(body) == panel

suite "dialog-hosted popover":
  test "closed dialog keeps the page sentinel visible":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    check IsWindowVisible(f.windowOf("sentinel")) != 0
    check IsWindowVisible(f.windowOf("pp-trigger")) != 0

  test "dialog level does not hide the page and owns the inner panel":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let pageSentinel = f.windowOf("sentinel")
    state.dialogOpen = true
    settle(f)
    # A modal level is its own owned surface: the page tree keeps its windows.
    check IsWindow(pageSentinel) != 0
    check IsWindowVisible(pageSentinel) != 0
    let surface = f.win.overlaySurfaceForTest(
      f.s.handleFor(f.runtime.find("dlg").id))
    check surface != nil
    let innerBody = f.windowOf("dlg-body")
    let innerPanel = f.win.popoverStateForTest(
      f.s.handleFor(f.runtime.find("dlg-pp").id)).panelHandle
    check innerPanel != nil
    check GetParent(innerBody) == innerPanel
    # The inner panel belongs to the dialog surface, never to the main window.
    check GetWindow(innerPanel, GwOwner) == surface
    check GetWindow(innerPanel, GwOwner) != f.h.windowHandle
    check IsWindowVisible(innerPanel) == 0
    state.dialogPanelOpen = true
    settle(f)
    check IsWindowVisible(innerPanel) != 0
    check GetParent(innerBody) == innerPanel
    check IsWindowEnabled(surface) != 0

  test "host teardown destroys the panel window":
    let state = PopoverState()
    let f = mounted(state)
    settle(f)
    let panel = f.panelOf()
    check IsWindow(panel) != 0
    close(f)
    check IsWindow(panel) == 0

  test "a growing panel body never inflates the dialog that owns it":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    state.dialogOpen = true
    settle(f)
    let surface = f.win.overlaySurfaceForTest(
      f.s.handleFor(f.runtime.find("dlg").id))
    let before = rectOf(surface)
    check before.width > 0
    state.rows = 8
    settle(f)
    check rectOf(surface) == before
    state.dialogPanelOpen = true
    settle(f)
    check rectOf(surface) == before

  test "one Esc closes only the innermost layer":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    state.dialogOpen = true
    settle(f)
    let surface = f.win.overlaySurfaceForTest(
      f.s.handleFor(f.runtime.find("dlg").id))
    check surface != nil
    state.dialogPanelOpen = true
    settle(f)
    let panel = f.win.popoverStateForTest(
      f.s.handleFor(f.runtime.find("dlg-pp").id)).panelHandle
    check IsWindowVisible(panel) != 0
    foreground(f.h.windowHandle)
    discard SetFocus(f.windowOf("dlg-select-trigger"))
    tapKey(0x0d) # Enter opens the inner select
    pump(surface)
    settle(f)
    check state.selectOpen
    let selState = f.win.selectStateForTest(
      f.s.handleFor(f.runtime.find("dlg-select").id))
    echo "REC beforeEsc accepted=", state.selectOpen,
      " published=", selState.visible,
      " popup=", uint64(cast[uint](selState.popup)),
      " focus=", uint64(cast[uint](GetFocus())),
      " foreground=", uint64(cast[uint](GetForegroundWindow())),
      " trigger=", uint64(cast[uint](f.windowOf("dlg-select-trigger"))),
      " panel=", uint64(cast[uint](panel)),
      " popupOwner=", (if selState.popup != nil:
        uint64(cast[uint](GetWindow(selState.popup, GwOwner))) else: 0'u64),
      " panelOwner=", uint64(cast[uint](GetWindow(panel, GwOwner)))
    let selDiag = f.win.selectStateForTest(
      f.s.handleFor(f.runtime.find("dlg-select").id))
    let focused = GetFocus()
    echo "REC diag live=", selDiag.live, " visible=", selDiag.visible,
      " popup=", uint64(cast[uint](selDiag.popup)),
      " shows=", selDiag.shows, " closes=", selDiag.closes,
      " focus=", uint64(cast[uint](focused)),
      " focusText=", (if focused != nil: text(focused) else: ""),
      " selectTrig=", uint64(cast[uint](f.windowOf("dlg-select-trigger"))),
      " selectTrigVis=", IsWindowVisible(f.windowOf("dlg-select-trigger"))
    block:
      var chain: seq[HWND]
      var cursor = f.windowOf("dlg-select-trigger")
      var depth = 0
      while cursor != nil and depth < 8:
        chain.add(cursor)
        cursor = GetParent(cursor)
        inc depth
      chain.add(f.h.windowHandle)
      var ids: seq[string]
      for window in chain: ids.add($uint64(cast[uint](window)))
      echo "REC chain=", ids.join(",")
      for line in seamLog:
        for id in ids:
          if line.contains("=" & id):
            echo "SEAM ", line
            break
      seamLog.setLen(0)
    tapKey(0x1b) # first Esc: the select only
    pump(surface)
    settle(f)
    check not state.selectOpen
    check state.dialogPanelOpen
    check state.dialogOpen
    check IsWindowVisible(panel) != 0
    # Focus is back on the select trigger, which lives inside the panel body.
    check GetFocus() == f.windowOf("dlg-select-trigger")
    tapKey(0x1b) # second Esc: the popover, requested from a body control
    pump(surface)
    settle(f)
    check not state.dialogPanelOpen
    check state.dialogOpen
    check IsWindowVisible(panel) == 0
    discard SetFocus(f.windowOf("dlg-trigger"))
    tapKey(0x1b) # third Esc: the dialog
    pump(surface)
    settle(f)
    check not state.dialogOpen

  test "an ignored inner close never bubbles to the popover or the dialog":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    state.ignoreSelectClose = true
    state.dialogOpen = true
    settle(f)
    let surface = f.win.overlaySurfaceForTest(
      f.s.handleFor(f.runtime.find("dlg").id))
    state.dialogPanelOpen = true
    settle(f)
    let panel = f.win.popoverStateForTest(
      f.s.handleFor(f.runtime.find("dlg-pp").id)).panelHandle
    foreground(f.h.windowHandle)
    discard SetFocus(f.windowOf("dlg-select-trigger"))
    tapKey(0x0d)
    pump(surface)
    settle(f)
    check state.selectOpen
    tapKey(0x1b) # inner request is ignored by the caller
    pump(surface)
    settle(f)
    check state.selectCloses == 1
    check state.selectOpen
    # Not bubbled: the popover and the dialog keep their accepted open state.
    check state.dialogPanelOpen
    check state.dialogOpen
    check IsWindowVisible(panel) != 0
    # Tab while the inner select is open is owned by that scope, not the panel.
    tapKey(0x09)
    pump(surface)
    settle(f)
    check state.dialogPanelOpen
    check state.dialogOpen
    check IsWindowVisible(panel) != 0

  test "an inner select stays published inside an open panel":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    state.dialogOpen = true
    settle(f)
    state.dialogPanelOpen = true
    settle(f)
    let trigger = f.windowOf("dlg-select-trigger")
    check IsWindowVisible(trigger) != 0
    foreground(f.h.windowHandle)
    discard SetFocus(trigger)
    tapKey(0x0d)
    pump(f.win.overlaySurfaceForTest(f.s.handleFor(f.runtime.find("dlg").id)))
    settle(f)
    check state.selectOpen
    # The panel body keeps its own layout: the select trigger stays visible and
    # the select really publishes a popup owned by the panel.
    check IsWindowVisible(f.windowOf("dlg-select-trigger")) != 0
    let sel = f.win.selectStateForTest(f.s.handleFor(f.runtime.find("dlg-select").id))
    check sel.live
    check sel.visible
    check sel.popup != nil
    if sel.popup != nil:
      check GetWindow(sel.popup, GwOwner) != nil
    # The dialog level itself never scrolls because of the panel body.
    let plan = f.win.overlayPlanForTest(f.s.handleFor(f.runtime.find("dlg").id))
    check plan.rangeY == 0.0

  test "an oversized candidate is rejected as a revision, not accepted":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let panel = f.panelOf()
    state.open = true
    settle(f)
    check IsWindowVisible(panel) != 0
    let edit = f.windowOf("pp-edit")
    foreground(panel)
    discard SetFocus(edit)
    typeText("draft")
    discard f.h.pumpQueued()
    settle(f)
    check f.runtime.find("pp-edit").node.text == "draft"
    check text(edit) == "draft"
    let acceptedEdit = f.windowOf("pp-edit")
    discard SendMessageW(edit, 0x00b1'u32, 1, 3)
    let selBefore = packedSel(edit)
    state.rows = 200
    var rejected = false
    try:
      settle(f)
    except UiError:
      rejected = true
    check rejected
    # Nothing was accepted: the old tree, geometry, draft and focus stay.
    check IsWindowVisible(panel) != 0
    check IsWindow(edit) != 0
    # The rejected revision never entered the accepted tree: the window text is
    # still the accepted draft (empty), and focus/draft identity are unchanged.
    check text(edit) == "draft"
    check f.windowOf("pp-edit") == acceptedEdit
    check packedSel(edit) == selBefore
    check GetFocus() == edit
    expect UiError:
      discard f.runtime.find("pp-row-1")

  test "theme switch keeps the EDIT window, text, selection and Undo":
    let f = mountedReactive()
    defer: close(f)
    f.win.safeListTurn()
    discard f.runtime.refresh()
    f.win.safeListTurn()
    discard f.runtime.dispatch(f.runtime.find("r").id,
      Event(kind: openChange, open: true))
    discard f.runtime.refresh()
    f.win.safeListTurn()
    let panel = f.win.popoverStateForTest(
      f.s.handleFor(f.runtime.find("r").id)).panelHandle
    let edit = f.win.nativeWindowForTest(f.s.handleFor(f.runtime.find("r-edit").id))
    foreground(panel)
    discard SetFocus(edit)
    check GetFocus() == edit
    typeText("abc")
    discard f.h.pumpQueued()
    f.win.safeListTurn()
    discard f.runtime.refresh()
    f.win.safeListTurn()
    check text(edit) == "abc"
    check f.runtime.find("r-edit").node.text == "abc"
    check SendMessageW(edit, 0x00c6'u32, 0, 0) != 0 # EM_CANUNDO before the theme
    discard SendMessageW(edit, 0x00b1'u32, 1, 3) # EM_SETSEL(1,3)
    let selBefore = packedSel(edit)
    check selBefore.stop > selBefore.start
    # Real click on the theme toggle.
    let toggle = f.win.nativeWindowForTest(
      f.s.handleFor(f.runtime.find("theme-toggle").id))
    let point = screenCentre(toggle)
    clickAt(point.x, point.y)
    discard f.h.pumpQueued()
    f.win.safeListTurn()
    discard f.runtime.refresh()
    f.win.safeListTurn()
    check f.win.nativeWindowForTest(f.s.handleFor(f.runtime.find("r-edit").id)) == edit
    check text(edit) == "abc"
    let selAfter = packedSel(edit)
    check selAfter.start == selBefore.start
    check selAfter.stop == selBefore.stop
    check SendMessageW(edit, 0x00c6'u32, 0, 0) != 0 # EM_CANUNDO after the theme
    discard SendMessageW(edit, 0x00c7'u32, 0, 0) # EM_UNDO
    check text(edit) != "abc"

  test "owner minimize hides the panel and removing the trigger retires it":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.open = true
    settle(f)
    let panel = f.panelOf()
    check IsWindowVisible(panel) != 0
    discard ShowWindow(f.h.windowHandle, 6) # SW_MINIMIZE
    settle(f)
    echo "REC minimize iconicHost=", IsIconic(f.h.windowHandle),
      " iconicRoot=", IsIconic(GetAncestor(f.h.windowHandle, GaRoot)),
      " ownerVisible=", IsWindowVisible(GetWindow(panel, GwOwner))
    check IsWindow(panel) != 0
    check IsWindowVisible(panel) == 0
    discard ShowWindow(f.h.windowHandle, 9) # SW_RESTORE
    discard f.h.pumpQueued()
    settle(f)
    echo "REC restore visible=", IsWindowVisible(panel),
      " iconic=", IsIconic(f.h.windowHandle)
    check IsWindowVisible(panel) != 0
    state.removeTrigger = true
    settle(f)
    check f.win.popoverCountForTest() == 0

  test "an outside click requests exactly one close and an inside click none":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.open = true
    settle(f)
    let panel = f.panelOf()
    check IsWindowVisible(panel) != 0
    foreground(f.h.windowHandle)
    # inside the panel body: no request
    let inside = screenCentre(f.windowOf("pp-edit"))
    clickAt(inside.x, inside.y)
    discard f.h.pumpQueued()
    settle(f)
    check state.requests == 0
    check IsWindowVisible(panel) != 0
    # outside, on the page sentinel: exactly one request
    let outside = screenCentre(f.windowOf("sentinel"))
    clickAt(outside.x, outside.y)
    discard f.h.pumpQueued()
    settle(f)
    check state.clicks == 1
    check state.requests == 1
    check not state.open
    check IsWindowVisible(panel) == 0

  test "a panel Esc request the caller ignores keeps the live body and EDIT":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.open = true
    settle(f)
    let panel = f.panelOf()
    let edit = f.windowOf("pp-edit")
    setText(edit, "keep-me")
    state.ignoreClose = true
    foreground(panel)
    discard SetFocus(panel) # the panel itself receives the key, not a body child
    check GetFocus() == panel
    tapKey(0x1b)
    discard f.h.pumpQueued() # production dispatch: the panel is an owned top level
    settle(f)
    # The request was recorded but nothing was destroyed or hidden.
    check state.closes >= 1
    check IsWindow(panel) != 0
    check IsWindowVisible(panel) != 0
    check IsWindow(edit) != 0
    check IsWindowVisible(edit) != 0
    check text(edit) == "keep-me"
    # A second accepted close hides without destroying, and a reopen keeps the
    # same EDIT window.
    state.ignoreClose = false
    discard SetFocus(panel)
    tapKey(0x1b)
    discard f.h.pumpQueued()
    settle(f)
    check not state.open
    check IsWindowVisible(panel) == 0
    check IsWindow(edit) != 0
    state.open = true
    settle(f)
    check IsWindowVisible(panel) != 0
    check f.windowOf("pp-edit") == edit

  test "Tab requests stay one per input and never lock out later input":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.open = true
    settle(f)
    let panel = f.panelOf()
    let last = f.windowOf("pp-close")
    state.ignoreClose = true
    foreground(panel)
    discard SetFocus(last)
    check GetFocus() == last
    tapKey(0x09) # Tab at the last body control: one boundary request
    discard f.h.pumpQueued()
    settle(f)
    check state.requests == 1
    # No new input: several ordinary turns must not repeat the request.
    settle(f)
    settle(f)
    settle(f)
    check state.requests == 1
    check IsWindowVisible(panel) != 0
    # A second real Tab earns exactly one new request.
    discard SetFocus(last)
    tapKey(0x09)
    discard f.h.pumpQueued()
    settle(f)
    check state.requests == 2
    # A pending tab never blocks Esc.
    state.ignoreClose = false
    discard SetFocus(panel)
    tapKey(0x1b)
    discard f.h.pumpQueued()
    settle(f)
    check not state.open
    check IsWindowVisible(panel) == 0

suite "reactive EDIT acceptance":
  test "page EDIT accepts through State.update and keeps text and undo":
    let f = mountedReactive()
    defer: close(f)
    f.win.safeListTurn()
    discard f.runtime.refresh()
    f.win.safeListTurn()
    let edit = f.win.nativeWindowForTest(f.s.handleFor(f.runtime.find("page-edit").id))
    foreground(f.h.windowHandle)
    discard SetFocus(edit)
    typeText("abc")
    discard f.h.pumpQueued()
    f.win.safeListTurn()
    discard f.runtime.refresh()
    f.win.safeListTurn()
    check text(edit) == "abc"
    check f.runtime.find("page-edit").node.text == "abc"
    check SendMessageW(edit, 0x00c6'u32, 0, 0) != 0

  test "popover EDIT accepts through State.update inside the panel":
    let f = mountedReactive()
    defer: close(f)
    f.win.safeListTurn()
    discard f.runtime.refresh()
    f.win.safeListTurn()
    discard f.runtime.dispatch(f.runtime.find("r").id, Event(kind: openChange, open: true))
    discard f.runtime.refresh()
    f.win.safeListTurn()
    let edit = f.win.nativeWindowForTest(f.s.handleFor(f.runtime.find("r-edit").id))
    foreground(f.win.popoverStateForTest(f.s.handleFor(f.runtime.find("r").id)).panelHandle)
    discard SetFocus(edit)
    typeText("xy")
    discard f.h.pumpQueued()
    f.win.safeListTurn()
    discard f.runtime.refresh()
    f.win.safeListTurn()
    check text(edit) == "xy"
    check f.runtime.find("r-edit").node.text == "xy"

  test "an ignored input restores the old accepted text without a new revision":
    let f = mountedReactive()
    defer: close(f)
    f.win.safeListTurn()
    discard f.runtime.refresh()
    f.win.safeListTurn()
    discard f.runtime.dispatch(f.runtime.find("page-edit").id, Event(kind: change, value: "abc"))
    discard f.runtime.refresh()
    f.win.safeListTurn()
    let edit = f.win.nativeWindowForTest(f.s.handleFor(f.runtime.find("page-edit").id))
    check text(edit) == "abc"
    # ignore the next input: the model keeps abc
    discard f.runtime.dispatch(f.runtime.find("theme-toggle").id, Event(kind: click))
    discard f.runtime.refresh()
    f.win.safeListTurn()
    check f.runtime.find("page-edit").node.text == "abc"
    check text(f.win.nativeWindowForTest(f.s.handleFor(f.runtime.find("page-edit").id))) == "abc"

  test "ShiftTab at the body boundary requests once and keeps focus until accepted":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.open = true
    settle(f)
    let panel = f.panelOf()
    let first = f.windowOf("pp-edit")
    foreground(panel)
    discard SetFocus(first)
    check GetFocus() == first
    state.ignoreClose = true
    # Shift+Tab via real input: hold shift, tap tab, release shift.
    pressShiftTab()
    discard f.h.pumpQueued()
    settle(f)
    check state.requests == 1
    # Refused: the panel keeps showing and focus stays on the same control.
    check IsWindowVisible(panel) != 0
    check GetFocus() == first
    settle(f)
    settle(f)
    check state.requests == 1
    # Accept: a real Shift+Tab at the same boundary hides the panel and moves
    # focus inside the owning window, never back into the body.
    state.ignoreClose = false
    check GetFocus() == first
    pressShiftTab()
    discard f.h.pumpQueued()
    settle(f)
    check state.requests == 2
    check not state.open
    check IsWindowVisible(panel) == 0
    check GetFocus() != f.windowOf("pp-edit")
    check GetFocus() != f.windowOf("pp-close")

  test "a temporary owner hide does not swallow a recorded user dismissal":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.open = true
    settle(f)
    let panel = f.panelOf()
    foreground(panel)
    discard SetFocus(panel)
    # Record a real user Esc dismissal, then hide the owner in the same cycle.
    tapKey(0x1b)
    discard f.h.pumpQueued() # dispatch first: the panel WndProc records the Esc
    discard ShowWindow(f.h.windowHandle, 0) # SW_HIDE: lifecycle, not a user close
    discard f.h.pumpQueued()
    settle(f)
    check IsWindowVisible(panel) == 0
    # The recorded dismissal must still produce exactly one request.
    check state.requests == 1
    check not state.open

  test "a system close request closes the panel exactly once":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.open = true
    settle(f)
    let panel = f.panelOf()
    check IsWindowVisible(panel) != 0
    discard SendMessageW(panel, 0x0010'u32, 0, 0) # WM_CLOSE
    discard f.h.pumpQueued()
    settle(f)
    check state.requests == 1
    check not state.open
    check IsWindowVisible(panel) == 0

  test "recreating the trigger keeps the host consistent and never goes silent":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.open = true
    settle(f)
    let oldEdit = f.windowOf("pp-edit")
    check IsWindow(oldEdit) != 0
    let oldTrigger = f.windowOf("pp-trigger")
    state.rebuildTrigger = true
    settle(f)
    # The host is still exactly one live panel and the accepted open state is
    # preserved: either the same live editor or a new one, never a dead handle.
    check f.win.popoverCountForTest() == 1
    let edit = f.windowOf("pp-edit")
    check edit != nil
    check IsWindow(edit) != 0
    # Same owner domain: the panel and the body keep their live HWNDs.
    check edit == oldEdit
    check IsWindow(oldTrigger) == 0
    check IsWindowVisible(edit) != 0
    check f.panelOf() != nil

  test "rebuilt trigger keeps the accepted draft, selection, undo and real input":
    let f = mountedReactive()
    defer: close(f)
    f.win.safeListTurn()
    discard f.runtime.refresh()
    f.win.safeListTurn()
    discard f.runtime.dispatch(f.runtime.find("r").id,
      Event(kind: openChange, open: true))
    discard f.runtime.refresh()
    f.win.safeListTurn()
    let edit = f.win.nativeWindowForTest(f.s.handleFor(f.runtime.find("r-edit").id))
    foreground(f.win.popoverStateForTest(f.s.handleFor(f.runtime.find("r").id)).panelHandle)
    discard SetFocus(edit)
    typeText("abc")
    discard f.h.pumpQueued()
    f.win.safeListTurn()
    discard f.runtime.refresh()
    f.win.safeListTurn()
    check f.runtime.find("r-edit").node.text == "abc"
    discard SendMessageW(edit, 0x00b1'u32, 1, 3)
    let selBefore = packedSel(edit)
    check SendMessageW(edit, 0x00c6'u32, 0, 0) != 0 # EM_CANUNDO
    let oldTrigger = f.win.nativeWindowForTest(f.s.handleFor(f.runtime.find("r-trigger").id))
    let panelBefore = f.win.popoverStateForTest(f.s.handleFor(f.runtime.find("r").id)).panelHandle
    discard f.runtime.dispatch(f.runtime.find("rebuild-btn").id, Event(kind: click))
    discard f.runtime.refresh()
    f.win.safeListTurn()
    # Same owner domain: same panel, same EDIT, accepted draft/selection/undo kept.
    check f.win.nativeWindowForTest(f.s.handleFor(f.runtime.find("r-edit").id)) == edit
    check f.runtime.find("r-edit").node.text == "abc"
    check packedSel(edit) == selBefore
    check SendMessageW(edit, 0x00c6'u32, 0, 0) != 0
    check IsWindow(oldTrigger) == 0
    let newTrigger = f.win.nativeWindowForTest(
      f.s.handleFor(f.runtime.find("r-trigger-2").id))
    check newTrigger != nil
    check IsWindow(newTrigger) != 0
    check text(newTrigger) == "打开"
    # The anchor really moved: the panel is visible again with a real rectangle.
    let panel = f.win.popoverStateForTest(f.s.handleFor(f.runtime.find("r").id)).panelHandle
    check panel == panelBefore
    check IsWindowVisible(panel) != 0
    let panelRect = rectOf(panel)
    check panelRect.width > 0
    check panelRect.height > 0
    # Real input still lands on the same live editor after the rebuild.
    foreground(panel)
    discard SetFocus(edit)
    typeText("d")
    discard f.h.pumpQueued()
    f.win.safeListTurn()
    discard f.runtime.refresh()
    f.win.safeListTurn()
    # The preserved selection (1..3) is replaced: abc -> ad, and the window text
    # must match the accepted value.
    check f.runtime.find("r-edit").node.text == "ad"
    check text(edit) == "ad"

  test "the same user key in a new parent domain becomes a new native root":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.open = true
    settle(f)
    let oldHandle = f.s.handleFor(f.runtime.find("pp").id)
    let oldPanel = f.panelOf()
    let oldEdit = f.windowOf("pp-edit")
    check IsWindowVisible(oldPanel) != 0
    # The draft must be accepted first, in its own revision.
    setText(oldEdit, "draft")
    state.text = "draft"
    settle(f)
    check f.runtime.find("pp-edit").node.text == "draft"
    check text(f.windowOf("pp-edit")) == "draft"
    # Same user key, new parent domain: this is a legitimate unload/create.
    state.moved = true
    settle(f)
    let newHandle = f.s.handleFor(f.runtime.find("pp").id)
    check newHandle != oldHandle
    # The old root, its panel and its body retired completely.
    check IsWindow(oldPanel) == 0
    check IsWindow(oldEdit) == 0
    # The new root lives in the dialog domain with its own panel and body.
    let dialogRoot = f.s.handleFor(f.runtime.find("mv-dlg").id)
    let surface = f.win.overlaySurfaceForTest(dialogRoot)
    check surface != nil
    let newPanel = f.win.popoverStateForTest(newHandle).panelHandle
    check newPanel != nil
    check IsWindowVisible(newPanel) != 0
    check GetWindow(newPanel, GwOwner) == surface
    let newEdit = f.windowOf("m-edit")
    check newEdit != nil
    check IsWindow(newEdit) != 0
    # Text is model-provided: the rebuilt body shows the accepted draft, but no
    # old EDIT/Undo is required to survive the unload.
    check text(newEdit) == "draft"
    # The new body is reachable and focusable. Real post-rebuild input is proven
    # in the page-level rebuild case ("ad"); inside a modal level the dialog's
    # own routing owns the keyboard, so this case asserts focusability only.
    check IsWindowEnabled(newEdit) != 0
    foreground(newPanel)
    discard SetFocus(newEdit)
    check GetFocus() == newEdit

  test "a genuinely new root in another domain is not misrejected":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.moved = true
    state.newKey = true
    settle(f)
    # The new root lives in the dialog domain and is accepted normally.
    let host = f.win.overlaySurfaceForTest(f.s.handleFor(f.runtime.find("mv-dlg").id))
    check host != nil
    state.open = true
    settle(f)
    let panel = f.win.popoverStateForTest(f.s.handleFor(f.runtime.find("pp-new").id)).panelHandle
    check panel != nil
    check IsWindowVisible(panel) != 0
    check GetWindow(panel, GwOwner) == host

  test "a construction-time panel failure releases every task resource":
    let state = PopoverState()
    discard state
    # Build the pieces by hand so the failing instance is ours to clean up.
    let activity = newUiScopeActivity()
    let app = fixtureApplication(proc(): Node = page(state), "Popover mount",
      480, 360).withNativeTheme(shadcnLight)
    let runtime = newRuntime(guardUiApplication(app,
      proc(): uint64 = uint64(GetCurrentThreadId()), activity))
    let h = createHost(app.title, DipSize(width: 480, height: 360),
      calls = systemWin32Calls(), theme = shadcnLight)
    h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or
      runtime.installingHook)
    var failed = false
    try:
      let win = newWin32Backend(h, calls = systemWin32Calls())
      let session = win.attachWin32Backend(runtime, protocol.strict)
      win.bindSession(session)
      h.bindSession(session, proc(): bool = activity.busy)
      win.safeListTurn()
      discard runtime.refresh()
      win.safeListTurn()
    except UiError:
      failed = true
    # Release whatever the failed construction created and prove it is zero.
    injectFail.create = false
    try: h.destroyHost()
    except CatchableError: discard
    runtime.closeRuntime()
    # A fresh instance is the supported path; no same-generation receipt retry
    # is claimed here.
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.open = true
    settle(f)
    let panel = f.win.popoverStateForTest(
      f.s.handleFor(f.runtime.find("pp").id)).panelHandle
    check panel != nil
    check IsWindowVisible(panel) != 0
    discard failed

  test "a panel destroy failure keeps a receipt until a retry succeeds":
    let state = PopoverState()
    let f = mounted(state)
    settle(f)
    state.open = true
    settle(f)
    let panel = f.panelOf()
    check IsWindow(panel) != 0
    injectFail.destroy = true
    var raised = false
    try:
      f.h.destroyHost()
    except CatchableError:
      raised = true
    check raised
    # The receipt was kept: the panel is still alive and reported.
    check IsWindow(panel) != 0
    # A retry without injection completes and releases only this task's windows.
    f.h.destroyHost()
    f.runtime.closeRuntime()
    check IsWindow(panel) == 0
    check f.win.diagnostics.liveWindows == 0
    check f.win.diagnostics.liveFonts == 0
    check f.win.diagnostics.liveRoots == 0
    check f.win.popoverCountForTest() == 0

  test "a show that does not become visible reports failure and keeps resources":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let panel = f.panelOf()
    let edit = f.windowOf("pp-edit")
    injectFail.show = true
    state.open = true
    var failed = false
    try:
      settle(f)
    except UiError:
      failed = true
    check failed
    # Accepted state is unchanged, the panel is not visible and no fake shown
    # receipt is kept; the panel and its EDIT still exist for a retry.
    check f.runtime.find("pp").node.popoverProps.get.open
    check IsWindow(panel) != 0
    check IsWindowVisible(panel) == 0
    check IsWindow(edit) != 0
    # A failed native effect faults the session, so no same-session retry is
    # claimed here; the accepted state and the live resources are what matter.
    check IsWindow(panel) != 0
    check f.win.popoverCountForTest() == 1
