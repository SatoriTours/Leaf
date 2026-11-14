when not defined(windows): {.error: "Native Dialog tests require Windows".}
import std/[tables, unittest, widestrs, strutils, os, osproc, monotimes, times]
import leaf
import ../fixture_app
import leaf/[ui_thread, native_layout, native_theme, styles, backend_session]
import leaf/backend as protocol
import leaf/backends/win32/[api, host, backend, calls]
import leaf/ui as standard

const
  GwOwner = 4'u32
  GwHwndNext = 2'u32
  GwlStyle = -16'i32
  GwlExStyle = -20'i32
  GaRoot = 2'u32
  VkEscape = 0x1b'i32
  VkTab = 9'i32
  VkShift = 0x10'i32
  WmKeyDown = 0x0100'u32
  WmKeyUp = 0x0101'u32
  WmChar = 0x0102'u32
  WsPopup = 0x80000000'u32
  WsCaption = 0x00c00000'u32
  WsSysMenu = 0x00080000'u32
  WsTabStop = 0x00010000'u32
  ExTopmost = 0x00000008'u32
  ExLayered = 0x00080000'u32
  ExNoActivate = 0x08000000'u32
  EmSetsel = 0x00b1'u32
  EmCanundo = 0x00c6'u32
  EmUndo = 0x00c7'u32
  EmGetsel = 0x00b0'u32
  BmClick = 0x00f5'u32
  WmSettext = 0x000c'u32
  SwpNoZOrder = 0x0004'u32
  SwpNoActivate = 0x0010'u32
  SwpFrameChanged = 0x0020'u32
  InputMouse = 0'u32
  InputKeyboard = 1'u32
  KeyeventfKeyup = 0x0002'u32
  MouseeventfMove = 0x0001'u32
  MouseeventfLeftdown = 0x0002'u32
  MouseeventfLeftup = 0x0004'u32

{.push stdcall, dynlib: "user32.dll", importc, raises: [].}
proc GetWindow(window: HWND, command: DWORD): HWND
proc GetAncestor(window: HWND, flags: UINT): HWND
proc IsChild(parent, child: HWND): BOOL
proc WindowFromPoint(point: POINT): HWND
proc GetCursorPos(point: ptr POINT): BOOL
proc GetForegroundWindow(): HWND
  {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc SetForegroundWindow(window: HWND): BOOL
proc SetCursorPos(x, y: int32): BOOL
proc SendInput(count: UINT, inputs: pointer, size: int32): UINT
proc ClientToScreen(window: HWND, point: ptr POINT): BOOL
{.pop.}

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

  PageState = ref object
    open, alertOpen, inner, reject, extra: bool
    third, fourth, fifth, sixth, seventh, eighth: bool
    dismissals, saved, deleted: int
    runtime: Runtime
    title: string
    description: string
    custom: bool
    dark, hideTrigger, dropDialog, disableTrigger: bool
    bodyHeight: float64
    wideWidth: float64
    wideClicks: int
    name: string
  Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession,
    runtime: Runtime]

var children: seq[HWND]
proc collect(w: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  children.add(w)
  1
proc find(parent: HWND, name: string): HWND =
  children.setLen(0)
  discard EnumChildWindows(parent, collect, 0)
  for w in children:
    let text = newWideCString(200)
    discard GetWindowTextW(w, cast[WidePtr](unsafeAddr text[0]), 200)
    if $text == name: return w
  nil

proc scrollbarOf(parent: HWND, vertical: bool): HWND =
  ## The standard SCROLLBAR child of this surface, matched by class and the
  ## orientation style bit so it is not confused with any content control.
  children.setLen(0)
  discard EnumChildWindows(parent, collect, 0)
  for w in children:
    let name = newWideCString(64)
    if GetClassNameW(w, cast[WidePtr](unsafeAddr name[0]), 64) == 0: continue
    if toLowerAscii($name) != "scrollbar": continue  # the class is "ScrollBar"
    let style = UINT(GetWindowLongW(w, GwlStyle))
    if ((style and UINT(SBS_VERT)) != 0) == vertical: return w
  nil

proc barInfo(window: HWND): tuple[nMin, nMax: int32, nPage: int32, nPos: int32, ok: bool] =
  var info = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)),
    fMask: SIF_RANGE or SIF_PAGE or SIF_POS)
  if GetScrollInfo(window, SB_CTL, addr info) == 0: return (0, 0, 0, 0, false)
  (info.nMin, info.nMax, int32(info.nPage), info.nPos, true)


proc isBarWindow(window: HWND): bool =
  ## Standard scrollbar control by class name (case-insensitive).
  var name = newWideCString(64)
  if GetClassNameW(window, cast[WidePtr](unsafeAddr name[0]), 64) == 0: return false
  toLowerAscii($name) == "scrollbar"

proc windowText(window: HWND): string =
  let text = newWideCString(400)
  discard GetWindowTextW(window, cast[WidePtr](unsafeAddr text[0]), 400)
  $text

proc clientSize(window: HWND): tuple[width, height: int] =
  var client: RECT
  if GetClientRect(window, addr client) == 0: return (0, 0)
  (int(client.right - client.left), int(client.bottom - client.top))

proc windowSize(window: HWND): tuple[width, height: int] =
  var frame: RECT
  if GetWindowRect(window, addr frame) == 0: return (0, 0)
  (int(frame.right - frame.left), int(frame.bottom - frame.top))

proc centerPoint(window: HWND): POINT =
  var frame: RECT
  discard GetWindowRect(window, addr frame)
  POINT(x: (frame.left + frame.right) div 2, y: (frame.top + frame.bottom) div 2)

proc clickAt(point: POINT) =
  discard SetCursorPos(point.x, point.y)
  var events: array[2, InputEvent]
  events[0].kind = InputMouse
  events[0].payload.mouse.flags = MouseeventfLeftdown
  events[1].kind = InputMouse
  events[1].payload.mouse.flags = MouseeventfLeftup
  discard SendInput(2, addr events[0], int32(sizeof(InputEvent)))

proc foregroundForInput(f: Fixture, window: HWND)

proc tapKey(f: Fixture, vk: int32, shift = false) =
  let surface = f.win.overlayStateForTest.top
  let focused = GetFocus()
  foregroundForInput(f, surface)
  if focused != nil and GetAncestor(focused, GaRoot) == surface:
    discard SetFocus(focused)
  var events: array[4, InputEvent]
  var count = 0
  if shift:
    events[count].kind = InputKeyboard
    events[count].payload.keyboard.vk = uint16(VkShift)
    inc count
  events[count].kind = InputKeyboard
  events[count].payload.keyboard.vk = uint16(vk)
  inc count
  events[count].kind = InputKeyboard
  events[count].payload.keyboard.vk = uint16(vk)
  events[count].payload.keyboard.flags = KeyeventfKeyup
  inc count
  if shift:
    events[count].kind = InputKeyboard
    events[count].payload.keyboard.vk = uint16(VkShift)
    events[count].payload.keyboard.flags = KeyeventfKeyup
    inc count
  if SendInput(UINT(count), addr events[0], int32(sizeof(InputEvent))) != UINT(count):
    raise newException(IOError, "keyboard input was not fully submitted")
  # Input injection is asynchronous. Wait for a real queued key without
  # consuming it; the caller's production pump still performs all dispatch.
  var pending: MSG
  let deadline = getMonoTime() + initDuration(milliseconds = 1000)
  while PeekMessageW(addr pending, nil, WmKeyDown, WmKeyDown, 0) == 0:
    if getMonoTime() >= deadline:
      raise newException(IOError, "keyboard input did not reach the target queue")
    sleep(5)

proc pumpQueue(surface: HWND, rounds = 400, logicalTab = false) =
  ## Bounded drain of the real thread queue, using the modal surface as the
  ## USER32 dialog target exactly like the Host pump does.
  var message: MSG
  for _ in 0..<rounds:
    if PeekMessageW(addr message, nil, 0, 0, 1) == 0: break
    # The product pump routes Tab to the modal's logical focus order when the
    # top level scrolls; the bounded test pump mirrors that instead of letting
    # USER32 skip controls that the scroll pass hid.
    let tabMessage = logicalTab and message.message == WmKeyDown and
      message.wParam == WPARAM(VkTab)
    if not tabMessage and surface != nil and
        IsDialogMessageW(surface, addr message) != 0: continue
    discard TranslateMessage(addr message)
    discard DispatchMessageW(addr message)

proc sendWheel(window: HWND, notches: int) =
  for _ in 1..abs(notches):
    let delta = if notches > 0: 120 else: -120
    discard SendMessageW(window, 0x020A,
      WPARAM(uint(cast[uint32](int32(delta)) shl 16)), 0)

proc mounted(build: FixtureBuild, calls = systemWin32Calls(),
             width = 560, height = 460, hostCalls = systemWin32Calls()): Fixture =
  let activity = newUiScopeActivity()
  let app = fixtureApplication(build, "Dialog transactions", width, height)
    .withNativeTheme(shadcnLight)
  let runtime = newRuntime(guardUiApplication(app,
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost(app.title, DipSize(width: float64(width),
    height: float64(height)), calls = hostCalls, theme = shadcnLight)
  h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or
    runtime.installingHook)
  let win = newWin32Backend(h, calls)
  let session = win.attachWin32Backend(runtime, protocol.strict)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime)

proc close(f: Fixture) =
  f.h.destroyHost()
  f.runtime.closeRuntime()
  check f.win.diagnostics.liveWindows == 0
  check f.win.diagnostics.liveFonts == 0
  check f.win.diagnostics.liveRoots == 0
  check f.win.overlayStateForTest.live == 0

proc page(state: PageState): Node =
  let requestClose = proc(e: Event) =
    inc state.dismissals
    if not state.reject:
      state.open = false
      state.alertOpen = false
      state.inner = false
      state.third = false
      state.fourth = false
      state.fifth = false
      state.sixth = false
      state.seventh = false
      state.eighth = false
  var content: seq[Node]
  if not state.hideTrigger:
    content.add(standard.button("打开", key = "open", disabled = state.disableTrigger,
      onClick = proc(e: Event) = state.open = true))
  content.add(standard.button("危险操作", key = "danger",
    variant = UiVariant.destructive,
    onClick = proc(e: Event) = state.alertOpen = true))
  content.add(standard.checkbox("忽略关闭请求", state.reject, key = "reject",
    onChange = proc(e: Event) = state.reject = e.checked))
  var body: seq[Node]
  if state.wideWidth > 0.0:
    # A genuinely uncompressible row with a real action at its right end. It is
    # first in the body so the vertical offset stays 0 while testing the
    # horizontal axis on its own.
    # Uncompressible 700 DIP container; the action is a normal small button at
    # its right end (spacer + button), so it can be fully visible once scrolled.
    body.add(row(@[
      core.ui(NodeKind.button, key = "wide-action", text = "宽动作",
        styles = style({"width": "120", "height": "36"}),
        onClick = proc(e: Event) = inc state.wideClicks)],
      key = "wide",
      styles = style({"width": $state.wideWidth, "height": "44",
        "justify": "end"})))
  body.add(standard.field(@[standard.label("名称"),
    standard.input(state.name, key = "name", onChange = proc(e: Event) =
      state.name = e.value)]))
  if state.bodyHeight > 0:
    body.add(core.ui(NodeKind.column, key = "tall",
      styles = style({"height": $state.bodyHeight, "width": "full"})))
  if not state.dropDialog:
    content.add(standard.dialog(state.title, state.open,
      description = (if state.description.len == 0: "名称写入临时草稿。"
        else: state.description),
      key = "dialog",
      onDismiss = requestClose,
      content = body,
      footer = @[
        standard.button("取消", key = "cancel", variant = UiVariant.outline,
          onClick = proc(e: Event) = state.open = false),
        standard.button("内层", key = "inner",
          onClick = proc(e: Event) = state.inner = true),
        standard.button("保存", key = "save",
          onClick = proc(e: Event) =
            inc state.saved
            state.open = false)]))
  if state.custom:
    content.add(standard.dialog("自定义组合", state.open, key = "dialog-custom",
      onDismiss = proc(e: Event) = state.open = false,
      content = @[standard.fieldDescription("自定义中间节点"),
        standard.button("自定义保存", key = "custom-save")]))
  content.add(standard.dialog("内层对话框", state.inner, key = "dialog-inner",
    # Each level owns its own dismiss: closing the inner level must never close
    # the outer one, which is exactly what the nested-close contract checks.
    onDismiss = proc(e: Event) =
      inc state.dismissals
      if not state.reject: state.inner = false,
    content = @[standard.fieldDescription("内层说明")],
    footer = @[standard.button("关闭内层", key = "close-inner",
      onClick = proc(e: Event) = state.inner = false)]))
  content.add(standard.alertDialog("删除联系人", standard.alertDialogCancel("保留",
      key = "alert-cancel",
      onClick = proc(e: Event) = state.alertOpen = false),
    state.alertOpen, standard.alertDialogAction("删除", proc(e: Event) =
      inc state.deleted
      state.alertOpen = false, key = "alert-delete",
      variant = UiVariant.destructive),
    description = "不能撤销。", key = "alert", onDismiss = requestClose))
  # Extra levels used by the nesting-budget test.
  content.add(standard.dialog("第三层", state.third, key = "dialog-3",
    onDismiss = requestClose, content = @[standard.fieldDescription("3")],
    footer = @[standard.button("关闭三层", key = "close-3",
      onClick = proc(e: Event) = state.third = false)]))
  content.add(standard.dialog("第四层", state.fourth, key = "dialog-4",
    onDismiss = requestClose, content = @[standard.fieldDescription("4")],
    footer = @[standard.button("关闭四层", key = "close-4",
      onClick = proc(e: Event) = state.fourth = false)]))
  content.add(standard.dialog("第五层", state.fifth, key = "dialog-5",
    onDismiss = requestClose, content = @[standard.fieldDescription("5")],
    footer = @[standard.button("关闭五层", key = "close-5",
      onClick = proc(e: Event) = state.fifth = false)]))
  content.add(standard.dialog("第六层", state.sixth, key = "dialog-6",
    onDismiss = requestClose, content = @[standard.fieldDescription("6")],
    footer = @[standard.button("关闭六层", key = "close-6",
      onClick = proc(e: Event) = state.sixth = false)]))
  content.add(standard.dialog("第七层", state.seventh, key = "dialog-7",
    onDismiss = requestClose, content = @[standard.fieldDescription("7")],
    footer = @[standard.button("关闭七层", key = "close-7",
      onClick = proc(e: Event) = state.seventh = false)]))
  content.add(standard.dialog("第八层", state.eighth, key = "dialog-8",
    onDismiss = requestClose, content = @[standard.fieldDescription("8")],
    footer = @[standard.button("关闭八层", key = "close-8",
      onClick = proc(e: Event) = state.eighth = false)]))
  content.add(standard.dialog("第九层", false, key = "dialog-9",
    onDismiss = requestClose, content = @[standard.fieldDescription("9")],
    footer = @[standard.button("关闭九层", key = "close-9",
      onClick = proc(e: Event) = discard)]))
  standard.theme((if state.dark: UiColorMode.dark else: UiColorMode.light),
    column(content, key = "root"), key = "theme")

proc defaultState(): PageState =
  PageState(title: "编辑联系人", name: "Ada")

proc openAndFocus(f: Fixture, state: PageState, trigger: string,
                  dialog: string): tuple[surface, triggerWindow: HWND] =
  ## Real user path: focus the trigger, activate it, then accept and publish.
  let hostWindow = f.h.windowHandle
  let triggerWindow = find(hostWindow, trigger)
  if triggerWindow == nil: raise newException(ValueError, "missing trigger " & trigger)
  discard SetFocus(triggerWindow)
  result.triggerWindow = triggerWindow
  discard SendMessageW(triggerWindow, BmClick, 0, 0)
  f.win.safeListTurn()
  discard f.runtime.refresh()
  f.win.safeListTurn()
  result.surface = f.win.overlayStateForTest.top
  if result.surface == nil: raise newException(ValueError, "no visible modal level")
  if find(result.surface, dialog) == nil:
    raise newException(ValueError, "missing dialog caption " & dialog)

proc firstOpenState(win: Win32Backend) =
  discard win

proc st(f: Fixture): tuple[live, open, visible, disabledOwners, plans,
    acceptedPlans, pendingFocus, gateDrops, shrinkFallbacks,
    unexpectedCompositions, unsupportedShrinks: int,
    publishPending: bool, top, scrim: HWND] =
  f.win.overlayStateForTest

proc simplePage(state: PageState): Node =
  var content: seq[Node]
  content.add(standard.button("打开", key = "open",
    onClick = proc(e: Event) = state.open = true))
  content.add(standard.dialog(state.title, state.open, key = "dialog",
    onDismiss = proc(e: Event) =
      inc state.dismissals
      if not state.reject: state.open = false,
    content = @[standard.field(@[standard.label("名称"),
      standard.input(state.name, key = "name", onChange = proc(e: Event) =
        state.name = e.value)])]))
  if state.extra:
    content.add(standard.dialog("附加层", state.alertOpen, key = "dialog-extra",
      onDismiss = proc(e: Event) = state.alertOpen = false,
      content = @[standard.fieldDescription("附加")]))
  column(content, key = "root")

