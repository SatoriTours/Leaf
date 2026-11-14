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
proc WindowFromPoint(point: POINT): HWND
proc GetClassNameW(window: HWND, text: pointer, max: int32): int32
{.pop.}

{.push stdcall, dynlib: "gdi32.dll", importc, raises: [].}
proc GetPixel(dc: HDC, x, y: int32): uint32
{.pop.}

var seamLog: seq[string]
# One-shot native refusals plus the real attempt counts, so a fault case can
# prove the injected failure was hit and that the receipts it created were
# released again. Nothing here is a product branch: every refusal is a real nil
# HWND / FALSE result with a real Win32 error code.
var injectFail = (create: false, destroy: false, show: false, unregister: false,
  setProp: false, redraw: false)
var injectDestroyTarget: HWND
var injectDestroyPanel = false
var seamAttempts = (register: 0, unregister: 0, create: 0, destroy: 0, show: 0,
  setProp: 0, redraw: 0)
var seamRefused = (create: 0, destroy: 0, show: 0, unregister: 0, setProp: 0,
  redraw: 0)
var seamLastPanel: HWND

proc resetSeams() =
  injectFail = (create: false, destroy: false, show: false, unregister: false,
    setProp: false, redraw: false)
  injectDestroyTarget = nil
  injectDestroyPanel = false
  seamAttempts = (register: 0, unregister: 0, create: 0, destroy: 0, show: 0,
    setProp: 0, redraw: 0)
  seamRefused = (create: 0, destroy: 0, show: 0, unregister: 0, setProp: 0,
    redraw: 0)
  seamLastPanel = nil

proc isPanelClass(window: HWND): bool =
  ## True for this thread's owned popover panel class (ASCII prefix compare).
  if window == nil: return false
  var buffer: array[64, uint16]
  let count = GetClassNameW(window, addr buffer[0], int32(buffer.len))
  const prefix = "LeafPopoverPanel-"
  if count < prefix.len: return false
  for index, c in prefix:
    if buffer[index] != uint16(c): return false
  true

type
  PopoverState = ref object
    open, dialogOpen, dialogPanelOpen, selectOpen, dark: bool
    text, value: string
    requests, closes, dialogRequests, selectRequests, selectCloses: int
    clicks: int
    removeTrigger, rebuildTrigger: bool
    omitPopover: bool
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
  if not state.removeTrigger and not state.omitPopover:
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

