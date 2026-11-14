when not defined(windows): {.error: "Native Select tests require Windows".}
import std/[unittest, strutils, os, times, monotimes]
import leaf
import ../fixture_app
import leaf/[ui_thread, native_layout, styles, backend_session, native_theme]
import leaf/backend as protocol
import leaf/backends/win32/[api, host, backend, calls]
import leaf/ui as standard

const
  GwOwner = 4'u32
  GaRoot = 2'u32
  GwlExStyle = -20'i32
  ExTopmost = 0x00000008'u32
  WmKeyDown = 0x0100'u32
  BmClick = 0x00f5'u32
  VkReturn = 0x0d'i32
  VkEscape = 0x1b'i32
  VkTab = 0x09'i32
  VkEnd = 0x23'i32
  VkHome = 0x24'i32
  VkUp = 0x26'i32
  VkDown = 0x28'i32
  InputMouse = 0'u32
  InputKeyboard = 1'u32
  KeyeventfKeyup = 0x0002'u32
  MouseeventfLeftdown = 0x0002'u32
  MouseeventfLeftup = 0x0004'u32
  SwMinimize = 6
  SwRestore = 9
  SwpNoZOrder = 0x0004'u32
  SwpNoSize = 0x0001'u32
  SwpNoActivate = 0x0010'u32

{.push stdcall, dynlib: "user32.dll", importc, raises: [].}
proc GetWindow(window: HWND, command: DWORD): HWND
proc GetForegroundWindow(): HWND
proc SetForegroundWindow(window: HWND): BOOL
proc SetCursorPos(x, y: int32): BOOL
proc SendInput(count: UINT, inputs: pointer, size: int32): UINT
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

  SelectState = ref object
    open, ignoreOpen, ignoreClose, ignoreValue, disabled, removed: bool
    allDisabled, inDialog, dialogOpen, dialogSelect: bool
    value, dialogValue: string
    commits, dialogCommits: seq[string]
    openRequests, dialogOpenRequests, outsideClicks: int

  Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession,
    runtime: Runtime]

proc clickAt(point: POINT) =
  discard SetCursorPos(point.x, point.y)
  var events: array[2, InputEvent]
  events[0].kind = InputMouse
  events[0].payload.mouse.flags = MouseeventfLeftdown
  events[1].kind = InputMouse
  events[1].payload.mouse.flags = MouseeventfLeftup
  if SendInput(2, addr events[0], int32(sizeof(InputEvent))) != 2:
    raise newException(IOError, "mouse input was not fully submitted")

proc tapKey(vk: int32) =
  ## Real keyboard injection; the product pump still performs all dispatch.
  var events: array[2, InputEvent]
  events[0].kind = InputKeyboard
  events[0].payload.keyboard.vk = uint16(vk)
  events[1].kind = InputKeyboard
  events[1].payload.keyboard.vk = uint16(vk)
  events[1].payload.keyboard.flags = KeyeventfKeyup
  if SendInput(2, addr events[0], int32(sizeof(InputEvent))) != 2:
    raise newException(IOError, "keyboard input was not fully submitted")
  var pending: MSG
  let deadline = getMonoTime() + initDuration(milliseconds = 1000)
  while PeekMessageW(addr pending, nil, WmKeyDown, WmKeyDown, 0) == 0:
    if getMonoTime() >= deadline:
      raise newException(IOError, "keyboard input did not reach the target queue")
    sleep(5)

proc pumpQueue(surface: HWND, rounds = 400) =
  var message: MSG
  for _ in 0..<rounds:
    if PeekMessageW(addr message, nil, 0, 0, 1) == 0: break
    if surface != nil and IsDialogMessageW(surface, addr message) != 0: continue
    discard TranslateMessage(addr message)
    discard DispatchMessageW(addr message)

proc foreground(window: HWND) =
  if GetForegroundWindow() == window: return
  discard SetForegroundWindow(window)
  let deadline = getMonoTime() + initDuration(milliseconds = 2000)
  while GetForegroundWindow() != window:
    if getMonoTime() >= deadline:
      raise newException(IOError, "window could not be made foreground")
    sleep(10)

proc mounted(build: FixtureBuild, calls = systemWin32Calls(),
             hostCalls = systemWin32Calls(),
             width = 520, height = 420): Fixture =
  let activity = newUiScopeActivity()
  let app = fixtureApplication(build, "Select transactions", width, height)
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
  check f.win.diagnostics.liveSelects == 0
  check f.win.overlayStateForTest.live == 0