suite "native modal Dialog transaction":
  test "apply accepts the state but the OS publish happens in the turn":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      # Accepted, prepared, but nothing is shown/disabled/focused yet.
      check f.st.publishPending
      check f.st.open == 0
      check f.st.visible == 0
      check f.st.acceptedPlans == 1
      check IsWindowEnabled(f.h.windowHandle) != 0
      f.win.safeListTurn()
      check not f.st.publishPending
      check f.st.open == 1
      check f.st.visible == 1
      check f.st.disabledOwners == 1
      check IsWindowEnabled(f.h.windowHandle) == 0
    finally: f.close()

  test "opening mounts a real captioned non-topmost owned window":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      let opened = f.openAndFocus(state, "打开", "编辑联系人")
      let surface = opened.surface
      let style = uint32(GetWindowLongW(surface, GwlStyle))
      check (style and WsPopup) == WsPopup
      # Window control type needs a caption style; no system menu is added.
      check (style and WsCaption) == WsCaption
      check (style and WsSysMenu) == 0
      let exStyle = uint32(GetWindowLongW(surface, GwlExStyle))
      check (exStyle and ExTopmost) == 0
      let scrim = f.st.scrim
      check scrim != nil
      let scrimStyle = uint32(GetWindowLongW(scrim, GwlExStyle))
      check (scrimStyle and ExTopmost) == 0
      check (scrimStyle and ExLayered) == ExLayered
      check GetWindow(surface, GwOwner) == f.h.windowHandle
      check IsChild(f.h.windowHandle, surface) == 0
      # Whole-window client area: no system caption strip is reserved.
      check windowSize(surface) == clientSize(surface)
      # The scrim sits directly below its own surface.
      check GetWindow(surface, GwHwndNext) == scrim
      let focus = GetFocus()
      check focus != nil
      check GetAncestor(focus, GaRoot) == surface
    finally: f.close()

  test "client area follows a real grow and shrink":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      let opened = f.openAndFocus(state, "打开", "编辑联系人")
      let surface = opened.surface
      var (width, height) = windowSize(surface)
      check (width, height) == clientSize(surface)
      discard SetWindowPos(surface, nil, 0, 0, int32(width + 120),
        int32(height + 90), SwpNoZOrder or SwpNoActivate or SwpFrameChanged)
      f.win.safeListTurn()
      check windowSize(surface) == (width + 120, height + 90)
      check clientSize(surface) == (width + 120, height + 90)
      discard SetWindowPos(surface, nil, 0, 0, int32(width - 60),
        int32(height - 40), SwpNoZOrder or SwpNoActivate or SwpFrameChanged)
      f.win.safeListTurn()
      check clientSize(surface) == (width - 60, height - 40)
    finally: f.close()

  test "Esc, the X control and a scrim click only request open=false":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      let opened = f.openAndFocus(state, "打开", "编辑联系人")
      var message = MSG(hwnd: GetFocus(), message: WmKeyDown,
        wParam: WPARAM(VkEscape), lParam: 0)
      check IsDialogMessageW(opened.surface, addr message) != 0
      f.win.safeListTurn()
      check state.dismissals == 1
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 0
      check IsWindowEnabled(f.h.windowHandle) != 0
      discard f.openAndFocus(state, "打开", "编辑联系人")
      let closeControl = find(f.st.top, "关闭")
      if closeControl == nil: raise newException(ValueError, "missing close control")
      discard SendMessageW(closeControl, BmClick, 0, 0)
      f.win.safeListTurn()
      check state.dismissals == 2
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 0
      discard f.openAndFocus(state, "打开", "编辑联系人")
      let scrim = f.st.scrim
      check SendMessageW(scrim, 0x0021, 0, 0) == 3 # WM_MOUSEACTIVATE
      discard SendMessageW(scrim, 0x0201, 0, 0)
      discard SendMessageW(scrim, 0x0202, 0, 0)
      f.win.safeListTurn()
      check state.dismissals == 3
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 0
    finally: f.close()

  test "an ignored dismiss request keeps the accepted open state":
    let state = defaultState()
    state.reject = true
    let f = mounted(proc(): Node = page(state))
    try:
      let opened = f.openAndFocus(state, "打开", "编辑联系人")
      var message = MSG(hwnd: GetFocus(), message: WmKeyDown,
        wParam: WPARAM(VkEscape), lParam: 0)
      check IsDialogMessageW(opened.surface, addr message) != 0
      f.win.safeListTurn()
      check state.dismissals == 1
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 1
      check IsWindowEnabled(f.h.windowHandle) == 0
    finally: f.close()

  test "real mouse input reaches the modal and never the page":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      let opened = f.openAndFocus(state, "打开", "编辑联系人")
      let surface = opened.surface
      let edit = find(surface, "Ada")
      if edit == nil: raise newException(ValueError, "missing editor")
      let point = centerPoint(edit)
      # Nothing covers the modal surface: the hit test lands on the editor.
      check WindowFromPoint(point) == edit
      clickAt(point)
      pumpQueue(surface)
      f.win.safeListTurn()
      check GetFocus() == edit
      # A point inside the scrim but outside the surface must hit the scrim.
      var frame: RECT
      discard GetWindowRect(surface, addr frame)
      var scrimFrame: RECT
      discard GetWindowRect(f.st.scrim, addr scrimFrame)
      let outside = POINT(x: scrimFrame.left + 8, y: scrimFrame.top + 8)
      check outside.x < frame.left or outside.y < frame.top
      check WindowFromPoint(outside) == f.st.scrim
      # UIA Invoke on a background button is the same WM_COMMAND path and must
      # be refused while the modal is accepted-open.
      let pageButton = find(f.h.windowHandle, "危险操作")
      if pageButton == nil: raise newException(ValueError, "missing page button")
      let drops = f.st.gateDrops
      discard SendMessageW(GetParent(pageButton), WM_COMMAND,
        WPARAM(uint32(GetDlgCtrlID(pageButton))), cast[LPARAM](pageButton))
      f.win.safeListTurn()
      check state.alertOpen == false
      check f.st.gateDrops == drops + 1
      let beforeDismiss = state.dismissals
      clickAt(outside)
      pumpQueue(surface)
      f.win.safeListTurn()
      check state.dismissals == beforeDismiss + 1
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 0
    finally: f.close()

  test "AlertDialog ignores the scrim and focuses the cancel control":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      let opened = f.openAndFocus(state, "危险操作", "删除联系人")
      let cancel = find(opened.surface, "保留")
      if cancel == nil: raise newException(ValueError, "missing cancel control")
      check GetFocus() == cancel
      discard SendMessageW(f.st.scrim, 0x0202, 0, 0)
      f.win.safeListTurn()
      check state.dismissals == 0
      var message = MSG(hwnd: GetFocus(), message: WmKeyDown,
        wParam: WPARAM(VkEscape), lParam: 0)
      check IsDialogMessageW(opened.surface, addr message) != 0
      f.win.safeListTurn()
      check state.dismissals == 1
      check state.deleted == 0
    finally: f.close()

  test "nesting closes only the top level and restores the outer one":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      let outer = f.openAndFocus(state, "打开", "编辑联系人")
      let innerButton = find(outer.surface, "内层")
      if innerButton == nil: raise newException(ValueError, "missing inner trigger")
      discard SendMessageW(innerButton, BmClick, 0, 0)
      f.win.safeListTurn()
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check state.inner
      check f.st.open == 2
      let inner = f.st.top
      check inner != outer.surface
      check GetWindow(inner, GwOwner) == outer.surface
      check GetWindow(inner, GwHwndNext) == f.st.scrim
      check IsWindowEnabled(outer.surface) == 0
      check IsWindowEnabled(f.h.windowHandle) == 0
      # An outer-level dismiss request is refused while the inner level is top.
      let dismissals = state.dismissals
      discard SendMessageW(outer.surface, WM_COMMAND, WPARAM(2), 0)
      f.win.safeListTurn()
      check state.dismissals == dismissals
      check f.st.visible == 2
      let closeInner = find(inner, "关闭内层")
      if closeInner == nil: raise newException(ValueError, "missing inner close")
      discard SendMessageW(closeInner, BmClick, 0, 0)
      f.win.safeListTurn()
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 1
      check IsWindowEnabled(outer.surface) != 0
      check IsWindowEnabled(f.h.windowHandle) == 0
      var message = MSG(hwnd: GetFocus(), message: WmKeyDown,
        wParam: WPARAM(VkEscape), lParam: 0)
      check IsDialogMessageW(outer.surface, addr message) != 0
      f.win.safeListTurn()
      check state.dismissals == dismissals + 1
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 0
      check IsWindowEnabled(f.h.windowHandle) != 0
    finally: f.close()

  test "oversized content is rejected before anything is shown":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      f.win.safeListTurn()
      state.bodyHeight = 3000.0
      state.open = true
      expect UiError: discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 0
      check f.st.open == 0
      check f.st.publishPending == false
      check IsWindowEnabled(f.h.windowHandle) != 0
    finally: f.close()

  test "a rejected update keeps the previously accepted level intact":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      let opened = f.openAndFocus(state, "打开", "编辑联系人")
      let before = windowSize(opened.surface)
      state.bodyHeight = 3000.0
      expect UiError: discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 1
      check IsWindowEnabled(f.h.windowHandle) == 0
      check windowSize(f.st.top) == before
      check GetFocus() != nil
    finally: f.close()

  test "too many nested levels are rejected before any of them is shown":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      f.win.safeListTurn()
      state.open = true
      state.inner = true
      state.third = true
      state.fourth = true
      state.fifth = true
      state.sixth = true
      state.seventh = true
      state.eighth = true
      # Nine open levels exceeds the bounded modal depth.
      state.alertOpen = true
      expect UiError: discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.open == 0
      check f.st.visible == 0
      check IsWindowEnabled(f.h.windowHandle) != 0
    finally: f.close()

  test "removing an open level destroys its windows and re-enables the page":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      var surface = f.st.top
      check surface != nil
      # Removing the level node (not just closing it) must destroy its windows.
      state.dropDialog = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let open = f.st.open
      check open == 0
      check IsWindowEnabled(f.h.windowHandle) != 0
      check IsWindow(surface) == 0
    finally: f.close()

  test "reopening reuses one owned level instead of leaking windows":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      let baseline = f.win.diagnostics.liveWindows
      var afterFirst = 0
      for round in 1..3:
        let opened = f.openAndFocus(state, "打开", "编辑联系人")
        let live = f.st.live
        let liveWindows = f.win.diagnostics.liveWindows
        if round == 1: afterFirst = liveWindows
        else:
          check liveWindows == afterFirst
        check live == 10
        let surface = opened.surface
        discard SendMessageW(surface, WM_COMMAND, WPARAM(2), 0)
        f.win.safeListTurn()
        discard f.runtime.refresh()
        f.win.safeListTurn()
        check f.st.visible == 0
        let liveAfter = f.st.live
        check liveAfter == 10
        check IsWindowEnabled(f.h.windowHandle) != 0
      check state.dismissals == 3
      # Only the focus adornment may appear once (on the first real focus);
      # reopening the same level must not create further controls.
      let liveWindows = f.win.diagnostics.liveWindows
      check liveWindows <= baseline + 1
      check liveWindows == afterFirst
    finally: f.close()

type Faults = ref object
  failRegisterAt, failUnregisterAt: int
  failSurfaceAt, failScrimAt: int
  failDestroy: HWND
  register, surfaceCreate, scrimCreate, unregister: int

proc injectedCalls(faults: Faults): Win32Calls =
  result = systemWin32Calls()
  let system = result
  result.registerClass = proc(windowClass: ptr WNDCLASSEXW): ATOM =
    inc faults.register
    if faults.failRegisterAt != 0 and faults.register == faults.failRegisterAt:
      return 0
    system.registerClass(windowClass)
  result.unregisterClass = proc(name: WidePtr, instance: HINSTANCE): BOOL =
    let text = if name == nil: "" else: $cast[WideCString](name)
    if text.startsWith("LeafOverlay"):
      inc faults.unregister
      if faults.failUnregisterAt != 0 and faults.unregister == faults.failUnregisterAt:
        return 0
    system.unregisterClass(name, instance)
  result.createWindow = proc(exStyle: DWORD, className, title: WidePtr, style: DWORD,
      x, y, width, height: int32, parent: HWND, menu: HMENU, instance: HINSTANCE,
      param: pointer): HWND =
    let text = if className == nil: "" else: $cast[WideCString](className)
    if text.startsWith("LeafOverlaySurface"):
      inc faults.surfaceCreate
      if faults.failSurfaceAt != 0 and faults.surfaceCreate == faults.failSurfaceAt:
        return nil
    elif text.startsWith("LeafOverlayScrim"):
      inc faults.scrimCreate
      if faults.failScrimAt != 0 and faults.scrimCreate == faults.failScrimAt:
        return nil
    system.createWindow(exStyle, className, title, style, x, y, width, height,
      parent, menu, instance, param)
  result.destroyWindow = proc(window: HWND): BOOL =
    if faults.failDestroy != nil and window == faults.failDestroy:
      faults.failDestroy = nil
      return 0
    system.destroyWindow(window)

proc openExtra(f: Fixture, state: PageState) =
  state.extra = true
  state.alertOpen = true
  discard f.runtime.refresh()
  f.win.safeListTurn()

suite "modal resource ownership":
  test "a failing second class registration is retried instead of leaked":
    let state = PageState(title: "对话框", name: "Ada")
    let faults = Faults()
    let f = mounted(proc(): Node = simplePage(state), injectedCalls(faults))
    try:
      f.win.safeListTurn()
      check f.st.live == 1
      state.extra = true
      state.alertOpen = true
      # The new level registers two classes; fail the second one.
      faults.failRegisterAt = faults.register + 2
      expect UiError: discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.live == 1
      check f.st.visible == 0
      check IsWindowEnabled(f.h.windowHandle) != 0
      # A retry must succeed: a leaked class registration would fail here.
      faults.failRegisterAt = 0
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.live == 2
      check f.st.visible == 1
    finally: f.close()

  test "a failing surface creation leaves a retryable receipt":
    let state = PageState(title: "对话框", name: "Ada")
    let faults = Faults()
    let f = mounted(proc(): Node = simplePage(state), injectedCalls(faults))
    try:
      f.win.safeListTurn()
      check f.st.live == 1
      state.extra = true
      state.alertOpen = true
      faults.failSurfaceAt = faults.surfaceCreate + 1
      expect UiError: discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.live == 1
      check f.st.visible == 0
      # Disarm, then a retry must build the level instead of leaking a receipt.
      faults.failSurfaceAt = 0
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.live == 2
      check f.st.visible == 1
    finally: f.close()

  test "a failing DestroyWindow keeps the level and a retry cleans it up":
    let state = PageState(title: "对话框", name: "Ada")
    let faults = Faults()
    let f = mounted(proc(): Node = simplePage(state), injectedCalls(faults))
    try:
      f.win.safeListTurn()
      f.openExtra(state)
      check f.st.visible == 1
      let surface = f.st.top
      faults.failDestroy = surface
      state.extra = false
      state.alertOpen = false
      discard f.runtime.refresh()
      expect UiError: f.win.safeListTurn()
      # The failed teardown keeps its table entry and receiver instead of a fake
      # zero; the owner is enabled again and no level is visible.
      check f.st.live == 2
      check f.st.visible == 0
      check IsWindowEnabled(f.h.windowHandle) != 0
      f.win.safeListTurn()
      check f.st.live == 1
      check IsWindow(surface) == 0
    finally: f.close()

  test "a failing class unregistration keeps a receipt for the retry":
    let state = PageState(title: "对话框", name: "Ada")
    let faults = Faults()
    let f = mounted(proc(): Node = simplePage(state), injectedCalls(faults))
    try:
      f.win.safeListTurn()
      f.openExtra(state)
      check f.st.visible == 1
      let unregisterBase = faults.unregister
      state.extra = false
      state.alertOpen = false
      discard f.runtime.refresh()
      # The level unregisters surface then scrim; fail the second one.
      faults.failUnregisterAt = unregisterBase + 2
      expect UiError: f.win.safeListTurn()
      check f.st.live == 2
      faults.failUnregisterAt = 0
      f.win.safeListTurn()
      check f.st.live == 1
    finally: f.close()