proc injectedCalls(): Win32Calls =
  ## One spy layer over the real Win32 calls. It logs the panel show/place
  ## sequence, counts the panel class register/unregister attempts and refuses
  ## exactly one panel create/show/destroy on request. A refusal is a real
  ## native failure (nil HWND, FALSE, SetLastError 5), so the product's own
  ## failure branch is what the test observes.
  var calls = systemWin32Calls()
  let rawShow = calls.showWindow
  calls.showWindow = proc(window: HWND, command: int32): BOOL
      {.closure, raises: [CatchableError].} =
    let before = GetWindowLongW(window, -16'i32)
    inc seamAttempts.show
    result = rawShow(window, command)
    seamLog.add("showWindow hwnd=" & $uint64(cast[uint](window)) &
      " cmd=" & $command & " beforeWsVis=" & $((before and 0x10000000) != 0) &
      " afterVisible=" & $(IsWindowVisible(window) != 0))
  let loggingShow = calls.showWindow
  calls.showWindow = proc(window: HWND, command: int32): BOOL
      {.closure, raises: [CatchableError].} =
    ## A refused show returns TRUE-like success semantics but leaves the window
    ## hidden: the product, not this seam, must notice that nothing became
    ## visible. Only SW_SHOW is refused once; every other command passes
    ## through untouched.
    if injectFail.show and command == 5:
      injectFail.show = false
      inc seamRefused.show
      setLastError(5)
      seamLog.add("showWindow REFUSED hwnd=" & $uint64(cast[uint](window)) &
        " cmd=" & $command)
      return 1
    loggingShow(window, command)
  let rawPos = calls.windowPos
  calls.windowPos = proc(window, after: HWND, x, y, width, height: int32,
      flags: UINT): BOOL {.closure, raises: [CatchableError].} =
    result = rawPos(window, after, x, y, width, height, flags)
    seamLog.add("windowPos hwnd=" & $uint64(cast[uint](window)) &
      " flags=" & $uint64(flags) & " visible=" & $(IsWindowVisible(window) != 0))
  let rawCreate = calls.createWindow
  calls.createWindow = proc(exStyle: DWORD, className, windowName: WidePtr,
      style: DWORD, x, y, width, height: int32, parent: HWND, menu: HMENU,
      instance: HINSTANCE, param: pointer): HWND {.closure,
      raises: [CatchableError].} =
    if className != nil:
      # Match the panel class by ASCII prefix; no wide decoding needed.
      let units = cast[ptr UncheckedArray[uint16]](className)
      const prefix = "LeafPopoverPanel-"
      var match = true
      for i, c in prefix:
        if units[i] != uint16(c):
          match = false
          break
      if match:
        inc seamAttempts.create
        if injectFail.create:
          injectFail.create = false
          inc seamRefused.create
          setLastError(5)
          return nil
    result = rawCreate(exStyle, className, windowName, style, x, y, width, height,
      parent, menu, instance, param)
    if result != nil and className != nil:
      let units = cast[ptr UncheckedArray[uint16]](className)
      const prefix = "LeafPopoverPanel-"
      var match = true
      for i, c in prefix:
        if units[i] != uint16(c):
          match = false
          break
      if match: seamLastPanel = result
  let rawSetProp = calls.setProp
  calls.setProp = proc(window: HWND, name: WidePtr, data: HANDLE): BOOL
      {.closure, raises: [CatchableError].} =
    inc seamAttempts.setProp
    if injectFail.setProp:
      injectFail.setProp = false
      inc seamRefused.setProp
      setLastError(5)
      return 0
    rawSetProp(window, name, data)
  let rawRedraw = calls.redrawWindow
  calls.redrawWindow = proc(window: HWND, update: ptr RECT, region: HRGN,
      flags: UINT): BOOL {.closure, raises: [CatchableError].} =
    inc seamAttempts.redraw
    if injectFail.redraw:
      injectFail.redraw = false
      inc seamRefused.redraw
      setLastError(5)
      return 0
    rawRedraw(window, update, region, flags)
  let rawRegister = calls.registerClass
  calls.registerClass = proc(windowClass: ptr WNDCLASSEXW): ATOM
      {.closure, raises: [CatchableError].} =
    inc seamAttempts.register
    rawRegister(windowClass)
  let rawUnregister = calls.unregisterClass
  calls.unregisterClass = proc(name: WidePtr, instance: HINSTANCE): BOOL
      {.closure, raises: [CatchableError].} =
    inc seamAttempts.unregister
    if injectFail.unregister:
      injectFail.unregister = false
      inc seamRefused.unregister
      setLastError(5)
      return 0
    rawUnregister(name, instance)
  let rawDestroy = calls.destroyWindow
  calls.destroyWindow = proc(window: HWND): BOOL {.closure, raises: [CatchableError].} =
    inc seamAttempts.destroy
    if injectFail.destroy and ((injectDestroyTarget != nil and
        window == injectDestroyTarget) or (injectDestroyPanel and
        isPanelClass(window))):
      injectFail.destroy = false
      inc seamRefused.destroy
      setLastError(5)
      return 0
    rawDestroy(window)
  calls

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
  let win = newWin32Backend(h, calls = injectedCalls())
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

proc luminance(color: uint32): int =
  ## Real displayed pixel -> perceived brightness (COLORREF is 0x00BBGGRR).
  let r = int(color and 0xFF)
  let g = int((color shr 8) and 0xFF)
  let b = int((color shr 16) and 0xFF)
  (r * 299 + g * 587 + b * 114) div 1000

proc isAncestorOf(ancestor, window: HWND): bool =
  var current = GetParent(window)
  var depth = 0
  while current != nil and depth < 64:
    if current == ancestor: return true
    current = GetParent(current)
    inc depth

proc isSelfOrDescendant(window, ancestor: HWND): bool =
  var current = window
  var depth = 0
  while current != nil and depth < 64:
    if current == ancestor: return true
    current = GetParent(current)
    inc depth

proc screenSamples(window: HWND, includeChildren = false,
                    throughParent = false): seq[uint32] =
  ## Pixels actually on screen inside one window's client area, sampled only at
  ## points where that very window is the hit target: a covered or child-covered
  ## point is skipped instead of being reported as this window's color.
  var client: RECT
  if window == nil or GetClientRect(window, addr client) == 0: return
  let wide = client.right - client.left
  let high = client.bottom - client.top
  if wide < 8 or high < 8: return
  var origin = POINT(x: 0, y: 0)
  if ClientToScreen(window, addr origin) == 0: return
  let screen = GetDC(nil)
  if screen == nil: return
  try:
    for fy in [0.02, 0.25, 0.5, 0.75, 0.98]:
      for fx in [0.02, 0.1, 0.3, 0.5, 0.7, 0.9, 0.98]:
        let x = origin.x + int32(float64(wide) * fx)
        let y = origin.y + int32(float64(high) * fy)
        # A label/static control is hit-transparent, so the point may belong to
        # its parent while its pixels are still the child's own background. The
        # parent is only accepted for such a child (throughParent), never for the
        # panel itself, where child pixels must not be read as panel pixels.
        let hit = WindowFromPoint(POINT(x: x, y: y))
        var owned = hit == window
        if not owned and includeChildren and hit != nil and
            isSelfOrDescendant(hit, window):
          owned = true
        if not owned and throughParent and hit != nil and isAncestorOf(hit, window):
          owned = true
        if not owned: continue
        let color = GetPixel(screen, x, y)
        if color == 0xFFFFFFFF'u32: continue # CLR_INVALID
        result.add(color)
  finally:
    discard ReleaseDC(nil, screen)

proc classNameOf(window: HWND): string =
  var buffer: array[128, uint16]
  let count = GetClassNameW(window, addr buffer[0], int32(buffer.len))
  for index in 0 ..< max(0, count):
    result.add(char(buffer[index] and 0x7F))

proc dumpTree(window: HWND, depth: int) =
  ## Diagnostic only: the real child windows of one surface, their classes and
  ## client rectangles, so a "the panel is white" report can be attributed to the
  ## panel itself or to a child that paints over it.
  if window == nil or depth > 2: return
  let size = rectOf(window)
  echo "PANELTREE ", repeat(' ', depth), classNameOf(window),
    " hwnd=", uint64(cast[uint](window)), " size=", size.width, "x", size.height,
    " visible=", (if IsWindowVisible(window) != 0: 1 else: 0)
  var child = GetWindow(window, 5) # GW_CHILD
  var guard = 0
  while child != nil and guard < 32:
    dumpTree(child, depth + 1)
    child = GetWindow(child, 2) # GW_HWNDNEXT
    inc guard

proc dominantColor(window: HWND, includeChildren = false,
                     throughParent = false): uint32 =
  ## Most frequent sampled color: for a text control this is its background, not
  ## the glyph pixels.
  var counts: seq[tuple[color: uint32, count: int]]
  for color in screenSamples(window, includeChildren, throughParent):
    var found = false
    for entry in counts.mitems:
      if entry.color == color:
        inc entry.count
        found = true
        break
    if not found: counts.add((color, 1))
  var best = 0'u32
  var bestCount = 0
  for entry in counts:
    if entry.count > bestCount:
      best = entry.color
      bestCount = entry.count
  best

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

  test "dark theme repaints the panel surface, its label and its editor":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.open = true
    settle(f)
    discard f.h.pumpQueued() # real WM_PAINT for the first published frame
    let panel = f.panelOf()
    let label = f.windowOf("pp-label")
    let edit = f.windowOf("pp-edit")
    check IsWindowVisible(panel) != 0
    foreground(panel)
    discard SetFocus(edit)
    typeText("ab")
    discard f.h.pumpQueued()
    settle(f)
    check text(edit) == "ab"
    discard SendMessageW(edit, 0x00b1'u32, 0, 1) # EM_SETSEL(0,1)
    let selection = packedSel(edit)
    check selection.stop > selection.start
    # Undo presence is proven by the dedicated theme test; here the claim is that
    # a theme switch does not change the EDIT's undo state.
    let undoBefore = SendMessageW(edit, 0x00c6'u32, 0, 0) # EM_CANUNDO
    # --- light baseline: every surface is really light on screen --------------
    let lightPanel = dominantColor(panel, includeChildren = true)
    let lightLabel = dominantColor(label, throughParent = true)
    let lightEdit = dominantColor(edit)
    check lightPanel != 0'u32
    check lightLabel != 0'u32
    check lightEdit != 0'u32
    check luminance(lightPanel) > 200
    check luminance(lightLabel) > 200
    check luminance(lightEdit) > 200
    # The label must sit on the same surface the panel paints, not on a second
    # color source (surface vs canvas).
    check abs(int((lightPanel and 0xFF)) - int((lightLabel and 0xFF))) < 24
    # --- dark: the panel AND its children must repaint with the new theme ----
    state.dark = true
    settle(f)
    discard f.h.pumpQueued()
    check f.windowOf("pp-edit") == edit
    check text(edit) == "ab"
    check packedSel(edit) == selection
    check SendMessageW(edit, 0x00c6'u32, 0, 0) == undoBefore
    let darkPanel = dominantColor(panel, includeChildren = true)
    let darkLabel = dominantColor(label, throughParent = true)
    let darkEdit = dominantColor(edit)
    echo "THEME panel light=", lightPanel, " dark=", darkPanel,
      " label light=", lightLabel, " dark=", darkLabel,
      " edit light=", lightEdit, " dark=", darkEdit
    # One line of real displayed colors is the evidence for this test; the window
    # tree/children are only dumped when the panel region itself is suspicious.
    if luminance(darkPanel) >= 96:
      dumpTree(panel, 0)
    check luminance(darkPanel) < 96
    check luminance(darkLabel) < 96
    check luminance(darkEdit) < 96
    check abs(int((darkPanel and 0xFF)) - int((darkLabel and 0xFF))) < 24
    # --- back to light: the same windows repaint again -----------------------
    state.dark = false
    settle(f)
    discard f.h.pumpQueued()
    let againPanel = dominantColor(panel, includeChildren = true)
    let againLabel = dominantColor(label, throughParent = true)
    check luminance(againPanel) > 200
    check luminance(againLabel) > 200
    check f.windowOf("pp-edit") == edit
    check text(edit) == "ab"
    check packedSel(edit) == selection

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

  test "a rejected revision rolls back a failed panel create completely":
    # The popover root only exists in the candidate revision, so the failing
    # host is not covered by the ordinary teardown of an accepted tree: what the
    # assertions see after the failure is exactly what the aborted construction
    # left behind.
    let state = PopoverState()
    state.omitPopover = true
    let f = mounted(state)
    defer: close(f)
    settle(f)
    check f.win.popoverCountForTest() == 0
    resetSeams()
    injectFail.create = true
    state.omitPopover = false
    var message = ""
    try:
      settle(f)
    except UiError as error:
      message = error.msg
    # The refusal really reached the panel class exactly once and surfaced the
    # product's own native failure, not a test-only shortcut.
    check message.contains("CreateWindowExW popover panel failed: Win32 error 5")
    check message.contains("popover panel construction rolled back")
    check seamRefused.create == 1
    check seamAttempts.create == 1
    # Rollback is observable at the resource level: the class registered for
    # THIS panel was released again and no host receipt survives.
    check seamAttempts.register == 1
    check seamAttempts.unregister == 1
    check f.win.popoverCountForTest() == 0
    # Both the backend counter AND the callback cookie table are empty; a host
    # tracked by only one of them would leak silently.
    check popoverReceiptsForTest() == 0
    echo "SEAM destroy attempts after rollback=", seamAttempts.destroy
    # The rejected revision published nothing: the accepted tree has no popover
    # root, so no stale panel state is reachable through business lookups.
    expect UiError:
      discard f.runtime.find("pp")
    # The same session and mount generation then builds a NEW panel instance on
    # the next ordinary turn and can publish it (not a same-generation receipt
    # retry of the failed one).
    settle(f)
    check f.win.popoverCountForTest() == 1
    check f.win.diagnostics.popoverShows == 0
    state.open = true
    settle(f)
    let panel = f.panelOf()
    check panel != nil
    check IsWindowVisible(panel) != 0
    check IsWindow(f.windowOf("pp-edit")) != 0
    check f.win.diagnostics.popoverShows == 1

  test "a rollback that cannot unregister keeps the receipt and still tears down":
    # The rollback itself can fail (here: UnregisterClassW refused). The failed
    # construction must then keep its receipt instead of dropping a half-open
    # host silently, and teardown must still release everything.
    let state = PopoverState()
    state.omitPopover = true
    let f = mounted(state)
    settle(f)
    resetSeams()
    injectFail.create = true
    injectFail.unregister = true
    state.omitPopover = false
    var message = ""
    try:
      settle(f)
    except UiError as error:
      message = error.msg
    check seamRefused.create == 1
    check seamRefused.unregister == 1
    check message.contains("CreateWindowExW popover panel failed: Win32 error 5")
    check message.contains("popover panel rollback failed")
    check message.contains("UnregisterClassW popover panel")
    # Receipt kept and reported instead of a silent leak.
    check f.win.popoverCountForTest() == 1
    check popoverReceiptsForTest() == 1
    # Removing the popover while the receipt is still kept retires it through the
    # ordinary stale-drop path (a second UnregisterClassW attempt), which is the
    # documented recovery; no teardown shortcut is needed.
    state.omitPopover = true
    settle(f)
    check f.win.popoverCountForTest() == 0
    check popoverReceiptsForTest() == 0
    check seamAttempts.unregister >= 2
    check not f.s.faulted
    var teardown = ""
    try:
      f.h.destroyHost()
    except CatchableError as error:
      teardown = error.msg
    try:
      f.runtime.closeRuntime()
    except CatchableError as error:
      if teardown.len == 0: teardown = error.msg
    check teardown == ""
    # The retried teardown released the kept class receipt and every window.
    check seamAttempts.unregister >= 2
    check f.win.popoverCountForTest() == 0
    check f.win.diagnostics.liveWindows == 0
    check f.win.diagnostics.liveFonts == 0
    check f.win.diagnostics.liveRoots == 0

  test "a surface-mark failure rolls the panel back and keeps no receipt":
    # The panel window exists before the surface mark runs; a refused SetProp must
    # not silently destroy it without a receipt. Here the ordinary rollback must
    # release the real HWND it created.
    let state = PopoverState()
    state.omitPopover = true
    let f = mounted(state)
    defer: close(f)
    settle(f)
    resetSeams()
    injectFail.setProp = true
    state.omitPopover = false
    var message = ""
    try:
      settle(f)
    except UiError as error:
      message = error.msg
    check seamRefused.setProp == 1
    check seamLastPanel != nil
    check message.contains("SetPropW popover panel surface failed: Win32 error 5")
    check message.contains("popover panel construction rolled back")
    # The window the failing step created is really gone again.
    check IsWindow(seamLastPanel) == 0
    check f.win.popoverCountForTest() == 0
    check popoverReceiptsForTest() == 0
    check seamAttempts.unregister == seamAttempts.register

  # Scope note: this pair proves the message-level contract (original SetProp
  # error preserved, cleanup error appended, live HWND still tracked and
  # releasable). The RED evidence for these cases was message-level only; a
  # deeper ownership-rollback negative control was not demonstrated.
  test "a failed surface mark whose cleanup also fails keeps the receipt":
    # Double fault: SetProp refused AND the panel's DestroyWindow refused. The
    # primary SetProp error must stay visible, the cleanup error must be reported
    # too, and the live HWND must stay tracked so it cannot be orphaned.
    let state = PopoverState()
    state.omitPopover = true
    let f = mounted(state)
    defer: close(f)
    settle(f)
    resetSeams()
    injectFail.setProp = true
    injectFail.destroy = true
    injectDestroyPanel = true
    state.omitPopover = false
    var message = ""
    try:
      settle(f)
    except UiError as error:
      message = error.msg
    check seamRefused.setProp == 1
    check seamRefused.destroy == 1
    check seamLastPanel != nil
    check message.contains("SetPropW popover panel surface failed: Win32 error 5")
    check message.contains("popover panel rollback failed")
    check message.contains("DestroyWindow popover panel failed: Win32 error 5")
    # Receipt kept: the surviving real window is still owned and reported.
    check IsWindow(seamLastPanel) != 0
    check f.win.popoverCountForTest() == 1
    check popoverReceiptsForTest() == 1
    # Clearing the injections lets the ordinary stale-drop release everything.
    injectDestroyPanel = false
    state.omitPopover = true
    settle(f)
    check IsWindow(seamLastPanel) == 0
    check f.win.popoverCountForTest() == 0
    check popoverReceiptsForTest() == 0
    check seamAttempts.unregister == seamAttempts.register

  # Scope note: the "retried" part exercises the HOST-LEVEL repaint debt (a
  # non-faulted ordinary turn finishes the repaint). Through the real message
  # pump the same RedrawWindow failure goes tick -> faultBackendEffects ->
  # frozen dispatch -> runNative cleanup and the app exits; in-application
  # automatic recovery is NOT claimed here or in the docs.
  test "a theme redraw failure is reported and retried instead of claimed":
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    state.open = true
    settle(f)
    discard f.h.pumpQueued()
    let panel = f.panelOf()
    check luminance(dominantColor(panel, includeChildren = true)) > 200
    resetSeams()
    injectFail.redraw = true
    state.dark = true
    var message = ""
    try:
      settle(f)
    except UiError as error:
      message = error.msg
    # Same contract as the modal surface: a failed repaint is a native error, not
    # a silently claimed theme switch.
    check seamRefused.redraw == 1
    check message.contains("RedrawWindow popover panel failed: Win32 error 5")
    check IsWindow(panel) != 0
    # The theme itself really changed and the repaint is retried on the next
    # ordinary turn: the panel body becomes dark without a second theme edit.
    settle(f)
    discard f.h.pumpQueued()
    check luminance(dominantColor(panel, includeChildren = true)) < 96

  test "a panel destroy failure keeps a receipt until a retry succeeds":
    resetSeams()
    let state = PopoverState()
    let f = mounted(state)
    settle(f)
    state.open = true
    settle(f)
    let panel = f.panelOf()
    check IsWindow(panel) != 0
    # Refuse the real DestroyWindow of THIS panel only, so the failure is the
    # panel teardown, not some child window that happens to be destroyed first.
    injectDestroyTarget = panel
    injectFail.destroy = true
    var message = ""
    try:
      f.h.destroyHost()
    except CatchableError as error:
      message = error.msg
    check seamRefused.destroy == 1
    check message.contains("DestroyWindow popover panel failed: Win32 error 5")
    # The receipt was kept: the panel is still alive and the host still tracked.
    check IsWindow(panel) != 0
    check f.win.popoverCountForTest() == 1
    # A retry without injection completes and releases only this task's windows.
    f.h.destroyHost()
    f.runtime.closeRuntime()
    check IsWindow(panel) == 0
    check f.win.diagnostics.liveWindows == 0
    check f.win.diagnostics.liveFonts == 0
    check f.win.diagnostics.liveRoots == 0
    check f.win.popoverCountForTest() == 0

  test "a failed show faults the session through the real production pump":
    # Production entry, not the test shortcut: host.pump() -> safeTurn() ->
    # bridge.nativeTick() -> Win32Backend.tick() -> nativeTurn() -> popoverTurn()
    # -> Win32Popover.show(). tick() is the frame that owns the fault contract,
    # so this is the only entry that can prove what a real app observes.
    resetSeams()
    let state = PopoverState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let panel = f.panelOf()
    let edit = f.windowOf("pp-edit")
    let showsBefore = f.win.diagnostics.popoverShows
    let requestsBefore = state.requests
    check not f.runtime.eventsFrozen
    check not f.s.faulted
    injectFail.show = true
    state.open = true # accepted open must stay true: the publish, not the state, fails
    discard f.runtime.refresh() # install the accepted open; the pump publishes
    check f.runtime.find("pp").node.popoverProps.get.open
    # Safety net: if the publish never ran, the pump returns instead of blocking.
    discard PostMessageW(f.h.windowHandle, 0x0012'u32, 1, 0)
    # Positive control for the later refusal: the SAME envelope shape is accepted
    # while the session is live (same handle, same observed revision).
    let editHandle = f.s.handleFor(f.runtime.find("pp-edit").id)
    let binding = f.win.controlBindingForTest(editHandle)
    let generation = f.s.mountGeneration
    let liveProbe = EventEnvelope(session: f.s.sessionId, mountGeneration: generation,
      bindingGeneration: binding, handle: editHandle, sequence: 1,
      observedRevision: 0, event: Event(kind: change, value: ""), source: sourceUser)
    check binding != 0
    check f.s.enqueue(liveProbe)
    f.s.drainEvents()
    check state.text == ""
    var message = ""
    try:
      discard f.h.pump()
    except UiError as error:
      message = error.msg
    check seamRefused.show == 1
    check message.contains("popover panel did not become visible")
    # Existing fault contract (plan invariant 9): a native effect failure inside
    # the ordinary native turn faults the session and freezes business dispatch
    # before the error leaves the pump, so a vanished panel can never receive
    # business events afterwards.
    check f.s.faulted
    check f.runtime.eventsFrozen
    # Frozen dispatch is effective: the same live session refuses a genuine user
    # envelope for the (now invisible) panel body instead of delivering it.
    let rootHandle = f.s.handleFor(f.runtime.find("pp").id)
    check not f.s.enqueue(EventEnvelope(session: f.s.sessionId,
      mountGeneration: generation, bindingGeneration: binding, handle: rootHandle,
      sequence: 2, observedRevision: 0,
      event: Event(kind: openChange, open: false), source: sourceUser))
    check not f.s.enqueue(EventEnvelope(session: f.s.sessionId,
      mountGeneration: generation, bindingGeneration: binding, handle: editHandle,
      sequence: 3, observedRevision: 0,
      event: Event(kind: change, value: "ghost"), source: sourceUser))
    f.s.drainEvents() # nothing was queued, so nothing can reach business
    # No fake receipt and no silent state change: the failed publish is not
    # counted, accepted open is unchanged, and neither the panel nor its EDIT is
    # destroyed behind the caller's back.
    check f.win.diagnostics.popoverShows == showsBefore
    check state.requests == requestsBefore
    check f.runtime.find("pp").node.popoverProps.get.open
    check IsWindow(panel) != 0
    check IsWindowVisible(panel) == 0
    check IsWindow(edit) != 0
    check f.win.popoverCountForTest() == 1
    check popoverReceiptsForTest() == 1
    # Intermediate state is explicit: show() failed AFTER place(), so the panel
    # has real geometry while nothing was published. No rect/show receipt exists,
    # so a later reader cannot mistake the placed rectangle for a publication.
    check rectOf(panel).width > 0
    check rectOf(panel).height > 0
    check not f.win.popoverPublishedRectForTest(rootHandle)