proc settle(f: Fixture) =
  ## Ordinary native turn -> business render/accept -> publish turn.
  f.win.safeListTurn()
  discard f.runtime.refresh()
  f.win.safeListTurn()

proc handleOf(f: Fixture, key: string): NodeHandle =
  f.s.handleFor(f.runtime.find(key).id)

proc accepted(f: Fixture, key = "colour"): SelectProps =
  f.runtime.find(key).node.selectProps.get

proc triggerWindow(f: Fixture, key = "colour"): HWND =
  f.win.nativeWindowForTest(f.handleOf(key & "-trigger"))

proc popupOf(f: Fixture, key = "colour"): HWND =
  f.win.selectStateForTest(f.handleOf(key)).popup

proc rowsFor(count: int, disabled: seq[int], allOff = false): seq[Node] =
  for index in 1 .. count:
    result.add(standard.selectItem("o" & $index, "选项" & $index,
      disabled = allOff or index in disabled))

proc page(state: SelectState): Node =
  var content: seq[Node]
  content.add(standard.button("外侧", key = "outside",
    onClick = proc(event: Event) = inc state.outsideClicks))
  content.add(standard.button("前置", key = "before"))
  if not state.removed:
    content.add(standard.select(
      standard.selectTrigger(placeholder = "选择", disabled = state.disabled,
        key = "colour-trigger"),
      standard.selectContent(rowsFor(20, @[3], state.allDisabled)),
      value = state.value, open = state.open, key = "colour", label = "颜色",
      onChange = proc(event: Event) =
        if not state.ignoreValue: state.value = event.value
        state.commits.add(event.value),
      onOpenChange = proc(event: Event) =
        inc state.openRequests
        if event.open:
          if not state.ignoreOpen: state.open = true
        else:
          if not state.ignoreClose: state.open = false))
  content.add(standard.button("后置", key = "after"))
  if state.inDialog:
    content.add(standard.dialog("含下拉", state.dialogOpen, key = "dialog",
      onDismiss = proc(event: Event) =
        if not state.ignoreClose: state.dialogOpen = false,
      content = @[standard.select(
        standard.selectTrigger(placeholder = "内层选择", key = "dialog-colour-trigger"),
        standard.selectContent(rowsFor(6, @[2])),
        value = state.dialogValue, open = state.dialogSelect,
        key = "dialog-colour", label = "内层颜色",
        onChange = proc(event: Event) =
          state.dialogValue = event.value
          state.dialogCommits.add(event.value),
        onOpenChange = proc(event: Event) =
          inc state.dialogOpenRequests
          if event.open: state.dialogSelect = true
          else: state.dialogSelect = false)]))
  standard.theme(UiColorMode.light, column(content, key = "root"), key = "theme")

proc openSelect(f: Fixture, key = "colour"): HWND =
  ## Real user path: activate the trigger, then let the ordinary turn publish.
  let trigger = f.triggerWindow(key)
  if trigger == nil: raise newException(ValueError, "missing trigger window")
  discard SetFocus(trigger)
  discard SendMessageW(trigger, BmClick, 0, 0)
  f.settle()
  result = f.popupOf(key)
  if result == nil or IsWindowVisible(result) == 0:
    raise newException(ValueError, "select popup was not published")

proc press(popup: HWND, vk: int32) =
  discard SendMessageW(popup, WmKeyDown, WPARAM(uint(vk)), 0)

proc rowPoint(popup: HWND, ordinal, rows: int): POINT =
  ## Screen point at the centre of one visible row.
  var client: RECT
  discard GetClientRect(popup, addr client)
  let height = (client.bottom - client.top) div int32(max(1, rows))
  var origin = POINT(x: 0, y: 0)
  discard ClientToScreen(popup, addr origin)
  POINT(x: origin.x + (client.right - client.left) div 2,
    y: origin.y + height * int32(ordinal) + height div 2)