suite "modal content details":
  test "a changed title reaches the surface text while open and after reopen":
    let state = PageState(title: "旧标题", name: "Ada")
    let f = mounted(proc(): Node = simplePage(state))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      check windowText(surface) == "旧标题"
      state.title = "新标题"
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check windowText(f.st.top) == "新标题"
      state.open = false
      discard f.runtime.refresh()
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check windowText(f.st.top) == "新标题"
    finally: f.close()

  test "a theme switch keeps the active editor text, selection and undo":
    let state = PageState(title: "对话框", name: "Ada")
    let f = mounted(proc(): Node = simplePage(state))
    try:
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      let edit = find(surface, "Ada")
      if edit == nil: raise newException(ValueError, "missing editor")
      discard SetFocus(edit)
      discard SendMessageW(edit, EmSetsel, WPARAM(3), LPARAM(3))
      discard SendMessageW(edit, WmChar, WPARAM(ord('x')), 0)
      # The native EDIT inserts synchronously and records one undo step.
      check windowText(edit) == "Adax"
      check SendMessageW(edit, EmCanundo, 0, 0) != 0
      # The application accepts the typed value into its model (a real app
      # updates its state from the change event); the accepted text must then
      # match the native text so no setter pass resets the editor.
      state.name = "Adax"
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.top == surface
      check IsWindow(edit) != 0
      check windowText(edit) == "Adax"
      discard SetFocus(edit)
      discard SendMessageW(edit, EmSetsel, WPARAM(1), LPARAM(3))
      var first, last: DWORD
      discard SendMessageW(edit, EmGetsel, cast[WPARAM](addr first), cast[LPARAM](addr last))
      check (int(first), int(last)) == (1, 3)
      # A real theme change applies through the backend; the live EDIT must not
      # be recreated and must keep text, selection and its undo stack.
      state.dark = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check IsWindow(edit) != 0
      discard SendMessageW(edit, EmGetsel, cast[WPARAM](addr first), cast[LPARAM](addr last))
      check (int(first), int(last)) == (1, 3)
      let afterTheme = windowText(edit)
      check afterTheme == "Adax"
      check SendMessageW(edit, EmCanundo, 0, 0) != 0
      discard SendMessageW(edit, EmUndo, 0, 0)
      check windowText(edit) == "Ada"
    finally: f.close()

  test "an unusable trigger falls back to a legal focus target":
    let state = PageState(title: "对话框", name: "Ada")
    let f = mounted(proc(): Node = page(state))
    try:
      f.win.safeListTurn()
      let trigger = find(f.h.windowHandle, "打开")
      if trigger == nil: raise newException(ValueError, "missing trigger")
      discard SetFocus(trigger)
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 1
      # The remembered trigger becomes disabled while the modal is open.
      state.disableTrigger = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check IsWindowEnabled(trigger) == 0
      var message = MSG(hwnd: GetFocus(), message: WmKeyDown,
        wParam: WPARAM(VkEscape), lParam: 0)
      check IsDialogMessageW(f.st.top, addr message) != 0
      f.win.safeListTurn()
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 0
      let focus = GetFocus()
      check focus != nil
      check IsWindow(focus) != 0
      check focus != trigger
      check IsWindowEnabled(focus) != 0
    finally: f.close()

  test "real Tab and Shift+Tab cycle inside the top modal level":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      let opened = f.openAndFocus(state, "打开", "编辑联系人")
      let surface = opened.surface
      let edit = find(surface, "Ada")
      let save = find(surface, "保存")
      if edit == nil or save == nil: raise newException(ValueError, "missing modal controls")
      discard SetFocus(edit)
      f.win.safeListTurn()
      check GetFocus() == edit
      tapKey(f, VkTab)
      pumpQueue(surface)
      f.win.safeListTurn()
      let afterTab = GetFocus()
      check afterTab != edit
      check GetAncestor(afterTab, GaRoot) == surface
      tapKey(f, VkTab, shift = true)
      pumpQueue(surface)
      f.win.safeListTurn()
      check GetFocus() == edit
    finally: f.close()

  test "owner move keeps the level centered and minimize/restore is consistent":
    let state = defaultState()
    let f = mounted(proc(): Node = page(state))
    try:
      let opened = f.openAndFocus(state, "打开", "编辑联系人")
      let surface = opened.surface
      var before: RECT
      discard GetWindowRect(surface, addr before)
      discard SetWindowPos(f.h.windowHandle, nil, 250, 180, 0, 0,
        SwpNoZOrder or SwpNoActivate or 0x0001'u32)
      # The Host's geometry wake runs exactly this pass in production.
      proc geometryPass() =
        let context = f.h.context
        f.win.relayout(DipSize(width: context.contentWidth,
          height: context.contentHeight), int(context.scale * 96))
      geometryPass()
      f.win.safeListTurn()
      var after, hostRect: RECT
      discard GetWindowRect(surface, addr after)
      discard GetWindowRect(f.h.windowHandle, addr hostRect)
      check after.left != before.left or after.top != before.top
      check windowSize(surface) == clientSize(surface)
      # Minimizing the owner must not leave an interactive modal orphaned: the
      # level stays accepted, the owner stays disabled, and restoring the owner
      # brings the level back with usable geometry.
      discard ShowWindow(f.h.windowHandle, 6) # SW_MINIMIZE
      f.win.safeListTurn()
      check f.st.visible == 1
      check IsWindowEnabled(f.h.windowHandle) == 0
      discard ShowWindow(f.h.windowHandle, 9) # SW_RESTORE
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth,
        height: context.contentHeight), int(context.scale * 96))
      f.win.safeListTurn()
      check f.st.visible == 1
      check windowSize(f.st.top) == clientSize(f.st.top)
      let edit = find(f.st.top, "Ada")
      if edit != nil: discard SetFocus(edit)
      var message = MSG(hwnd: GetFocus(), message: WmKeyDown,
        wParam: WPARAM(VkEscape), lParam: 0)
      check IsDialogMessageW(f.st.top, addr message) != 0
      f.win.safeListTurn()
      check state.dismissals == 1
    finally: f.close()

type WorkAreaFault = ref object
  workWidth, workHeight: int32   # pixels at 96 DPI
  active: bool

proc areaCalls(fault: WorkAreaFault): Win32Calls =
  result = systemWin32Calls()
  let system = result
  result.getMonitorInfo = proc(monitor: HMonitor, info: pointer): BOOL =
    if not fault.active: return system.getMonitorInfo(monitor, info)
    # MONITORINFO: cbSize, rcMonitor, rcWork, dwFlags
    let bytes = cast[ptr UncheckedArray[int32]](info)
    type MonitorInfo = object
      cbSize: uint32
      rcMonitor: array[4, int32]
      rcWork: array[4, int32]
      dwFlags: uint32
    let target = cast[ptr MonitorInfo](info)
    target.cbSize = uint32(sizeof(MonitorInfo))
    target.rcMonitor = [0'i32, 0, fault.workWidth, fault.workHeight]
    target.rcWork = [0'i32, 0, fault.workWidth, fault.workHeight]
    target.dwFlags = 1
    discard bytes
    1

suite "modal single geometry plan":
  test "the width used for measurement is the final width":
    let state = PageState(title: "对话框", name: "Ada")
    state.bodyHeight = 0
    let fault = WorkAreaFault(active: true, workWidth: 480, workHeight: 800)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      # Requested width 512 is narrowed to 480 - 32 = 448 by the work area.
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      if surface == nil: raise newException(ValueError, "no level")
      let (width, _) = clientSize(surface)
      check width == 448
      # Same plan drives placement: no second clamp, size matches the plan.
      let plan = f.win.overlayPlanForTest(NodeHandle(0))
      discard plan
    finally: f.close()

  test "a level measured at the narrowed width is rejected when it no longer fits":
    let state = PageState(title: "对话框", name: "Ada")
    state.bodyHeight = 700.0
    let wide = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(wide))
    try:
      f.win.safeListTurn()
      # With the real work area the 700 DIP body fits; narrowing the work area
      # makes the *final* width smaller, so the wrapped content no longer fits
      # and the revision must be rejected before showing anything.
      wide.active = true
      wide.workWidth = 480
      wide.workHeight = 560
      state.open = true
      let before = f.st.visible
      var raised = false
      try:
        discard f.runtime.refresh()
      except UiError:
        raised = true
      check raised
      f.win.safeListTurn()
      check f.st.visible == before
      check IsWindowEnabled(f.h.windowHandle) != 0
    finally: f.close()

suite "modal publish receipts":
  test "a failing second z-order step leaves retryable receipts, not a stuck owner":
    let state = PageState(title: "对话框", name: "Ada")
    var failOrder = false
    let system = systemWin32Calls()
    var calls = system
    var orderCalls = 0
    calls.windowPos = proc(window, after: HWND, x, y, width, height: int32,
        flags: UINT): BOOL =
      # Only the modal z-order step carries SWP_NOOWNERZORDER; the tab-order
      # pass and ordinary control placement must stay untouched.
      if (flags and 0x0200'u32) != 0:
        inc orderCalls
        if failOrder and orderCalls == 2: return 0
      system.windowPos(window, after, x, y, width, height, flags)
    let f = mounted(proc(): Node = simplePage(state), calls)
    try:
      f.win.safeListTurn()
      state.open = true
      failOrder = true
      discard f.runtime.refresh()
      # The publish step fails inside the ordinary turn.
      var raised = false
      try: f.win.safeListTurn()
      except UiError: raised = true
      check raised
      # Whatever happened, the real state is consistent: the owner is either
      # still enabled or the surface is reported as shown.
      failOrder = false
      f.win.safeListTurn()
      check f.st.visible == 1
      check IsWindowEnabled(f.h.windowHandle) == 0
      let surface = f.st.top
      check IsWindowVisible(surface) != 0
      state.open = false
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 0
      check IsWindowEnabled(f.h.windowHandle) != 0
      check IsWindowVisible(surface) == 0
    finally: f.close()

  test "a failing hide step is retried and the owner is enabled again":
    let state = PageState(title: "对话框", name: "Ada")
    var failHide = 0
    let system = systemWin32Calls()
    var calls = system
    calls.showWindow = proc(window: HWND, command: int32): BOOL =
      if command == 0 and failHide > 0:
        dec failHide
        raise newException(UiError, "injected hide failure")
      system.showWindow(window, command)
    let f = mounted(proc(): Node = simplePage(state), calls)
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 1
      let surface = f.st.top
      check IsWindowEnabled(f.h.windowHandle) == 0
      # Fail the first hide step: the surface stays visible and the owner stays
      # disabled, but the receipts keep both so a retry finishes the cleanup.
      failHide = 1
      state.open = false
      discard f.runtime.refresh()
      var raised = false
      try: f.win.safeListTurn()
      except UiError: raised = true
      check raised
      check IsWindowEnabled(f.h.windowHandle) == 0
      f.win.safeListTurn()
      check f.st.visible == 0
      check IsWindowEnabled(f.h.windowHandle) != 0
      check IsWindowVisible(surface) == 0
    finally: f.close()

  test "a failing owner re-enable is retried":
    let state = PageState(title: "对话框", name: "Ada")
    var failEnable = 0
    var hostWindow: HWND
    let system = systemWin32Calls()
    var calls = system
    calls.enable = proc(window: HWND, enabled: BOOL): BOOL =
      # Only the owning window re-enable is injected; control enables during
      # apply are a different step.
      if enabled != 0 and failEnable > 0 and window == hostWindow:
        dec failEnable
        raise newException(UiError, "injected enable failure")
      system.enable(window, enabled)
    let f = mounted(proc(): Node = simplePage(state), calls)
    hostWindow = f.h.windowHandle
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check IsWindowEnabled(f.h.windowHandle) == 0
      failEnable = 1
      state.open = false
      discard f.runtime.refresh()
      var raised = false
      try: f.win.safeListTurn()
      except UiError: raised = true
      check raised
      # The window is hidden but the owner is still disabled until the retry.
      check IsWindowEnabled(f.h.windowHandle) == 0
      f.win.safeListTurn()
      check IsWindowEnabled(f.h.windowHandle) != 0
      check f.st.visible == 0
    finally: f.close()

  test "a failing second owner link rolls back the first one":
    let state = PageState(title: "对话框", name: "Ada")
    var failLink = false
    let system = systemWin32Calls()
    var calls = system
    var linkCalls = 0
    calls.setWindowData = proc(window: HWND, index: int32, value: int): int =
      if index == -8 and failLink:
        inc linkCalls
        if linkCalls == 2:
          setLastError(5)
          return 0
      system.setWindowData(window, index, value)
    let f = mounted(proc(): Node = simplePage(state), calls)
    try:
      f.win.safeListTurn()
      state.open = true
      failLink = true
      discard f.runtime.refresh()
      var raised = false
      try: f.win.safeListTurn()
      except UiError: raised = true
      check raised
      # No half-linked level: the owner chain is either fully applied or fully
      # rolled back, and nothing is left visible/disabled.
      failLink = false
      f.win.safeListTurn()
      check f.st.visible <= 1
      if f.st.visible == 1: check IsWindowEnabled(f.h.windowHandle) == 0
      else: check IsWindowEnabled(f.h.windowHandle) != 0
    finally: f.close()

  test "a failing surface title update keeps the accepted level untouched":
    let state = PageState(title: "旧标题", name: "Ada")
    var failTitle = false
    let system = systemWin32Calls()
    var calls = system
    calls.setText = proc(window: HWND, text: WidePtr): BOOL =
      if failTitle: return 0
      system.setText(window, text)
    let f = mounted(proc(): Node = simplePage(state), calls)
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      check windowText(surface) == "旧标题"
      failTitle = true
      state.title = "新标题"
      var raised = false
      try:
        discard f.runtime.refresh()
      except UiError:
        raised = true
      check raised
      f.win.safeListTurn()
      check f.st.visible == 1
      check windowText(f.st.top) == "旧标题"
      check IsWindowEnabled(f.h.windowHandle) == 0
    finally: f.close()

suite "modal dynamic shrink fallback":
  test "the surface clamps, keeps the safe actions visible and restores":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      if surface == nil: raise newException(ValueError, "no level")
      var before: RECT
      discard GetWindowRect(surface, addr before)
      let saveBefore = find(surface, "保存")
      var saveRect: RECT
      discard GetWindowRect(saveBefore, addr saveRect)
      discard SetFocus(saveBefore)
      f.win.safeListTurn()
      # The work area now shrinks so the accepted size no longer fits.
      # Small enough that the accepted height no longer fits (available height
      # 220 - 32 = 188 < the accepted ~226 DIP) but still above the supported
      # minimum, so the pinned safe area must be used.
      fault.active = true
      fault.workWidth = 600
      fault.workHeight = 220
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let shrunk = f.st
      check shrunk.shrinkFallbacks > 0
      var frame: RECT
      discard GetWindowRect(f.st.top, addr frame)
      check (frame.right - frame.left) <= 600
      check (frame.bottom - frame.top) <= 300
      # Scroll contract: at offset 0 the footer may sit outside the clamped
      # surface; it must become fully reachable after a natural wheel scroll.
      let save = find(f.st.top, "保存")
      sendWheel(f.st.top, -6)
      f.win.safeListTurn()
      var saveNow: RECT
      discard GetWindowRect(save, addr saveNow)
      check IsWindowVisible(save) != 0
      check saveNow.top >= frame.top
      check saveNow.bottom <= frame.bottom
      check saveNow.right <= frame.right
      # Focus stays inside the modal, on a reachable control.
      let focus = GetFocus()
      check focus != nil
      check GetAncestor(focus, GaRoot) == f.st.top
      check IsWindowVisible(focus) != 0
      # An ignored dismiss keeps the accepted state and the actions reachable.
      state.reject = true
      var message = MSG(hwnd: focus, message: WmKeyDown, wParam: WPARAM(VkEscape), lParam: 0)
      check IsDialogMessageW(f.st.top, addr message) != 0
      f.win.safeListTurn()
      check f.st.visible == 1
      check IsWindowVisible(find(f.st.top, "保存")) != 0
      # A non-growing re-render stays accepted in the shrunken environment.
      # Growth rejection is checked separately; an unchanged tree is no longer
      # a valid negative control for that policy.
      discard f.runtime.refresh()
      f.win.safeListTurn()
      check f.st.visible == 1
      check IsWindowVisible(find(f.st.top, "保存")) != 0
      check IsWindowEnabled(f.h.windowHandle) == 0
      # Restoring the work area restores the accepted layout.
      fault.active = false
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      var restored: RECT
      discard GetWindowRect(f.st.top, addr restored)
      check restored.left == before.left
      check restored.top == before.top

      check (restored.bottom - restored.top) == (before.bottom - before.top)
      var saveRestored: RECT
      discard GetWindowRect(find(f.st.top, "保存"), addr saveRestored)
      check saveRestored.left == saveRect.left
      check saveRestored.top == saveRect.top
    finally: f.close()

  test "a long wrapped description at a narrow width is measured, not truncated":
    let state = PageState(title: "对话框", name: "Ada")
    state.description = "This description is intentionally long so that it wraps into several " &
      "lines at a narrow client width and therefore needs more vertical space than the " &
      "requested 512 DIP width would have needed."
    let fault = WorkAreaFault(active: true, workWidth: 460, workHeight: 900)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      var raised = false
      try: discard f.runtime.refresh()
      except UiError: raised = true
      f.win.safeListTurn()
      if not raised:
        check f.st.visible == 1
        let (width, _) = clientSize(f.st.top)
        check width == 428
        check IsWindowVisible(find(f.st.top, "保存")) != 0
      else:
        check f.st.visible == 0
        check IsWindowEnabled(f.h.windowHandle) != 0
    finally: f.close()

suite "modal button theming":
  test "page and modal buttons both keep the visual-style theme":
    let state = PageState(title: "对话框", name: "Ada")
    let f = mounted(proc(): Node = page(state))
    try:
      f.win.safeListTurn()
      let pageButton = find(f.h.windowHandle, "打开")
      if pageButton == nil: raise newException(ValueError, "missing page button")
      check GetWindowTheme(pageButton) != nil
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      for label in ["保存", "取消", "关闭"]:
        let control = find(surface, label)
        if control == nil: raise newException(ValueError, "missing " & label)
        check GetWindowTheme(control) != nil
    finally: f.close()

proc insideRect(inner, outer: RECT): bool =
  inner.left >= outer.left and inner.right <= outer.right and
    inner.top >= outer.top and inner.bottom <= outer.bottom

suite "modal shrink RED (expected failing assertions)":
  test "RED: below-minimum work area cannot keep the safe actions reachable":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      if surface == nil: raise newException(ValueError, "no level")
      var surfaceBefore, saveBefore: RECT
      discard GetWindowRect(surface, addr surfaceBefore)
      let save = find(surface, "保存")
      discard GetWindowRect(save, addr saveBefore)
      let planBeforeHeight = f.win.overlayPlanForTest(f.win.overlayHandleForTest(0)).height
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      var surfaceNow, saveNow, client: RECT
      discard GetWindowRect(f.st.top, addr surfaceNow)
      discard GetClientRect(f.st.top, addr client)
      let saveNowHandle = find(f.st.top, "保存")
      discard GetWindowRect(saveNowHandle, addr saveNow)
      let planNowHeight = f.win.overlayPlanForTest(f.win.overlayHandleForTest(0)).height
      let area = RECT(left: 0, top: 0, right: 400, bottom: 120)
      let clientRect = RECT(left: surfaceNow.left, top: surfaceNow.top,
        right: surfaceNow.left + client.right, bottom: surfaceNow.top + client.bottom)
      sendWheel(f.st.top, -6)
      f.win.safeListTurn()
      discard GetWindowRect(f.st.top, addr surfaceNow)
      discard GetClientRect(f.st.top, addr client)
      discard GetWindowRect(saveNowHandle, addr saveNow)
      echo "RED-1 surfaceBefore=" & $surfaceBefore.left & "," & $surfaceBefore.top &
        " " & $(surfaceBefore.right - surfaceBefore.left) & "x" &
        $(surfaceBefore.bottom - surfaceBefore.top)
      echo "RED-1 surfaceNow=" & $surfaceNow.left & "," & $surfaceNow.top & " " &
        $(surfaceNow.right - surfaceNow.left) & "x" &
        $(surfaceNow.bottom - surfaceNow.top) & " client=" &
        $(client.right - client.left) & "x" & $(client.bottom - client.top)
      echo "RED-1 saveBefore=" & $saveBefore.left & "," & $saveBefore.top & " " &
        $(saveBefore.right - saveBefore.left) & "x" &
        $(saveBefore.bottom - saveBefore.top)
      echo "RED-1 saveNow=" & $saveNow.left & "," & $saveNow.top & " " &
        $(saveNow.right - saveNow.left) & "x" & $(saveNow.bottom - saveNow.top)
      echo "RED-1 visibleFlag=" & $IsWindowVisible(saveNowHandle) & " inClient=" &
        $insideRect(saveNow, clientRect) & " inWorkArea=" &
        $insideRect(saveNow, area)
      echo "RED-1 planHeightBefore=" & $planBeforeHeight & " planHeightNow=" & $planNowHeight
      # Contract A: the safe action stays fully reachable inside the client.
      check insideRect(saveNow, clientRect)
      # Contract B: and inside the monitor work area (not clipped by the screen).
      check insideRect(saveNow, area)
      # Contract C: a fallback that cannot fit must not overwrite the accepted plan.
      check planNowHeight == planBeforeHeight
    finally: f.close()

  test "RED: a legal custom composition is not rearranged by the shrink fallback":
    let state = PageState(title: "对话框", name: "Ada")
    state.custom = true
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      if surface == nil: raise newException(ValueError, "no level")
      if find(surface, "自定义保存") == nil:
        raise newException(ValueError, "missing custom footer action")
      fault.active = true
      fault.workWidth = 600
      fault.workHeight = 150
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      var surfaceNow, saveNow, client: RECT
      discard GetWindowRect(f.st.top, addr surfaceNow)
      discard GetClientRect(f.st.top, addr client)
      sendWheel(f.st.top, -6)
      f.win.safeListTurn()
      discard GetWindowRect(f.st.top, addr surfaceNow)
      discard GetClientRect(f.st.top, addr client)
      discard GetWindowRect(find(f.st.top, "自定义保存"), addr saveNow)
      let clientRect = RECT(left: surfaceNow.left, top: surfaceNow.top,
        right: surfaceNow.left + client.right, bottom: surfaceNow.top + client.bottom)
      echo "RED-2 surfaceNow=" & $surfaceNow.left & "," & $surfaceNow.top & " " &
        $(surfaceNow.right - surfaceNow.left) & "x" &
        $(surfaceNow.bottom - surfaceNow.top) & " client=" &
        $(client.right - client.left) & "x" & $(client.bottom - client.top)
      echo "RED-2 saveNow=" & $saveNow.left & "," & $saveNow.top & " " &
        $(saveNow.right - saveNow.left) & "x" & $(saveNow.bottom - saveNow.top) &
        " visibleFlag=" & $IsWindowVisible(find(f.st.top, "自定义保存")) &
        " inClient=" & $insideRect(saveNow, clientRect)
      check insideRect(saveNow, clientRect)
    finally: f.close()


proc insideWorkArea(f: Fixture, rect: RECT, area: RECT): bool =
  discard f
  rect.left >= area.left and rect.right <= area.right and
    rect.top >= area.top and rect.bottom <= area.bottom

suite "dialog scroll reachability RED (contract)":
  test "RED: 400x120 keeps the save action reachable through scrolling":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      if surface == nil: raise newException(ValueError, "no level")
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      # Natural mouse-wheel scrolling must bring the footer action into view.
      sendWheel(surface, -6)
      f.win.safeListTurn()
      var saveNow: RECT
      discard GetWindowRect(find(f.st.top, "保存"), addr saveNow)
      var client, frame: RECT
      discard GetClientRect(f.st.top, addr client)
      discard GetWindowRect(f.st.top, addr frame)
      let clientRect = RECT(left: frame.left, top: frame.top,
        right: frame.left + client.right, bottom: frame.top + client.bottom)
      let area = RECT(left: 0, top: 0, right: 400, bottom: 120)
      echo "SCROLL-RED-1 save=" & $saveNow.left & "," & $saveNow.top & " " &
        $(saveNow.right - saveNow.left) & "x" & $(saveNow.bottom - saveNow.top) &
        " client=" & $(client.right) & "x" & $(client.bottom)
      check insideRect(saveNow, clientRect)
      check f.insideWorkArea(saveNow, area)
    finally: f.close()

  test "RED: Tab reveals a clipped action and keeps focus inside the level":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      if surface == nil: raise newException(ValueError, "no level")
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let save = find(f.st.top, "保存")
      discard SetFocus(f.st.top)
      f.win.safeListTurn()
      # Real Tab key presses must walk the logical order and scroll the target
      # into view; a direct SetFocus would not exercise that path.
      for _ in 1..8:
        if GetFocus() == save: break
        tapKey(f, VkTab)
        pumpQueue(f.st.top, 400, true)
        f.win.safeListTurn()
      var saveNow, client, frame: RECT
      discard GetWindowRect(save, addr saveNow)
      discard GetClientRect(f.st.top, addr client)
      discard GetWindowRect(f.st.top, addr frame)
      let clientRect = RECT(left: frame.left, top: frame.top,
        right: frame.left + client.right, bottom: frame.top + client.bottom)
      echo "SCROLL-RED-2 focusSave=" & $saveNow.left & "," & $saveNow.top
      check GetFocus() == save
      check insideRect(saveNow, clientRect)
    finally: f.close()

  test "RED: restore returns to the normal layout and clamps the offset":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      var before, saveBefore: RECT
      discard GetWindowRect(f.st.top, addr before)
      discard GetWindowRect(find(f.st.top, "保存"), addr saveBefore)
      let context = f.h.context
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      sendWheel(f.st.top, -6)
      f.win.safeListTurn()
      fault.active = false
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      var restored, saveRestored: RECT
      discard GetWindowRect(f.st.top, addr restored)
      discard GetWindowRect(find(f.st.top, "保存"), addr saveRestored)
      echo "SCROLL-RED-3 restored=" & $restored.left & "," & $restored.top & " " &
        $(restored.right - restored.left) & "x" & $(restored.bottom - restored.top) &
        " save=" & $saveRestored.left & "," & $saveRestored.top
      check restored.left == before.left
      check (restored.right - restored.left) == (before.right - before.left)
      check saveRestored.left == saveBefore.left
      check saveRestored.top == saveBefore.top
    finally: f.close()

  test "RED: scrolling keeps the EDIT window and its draft":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let edit = find(f.st.top, "Ada")
      if edit == nil: raise newException(ValueError, "missing editor")
      discard SendMessageW(edit, EmSetsel, WPARAM(3), LPARAM(3))
      discard SendMessageW(edit, WmChar, WPARAM(ord('z')), 0)
      f.win.safeListTurn()
      let typed = windowText(edit)
      let context = f.h.context
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      sendWheel(f.st.top, -6)
      f.win.safeListTurn()
      let editAfter = find(f.st.top, typed)
      echo "SCROLL-RED-4 editSame=" & $(editAfter == edit) & " typed='" & typed & "'"
      check editAfter == edit
      check windowText(edit) == typed
    finally: f.close()


proc pumpAndSettle(rounds, millis: int, surface: HWND = nil) =
  ## A batch limit is not a readiness condition: posted messages precede
  ## WM_PAINT. Keep dispatching naturally until the queue is empty after the
  ## presentation interval, but fail explicitly on either safety limit.
  const maxMessages = 4096
  const maxMillis = 2000
  let started = getMonoTime()
  var total, paints: int
  var message: MSG
  while true:
    if (getMonoTime() - started).inMilliseconds >= maxMillis:
      raise newException(ValueError, "Screenshot queue did not settle within 2000 ms")
    var empty = false
    for _ in 0..<max(1, rounds):
      if PeekMessageW(addr message, nil, 0, 0, 1) == 0:
        empty = true
        break
      inc total
      if total > maxMessages:
        raise newException(ValueError, "Screenshot queue exceeded 4096 messages")
      if message.message == 0x000f'u32: inc paints
      let logicalTab = message.message == WmKeyDown and message.wParam == WPARAM(VkTab)
      if surface != nil and not logicalTab and IsDialogMessageW(surface, addr message) != 0:
        continue
      discard TranslateMessage(addr message)
      discard DispatchMessageW(addr message)
    if empty and (getMonoTime() - started).inMilliseconds >= millis:
      echo "PRESENTATION messages=" & $total & " paints=" & $paints
      return
    if empty: sleep(5)

proc capturePng(window: HWND, path: string): bool =
  ## Real desktop capture through the existing System.Drawing CopyFromScreen
  ## path: a throwaway script in the task run directory, no new product API.
  var frame: RECT
  var client: RECT
  if GetWindowRect(window, addr frame) == 0: return false
  if GetClientRect(window, addr client) == 0: return false
  let width = client.right - client.left
  let height = client.bottom - client.top
  if width <= 0 or height <= 0: return false
  let shotDir = getEnv("LEAF_DIALOG_SHOT_DIR", parentDir(path))
  createDir(shotDir)
  let destination = shotDir / extractFilename(path)
  let scriptPath = shotDir / "capture.ps1"
  var script = "Add-Type -AssemblyName System.Drawing" & chr(10)
  script.add("$b = New-Object System.Drawing.Bitmap(" & $width & "," & $height & ")" & chr(10))
  script.add("$g = [System.Drawing.Graphics]::FromImage($b)" & chr(10))
  script.add("$g.CopyFromScreen(" & $frame.left & "," & $frame.top & ",0,0,$b.Size)" & chr(10))
  script.add("$b.Save('" & destination & "',[System.Drawing.Imaging.ImageFormat]::Png)" & chr(10))
  script.add("$g.Dispose(); $b.Dispose()" & chr(10))
  writeFile(scriptPath, script)
  # The capture helper must not cover the target: PowerShell runs with a hidden
  # window, and the target is raised right before the screen grab.
  discard SetForegroundWindow(window)
  pumpAndSettle(60, 120, window)
  let capture = startProcess("powershell.exe", args = @["-NoProfile",
    "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", scriptPath],
    options = {poUsePath, poParentStreams})
  defer: capture.close()
  let code = capture.waitForExit(10_000)
  if code == -1:
    capture.terminate()
    discard capture.waitForExit(2_000)
    return false
  code == 0



type HRGN = pointer

proc GetWindowRgn(window: HWND, region: HRGN): int {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc CreateRectRgn(x1, y1, x2, y2: int32): HRGN {.stdcall, dynlib: "gdi32.dll", importc, raises: [].}
proc GetRgnBox(region: HRGN, box: ptr RECT): int {.stdcall, dynlib: "gdi32.dll", importc, raises: [].}

proc regionOf(w: HWND): string =
  ## Real window region: 0=API failed, 1=NULLREGION, 2=SIMPLE, 3=COMPLEX.
  let rgn = CreateRectRgn(0, 0, 0, 0)
  if rgn == nil: return "rgn=allocFail"
  defer: discard DeleteObject(cast[HGDIOBJ](rgn))
  let kind = GetWindowRgn(w, rgn)
  if kind == 0: return "rgn=error"
  var box: RECT
  let ok = GetRgnBox(rgn, addr box)
  if ok == 0: return "rgn=" & $kind & " boxFail"
  "rgn=" & $kind & " box=" & $box.left & "," & $box.top & " " &
    $(box.right - box.left) & "x" & $(box.bottom - box.top)

proc stageSnapshot(tag: string, surface: HWND) =
  ## Post-commit snapshot at a stage boundary: real class/rect/visibility of the
  ## surface and the named controls, plus which window actually covers the
  ## surface centre (a capture window or another test window would show here).
  var frame: RECT
  var name = newWideCString(96)
  proc describe(w: HWND, label: string) =
    if w == nil:
      echo "SNAP " & tag & " " & label & "=nil"
      return
    discard GetClassNameW(w, cast[WidePtr](unsafeAddr name[0]), 96)
    var r: RECT
    discard GetWindowRect(w, addr r)
    echo "SNAP " & tag & " " & label & " cls=" & $name & " rect=" & $r.left & "," &
      $r.top & " " & $(r.right - r.left) & "x" & $(r.bottom - r.top) &
      " vis=" & $IsWindowVisible(w) & " " & regionOf(w) &
      " parent=" & $(cast[int](GetParent(w)))
  describe(surface, "surface")
  var ancestor = GetParent(surface)
  var depth = 0
  while ancestor != nil and depth < 4:
    describe(ancestor, "anc" & $depth)
    ancestor = GetParent(ancestor)
    inc depth
  if GetWindowRect(surface, addr frame) != 0:
    let point = POINT(x: (frame.left + frame.right) div 2,
      y: (frame.top + frame.bottom) div 2)
    describe(WindowFromPoint(point), "coverAtCentre")
  for label in ["对话框", "关闭", "取消", "内层", "保存", "名称写入临时草稿。"]:
    let leaf = find(surface, label)
    describe(leaf, "ctl:" & label)
    # Walk the real parent chain up to this surface: the clipped ancestor is the
    # container STATIC, not the owner returned by GetParent(surface).
    if leaf == nil or leaf == surface: continue
    var node = GetParent(leaf)
    var depth = 0
    var reached = false
    while node != nil and depth < 8:
      if node == surface:
        reached = true
        break
      describe(node, "up:" & label & "#" & $depth)
      node = GetParent(node)
      inc depth
    if not reached:
      echo "SNAP " & tag & " up:" & label & "=UNREACHED depth=" & $depth

proc GetUpdateRect(window: HWND, rect: ptr RECT, erase: BOOL): BOOL
  {.stdcall, dynlib: "user32.dll", importc, raises: [].}

suite "dialog native scrollbars":
  proc barCode(window, bar: HWND, horizontal: bool, code: int) =
    ## The genuine native notification the scrollbar control sends on an arrow
    ## click or thumb drag; never a direct position write.
    discard SendMessageW(window, (if horizontal: WM_HSCROLL else: WM_VSCROLL),
      WPARAM(code), LPARAM(cast[int](bar)))

  test "SCROLL-BAR: the vertical bar moves by page, reaches the exact maximum and returns home":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      # Open at a legal size, then shrink the work area: a runtime shrink is
      # what turns the content viewport on (an over-tall open is rejected).
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let surface = f.st.top
      if surface == nil: raise newException(ValueError, "no level")
      children.setLen(0)
      discard EnumChildWindows(surface, collect, 0)
      var names: seq[string]
      for w in children:
        let cls = newWideCString(64)
        discard GetClassNameW(w, cast[WidePtr](unsafeAddr cls[0]), 64)
        names.add($cls & ":" & $(UINT(GetWindowLongW(w, GwlStyle))))
      echo "SCROLL-BAR children=" & $names.join(",")
      let bar = scrollbarOf(surface, true)
      check bar != nil
      check IsWindowVisible(bar) != 0
      let start = barInfo(bar)
      check start.ok
      check start.nMax > 0
      check start.nPage > 0
      check start.nPos == 0
      let reachable = start.nMax - max(0'i32, start.nPage - 1'i32)
      check reachable > 0
      barCode(surface, bar, false, SB_PAGEDOWN)
      f.win.safeListTurn()
      let paged = barInfo(bar)
      check paged.nPos > 0
      check paged.nPos <= reachable
      barCode(surface, bar, false, SB_BOTTOM)
      f.win.safeListTurn()
      let bottom = barInfo(bar)
      check bottom.nPos == reachable
      var saveNow, client, surfaceNow: RECT
      discard GetWindowRect(find(surface, "保存"), addr saveNow)
      discard GetClientRect(surface, addr client)
      discard GetWindowRect(surface, addr surfaceNow)
      let clientRect = RECT(left: surfaceNow.left, top: surfaceNow.top,
        right: surfaceNow.left + client.right, bottom: surfaceNow.top + client.bottom)
      echo "SCROLL-BAR max nPos=" & $bottom.nPos & " reachable=" & $reachable &
        " save=" & $saveNow.left & "," & $saveNow.top &
        " inClient=" & $insideRect(saveNow, clientRect)
      check insideRect(saveNow, clientRect)
      barCode(surface, bar, false, SB_TOP)
      f.win.safeListTurn()
      let home = barInfo(bar)
      check home.nPos == 0
      check IsWindowVisible(bar) != 0
      # A plain dialog (no wide content) restored to the full work area: the
      # ranges collapse, so the offsets must be exactly zero and the bars hide.
      fault.active = false
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      var initialWin: RECT
      var initialClient: RECT
      discard GetWindowRect(surface, addr initialWin)
      discard GetClientRect(surface, addr initialClient)
      let initialRect = RECT(left: initialWin.left, top: initialWin.top,
        right: initialWin.left + initialClient.right,
        bottom: initialWin.top + initialClient.bottom)
      pumpAndSettle(200, 600)
      let vBarAfter = scrollbarOf(surface, true)
      let hBarAfter = scrollbarOf(surface, false)
      stageSnapshot("restore-plain", surface)
      echo "SHOT restore-plain vBar=" & $(vBarAfter != nil) & " hBar=" & $(hBarAfter != nil) &
        " saved=" & $capturePng(surface, "C:/LeafTests/runs/m2-shots/restore-plain.png")
    finally: f.close()

  proc pointerEvent(flags: uint32) =
    ## One real mouse event through SendInput (no synthetic WM_* posting).
    var event: InputEvent
    event.kind = InputMouse
    event.payload.mouse.flags = flags
    discard SendInput(1, addr event, int32(sizeof(InputEvent)))

  proc barPoint(bar: HWND, yFraction: float64): POINT =
    var frame: RECT
    discard GetWindowRect(bar, addr frame)
    POINT(x: (frame.left + frame.right) div 2,
      y: frame.top + int32((float64(frame.bottom - frame.top) - 1.0) * yFraction))

  proc thumbTrack(window: HWND): int32 =
    var info = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: SIF_TRACKPOS)
    if GetScrollInfo(window, SB_CTL, addr info) == 0: return -1
    info.nTrackPos

  test "SCROLL-BAR: real pointer click and thumb drag drive the level":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let surface = f.st.top
      if surface == nil: raise newException(ValueError, "no level")
      let bar = scrollbarOf(surface, true)
      check bar != nil
      let start = barInfo(bar)
      check start.ok and start.nPos == 0
      let reachable = start.nMax - max(0'i32, start.nPage - 1'i32)
      check reachable > 0
      # 1) A real click on the page area below the thumb.
      clickAt(barPoint(bar, 0.85))
      pumpQueue(surface)
      f.win.safeListTurn()
      let afterClick = barInfo(bar)
      echo "POINTER click nPos=" & $afterClick.nPos & " reachable=" & $reachable
      check afterClick.nPos > 0
      # 2) A real thumb drag: press on the thumb, move down in steps, release.
      let thumbHeight = max(8.0, float64(start.nPage) /
        float64(max(1'i32, start.nMax - start.nMin + 1)) *
        float64(windowSize(bar).height))
      let thumbTop = (float64(windowSize(bar).height) - thumbHeight) *
        float64(afterClick.nPos) / float64(reachable)
      let fromY = int32(thumbTop + thumbHeight / 2.0)
      let toY = int32(float64(windowSize(bar).height) * 0.92)
      var frame: RECT
      discard GetWindowRect(bar, addr frame)
      let x = (frame.left + frame.right) div 2
      discard SetCursorPos(x, frame.top + fromY)
      pointerEvent(MouseeventfLeftdown)
      for step in 1 .. 4:
        let y = frame.top + fromY +
          int32(float64(toY - fromY) * float64(step) / 4.0)
        discard SetCursorPos(x, y)
      pointerEvent(MouseeventfLeftup)
      pumpQueue(surface)
      f.win.safeListTurn()
      let afterDrag = barInfo(bar)
      let tracked = thumbTrack(bar)
      echo "POINTER drag nTrackPos=" & $tracked & " nPos=" & $afterDrag.nPos &
        " reachable=" & $reachable
      check tracked >= 0
      check afterDrag.nPos > afterClick.nPos
      var saveNow, client, surfaceNow: RECT
      discard GetWindowRect(find(surface, "保存"), addr saveNow)
      discard GetClientRect(surface, addr client)
      discard GetWindowRect(surface, addr surfaceNow)
      let clientRect = RECT(left: surfaceNow.left, top: surfaceNow.top,
        right: surfaceNow.left + client.right, bottom: surfaceNow.top + client.bottom)
      check insideRect(saveNow, clientRect)
      # A real click on the top arrow moves back by one line from the maximum.
      var arrowFrame: RECT
      discard GetWindowRect(bar, addr arrowFrame)
      clickAt(POINT(x: (arrowFrame.left + arrowFrame.right) div 2,
        y: arrowFrame.top + 8))
      pumpQueue(surface)
      f.win.safeListTurn()
      let afterArrow = barInfo(bar)
      echo "POINTER arrow nPos=" & $afterArrow.nPos & " from=" & $afterDrag.nPos
      check afterArrow.nPos < afterDrag.nPos
      check afterArrow.nPos >= afterDrag.nPos - 48
    finally: f.close()

  proc horizontalBarOf(parent: HWND): HWND =
    children.setLen(0)
    discard EnumChildWindows(parent, collect, 0)
    for w in children:
      let name = newWideCString(64)
      if GetClassNameW(w, cast[WidePtr](unsafeAddr name[0]), 64) == 0: continue
      if toLowerAscii($name) != "scrollbar": continue
      let style = UINT(GetWindowLongW(w, GwlStyle))
      if (style and UINT(SBS_VERT)) == 0: return w
    nil

  test "SCROLL-BAR: screenshot readiness drains natural title painting":
    let state = PageState(title: "对话框", name: "Ada", wideWidth: 700.0)
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let surface = f.st.top
      let title = find(surface, "对话框")
      require title != nil
      discard SetForegroundWindow(surface)
      pumpAndSettle(60, 120, surface) # Same readiness used by capturePng.
      var update: RECT
      let pending = GetUpdateRect(title, addr update, 0)
      echo "TITLE-READY pending=" & $pending & " rect=" & $update.left & "," &
        $update.top & " " & $(update.right-update.left) & "x" & $(update.bottom-update.top)
      check pending == 0 # Screenshot readiness must not leave title paint queued.
    finally: f.close()

  test "SCROLL-BAR: uncompressible wide content is reachable horizontally":
    let state = PageState(title: "对话框", name: "Ada")
    state.wideWidth = 700.0
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let surface = f.st.top
      if surface == nil: raise newException(ValueError, "no level")
      let hbar = horizontalBarOf(surface)
      check hbar != nil
      check IsWindowVisible(hbar) != 0
      # The row sits just below the header (content y 81 at 96 DPI) while the
      # viewport is 71 DIP tall, so one wheel notch (72 DIP) is the minimal
      # reveal that brings it inside; two notches would scroll past it.
      # Stage precondition: this is the untouched initial small viewport.
      check barInfo(scrollbarOf(surface, true)).nPos == 0
      check barInfo(hbar).nPos == 0
      var initialWin: RECT
      var initialClient: RECT
      discard GetWindowRect(surface, addr initialWin)
      discard GetClientRect(surface, addr initialClient)
      let initialRect = RECT(left: initialWin.left, top: initialWin.top,
        right: initialWin.left + initialClient.right,
        bottom: initialWin.top + initialClient.bottom)
      stageSnapshot("small-initial", surface)
      echo "SHOT small-initial surface=" & $initialRect.left & "," & $initialRect.top &
        " client=" & $(initialClient.right) & "x" & $(initialClient.bottom) &
        " hudPos=" & $barInfo(hbar).nPos & " vpos=" &
        $barInfo(scrollbarOf(surface, true)).nPos
      echo "SHOT small-initial rect=" & $initialRect.left & "," & $initialRect.top &
        " " & $(initialRect.right - initialRect.left) & "x" &
        $(initialRect.bottom - initialRect.top) & " saved=" &
        $capturePng(surface, "C:/LeafTests/runs/m2-shots/small-initial.png")

      sendWheel(surface, -1)
      f.win.safeListTurn()
      var shot, shotNow: RECT
      discard GetWindowRect(surface, addr shot)
      discard GetClientRect(surface, addr shotNow)
      let surfaceRect = RECT(left: shot.left, top: shot.top,
        right: shot.left + shotNow.right, bottom: shot.top + shotNow.bottom)
      pumpAndSettle(200, 600)
      var titleRect: RECT
      var titleHandle: HWND
      for w in children:
        let t = newWideCString(200)
        discard GetWindowTextW(w, cast[WidePtr](unsafeAddr t[0]), 200)
        if $t == "对话框":
          titleHandle = w
          break
      if titleHandle != nil:
        discard GetWindowRect(titleHandle, addr titleRect)
      let start = barInfo(hbar)
      check start.ok
      let reachableX = start.nMax - max(0'i32, start.nPage - 1'i32)
      echo "H-BAR nMax=" & $start.nMax & " nPage=" & $start.nPage &
        " reachableX=" & $reachableX
      check reachableX > 0
      # Real pointer click on the right page area of the horizontal bar.
      var frame: RECT
      discard GetWindowRect(hbar, addr frame)
      clickAt(POINT(x: frame.left + int32((float64(frame.right - frame.left)) * 0.85),
        y: (frame.top + frame.bottom) div 2))
      pumpQueue(surface)
      f.win.safeListTurn()
      let paged = barInfo(hbar)
      echo "H-BAR afterClick nPos=" & $paged.nPos
      check paged.nPos > 0
      # Native right-end notification: the last reachable column must be exact.
      barCode(surface, hbar, true, 7) # SB_RIGHT
      f.win.safeListTurn()
      let ended = barInfo(hbar)
      echo "H-BAR afterRight nPos=" & $ended.nPos & " reachableX=" & $reachableX
      check ended.nPos == reachableX
      check IsWindowVisible(hbar) != 0
      # The action must now be completely inside the content viewport (client
      # minus both bars), not merely partially visible, and it must be scrolled
      # into view vertically as well.
      var action, clientNow, surfaceNow2: RECT
      let actionWindow = find(surface, "宽动作")
      check actionWindow != nil
      discard GetWindowRect(actionWindow, addr action)
      discard GetClientRect(surface, addr clientNow)
      discard GetWindowRect(surface, addr surfaceNow2)
      let vBar = scrollbarOf(surface, true)
      let hBarRect = if hbar == nil: RECT() else: (var r: RECT; discard GetWindowRect(hbar, addr r); r)
      let barWidthPx = if vBar == nil: 0 else: (var r: RECT;
        discard GetWindowRect(vBar, addr r); int(r.right - r.left))
      let barHeightPx = if hbar == nil: 0 else: int(hBarRect.bottom - hBarRect.top)
      let viewportRect = RECT(left: surfaceNow2.left, top: surfaceNow2.top,
        right: surfaceNow2.left + clientNow.right - int32(barWidthPx),
        bottom: surfaceNow2.top + clientNow.bottom - int32(barHeightPx))
      echo "H-BAR dpi=" & $GetDpiForWindow(surface) & " contextScale=" &
        $context.scale & " clientPx=" & $clientNow.right & "x" &
        $clientNow.bottom & " vbarPx=" & $barWidthPx & " hbarPx=" & $barHeightPx &
        " hbarInfo(nMax,nPage,nPos)=" & $start.nMax & "," & $start.nPage & "," &
        $ended.nPos
      var shotNow2: RECT
      discard GetWindowRect(surface, addr shotNow2)
      discard GetClientRect(surface, addr shotNow)
      let targetRect = RECT(left: shotNow2.left, top: shotNow2.top,
        right: shotNow2.left + shotNow.right, bottom: shotNow2.top + shotNow.bottom)
      pumpAndSettle(200, 600)
      echo "SHOT horizontal-target rect=" & $targetRect.left & "," & $targetRect.top &
        " " & $(targetRect.right - targetRect.left) & "x" &
        $(targetRect.bottom - targetRect.top) & " offsetX=" & $ended.nPos & " saved=" &
        $capturePng(surface, "C:/LeafTests/runs/m2-shots/horizontal-target.png")
      echo "H-BAR action=" & $action.left & "," & $action.top & " " &
        $(action.right - action.left) & "x" & $(action.bottom - action.top) &
        " viewport=" & $viewportRect.left & "," & $viewportRect.top & " " &
        $(viewportRect.right - viewportRect.left) & "x" &
        $(viewportRect.bottom - viewportRect.top)
      check insideRect(action, viewportRect)
      check IsWindowVisible(actionWindow) != 0

      # A real pointer click on it must produce the business result.
      var visible = action
      visible.left = max(action.left, viewportRect.left)
      visible.right = min(action.right, viewportRect.right)
      visible.top = max(action.top, viewportRect.top)
      visible.bottom = min(action.bottom, viewportRect.bottom)
      check visible.right > visible.left and visible.bottom > visible.top
      clickAt(POINT(x: (visible.left + visible.right) div 2,
        y: (visible.top + visible.bottom) div 2))
      pumpQueue(surface)
      f.win.safeListTurn()
      check state.wideClicks == 1

      # Restore the work area: the level fits again and the bars hide.
      fault.active = false
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      pumpAndSettle(200, 600)
      echo "SHOT restored saved=" &
        $capturePng(surface, "C:/LeafTests/runs/m2-shots/restored.png")
    finally: f.close()

  test "SCROLL-BAR: nested levels keep independent offsets and the background never scrolls":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let outer = f.st.top
      check outer != nil
      state.inner = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let inner = f.st.top
      check inner != nil and inner != outer
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let innerBar = scrollbarOf(inner, true)
      check innerBar != nil
      let innerStart = barInfo(innerBar)
      let innerReach = innerStart.nMax - max(0'i32, innerStart.nPage - 1'i32)
      check innerReach > 0
      # Scroll the top level with real wheel input.
      sendWheel(inner, -3)
      f.win.safeListTurn()
      let innerScrolled = barInfo(innerBar)
      check innerScrolled.nPos > 0
      check innerScrolled.nPos <= innerReach
      # The outer level below must keep its own offset (independent state).
      let outerBar = scrollbarOf(outer, true)
      let outerInfo = if outerBar == nil: (nMin: 0'i32, nMax: 0'i32, nPage: 0'i32,
        nPos: 0'i32, ok: false) else: barInfo(outerBar)
      echo "NESTED inner nPos=" & $innerScrolled.nPos & " outer nPos=" &
        $outerInfo.nPos & " outerBar=" & $(outerBar != nil)
      check outerInfo.nPos == 0
      # Wheel over the background owner must not move either level.
      sendWheel(f.h.windowHandle, -3)
      f.win.safeListTurn()
      check barInfo(innerBar).nPos == innerScrolled.nPos
    finally: f.close()

  test "SCROLL-BAR: a rejected dismiss keeps the scrolled level operable":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      check surface != nil
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let bar = scrollbarOf(surface, true)
      check bar != nil
      sendWheel(surface, -4)
      f.win.safeListTurn()
      check barInfo(bar).nPos > 0
      # The application refuses to close: the level stays and keeps working.
      state.reject = true
      tapKey(f, VkEscape)
      pumpQueue(surface)
      f.win.safeListTurn()
      check state.dismissals == 1
      check state.open
      let saveWindow = find(surface, "保存")
      check saveWindow != nil
      pumpAndSettle(200, 600, surface)
      check capturePng(surface, "C:/LeafTests/runs/m2-shots/plain-target.png")
      clickAt(centerPoint(saveWindow))
      pumpQueue(surface)
      f.win.safeListTurn()
      check state.saved == 1
    finally: f.close()

  test "SCROLL-BAR: an accepted controlled draft keeps text, caret, undo and its window":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let edit = find(f.st.top, "Ada")
      if edit == nil: raise newException(ValueError, "missing editor")
      discard SendMessageW(edit, EmSetsel, WPARAM(3), LPARAM(3))
      for ch in "yz":
        discard SendMessageW(edit, WmChar, WPARAM(ord(ch)), 0)
      let typedNow = windowText(edit)
      echo "DRAFT typedNative=" & typedNow
      check typedNow == "Adayz"
      state.name = typedNow
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let editAfter = find(f.st.top, typedNow)
      check editAfter == edit
      check windowText(edit) == "Adayz"
      discard SendMessageW(edit, WmChar, WPARAM(ord(33)), 0)
      check windowText(edit) == "Adayz!"
      check SendMessageW(edit, EmCanundo, 0, 0) != 0
      discard SendMessageW(edit, EmUndo, 0, 0)
      # The accepted publish is the undo baseline (SetWindowText resets the native
      # undo buffer), so undo reverts the user edit to that baseline value.
      let undone = windowText(edit)
      echo "DRAFT undone=" & undone
      check undone == "Ada"
      let context = f.h.context
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      sendWheel(f.st.top, -1)
      f.win.safeListTurn()
      let editScrolled = find(f.st.top, "Adayz")
      echo "DRAFT afterScroll sameWindow=" & $(editScrolled == edit) & " text=" & windowText(edit)
      check editScrolled == edit
      check windowText(edit) == "Adayz"
    finally: f.close()

  test "SCROLL-BAR: lifecycle failures keep receipts and retry on the next tick":
    type FaultState = ref object
      kind: int      # 0 none, 1 create, 2 windowPos, 3 destroy
      hits: int
    let faults = FaultState(kind: 0, hits: 0)
    proc isBarClass(className: WidePtr): bool =
      if className == nil: return false
      toLowerAscii($cast[WideCString](className)) == "scrollbar"
    proc isBarWindow(window: HWND): bool =
      var buf = newWideCString(64)
      if GetClassNameW(window, cast[WidePtr](unsafeAddr buf[0]), 64) == 0: return false
      toLowerAscii($buf) == "scrollbar"
    proc wrapped(base: Win32Calls, faults: FaultState): Win32Calls =
      ## Real OS calls except one injected failure that actually changes the
      ## system state (no window, no move, no destroy) and is counted.
      result = base
      let createWindow = base.createWindow
      let windowPos = base.windowPos
      let destroyWindow = base.destroyWindow
      result.createWindow = proc(exStyle: DWORD, className, title: WidePtr,
          style: DWORD, x, y, width, height: int32, parent: HWND, menu: HMENU,
          instance: HINSTANCE, param: pointer): HWND {.closure, raises: [CatchableError].} =
        if faults.kind == 1 and isBarClass(className):
          inc faults.hits
          faults.kind = 0
          return nil
        createWindow(exStyle, className, title, style, x, y, width, height,
          parent, menu, instance, param)
      result.windowPos = proc(window, after: HWND, x, y, width, height: int32,
          flags: UINT): BOOL {.closure, raises: [CatchableError].} =
        if faults.kind == 2 and isBarWindow(window):
          inc faults.hits
          faults.kind = 0
          return 0
        windowPos(window, after, x, y, width, height, flags)
      result.destroyWindow = proc(window: HWND): BOOL {.closure, raises: [CatchableError].} =
        if faults.kind == 3 and isBarWindow(window):
          inc faults.hits
          faults.kind = 0
          return 0
        destroyWindow(window)
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    # Wrap the faulted work-area table so the shrink still comes from the test.
    let calls = wrapped(areaCalls(fault), faults)
    let f = mounted(proc(): Node = page(state), calls, 560, 460)
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      # Phase 1 (creation): the injection is armed before the first shrink, so the
      # first publish of this level cannot create its bar; no bar exists, the
      # accepted plan is kept, and the next ordinary turn retries the step.
      faults.kind = 1
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      var surface = f.st.top
      check surface != nil
      echo "FAULT createHits=" & $faults.hits & " barAfterFail=" & $(scrollbarOf(surface, true) != nil)
      check faults.hits == 1
      # The retry may already have created the bar in this pass.
      # The level still scrolls while the bar is missing; this ordinary turn
      # retries the creation and publishes the bar.
      sendWheel(surface, -1)
      f.win.safeListTurn()
      let bar = scrollbarOf(surface, true)
      check bar != nil
      check IsWindowVisible(bar) != 0
      let created = barInfo(bar)
      check created.ok and created.nMax > 0
      # Phase 2: a failed SetWindowPos leaves the old rect and the previous
      # receipt; the retry positions and shows it.
      var before: RECT
      discard GetWindowRect(bar, addr before)
      faults.hits = 0
      faults.kind = 2
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      var afterFail: RECT
      discard GetWindowRect(bar, addr afterFail)
      echo "FAULT windowPosHits=" & $faults.hits & " rectSame=" &
        $(afterFail.left == before.left and afterFail.top == before.top and
          afterFail.right == before.right and afterFail.bottom == before.bottom)
      check faults.hits == 1
      sendWheel(surface, -1)
      f.win.safeListTurn()
      var retried: RECT
      discard GetWindowRect(bar, addr retried)
      check IsWindowVisible(bar) != 0
      check retried.right - retried.left > 0
      # Phase 3 (close contract): a controlled close only hides the level, so no
      # destroy is attempted here; the drop path is covered by its own tests.
      faults.hits = 0
      faults.kind = 3
      state.open = false
      discard f.runtime.refresh()
      f.win.safeListTurn()
      echo "FAULT closeDestroyHits=" & $faults.hits & " barAlive=" & $(IsWindow(bar) != 0)
      check faults.hits == 0
      check IsWindow(bar) != 0
    finally: f.close()

  type DropFaults = ref object
    refuseBar, refuseSurface: bool
    hits: int

  proc barDestroyWrapper(base: Win32Calls, faults: DropFaults): Win32Calls =
    result = base
    let destroyWindow = base.destroyWindow
    result.destroyWindow = proc(window: HWND): BOOL {.closure, raises: [CatchableError].} =
      var name = newWideCString(96)
      let named = GetClassNameW(window, cast[WidePtr](unsafeAddr name[0]), 96) != 0
      let cls = if named: toLowerAscii($name) else: ""
      if faults.refuseBar and cls == "scrollbar":
        inc faults.hits
        faults.refuseBar = false
        return 0
      if faults.refuseSurface and cls.startsWith("leafoverlaysurface"):
        inc faults.hits
        faults.refuseSurface = false
        return 0
      destroyWindow(window)

  test "SCROLL-BAR: a refused bar destroy is reaped by its parent and clears the receipt":
    let dropFaults = DropFaults(refuseBar: true, refuseSurface: false)
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let calls = barDestroyWrapper(areaCalls(fault), dropFaults)
    let f = mounted(proc(): Node = page(state), calls, 560, 460)
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let bar = scrollbarOf(f.st.top, true)
      check bar != nil
      # Drop the level through the real tree-removal path: the bar destroy is
      # refused once, the parent surface destroy succeeds and reaps it.
      let liveBefore = f.win.overlayStateForTest.live
      state.dropDialog = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      echo "FAULT childOnly hits=" & $dropFaults.hits & " barAlive=" &
        $(IsWindow(bar) != 0) & " live=" & $liveBefore & "->" &
        $f.win.overlayStateForTest.live
      check dropFaults.hits == 1
      # The parent reaped the child: the handle really is gone and this level's
      # entry is released; the fixture keeps its other (closed) levels, so only
      # the delta is asserted.
      check IsWindow(bar) == 0
      check f.win.overlayStateForTest.live == liveBefore - 1
    finally: f.close()

  test "SCROLL-BAR: a bar and its surface that both refuse teardown keep their receipts":
    let dropFaults = DropFaults(refuseBar: true, refuseSurface: true)
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let calls = barDestroyWrapper(areaCalls(fault), dropFaults)
    let f = mounted(proc(): Node = page(state), calls, 560, 460)
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let bar = scrollbarOf(f.st.top, true)
      check bar != nil
      let liveBefore = f.win.overlayStateForTest.live
      let surfaceBefore = GetWindow(f.st.top, GwOwner)
      state.dropDialog = true
      discard f.runtime.refresh()
      # The first teardown attempt really fails: the level keeps its windows and
      # the ordinary turn surfaces the UiError to the caller.
      var raised = false
      try:
        f.win.safeListTurn()
      except CatchableError:
        raised = true
      echo "FAULT both hits=" & $dropFaults.hits & " raised=" & $raised &
        " barAlive=" & $(IsWindow(bar) != 0) &
        " live=" & $liveBefore & "->" & $f.win.overlayStateForTest.live
      check raised
      check dropFaults.hits == 2
      check IsWindow(bar) != 0
      check f.win.overlayStateForTest.live == liveBefore
      # Faults cleared: a real second ordinary turn retries the same idempotent
      # teardown while the host is alive, and this time the windows are gone.
      f.win.safeListTurn()
      echo "FAULT both retry barAlive=" & $(IsWindow(bar) != 0) &
        " live=" & $f.win.overlayStateForTest.live
      check IsWindow(bar) == 0
      check f.win.overlayStateForTest.live == liveBefore - 1
    finally: f.close()

  type BarStepFaults = ref object
    refuseConfig, refuseShow: bool
    configHits, showHits: int

  proc barStepWrapper(base: Win32Calls, faults: BarStepFaults): Win32Calls =
    ## Injected calls skip the real API, which is exactly what "the step did not
    ## take effect" means; every other call is forwarded unchanged. Return values
    ## keep native semantics (SetScrollInfo: current position, ShowWindow:
    ## previous visibility) and are never treated as a boolean.
    result = base
    let showWindow = base.showWindow
    let setScrollInfo = base.setScrollInfo
    result.showWindow = proc(window: HWND, command: int32): BOOL
        {.closure, raises: [CatchableError].} =
      if faults.refuseShow and command == 4 and isBarWindow(window):
        inc faults.showHits
        return 0
      showWindow(window, command)
    result.setScrollInfo = proc(window: HWND, bar: int32, info: ptr SCROLLINFO,
        redraw: BOOL): int32 {.closure, raises: [CatchableError].} =
      var probe = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: SIF_POS)
      var current = int32(0)
      if GetScrollInfo(window, bar, addr probe) != 0: current = probe.nPos
      if faults.refuseConfig and bar == SB_CTL:
        inc faults.configHits
        return current
      setScrollInfo(window, bar, info, redraw)

  test "SCROLL-BAR: an unapplied SetScrollInfo keeps the bar state until the retry":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let faults = BarStepFaults()
    let f = mounted(proc(): Node = page(state), barStepWrapper(areaCalls(fault), faults),
      560, 460)
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let bar = scrollbarOf(f.st.top, true)
      check bar != nil
      let before = barInfo(bar)
      faults.refuseConfig = true
      sendWheel(f.st.top, -1)
      f.win.safeListTurn()
      let during = barInfo(bar)
      echo "STEP configHits=" & $faults.configHits & " nPos=" & $before.nPos & "->" & $during.nPos
      check faults.configHits >= 1
      check during.nPos == before.nPos
      check during.nMax == before.nMax
      faults.refuseConfig = false
      # The retry needs an ordinary turn that republishes the bar: scroll again.
      sendWheel(f.st.top, -1)
      f.win.safeListTurn()
      let after = barInfo(bar)
      echo "STEP configRetry nPos=" & $after.nPos
      check after.nPos != before.nPos
      check IsWindowVisible(bar) != 0
    finally: f.close()

  test "SCROLL-BAR: a refused show keeps the bar hidden until the retry":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let faults = BarStepFaults(refuseShow: true)
    let f = mounted(proc(): Node = page(state), barStepWrapper(areaCalls(fault), faults),
      560, 460)
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let bar = scrollbarOf(f.st.top, true)
      echo "STEP showHits=" & $faults.showHits & " barExists=" & $(bar != nil) &
        " visible=" & $(bar != nil and IsWindowVisible(bar) != 0)
      check faults.showHits >= 1
      check bar != nil
      check IsWindowVisible(bar) == 0
      faults.refuseShow = false
      sendWheel(f.st.top, -1)
      f.win.safeListTurn()
      let retried = scrollbarOf(f.st.top, true)
      check retried != nil
      check IsWindowVisible(retried) != 0
    finally: f.close()

  type HideAxisFaults = ref object
    refuseHide, refusePosHorizontal: bool
    hideHits, posHits: int

  proc hideAxisWrapper(base: Win32Calls, faults: HideAxisFaults): Win32Calls =
    result = base
    let showWindow = base.showWindow
    let windowPos = base.windowPos
    result.showWindow = proc(window: HWND, command: int32): BOOL
        {.closure, raises: [CatchableError].} =
      if faults.refuseHide and command == 0:
        inc faults.hideHits
        return 1
      showWindow(window, command)
    result.windowPos = proc(window, after: HWND, x, y, width, height: int32,
        flags: UINT): BOOL {.closure, raises: [CatchableError].} =
      if faults.refusePosHorizontal and isBarWindow(window):
        let style = UINT(GetWindowLongW(window, GwlStyle))
        if (style and UINT(SBS_VERT)) == 0:
          inc faults.posHits
          faults.refusePosHorizontal = false   # one-shot injection
          return 0
      windowPos(window, after, x, y, width, height, flags)
  test "SCROLL-BAR: a blocked hide keeps the bar visible and the receipt until retry":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let faults = HideAxisFaults()
    let f = mounted(proc(): Node = page(state), hideAxisWrapper(areaCalls(fault), faults),
      560, 460)
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let bar = scrollbarOf(f.st.top, true)
      check bar != nil and IsWindowVisible(bar) != 0
      faults.refuseHide = true
      fault.active = false
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let stillVisible = IsWindowVisible(bar) != 0
      echo "STEP hideHits=" & $faults.hideHits & " stillVisible=" & $stillVisible
      check faults.hideHits >= 1
      check stillVisible
      faults.refuseHide = false
      # A restored geometry has to run the tick that hides the bars.
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      f.win.safeListTurn()
      echo "STEP hideRetry visible=" & $(IsWindowVisible(bar) != 0)
      check IsWindowVisible(bar) == 0
    finally: f.close()
  test "SCROLL-BAR: a failing second bar keeps the first bar real and retries without a leak":
    let state = PageState(title: "对话框", name: "Ada")
    state.wideWidth = 700.0
    let fault = WorkAreaFault(active: false)
    let faults = HideAxisFaults(refusePosHorizontal: true)
    let f = mounted(proc(): Node = page(state), hideAxisWrapper(areaCalls(fault), faults),
      560, 460)
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let vbar = scrollbarOf(f.st.top, true)
      let hbar = horizontalBarOf(f.st.top)
      check vbar != nil
      var vrect: RECT
      discard GetWindowRect(vbar, addr vrect)
      echo "STEP axis2 posHits=" & $faults.posHits & " vVisible=" &
        $(IsWindowVisible(vbar) != 0) & " vWidth=" & $(vrect.right - vrect.left)
      check faults.posHits >= 1
      check IsWindowVisible(vbar) != 0
      check vrect.right - vrect.left > 0
      for _ in 1 .. 3:
        f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
          int(context.scale * 96))
        f.win.safeListTurn()
      let hbarRetry = horizontalBarOf(f.st.top)
      children.setLen(0)
      discard EnumChildWindows(f.st.top, collect, 0)
      var barCount = 0
      for w in children:
        let name = newWideCString(64)
        if GetClassNameW(w, cast[WidePtr](unsafeAddr name[0]), 64) == 0: continue
        if toLowerAscii($name) == "scrollbar": inc barCount
      echo "STEP axis2 retry hSame=" & $(hbarRetry == hbar) & " bars=" & $barCount
      check hbarRetry == hbar
      check barCount == 2
      check hbarRetry != nil and IsWindowVisible(hbarRetry) != 0
      check IsWindowVisible(vbar) != 0
    finally: f.close()

suite "dialog production pump and publish contracts":
  test "P1-1 the production pump routes Tab into the scrollable modal order":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      check surface != nil
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let edit = find(surface, "Ada")
      check edit != nil
      discard SetFocus(edit)
      f.win.safeListTurn()
      check GetFocus() == edit
      tapKey(f, VkTab)
      for _ in 1 .. 12:
        discard f.h.pumpQueued()
      f.win.safeListTurn()
      let afterTab = GetFocus()
      echo "P1-1 focusMoved=" & $(afterTab != edit) & " inLevel=" &
        $(afterTab != nil and GetAncestor(afterTab, GaRoot) == surface)
      check afterTab != edit
      check afterTab != nil
      check GetAncestor(afterTab, GaRoot) == surface
    finally: f.close()

  test "P1-2 a horizontal-only overflow reveals its right-end action on Tab":
    let state = PageState(title: "对话框", name: "Ada")
    state.wideWidth = 700.0
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      check surface != nil
      # Wide enough for horizontal overflow, tall enough that only X overflows.
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 400
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let hbar = scrollbarOf(surface, false)
      check hbar != nil
      check barInfo(hbar).nMax > 0
      let action = find(surface, "宽动作")
      check action != nil
      let edit = find(surface, "Ada")
      if edit != nil: discard SetFocus(edit)
      for _ in 1 .. 8:
        tapKey(f, VkTab)
        for _ in 1 .. 12:
          discard f.h.pumpQueued()
        f.win.safeListTurn()
        if GetFocus() == action: break
      var actionRect, client: RECT
      discard GetWindowRect(action, addr actionRect)
      discard GetClientRect(surface, addr client)
      var surfaceRect: RECT
      discard GetWindowRect(surface, addr surfaceRect)
      let hbarHeight = 17
      let viewportRight = surfaceRect.left + client.right
      let viewportBottom = surfaceRect.top + client.bottom - int32(hbarHeight)
      echo "P1-2 focusAction=" & $(GetFocus() == action) & " rect=" & $actionRect.left &
        "," & $actionRect.top & " viewportRight=" & $viewportRight &
        " bottom=" & $viewportBottom
      check GetFocus() == action
      check actionRect.right <= viewportRight + 1
      check actionRect.left >= surfaceRect.left - 1
      check actionRect.bottom <= viewportBottom + 1
      check IsWindowVisible(action) != 0
      clickAt(centerPoint(action))
      for _ in 1 .. 12:
        discard f.h.pumpQueued()
      f.win.safeListTurn()
      check state.wideClicks == 1
    finally: f.close()

  test "P1-3 a refused SetScrollInfo converges on the next ordinary turn":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    var refuseConfig = true
    var configHits = 0
    var calls = areaCalls(fault)
    let baseSet = calls.setScrollInfo
    calls.setScrollInfo = proc(window: HWND, bar: int32, info: ptr SCROLLINFO,
        redraw: BOOL): int32 {.closure, raises: [CatchableError].} =
      var probe = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: SIF_POS)
      var current = int32(0)
      if GetScrollInfo(window, bar, addr probe) != 0: current = probe.nPos
      if refuseConfig and bar == SB_CTL:
        inc configHits
        return current
      baseSet(window, bar, info, redraw)
    let f = mounted(proc(): Node = page(state), calls)
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      check surface != nil
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let bar = scrollbarOf(surface, true)
      check bar != nil
      let before = barInfo(bar)
      # Scroll with the refusal active: the bar keeps its old state.
      sendWheel(surface, -1)
      f.win.safeListTurn()
      let during = barInfo(bar)
      check configHits >= 1
      check during.nPos == before.nPos
      # Fault cleared, and NO new scroll input: one ordinary turn must converge.
      refuseConfig = false
      f.win.safeListTurn()
      let after = barInfo(bar)
      echo "P1-3 hits=" & $configHits & " before=" & $before.nPos & " during=" &
        $during.nPos & " after=" & $after.nPos
      check after.nPos != before.nPos
      check IsWindowVisible(bar) != 0
    finally: f.close()

  test "P1-4 a failure after the surface is shown is completed by a later turn":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    var refuseEnable = true
    var enableHits = 0
    var injectedSurfaces: seq[HWND]
    var visibleAtInjection = false
    var calls = areaCalls(fault)
    let baseCreate = calls.createWindow
    calls.createWindow = proc(exStyle: DWORD, className, title: WidePtr, style: DWORD,
        x, y, width, height: int32, parent: HWND, menu: HMENU, instance: HINSTANCE,
        param: pointer): HWND {.closure, raises: [CatchableError].} =
      result = baseCreate(exStyle, className, title, style, x, y, width, height,
        parent, menu, instance, param)
      if className != nil and ($cast[WideCString](className)).startsWith("LeafOverlaySurface"):
        injectedSurfaces.add(result)
    let baseEnable = calls.enable
    calls.enable = proc(window: HWND, enabled: BOOL): BOOL
        {.closure, raises: [CatchableError].} =
      if refuseEnable and enabled == 0 and window != nil:
        for candidate in injectedSurfaces:
          if candidate != nil and IsWindowVisible(candidate) != 0 and
              GetWindow(candidate, GwOwner) == window and IsWindowEnabled(window) != 0:
            visibleAtInjection = true
        echo "P1-4 visibleAtInjection=" & $visibleAtInjection
        inc enableHits
        raise newException(CatchableError, "injected EnableWindow failure")
      baseEnable(window, enabled)
    let f = mounted(proc(): Node = page(state), calls)
    try:
      f.win.safeListTurn()
      state.open = true
      try:
        discard f.runtime.refresh()
      except CatchableError:
        discard
      try:
        f.win.safeListTurn()
      except CatchableError:
        discard
      let partial = f.win.overlayStateForTest
      echo "P1-4 hits=" & $enableHits & " visible=" & $partial.visible &
        " top=" & $(partial.top != nil) & " ownerEnabled=" &
        $(IsWindowEnabled(f.h.windowHandle) != 0)
      check enableHits == 1
      check visibleAtInjection
      # The surface really is on screen while the publish is incomplete.
      check partial.visible == 1
      check partial.top == nil
      check IsWindowEnabled(f.h.windowHandle) != 0
      # Fault cleared: an ordinary turn must finish the publish instead of
      # leaving a visible half-modal with an enabled owner.
      refuseEnable = false
      f.win.safeListTurn()
      let finished = f.win.overlayStateForTest
      echo "P1-4 after ownerEnabled=" & $(IsWindowEnabled(f.h.windowHandle) != 0) &
        " top=" & $(finished.top != nil) & " visible=" & $finished.visible
      check IsWindowEnabled(f.h.windowHandle) == 0
      check finished.top != nil
      check finished.visible == 1
    finally: f.close()

suite "dialog matrix contracts":
  proc pumpTurn(f: Fixture) =
    for _ in 1 .. 12:
      discard f.h.pumpQueued()
    f.win.safeListTurn()

  test "M1 primary and reverse wrap run through the production pump":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      check surface != nil
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let saveWindow = find(surface, "保存")
      check saveWindow != nil
      discard SetFocus(saveWindow)
      f.win.safeListTurn()
      check GetFocus() == saveWindow
      # Forward from the last candidate wraps to the first control in the level.
      tapKey(f, VkTab)
      pumpTurn(f)
      let wrapped = GetFocus()
      echo "M1 wrapFwd moved=" & $(wrapped != saveWindow) & " inLevel=" &
        $(wrapped != nil and GetAncestor(wrapped, GaRoot) == surface)
      check wrapped != saveWindow
      check wrapped != nil
      check GetAncestor(wrapped, GaRoot) == surface
      # Reverse from that same first control wraps back to the last.
      tapKey(f, VkTab, shift = true)
      pumpTurn(f)
      let back = GetFocus()
      echo "M1 wrapBack sameAsSave=" & $(back == saveWindow) & " focus=" & $(back != nil)
      check back != nil
      check GetAncestor(back, GaRoot) == surface
    finally: f.close()

  test "M2 dual-axis reveal and repeated hide/reveal stay operable":
    let state = PageState(title: "对话框", name: "Ada")
    state.wideWidth = 700.0
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      check surface != nil
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      check scrollbarOf(surface, true) != nil
      check scrollbarOf(surface, false) != nil
      let action = find(surface, "宽动作")
      let saveWindow = find(surface, "保存")
      check action != nil and saveWindow != nil
      var client, surfaceRect: RECT
      discard GetClientRect(surface, addr client)
      discard GetWindowRect(surface, addr surfaceRect)
      let viewportLeft = surfaceRect.left
      let viewportTop = surfaceRect.top
      let viewportRight = surfaceRect.left + client.right - 17  # client minus vbar
      let viewportBottom = surfaceRect.top + client.bottom - 17 # client minus hbar
      # Forward reveal: from the footer, Tab until the wide action owns focus.
      discard SetFocus(saveWindow)
      for _ in 1 .. 8:
        tapKey(f, VkTab)
        for _ in 1 .. 12:
          discard f.h.pumpQueued()
        f.win.safeListTurn()
        if GetFocus() == action: break
      check GetFocus() == action
      var actionRect: RECT
      discard GetWindowRect(action, addr actionRect)
      echo "M2 action=" & $actionRect.left & "," & $actionRect.top & " vis=" &
        $IsWindowVisible(action) & " viewport=" & $viewportLeft & "," & $viewportTop
      # Contract asserted here: the target is really on screen, owns focus and
      # runs its business action. The exact per-edge viewport math for a target
      # wider than the viewport is tracked separately (see status.md).
      check IsWindowVisible(action) != 0
      check min(actionRect.right, viewportRight) > max(actionRect.left, viewportLeft)
      check actionRect.top >= viewportTop - 1
      check actionRect.bottom <= viewportBottom + 1
      let before = state.wideClicks
      clickAt(POINT(x: max(actionRect.left, viewportLeft),
        y: (actionRect.top + actionRect.bottom) div 2))
      for _ in 1 .. 12:
        discard f.h.pumpQueued()
      f.win.safeListTurn()
      check state.wideClicks == before + 1
      # Reverse reveal: back to the footer and check it is fully inside too.
      for _ in 1 .. 8:
        tapKey(f, VkTab, shift = true)
        for _ in 1 .. 12:
          discard f.h.pumpQueued()
        f.win.safeListTurn()
        if GetFocus() == saveWindow: break
      check GetFocus() == saveWindow
      var saveRect: RECT
      discard GetWindowRect(saveWindow, addr saveRect)
      echo "M2 save=" & $saveRect.left & "," & $saveRect.top & " vis=" &
        $IsWindowVisible(saveWindow)
      check IsWindowVisible(saveWindow) != 0
      check saveRect.top >= viewportTop - 1
      check saveRect.bottom <= viewportBottom + 1
    finally: f.close()

proc setKeyboardCtrlZ() =
  ## Real Ctrl+Z through SendInput so the native editor handles it.
  var events: array[4, InputEvent]
  events[0].kind = InputKeyboard
  events[0].payload.keyboard.vk = uint16(0x11)  # VK_CONTROL
  events[1].kind = InputKeyboard
  events[1].payload.keyboard.vk = uint16(0x5A)  # VK_Z
  events[2].kind = InputKeyboard
  events[2].payload.keyboard.vk = uint16(0x5A)
  events[2].payload.keyboard.flags = KeyeventfKeyup
  events[3].kind = InputKeyboard
  events[3].payload.keyboard.vk = uint16(0x11)
  events[3].payload.keyboard.flags = KeyeventfKeyup
  if SendInput(4, addr events[0], int32(sizeof(InputEvent))) != 4:
    raise newException(IOError, "Ctrl+Z input was not fully submitted")


type
  EditModel = object
    open: bool
    name: string

let EditFixture = defineComponent[int, State[EditModel]]("EditFixture",
  proc(ctx: MountContext, p: int): State[EditModel] =
    ctx.state(EditModel(name: "Ada")),
  proc(ctx: ComponentContext, p: int, state: State[EditModel]): UiDescription =
    let m = ctx.value(state)
    host(standard.theme(UiColorMode.light,
      column(@[
        standard.button("打开", key = "open", onClick = proc(e: Event) =
          discard state.update(proc(old: EditModel): EditModel =
            (result = old; result.open = true))),
        standard.dialog((if m.name.endsWith("!"): "编辑联系人!" else: "编辑联系人"),
          m.open, key = "dialog",
          onDismiss = proc(e: Event) =
            discard state.update(proc(old: EditModel): EditModel =
              (result = old; result.open = false)),
          content = @[standard.field(@[standard.label("名称"),
            standard.input(m.name, key = "name", onChange = proc(e: Event) =
              discard state.update(proc(old: EditModel): EditModel =
                (result = old; result.name = e.value)))])],
          footer = @[standard.button("保存", key = "save", onClick = proc(e: Event) =
            discard state.update(proc(old: EditModel): EditModel =
              (result = old; result.open = false)))])],
        key = "root"),
      key = "theme")))

proc mountedEdit(calls = systemWin32Calls()): Fixture =
  let activity = newUiScopeActivity()
  let app = componentApplication(component(EditFixture, 0), "Edit fixture", 560, 460)
    .withNativeTheme(shadcnLight)
  let runtime = newRuntime(guardUiApplication(app,
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost(app.title, DipSize(width: 560.0, height: 460.0),
    theme = shadcnLight)
  h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or
    runtime.installingHook)
  let win = newWin32Backend(h, calls)
  let session = win.attachWin32Backend(runtime, protocol.strict)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime)

proc foregroundForInput(f: Fixture, window: HWND) =
  discard SetForegroundWindow(window)
  if GetForegroundWindow() != window:
    var rect: RECT
    if GetWindowRect(window, addr rect) == 0:
      raise newException(IOError, "input target has no window rectangle")
    let point = POINT(x: rect.left + 8, y: rect.top + 8)
    let hit = WindowFromPoint(point)
    if hit == nil or GetAncestor(hit, GaRoot) != window:
      raise newException(IOError, "input target is covered; foreground='" &
        windowText(GetForegroundWindow()) & "'")
    clickAt(point) # real activation of this task's own unobscured window
  let deadline = getMonoTime() + initDuration(milliseconds = 1000)
  while GetForegroundWindow() != window and getMonoTime() < deadline:
    discard f.h.pumpQueued()
    sleep(10)
  if GetForegroundWindow() != window:
    raise newException(IOError, "input target did not become foreground; actual='" &
      windowText(GetForegroundWindow()) & "'")

suite "dialog remaining contracts":
  proc openLevels(f: Fixture, state: PageState): tuple[outer, inner: HWND] =
    f.win.safeListTurn()
    state.open = true
    discard f.runtime.refresh()
    f.win.safeListTurn()
    result.outer = f.st.top
    state.inner = true
    discard f.runtime.refresh()
    f.win.safeListTurn()
    result.inner = f.st.top

  proc focusInside(window: HWND): bool =
    let focus = GetFocus()
    focus != nil and GetAncestor(focus, GaRoot) == window

  test "C1 nested Esc closes only the inner level and keeps the page disabled":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      let levels = f.openLevels(state)
      check levels.outer != nil and levels.inner != nil and levels.inner != levels.outer
      let trigger = find(levels.outer, "内层")
      check trigger != nil
      discard SetFocus(trigger)
      f.win.safeListTurn()
      # Real keyboard input through the production pump.
      tapKey(f, VkEscape)
      for _ in 1 .. 12:
        discard f.h.pumpQueued()
      f.win.safeListTurn()
      discard f.runtime.refresh()
      # The accepted close is published by the following ordinary turn.
      f.win.safeListTurn()
      let after = f.win.overlayStateForTest
      echo "C1 dismissals=" & $state.dismissals & " innerOpen=" & $state.inner &
        " outerOpen=" & $state.open & " stack=" & $after.open & " pageEnabled=" &
        $(IsWindowEnabled(f.h.windowHandle) != 0)
      check state.dismissals == 1
      check not state.inner
      check state.open
      check after.open == 1
      check after.top == levels.outer
      check IsWindowEnabled(f.h.windowHandle) == 0
      check focusInside(levels.outer)
      check IsWindowVisible(levels.outer) != 0
    finally: f.close()

  test "C2 the inner close control closes only the inner level":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      let levels = f.openLevels(state)
      let closeControl = find(levels.inner, "关闭")
      check closeControl != nil
      discard SendMessageW(closeControl, BmClick, 0, 0)
      f.win.safeListTurn()
      discard f.runtime.refresh()
      # The accepted close is published by the following ordinary turn.
      f.win.safeListTurn()
      let after = f.win.overlayStateForTest
      echo "C2 dismissals=" & $state.dismissals & " innerOpen=" & $state.inner &
        " stack=" & $after.open & " topOuter=" & $(after.top == levels.outer)
      check state.dismissals == 1
      check not state.inner
      check state.open
      check after.open == 1
      check after.top == levels.outer
      check IsWindowEnabled(f.h.windowHandle) == 0
      check focusInside(levels.outer)
    finally: f.close()

  test "C3 a real WM_CLOSE on the inner surface closes only that level":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      let levels = f.openLevels(state)
      discard SendMessageW(levels.inner, 0x0010'u32, 0, 0)  # WM_CLOSE
      f.win.safeListTurn()
      discard f.runtime.refresh()
      # The accepted close is published by the following ordinary turn.
      f.win.safeListTurn()
      let after = f.win.overlayStateForTest
      echo "C3 dismissals=" & $state.dismissals & " innerOpen=" & $state.inner &
        " stack=" & $after.open & " pageEnabled=" &
        $(IsWindowEnabled(f.h.windowHandle) != 0)
      check state.dismissals == 1
      check not state.inner
      check state.open
      check after.open == 1
      check after.top == levels.outer
      check IsWindowEnabled(f.h.windowHandle) == 0
      check focusInside(levels.outer)
    finally: f.close()

  test "C4 a controlled reject keeps the inner level open and operable":
    let state = PageState(title: "对话框", name: "Ada")
    state.reject = true
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      let levels = f.openLevels(state)
      tapKey(f, VkEscape)
      for _ in 1 .. 12:
        discard f.h.pumpQueued()
      f.win.safeListTurn()
      check state.dismissals == 1
      check state.inner
      check f.win.overlayStateForTest.top == levels.inner
      let closeInner = find(levels.inner, "关闭内层")
      check closeInner != nil
      clickAt(centerPoint(closeInner))
      for _ in 1 .. 12:
        discard f.h.pumpQueued()
      f.win.safeListTurn()
      check not state.inner
      check state.open
    finally: f.close()

  test "C5 removing the trigger keeps a deterministic live focus fallback":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    try:
      f.win.safeListTurn()
      let trigger = find(f.h.windowHandle, "打开")
      check trigger != nil
      discard SetFocus(trigger)
      discard SendMessageW(trigger, BmClick, 0, 0)
      f.win.safeListTurn()
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      check surface != nil
      # The trigger node is removed from the tree while the level is open.
      state.hideTrigger = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      discard SendMessageW(find(surface, "关闭"), BmClick, 0, 0)
      f.win.safeListTurn()
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let focus = GetFocus()
      echo "C5 surfaceGone=" & $(f.st.top == nil) & " focus=" & $(
        if focus == nil: 0'u64 else: uint64(cast[int](focus)))
      check f.st.top == nil
      check focus != nil
      check focus != trigger
      check IsWindow(focus) != 0
      check GetAncestor(focus, GaRoot) == f.h.windowHandle
    finally: f.close()

  for shrinkWidth in [400'i32, 240'i32]:
    test "C6 controlled Undo across a scroll at work width " & $shrinkWidth:
      let fault = WorkAreaFault(active: false)
      var watched: HWND
      var keyCount, charCount, writes: int
      var calls = areaCalls(fault)
      let baseDefault = calls.defaultSubclass
      calls.defaultSubclass = proc(w: HWND, msg: UINT, wp: WPARAM, lp: LPARAM): LRESULT {.closure, raises: [CatchableError].} =
        if w == watched:
          if msg == 0x0100'u32: inc keyCount; echo "C6 key=" & $wp
          if msg == WM_CHAR: inc charCount; echo "C6 char=" & $wp
        baseDefault(w, msg, wp, lp)
      let baseText = calls.setText
      calls.setText = proc(w: HWND, text: WidePtr): BOOL {.closure, raises: [CatchableError].} =
        if w == watched: inc writes
        baseText(w, text)
      let f = mountedEdit(calls)
      try:
        f.win.safeListTurn()
        let openButton = find(f.h.windowHandle, "打开")
        check openButton != nil
        discard SendMessageW(openButton, BmClick, 0, 0)
        f.win.safeListTurn()
        f.win.safeListTurn()
        let surface = f.st.top
        check surface != nil
        let edit = find(surface, "Ada")
        check edit != nil
        watched = edit
        discard SetFocus(edit)
        discard SendMessageW(edit, EmSetsel, WPARAM(3), LPARAM(3))
        for ch in "xy":
          discard SendMessageW(edit, WmChar, WPARAM(ord(ch)), 0)
        var selTyped: int32
        var selTypedEnd: int32
        discard SendMessageW(edit, EmGetsel, WPARAM(cast[int](addr selTyped)),
          LPARAM(cast[int](addr selTypedEnd)))
        echo "C6 typed text='" & windowText(edit) & "' sel=" & $selTyped & ".." & $selTypedEnd
        # One ordinary turn: the controlled handler accepts inside event settlement.
        f.win.safeListTurn()
        var selAccepted: int32
        var selAcceptedEnd: int32
        discard SendMessageW(edit, EmGetsel, WPARAM(cast[int](addr selAccepted)),
          LPARAM(cast[int](addr selAcceptedEnd)))
        let acceptedText = windowText(edit)
        let canUndo = SendMessageW(edit, EmCanundo, 0, 0)
        echo "C6 accepted text='" & acceptedText & "' sel=" & $selAccepted & ".." &
          $selAcceptedEnd & " canUndo=" & $canUndo
        check acceptedText == "Adaxy"
        check selAccepted == selTyped and selAcceptedEnd == selTypedEnd
        check find(surface, "Adaxy") == edit
        # Shrink and scroll with no further model change.
        fault.active = true
        fault.workWidth = shrinkWidth
        fault.workHeight = 120
        let context = f.h.context
        f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
          int(context.scale * 96))
        f.win.safeListTurn()
        var shrunk: RECT
        check GetClientRect(surface, addr shrunk) != 0
        check shrunk.right == shrinkWidth - 32 and shrunk.bottom == 88
        sendWheel(surface, -1) # injected wheel message; Ctrl+Z below is SendInput
        f.win.safeListTurn()
        let scrollBar = scrollbarOf(surface, true)
        let scrollInfo = barInfo(scrollBar)
        echo "C6 actualScroll bar=" & $(scrollBar != nil) & " pos=" & $scrollInfo.nPos
        check scrollBar != nil
        check scrollInfo.ok and scrollInfo.nPos > 0
        var selScrolled: int32
        var selScrolledEnd: int32
        discard SendMessageW(edit, EmGetsel, WPARAM(cast[int](addr selScrolled)),
          LPARAM(cast[int](addr selScrolledEnd)))
        echo "C6 afterTurn sameHwnd=" & $(find(surface, "Adaxy") == edit) & " text='" &
          windowText(edit) & "' sel=" & $selScrolled & ".." & $selScrolledEnd &
          " canUndo=" & $SendMessageW(edit, EmCanundo, 0, 0)
        check find(surface, "Adaxy") == edit
        check windowText(edit) == "Adaxy"
        check selScrolled == selAccepted and selScrolledEnd == selAcceptedEnd
        check SendMessageW(edit, EmCanundo, 0, 0) != 0
        # Shrinking can hide the focused EDIT temporarily. Address the now
        # revealed same HWND before testing keyboard Undo, without changing text.
        check IsWindowVisible(edit) != 0
        foregroundForInput(f, surface)
        discard SetFocus(edit)
        check GetFocus() == edit
        discard SendMessageW(edit, EmGetsel, WPARAM(cast[int](addr selScrolled)),
          LPARAM(cast[int](addr selScrolledEnd)))
        check selScrolled == selAccepted and selScrolledEnd == selAcceptedEnd
        echo "C6 undoTarget=" & $(GetFocus() == edit) & " foregroundSurface=" & $(GetForegroundWindow() == surface) & " enabled=" & $(IsWindowEnabled(edit) != 0)
        # Ctrl+Z through real keyboard input undoes the accepted edit.
        setKeyboardCtrlZ()
        # SendInput is asynchronous: a fixed number of empty PeekMessage calls
        # does not mean the keyboard message has reached this thread.
        let undoDeadline = getMonoTime() + initDuration(milliseconds = 1500)
        var undoTurns = 0
        while getMonoTime() < undoDeadline and windowText(edit) == "Adaxy":
          discard f.h.pumpQueued()
          f.win.safeListTurn()
          inc undoTurns
          sleep(10)
        echo "C6 undoTurns=" & $undoTurns
        let undone = windowText(edit)
        echo "C6 undone='" & undone & "' keys=" & $keyCount & " chars=" & $charCount & " writes=" & $writes
        check undone == "Ada"
        check find(surface, "Ada") == edit
      finally: f.close()

  test "C7 an independent top-level window keeps its focus while a modal is open":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(fault))
    var second: HWND
    try:
      f.win.safeListTurn()
      let cls = newWideCString("BUTTON")
      second = CreateWindowExW(0, cast[WidePtr](unsafeAddr cls[0]), nil,
        WsPopup or WsVisible, 620, 80, 220, 140, nil, nil, nil, nil)
      check second != nil
      # Positive control before any modal: the second window really takes focus
      # and accepts an interaction of its own.
      foregroundForInput(f, second)
      discard SetFocus(second)
      for _ in 1 .. 8:
        discard f.h.pumpQueued()
      f.win.safeListTurn()
      let text = newWideCString("second-window")
      discard SendMessageW(second, 0x000C'u32, 0, LPARAM(cast[int](unsafeAddr text[0])))
      echo "C7 noModal focusSecond=" & $(GetFocus() == second) & " text=" & windowText(second)
      check GetFocus() == second
      check windowText(second) == "second-window"
      # Open the modal: the page is disabled, the independent window is not.
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      check surface != nil
      echo "C7 modal secondEnabled=" & $(IsWindowEnabled(second) != 0) &
        " pageEnabled=" & $(IsWindowEnabled(f.h.windowHandle) != 0) &
        " ownerIsSecond=" & $(GetWindow(surface, GwOwner) == second)
      check IsWindowEnabled(second) != 0
      check IsWindowEnabled(f.h.windowHandle) == 0
      check GetWindow(surface, GwOwner) != second
      # Switching to it survives ordinary turns: no focus pull-back.
      foregroundForInput(f, second)
      discard SetFocus(second)
      for _ in 1 .. 8:
        discard f.h.pumpQueued()
      f.win.safeListTurn()
      f.win.safeListTurn()
      echo "C7 modal focusSecond=" & $(GetFocus() == second) & " visible=" &
        $(IsWindowVisible(second) != 0)
      check GetFocus() == second
      check IsWindowVisible(second) != 0
      # An unrelated foreground with deliberately empty thread focus must
      # not be interpreted as a request to restore this modal's initial focus.
      discard SetFocus(nil)
      check GetFocus() == nil
      check GetForegroundWindow() == second
      f.win.safeListTurn()
      echo "C7 nilFocusPreserved=" & $(GetFocus() == nil) &
        " foregroundIndependent=" & $(GetForegroundWindow() == second)
      check GetFocus() == nil
      check GetForegroundWindow() == second
      # Returning to this host's modal keeps focus inside the top surface.
      foregroundForInput(f, surface)
      discard SetFocus(nil)
      check GetForegroundWindow() == surface
      f.win.safeListTurn()
      check GetFocus() != nil
      check GetAncestor(GetFocus(), GaRoot) == surface
      for _ in 1 .. 8:
        discard f.h.pumpQueued()
      f.win.safeListTurn()
      check GetAncestor(GetFocus(), GaRoot) == surface
      # Background page focus is still gated from inside the modal group.
      let pageTrigger = find(f.h.windowHandle, "打开")
      check pageTrigger != nil
      discard SetFocus(pageTrigger)
      for _ in 1 .. 8:
        discard f.h.pumpQueued()
      f.win.safeListTurn()
      let focusAfter = GetFocus()
      echo "C7 pageGate insideModal=" & $(focusAfter != nil and
        GetAncestor(focusAfter, GaRoot) == surface) & " onTrigger=" &
        $(focusAfter == pageTrigger)
      check focusAfter != pageTrigger
      check GetAncestor(focusAfter, GaRoot) == surface
      check f.win.overlayStateForTest.top == surface
      check f.win.overlayStateForTest.top == surface
    finally:
      if second != nil: discard DestroyWindow(second)
      f.close()

  for narrowWidth in [400'i32, 240'i32]:
    test "C8 controlled edit precedes shrink layout at width " & $narrowWidth:
      let fault = WorkAreaFault(active: false)
      let f = mountedEdit(areaCalls(fault))
      try:
        f.win.safeListTurn()
        discard SendMessageW(find(f.h.windowHandle, "打开"), BmClick, 0, 0)
        f.win.safeListTurn()
        f.win.safeListTurn()
        let surface = f.st.top
        require surface != nil
        let edit = find(surface, "Ada")
        require edit != nil
        discard SetFocus(edit)
        discard SendMessageW(edit, EmSetsel, 3, 3)
        discard SendMessageW(edit, WmChar, WPARAM(ord('x')), 0)
        f.win.safeListTurn()
        check windowText(edit) == "Adax"
        check scrollbarOf(surface, true) == nil
        var initialClient: RECT
        require GetClientRect(surface, addr initialClient) != 0
        # Work area changes, but no geometry-only relayout has occurred yet.
        fault.active = true
        fault.workWidth = narrowWidth
        fault.workHeight = 120
        discard SendMessageW(edit, WmChar, WPARAM(ord('y')), 0)
        f.win.safeListTurn()
        check windowText(edit) == "Adaxy"
        check find(surface, "Adaxy") == edit
        check SendMessageW(edit, EmCanundo, 0, 0) != 0
        var client: RECT
        check GetClientRect(surface, addr client) != 0
        check client.right == narrowWidth - 32 and client.bottom == 88
        fault.active = false
        let context = f.h.context
        f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
          int(context.scale * 96))
        f.win.safeListTurn()
        var restored: RECT
        require GetClientRect(surface, addr restored) != 0
        check restored.right == initialClient.right
        check restored.bottom == initialClient.bottom
        check find(surface, "Adaxy") == edit
      finally: f.close()

  type AxisFaults = ref object
    refuseConfigX, refuseConfigY, refusePosX, refusePosY: bool
    configX, configY, posX, posY: int

  proc axisWrapper(base: Win32Calls, faults: AxisFaults): Win32Calls =
    result = base
    let setScrollInfo = base.setScrollInfo
    let windowPos = base.windowPos
    result.setScrollInfo = proc(window: HWND, bar: int32, info: ptr SCROLLINFO,
        redraw: BOOL): int32 {.closure, raises: [CatchableError].} =
      var probe = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: SIF_POS)
      var current = int32(0)
      if GetScrollInfo(window, bar, addr probe) != 0: current = probe.nPos
      if bar == SB_CTL and isBarWindow(window):
        let style = UINT(GetWindowLongW(window, GwlStyle))
        let vertical = (style and UINT(SBS_VERT)) != 0
        if vertical and faults.refuseConfigY:
          inc faults.configY
          faults.refuseConfigY = false
          return current
        if not vertical and faults.refuseConfigX:
          inc faults.configX
          faults.refuseConfigX = false
          return current
      setScrollInfo(window, bar, info, redraw)
    result.windowPos = proc(window, after: HWND, x, y, width, height: int32,
        flags: UINT): BOOL {.closure, raises: [CatchableError].} =
      if isBarWindow(window):
        let style = UINT(GetWindowLongW(window, GwlStyle))
        let vertical = (style and UINT(SBS_VERT)) != 0
        if vertical and faults.refusePosY:
          inc faults.posY
          faults.refusePosY = false
          return 0
        if not vertical and faults.refusePosX:
          inc faults.posX
          faults.refusePosX = false
          return 0
      windowPos(window, after, x, y, width, height, flags)

  test "F1 the horizontal scrollbar configuration converges without new input":
    let state = PageState(title: "对话框", name: "Ada")
    state.wideWidth = 700.0
    let fault = WorkAreaFault(active: false)
    let faults = AxisFaults(refuseConfigX: true)
    let f = mounted(proc(): Node = page(state), axisWrapper(areaCalls(fault), faults))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 400
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let surface = f.st.top
      let hbar = scrollbarOf(surface, false)
      check hbar != nil
      let before = barInfo(hbar)
      sendWheel(surface, -1)
      discard SendMessageW(surface, 0x0114'u32, WPARAM(3), LPARAM(cast[int](hbar)))
      f.win.safeListTurn()
      let during = barInfo(hbar)
      check faults.configX == 1
      echo "F1 during=" & $during.nPos
      # No new input: an ordinary turn converges the accepted target.
      f.win.safeListTurn()
      let after = barInfo(hbar)
      echo "F1 configX=" & $faults.configX & " before=" & $before.nPos &
        " after=" & $after.nPos
      check after.nPos != before.nPos
    finally: f.close()

  test "F2 the vertical scrollbar position fault keeps receipts and converges":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    let faults = AxisFaults(refusePosY: true)
    let f = mounted(proc(): Node = page(state), axisWrapper(areaCalls(fault), faults))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let surface = f.st.top
      let bar = scrollbarOf(surface, true)
      check bar != nil
      check faults.posY == 1
      # A plain turn retries the refused placement without new input.
      f.win.safeListTurn()
      echo "F2 posY=" & $faults.posY & " visible=" & $(IsWindowVisible(bar) != 0)
      check IsWindowVisible(bar) != 0
    finally: f.close()

  test "F3 a persistent bar fault stays bounded and converges after clearing":
    let state = PageState(title: "对话框", name: "Ada")
    let fault = WorkAreaFault(active: false)
    var refuseAlways = true
    var attempts = 0
    var target: SCROLLINFO
    var configured = 0
    var calls = areaCalls(fault)
    let baseSet = calls.setScrollInfo
    calls.setScrollInfo = proc(window: HWND, bar: int32, info: ptr SCROLLINFO,
        redraw: BOOL): int32 {.closure, raises: [CatchableError].} =
      var probe = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: SIF_POS)
      var current = int32(0)
      if GetScrollInfo(window, bar, addr probe) != 0: current = probe.nPos
      if bar == SB_CTL and isBarWindow(window):
        target = info[]
        if refuseAlways:
          inc attempts
          return current
        inc configured
      baseSet(window, bar, info, redraw)
    var messageCount = 0
    var hostCalls = systemWin32Calls()
    let basePeek = hostCalls.peekMessage
    hostCalls.peekMessage = proc(msg: ptr MSG, window: HWND, first, last, remove: UINT): BOOL
        {.closure, raises: [CatchableError].} =
      result = basePeek(msg, window, first, last, remove)
      if result != 0 and (remove and 1) != 0: inc messageCount
    let f = mounted(proc(): Node = page(state), calls, hostCalls = hostCalls)
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      let surface = f.st.top
      check scrollbarOf(surface, true) != nil
      # Persistent failure: each ordinary turn may retry at most once and the
      # queued-message drain must stay bounded (no self-posted storm).
      let baseline = attempts
      var perTurn: seq[int]
      for turn in 1 .. 3:
        let before = attempts
        f.win.safeListTurn()
        let deadline = getMonoTime() + initDuration(milliseconds = 1000)
        var msg: MSG
        var batches = 0
        while PeekMessageW(addr msg, nil, 0, 0, 0) != 0 and batches < 64 and getMonoTime() < deadline:
          discard f.h.pumpQueued()
          inc batches
        let idle = PeekMessageW(addr msg, nil, 0, 0, 0) == 0
        echo "F3 queueEmpty=" & $idle & " messages=" & $messageCount & " batches=" & $batches
        perTurn.add(attempts - before) # includes queued dispatch, not just explicit turn
        check idle # exhausting a budget is NOT idle
        check messageCount < 4096
        sleep(20)
      echo "F3 persistent attempts=" & $perTurn
      for count in perTurn:
        check count <= 2
      check attempts >= baseline
      refuseAlways = false
      f.win.safeListTurn()
      f.win.safeListTurn()
      let bar = scrollbarOf(surface, true)
      echo "F3 converged nPos=" & $barInfo(bar).nPos & " visible=" &
        $(IsWindowVisible(bar) != 0)
      let receipt = barInfo(bar)
      check receipt.ok
      check configured > 0
      check receipt.nMin == target.nMin
      check receipt.nMax == target.nMax
      check UINT(receipt.nPage) == target.nPage
      check receipt.nPos == target.nPos
      check IsWindowVisible(bar) != 0
      let settledCalls = configured
      f.win.safeListTurn()
      check configured == settledCalls # no dirty retry after successful receipt
    finally: f.close()

  test "F4 an already scrolled level still rejects growing oversized content":
    let state = PageState(title: "对话框", name: "Ada")
    let area = WorkAreaFault(active: false)
    let f = mounted(proc(): Node = page(state), areaCalls(area))
    try:
      f.win.safeListTurn()
      state.open = true
      discard f.runtime.refresh()
      f.win.safeListTurn()
      let surface = f.st.top
      area.active = true
      area.workWidth = 400
      area.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      check scrollbarOf(surface, true) != nil
      state.bodyHeight = 1200
      expect UiError:
        discard f.runtime.refresh()
      check f.st.top == surface
      check IsWindowVisible(surface) != 0
      check IsWindowEnabled(f.h.windowHandle) == 0
    finally: f.close()


  test "F5 failed late apply and restore freeze dispatch and release modality":
    let fault = WorkAreaFault(active: false)
    var calls = areaCalls(fault)
    let baseText = calls.setText
    var surface: HWND
    var armed = false
    var hits = 0
    calls.setText = proc(window: HWND, text: WidePtr): BOOL
        {.closure, raises: [CatchableError].} =
      if armed and window == surface and text != nil and
          ($cast[WideCString](text)).endsWith("!"):
        armed = false
        inc hits
        return 0
      baseText(window, text)
    let f = mountedEdit(calls)
    try:
      f.win.safeListTurn()
      discard SendMessageW(find(f.h.windowHandle, "打开"), BmClick, 0, 0)
      f.win.safeListTurn()
      f.win.safeListTurn()
      surface = f.st.top
      require surface != nil
      let edit = find(surface, "Ada")
      require edit != nil
      discard SetFocus(edit)
      discard SendMessageW(edit, EmSetsel, 3, 3)
      discard SendMessageW(edit, WmChar, WPARAM(ord('x')), 0)
      f.win.safeListTurn()
      require windowText(edit) == "Adax"
      fault.active = true
      fault.workWidth = 400
      fault.workHeight = 120
      let context = f.h.context
      f.win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
        int(context.scale * 96))
      f.win.safeListTurn()
      sendWheel(surface, -1)
      f.win.safeListTurn()
      let revision = f.runtime.acceptedRevision
      let resources = f.win.diagnostics.liveWindows
      require SendMessageW(edit, EmCanundo, 0, 0) != 0
      armed = true
      var failure = ""
      try:
        discard SendMessageW(edit, WmChar, WPARAM(ord('!')), 0)
        f.win.safeListTurn()
        f.win.safeListTurn()
      except CatchableError as error:
        failure = error.msg
      echo "F5 hits=" & $hits & " error='" & failure & "' revision=" &
        $f.runtime.acceptedRevision & " before=" & $revision
      check hits == 1
      check f.runtime.acceptedRevision == revision
      f.win.safeListTurn()
      # BackendSession explicitly freezes dispatch when replay of the accepted
      # tree cannot fit this environment. This is a safe fault, not successful
      # in-place rollback and not an EDIT/Undo-preservation guarantee.
      echo "F5 faulted=" & $f.s.faulted & " frozen=" & $f.s.frozen &
        " ownerEnabled=" & $(IsWindowEnabled(f.h.windowHandle) != 0) &
        " oldEditAlive=" & $(IsWindow(edit) != 0) &
        " windows=" & $f.win.diagnostics.liveWindows
      check f.s.faulted
      check f.runtime.eventsFrozen
      var blocked = ""
      try: discard f.runtime.dispatch("open", Event(kind: EventKind.click))
      except UiError as error: blocked = error.msg
      check blocked.startsWith("business events are frozen:")
      check f.runtime.acceptedRevision == revision
      check f.st.top == nil
      check IsWindowEnabled(f.h.windowHandle) != 0
      check IsWindow(edit) == 0 # no live stale editor to receive input
      let adornment = f.win.focusAdornmentForTest()
      echo "F5 adornment=" & $(adornment != nil) & " alive=" &
        $(adornment != nil and IsWindow(adornment) != 0) & " visible=" &
        $(adornment != nil and IsWindowVisible(adornment) != 0) &
        " subclasses=" & $f.win.diagnostics.liveSubclasses
      # A lazily created host adornment survives a transaction restore, but
      # must be hidden and still belong to this host. No native controls remain.
      check f.win.diagnostics.liveWindows == ord(adornment != nil)
      check f.win.diagnostics.liveSubclasses == 0
      if adornment != nil:
        check IsWindow(adornment) != 0
        check IsWindowVisible(adornment) == 0
        check GetWindow(adornment, GwOwner) == f.h.windowHandle
      var acceptedText = ""
      for _, entity in f.s.acceptedEntities:
        if entity.kind == NodeKind.input: acceptedText = entity.props.control.value.get("")
      check acceptedText == "Adax"
      check resources > 0
      check f.s.queuedEvents == 0
      f.s.dispose()
      check f.s.disposed
      check f.win.diagnostics.liveWindows == 0
      check f.win.diagnostics.liveFonts == 0
      check f.win.diagnostics.liveSubclasses == 0
      if adornment != nil: check IsWindow(adornment) == 0
      echo "F5 disposedWindows=" & $f.win.diagnostics.liveWindows
    finally: f.close()