suite "native owned Select popup":
  test "the accepted open state publishes one owned anchored popup in the turn":
    let state = SelectState()
    let f = mounted(proc(): Node = page(state))
    var popup: HWND
    try:
      f.settle()
      let trigger = f.triggerWindow()
      check trigger != nil
      check IsWindowVisible(trigger) != 0
      # The trigger element provider exists while the select root does; the
      # popup window and its List element do not.
      check f.win.diagnostics.liveSelects == 1
      check f.win.selectStateForTest(f.handleOf("colour")).live
      check f.win.selectStateForTest(f.handleOf("colour")).popup == nil
      state.open = true
      discard f.runtime.refresh()
      # Accepted but not published yet: no popup, no focus change.
      check f.win.selectStateForTest(f.handleOf("colour")).popup == nil
      f.win.safeListTurn()
      let published = f.win.selectStateForTest(f.handleOf("colour"))
      check published.live
      check published.visible
      popup = published.popup
      check popup != nil
      check IsWindowVisible(popup) != 0
      # Owned by the page window, never globally topmost, owner never disabled.
      check GetWindow(popup, GwOwner) == f.h.windowHandle
      check GetAncestor(popup, GaRoot) == popup
      check (UINT(GetWindowLongW(popup, GwlExStyle)) and ExTopmost) == 0
      check IsWindowEnabled(f.h.windowHandle) != 0
      check GetFocus() == popup
      # Anchored directly below the trigger at the same width, whole rows only.
      var t: RECT
      discard GetWindowRect(trigger, addr t)
      var p: RECT
      discard GetWindowRect(popup, addr p)
      check p.left == t.left
      check p.top >= t.bottom
      check (p.right - p.left) == (t.right - t.left)
      check (p.bottom - p.top) mod int32(published.rows) == 0
      check published.rows == 8
      # Closing hides the popup and restores focus to the trigger.
      state.open = false
      f.settle()
      check not f.win.selectStateForTest(f.handleOf("colour")).visible
      check GetFocus() == trigger
      # Retiring the select destroys the popup and releases its receipts.
      state.open = true
      f.settle()
      check f.win.selectStateForTest(f.handleOf("colour")).visible
      state.removed = true
      f.settle()
      check f.win.diagnostics.liveSelects == 0
      check IsWindow(popup) == 0
    finally:
      f.close()

  test "trigger activation is one typed request and an ignored request does not drift":
    let state = SelectState()
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      state.ignoreOpen = true
      discard SendMessageW(f.triggerWindow(), BmClick, 0, 0)
      f.settle()
      # Exactly one request reached the business layer, the accepted open state
      # is still false, and no popup exists: a rejected request cannot drift.
      check state.openRequests == 1
      check not accepted(f).open
      check f.win.selectStateForTest(f.handleOf("colour")).popup == nil
      state.ignoreOpen = false
      discard SendMessageW(f.triggerWindow(), BmClick, 0, 0)
      f.settle()
      check state.openRequests == 2
      check accepted(f).open
      check f.win.selectStateForTest(f.handleOf("colour")).visible
    finally:
      f.close()

  test "a disabled trigger cannot request opening and owns no popup":
    let state = SelectState(disabled: true)
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      check IsWindowEnabled(f.triggerWindow()) == 0
      discard SendMessageW(f.triggerWindow(), BmClick, 0, 0)
      f.settle()
      check state.openRequests == 0
      check f.win.selectStateForTest(f.handleOf("colour")).popup == nil
      check accepted(f).usableCount > 0
    finally:
      f.close()

  test "candidate navigation is transient and Enter commits exactly once":
    let state = SelectState()
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      let popup = openSelect(f, "colour")
      # Initial candidate is the first usable option; disabled o3 is skipped.
      check f.win.selectStateForTest(f.handleOf("colour")).candidate == 0
      press(popup, VkDown)
      check f.win.selectStateForTest(f.handleOf("colour")).candidate == 1
      press(popup, VkDown)
      check f.win.selectStateForTest(f.handleOf("colour")).candidate == 3
      check state.value == ""
      check state.commits.len == 0
      press(popup, VkEnd)
      check f.win.selectStateForTest(f.handleOf("colour")).candidate == 19
      press(popup, VkHome)
      check f.win.selectStateForTest(f.handleOf("colour")).candidate == 0
      check state.commits.len == 0
      f.settle()
      # Moving never committed, so the accepted value is unchanged and the
      # popup is still open for exactly one commit.
      check state.value == ""
      check accepted(f).open
      press(popup, VkEnd)
      press(popup, VkReturn)
      f.settle()
      check state.commits.len == 1
      check state.commits[0] == "o20"
      check state.value == "o20"
      check not accepted(f).open
      check not f.win.selectStateForTest(f.handleOf("colour")).visible
    finally:
      f.close()

  test "real keyboard input commits once through the production pump":
    let state = SelectState()
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      # Activate the application before opening: an activation change while the
      # popup is open would legitimately deliver a close request.
      foreground(f.h.windowHandle)
      let popup = openSelect(f, "colour")
      if GetFocus() != popup: discard SetFocus(popup)
      check GetFocus() == popup
      tapKey(VkDown)
      # Dispatch straight to the focused window: the real dialog pump would
      # translate Enter into an IDOK before it could reach the popup.
      pumpQueue(nil)
      check f.win.selectStateForTest(f.handleOf("colour")).candidate == 1
      tapKey(VkReturn)
      pumpQueue(nil)
      f.settle()
      check state.commits.len == 1
      check state.commits[0] == "o2"
      check state.value == "o2"
      check not accepted(f).open
    finally:
      f.close()

  test "Escape cancels the candidate, restores focus and never commits":
    let state = SelectState()
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      let trigger = f.triggerWindow()
      let popup = openSelect(f, "colour")
      press(popup, VkDown)
      press(popup, VkEscape)
      f.settle()
      check state.commits.len == 0
      check state.value == ""
      check not accepted(f).open
      check not f.win.selectStateForTest(f.handleOf("colour")).visible
      check GetFocus() == trigger
      # One open request and one close request: no duplicate events.
      check state.openRequests == 2
    finally:
      f.close()

  test "Tab closes the popup and moves focus inside the owner focus domain":
    let state = SelectState()
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      let trigger = f.triggerWindow()
      let popup = openSelect(f, "colour")
      press(popup, VkTab)
      f.settle()
      check not accepted(f).open
      check not f.win.selectStateForTest(f.handleOf("colour")).visible
      let focus = GetFocus()
      check focus != nil
      check focus != popup
      check focus != trigger
      check GetAncestor(focus, GaRoot) == f.h.windowHandle
      check IsWindowVisible(focus) != 0
      check IsWindowEnabled(focus) != 0
      # Tab moves forward in the page focus order: the control after the trigger.
      check focus == f.win.nativeWindowForTest(f.handleOf("after"))
    finally:
      f.close()

  test "an outside click closes the popup without double-delivering the click":
    let state = SelectState()
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      foreground(f.h.windowHandle)
      discard openSelect(f, "colour")
      let outside = f.win.nativeWindowForTest(f.handleOf("outside"))
      var frame: RECT
      discard GetWindowRect(outside, addr frame)
      clickAt(POINT(x: (frame.left + frame.right) div 2,
        y: (frame.top + frame.bottom) div 2))
      pumpQueue(f.h.windowHandle)
      f.settle()
      check not accepted(f).open
      check not f.win.selectStateForTest(f.handleOf("colour")).visible
      # The click really reached the control under the cursor exactly once.
      check state.outsideClicks == 1
    finally:
      f.close()

  test "a disabled candidate cannot be committed by clicking its row":
    let state = SelectState()
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      foreground(f.h.windowHandle)
      let popup = openSelect(f, "colour")
      let rows = f.win.selectStateForTest(f.handleOf("colour")).rows
      # Row 2 is the disabled option o3.
      clickAt(rowPoint(popup, 2, rows))
      pumpQueue(popup)
      f.settle()
      check state.commits.len == 0
      check accepted(f).open
      # A usable row commits once and closes.
      let again = f.popupOf("colour")
      clickAt(rowPoint(again, 0, rows))
      pumpQueue(again)
      f.settle()
      check state.commits.len == 1
      check state.commits[0] == "o1"
      check state.value == "o1"
      check not accepted(f).open
    finally:
      f.close()

  test "a long list scrolls instead of growing and keeps the candidate reachable":
    let state = SelectState()
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      let popup = openSelect(f, "colour")
      let opened = f.win.selectStateForTest(f.handleOf("colour"))
      check opened.rows == 8
      press(popup, VkEnd)
      let scrolled = f.win.selectStateForTest(f.handleOf("colour"))
      check scrolled.candidate == 19
      check scrolled.firstRow == 20 - opened.rows
      press(popup, VkHome)
      check f.win.selectStateForTest(f.handleOf("colour")).firstRow == 0
      # Wheel input clamps into the reachable range instead of drifting.
      discard SendMessageW(popup, 0x020a'u32,
        WPARAM(uint(cast[uint32](int32(-120)) shl 16)), 0)
      let wheeled = f.win.selectStateForTest(f.handleOf("colour"))
      check wheeled.firstRow >= 0
      check wheeled.firstRow <= 20 - opened.rows
    finally:
      f.close()

  test "owner movement republishes the anchor and owner minimize hides the popup":
    let state = SelectState()
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      let popup = openSelect(f, "colour")
      var before: RECT
      discard GetWindowRect(popup, addr before)
      var hostFrame: RECT
      discard GetWindowRect(f.h.windowHandle, addr hostFrame)
      # A programmatic move (no activation): the popup follows its anchor instead
      # of treating the move as a user focus change.
      discard SetWindowPos(f.h.windowHandle, nil, hostFrame.left + 48,
        hostFrame.top + 24, 0, 0, SwpNoSize or SwpNoZOrder or SwpNoActivate)
      f.settle()
      var after: RECT
      discard GetWindowRect(popup, addr after)
      check after.left != before.left
      # Still anchored below its trigger after the owner moved.
      let trigger = f.triggerWindow()
      var t: RECT
      discard GetWindowRect(trigger, addr t)
      check after.left == t.left
      check after.top >= t.bottom
      # Owner minimize drops the popup without moving focus elsewhere; the
      # accepted state then decides whether it comes back on restore.
      discard ShowWindow(f.h.windowHandle, SwMinimize)
      f.settle()
      check IsIconic(f.h.windowHandle) != 0
      check not f.win.selectStateForTest(f.handleOf("colour")).visible
      discard ShowWindow(f.h.windowHandle, SwRestore)
      f.settle()
      check IsIconic(f.h.windowHandle) == 0
      # Visible exactly when the accepted state still says open: never a drift.
      check f.win.selectStateForTest(f.handleOf("colour")).visible ==
        accepted(f).open
    finally:
      f.close()

  test "a select inside a Dialog stays in the modal scope and dies with it":
    let state = SelectState(inDialog: true, dialogOpen: true)
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      let surface = f.win.overlayStateForTest.top
      check surface != nil
      check IsWindowVisible(surface) != 0
      # The page control is gated while the dialog is the top modal level.
      discard SendMessageW(f.win.nativeWindowForTest(f.handleOf("outside")),
        BmClick, 0, 0)
      f.settle()
      check state.outsideClicks == 0
      let popup = openSelect(f, "dialog-colour")
      check GetWindow(popup, GwOwner) == surface
      check GetAncestor(popup, GaRoot) == popup
      # The first Escape only closes the select, never the dialog.
      press(popup, VkEscape)
      f.settle()
      check state.dialogOpen
      check IsWindowVisible(surface) != 0
      check not accepted(f, "dialog-colour").open
      check state.dialogCommits.len == 0
      # Reopening and committing inside the dialog inserts the popup above the
      # surface; closing the dialog then reaps its select popup with it.
      let again = openSelect(f, "dialog-colour")
      press(again, VkDown)
      press(again, VkReturn)
      f.settle()
      check state.dialogCommits.len == 1
      check state.dialogCommits[0] == "o3"
      check state.dialogValue == "o3"
      check state.dialogOpen
      state.dialogOpen = false
      f.settle()
      check f.win.overlayStateForTest.top == nil
      # Both select roots stay accepted (the dialog node still renders closed),
      # so both trigger elements stay live while every popup is released.
      check f.win.diagnostics.liveSelects == 2
      check f.win.selectStateForTest(f.handleOf("dialog-colour")).popup == nil
      check f.win.selectStateForTest(f.handleOf("colour")).popup == nil
    finally:
      f.close()

  test "a failed show keeps a retryable receipt instead of a fake success":
    let state = SelectState()
    var popup: HWND
    var failShow = true
    var calls = systemWin32Calls()
    let systemPos = calls.windowPos
    calls.windowPos = proc(window, after: HWND, x, y, width, height: int32,
        flags: UINT): BOOL {.closure, raises: [CatchableError].} =
      # Only the select popup's own geometry call fails, exactly once.
      # Only the popup's own geometry call carries exactly these two bits.
      if failShow and window != nil and (flags and 0x0210'u32) == 0x0210'u32:
        failShow = false
        return 0
      systemPos(window, after, x, y, width, height, flags)
    let f = mounted(proc(): Node = page(state), calls = calls)
    try:
      f.settle()
      var raised = false
      state.open = true
      discard f.runtime.refresh()
      try:
        f.win.safeListTurn()
      except CatchableError:
        raised = true
      check raised
      # The popup host was kept as a retryable receipt, not reported as shown.
      let failed = f.win.selectStateForTest(f.handleOf("colour"))
      check failed.live
      check not failed.visible
      f.win.safeListTurn()
      let retried = f.win.selectStateForTest(f.handleOf("colour"))
      check retried.visible
      popup = retried.popup
      check popup != nil
      check IsWindowVisible(popup) != 0
    finally:
      f.close()
