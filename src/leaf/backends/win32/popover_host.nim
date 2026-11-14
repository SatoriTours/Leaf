## Owned non-modal popover panel for the standard Popover.
##
## One panel is a real owned WS_POPUP|WS_CAPTION window of the trigger's
## top-level window: the owner stays enabled, the panel is never globally
## topmost, and there is no second message pump. The caption style bit is what
## makes the stock proxy expose Window + WindowPattern (IsModal=false) while
## WM_NCCALCSIZE keeps the whole window as client area.
##
## The callback only records one typed dismissal (Esc / outside / system close)
## or a Tab request; the accepted props decide what is really shown.
when not defined(windows): {.error: "Win32 popovers require Windows".}
import std/[tables, math, unicode]
import ../../[core, native_theme]
import ../../popover_protocol
import ./[api, calls, skin]

type
  PaintStruct {.importc: "PAINTSTRUCT", header: "<windows.h>", bycopy.} = object
    hdc: HDC
    fErase: BOOL
    rcPaint: RECT
    fRestore, fIncUpdate: BOOL
    rgbReserved: array[32, uint8]

  PopoverWindows* = object
    ## Per-step receipts so a retry never creates a second resource.
    classRegistered*, rootPublished*: bool
    panel*: HWND

  Win32Popover* = ref object
    ownerThread: DWORD
    calls: Win32Calls
    theme: NativeTheme
    cookie: uint
    className: seq[WCHAR]
    instance: HINSTANCE
    windows: PopoverWindows
    ownerWindow*, wakeWindow*, triggerWindow*: HWND
    props*: PopoverProps
    shown*, closed*: bool
    hiding: bool
    hasDismiss*: bool
    dismiss*: PopoverDismiss
    tabPending*: int      # 0 none, 1 forward, -1 backward
    pendingTab*: int      # direction kept until the caller accepts the close
    requestPending*: bool # one request per input, never re-sent each turn
    needsLayout*: bool
    scale*: float64
    needsThemeRepaint*: bool
      ## A theme change still owes the panel and its children a repaint. It stays
      ## set when the repaint itself fails, so the next ordinary turn retries the
      ## real repaint instead of treating the new theme as already painted.

const
  RdwInvalidate = 0x0001'u32
  RdwErase = 0x0004'u32
  RdwAllChildren = 0x0080'u32
  WmEraseBackground = 0x0014'u32
  WmPaint = 0x000f'u32
  WmNcCalcSize = 0x0083'u32
  WmKeyDown = 0x0100'u32
  WmKillFocus = 0x0008'u32
  WmActivateApp = 0x001c'u32
  WmSize = 0x0005'u32
  WmClose = 0x0010'u32
  WmNcCreate = 0x0081'u32
  WmNcDestroy = 0x0082'u32
  WmGetDlgCode = 0x0087'u32
  WsPopup = 0x80000000'u32
  WsCaption = 0x00c00000'u32
  WsClipChildren = 0x02000000'u32
  WsClipSiblings = 0x04000000'u32
  SwHide = 0
  SwShow = 5
  GwlpUserData = -21'i32
  GwlStyle = -16'i32
  GwlExStyle = -20'i32
  DcBrush = 18'i32
  VkTab = 0x09'i32
  VkEscape = 0x1b'i32
  VkShift = 0x10'i32
  PopoverWake = WM_HOST_TICK

var popovers {.threadvar.}: Table[uint, Win32Popover]
var nextPopoverCookie {.threadvar.}: uint

proc wide(value: string): seq[WCHAR] =
  for rune in value.runes:
    let code = int(rune)
    if code <= 0xffff:
      result.add(WCHAR(code))
    else:
      let pair = code - 0x10000
      result.add(WCHAR(0xd800 + (pair shr 10)))
      result.add(WCHAR(0xdc00 + (pair and 0x3ff)))
  result.add(0)

proc nativeError(operation: string) {.noreturn.} =
  fail(operation & " failed: Win32 error " & $lastError())

proc surfaceFill(theme: NativeTheme, window: HWND): uint32 {.raises: [].} =
  ## Resolve the panel background through the SAME function the panel's children
  ## use (skin.surfaceColor). Painting the panel from palette.surface while the
  ## body resolved palette.canvas produced two different colors in one panel.
  ## Returns an already converted COLORREF; callers must not convert again.
  if theme == systemTheme: return colorRef(0x00ffffff'u32)
  try: colorRef(surfaceColor(theme, window))
  except CatchableError: colorRef(0x00ffffff'u32)

proc ownerCheck(host: Win32Popover) {.raises: [CatchableError].} =
  if host == nil: fail("Win32 popover is nil")
  if GetCurrentThreadId() != host.ownerThread:
    fail("Win32 popover must run on its owning UI thread")

proc ownerLifecycleHidden(host: Win32Popover): bool {.raises: [].} =
  ## True when the owner chain is temporarily unavailable for reasons of the
  ## owner's lifecycle (minimized, hidden, or a modal surface whose root owner is
  ## minimized). This is not a user click outside, so it must not record one.
  if host.ownerWindow == nil: return false
  let rootOwner = GetAncestor(host.ownerWindow, 3'u32) # GA_ROOTOWNER
  if rootOwner != nil and IsIconic(rootOwner) != 0: return true
  if IsWindowVisible(host.ownerWindow) == 0: return true
  if IsIconic(host.ownerWindow) != 0: return true
  false

proc noteDismiss(host: Win32Popover, dismiss: PopoverDismiss) {.raises: [].} =
  ## WndProc path: scalars only, and never while this module hides the panel.
  when defined(leafProtocolProbes):
    echo "DISMISS note kind=", dismiss, " closed=", host.closed,
      " hiding=", host.hiding, " hasDismiss=", host.hasDismiss,
      " ownerIconic=", (if host.ownerWindow != nil:
        IsIconic(GetAncestor(host.ownerWindow, 2'u32)) else: 0)
  if host.closed or host.hiding or host.hasDismiss: return
  # A lifecycle deactivation is not an outside click and never becomes a request.
  if dismiss == pdOutside and host.ownerLifecycleHidden():
    when defined(leafProtocolProbes):
      echo "DISMISS suppress kind=pdOutside ownerLifecycleHidden=1 panel=",
        uint64(cast[uint](host.windows.panel))
    return
  host.hasDismiss = true
  host.dismiss = dismiss

proc isWithin(host: Win32Popover, window: HWND): bool {.raises: [].} =
  if window == nil or host.windows.panel == nil: return false
  if window == host.windows.panel: return true
  var current = window
  var depth = 0
  while current != nil and depth < 64:
    current = GetParent(current)
    if current == host.windows.panel: return true
    inc depth
  false

proc paintPanel(host: Win32Popover, window: HWND, dc: HDC): bool {.raises: [].} =
  if dc == nil: return false
  var rect: RECT
  try:
    if host.calls.clientRect(window, addr rect) == 0: return false
    discard host.calls.setDCBrushColor(dc, surfaceFill(host.theme, window))
    let brush = host.calls.getStockObject(DcBrush)
    if brush == nil: return false
    discard host.calls.fillRect(dc, addr rect, cast[HBRUSH](brush))
    true
  except CatchableError: false

proc keyDown(host: Win32Popover, key: int32) {.raises: [].} =
  case key
  of VkEscape: host.noteDismiss(pdEscape)
  of VkTab:
    let shift = (GetKeyState(VkShift) and 0x8000) != 0
    host.tabPending = (if shift: -1 else: 1)
  else: discard

proc popoverProc(window: HWND, message: UINT, wp: WPARAM,
                 lp: LPARAM): LRESULT {.stdcall, raises: [].} =
  ## Paint, record one dismissal and keep the full-client geometry. No business
  ## code and no allocation runs here.
  var host: Win32Popover
  try:
    var raw = cast[uint](GetWindowLongPtrW(window, GwlpUserData))
    if message == WmNcCreate:
      let creation = cast[ptr CREATESTRUCTW](lp)
      if creation == nil: return 0
      raw = cast[uint](creation.lpCreateParams)
      if raw == 0: return 0
      discard SetWindowLongPtrW(window, GwlpUserData, cast[int](raw))
    if raw == 0 or not popovers.hasKey(raw):
      return DefWindowProcW(window, message, wp, lp)
    host = popovers[raw]
    if message == WmNcCreate:
      return DefWindowProcW(window, message, wp, lp)
    # The panel reuses the same skin protocol as the page and dialog surface, so
    # its direct children get the themed background brush instead of stock ones.
    var skinReply: LRESULT
    if skinMessage(host.theme, window, message, wp, lp, skinReply):
      return skinReply
    case message
    of WmNcCalcSize:
      if wp != 0:
        return 0
      var frame = cast[ptr RECT](lp)[]
      let style = DWORD(GetWindowLongW(window, GwlStyle))
      let exStyle = DWORD(GetWindowLongW(window, GwlExStyle))
      let dpi = GetDpiForWindow(window)
      if dpi != 0 and AdjustWindowRectExForDpi(addr frame, style, 0, exStyle, dpi) != 0:
        cast[ptr RECT](lp)[] = frame
        return 0
      return DefWindowProcW(window, message, wp, lp)
    of WmEraseBackground:
      if paintPanel(host, window, cast[HDC](wp)): return 1
      return DefWindowProcW(window, message, wp, lp)
    of WmPaint:
      var paint: PaintStruct
      let dc = BeginPaint(window, addr paint)
      if dc != nil: discard paintPanel(host, window, dc)
      discard EndPaint(window, addr paint)
      return 0
    of WmKeyDown:
      host.keyDown(int32(wp))
      return 0
    of WmGetDlgCode:
      return LRESULT(0x0001'u32 or 0x0080'u32) # DLGC_WANTARROWS|WANTCHARS
    of WmKillFocus:
      when defined(leafProtocolProbes):
        echo "PANELMSG WM_KILLFOCUS target=", uint64(cast[uint](wp)),
          " panel=", uint64(cast[uint](window)),
          " inPanel=", host.isWithin(cast[HWND](wp))
      if host.hiding: return 0
      if not host.isWithin(cast[HWND](wp)):
        host.noteDismiss(pdOutside)
      return 0
    of WmActivateApp:
      when defined(leafProtocolProbes):
        echo "PANELMSG WM_ACTIVATEAPP wp=", wp
      if wp == 0 and not host.hiding: host.noteDismiss(pdOutside)
      return 0
    of WmSize:
      host.needsLayout = true
      return 0
    of WmClose:
      host.noteDismiss(pdSystemClose)
      return 0
    of WmNcDestroy:
      when defined(leafProtocolProbes):
        echo "PANEL NCDESTROY hwnd=", uint64(cast[uint](window)), " cookie=", raw
      host.windows.panel = nil
      return 0
    else:
      return DefWindowProcW(window, message, wp, lp)
  except CatchableError:
    return DefWindowProcW(window, message, wp, lp)

proc newPopover*(calls: Win32Calls, ownerWindow, wakeWindow, triggerWindow: HWND,
                 theme: NativeTheme, props: PopoverProps): Win32Popover {.raises: [CatchableError].} =
  ## Pure allocation: no OS resource yet, so the object itself is the retry
  ## receipt before any native step runs.
  if ownerWindow == nil: fail("popover requires an owning window")
  inc nextPopoverCookie
  if nextPopoverCookie == 0: fail("popover cookie space exhausted")
  result = Win32Popover(ownerThread: GetCurrentThreadId(), calls: calls,
    theme: theme, cookie: nextPopoverCookie, ownerWindow: ownerWindow,
    wakeWindow: wakeWindow, triggerWindow: triggerWindow, props: props,
    scale: 1.0)
  result.className = wide("LeafPopoverPanel-" & $result.ownerThread & "-" &
    $result.cookie)
  result.instance = GetModuleHandleW(nil)
  if result.instance == nil: nativeError("GetModuleHandleW")

proc openWindows*(host: Win32Popover) {.raises: [CatchableError].} =
  ## Idempotent and resumable: every completed step is recorded immediately.
  host.ownerCheck()
  if host.closed: fail("popover is closed")
  if not host.windows.classRegistered:
    var cls = WNDCLASSEXW(cbSize: UINT(sizeof(WNDCLASSEXW)), style: 3,
      lpfnWndProc: popoverProc, hInstance: host.instance,
      hbrBackground: nil, lpszClassName: addr host.className[0])
    if host.calls.registerClass(addr cls) == 0:
      nativeError("RegisterClassExW popover panel")
    host.windows.classRegistered = true
  if not host.windows.rootPublished:
    popovers[host.cookie] = host
    host.windows.rootPublished = true
  if host.windows.panel == nil:
    let title = wide(host.props.name)
    let panel = host.calls.createWindow(0, addr host.className[0],
      unsafeAddr title[0], WsPopup or WsCaption or WsClipChildren or WsClipSiblings,
      0, 0, 0, 0, host.ownerWindow, nil, host.instance,
      cast[pointer](host.cookie))
    if panel == nil: nativeError("CreateWindowExW popover panel")
    # Record the real HWND receipt BEFORE any step that can fail: a refused
    # surface mark must leave the window owned and cleanable instead of dropping
    # it. The failure is raised with its own last error and the existing
    # closeWindows rollback performs (and reports) the cleanup; nothing is
    # destroyed and discarded in this branch, so the primary error cannot be
    # overwritten by a cleanup error.
    host.windows.panel = panel
    # The panel is a surface: mark it so the panel fill and every child resolve
    # the same background (skin.surfaceColor walks up to this mark).
    if markPanelSurface(panel, host.calls.setProp) == 0:
      nativeError("SetPropW popover panel surface")
    # A fresh window paints from scratch with the current theme.
    host.needsThemeRepaint = false

proc setTheme*(host: Win32Popover, theme: NativeTheme) {.raises: [CatchableError].} =
  when defined(leafProtocolProbes):
    if host.theme != theme:
      echo "PANELTHEME from=", host.theme, " to=", theme
  if host.theme != theme:
    host.theme = theme
    host.needsLayout = true
    host.needsThemeRepaint = true
  elif not host.needsThemeRepaint: return
  if host.windows.panel != nil:
    # A surface-only invalidation leaves the panel's body and text children with
    # their old pixels (the same defect already fixed for the modal surface in
    # overlay_host). Repaint the panel AND every child, only when the theme
    # really changed or a previous repaint failed, so an ordinary turn stays
    # paint-free.
    when defined(leafProtocolProbes):
      echo "PANELTHEME repaint hwnd=", uint64(cast[uint](host.windows.panel)),
        " theme=", host.theme
    # The theme is already updated here: a refused repaint is a real native
    # failure and must be reported (the modal surface does the same). The debt
    # stays recorded, so the next ordinary turn retries the repaint instead of
    # claiming a themed panel it never painted.
    if host.calls.redrawWindow(host.windows.panel, nil, nil,
        RdwInvalidate or RdwErase or RdwAllChildren) == 0:
      nativeError("RedrawWindow popover panel")
    host.needsThemeRepaint = false

proc applyProps*(host: Win32Popover, props: PopoverProps, theme: NativeTheme) {.raises: [CatchableError].} =
  host.props = props
  host.setTheme(theme)
  if host.windows.panel != nil:
    let title = wide(props.name)
    discard SetWindowTextW(host.windows.panel, unsafeAddr title[0])

proc panelHandle*(host: Win32Popover): HWND {.raises: [CatchableError].} =
  host.ownerCheck()
  host.windows.panel

proc place*(host: Win32Popover, x, y, width, height: int32) {.raises: [CatchableError].} =
  ## Geometry only: never shows, focuses or activates anything.
  host.ownerCheck()
  if host.windows.panel == nil: fail("popover panel is not live")
  if host.calls.windowPos(host.windows.panel, nil, x, y, max(1'i32, width),
      max(1'i32, height), 0x0004'u32 or 0x0010'u32) == 0: # SWP_NOZORDER|SWP_NOACTIVATE
    nativeError("SetWindowPos popover panel")

proc show*(host: Win32Popover) {.raises: [CatchableError].} =
  host.ownerCheck()
  if host.closed: fail("popover is closed")
  if host.windows.panel == nil: fail("popover panel is not live")
  host.hasDismiss = false
  host.tabPending = 0
  discard host.calls.showWindow(host.windows.panel, SwShow)
  if IsWindowVisible(host.windows.panel) == 0:
    fail("popover panel did not become visible")
  host.shown = true
  host.needsLayout = false

proc hide*(host: Win32Popover) {.raises: [CatchableError].} =
  host.ownerCheck()
  if host.closed: return
  host.hiding = true
  try:
    host.hasDismiss = false
    host.tabPending = 0
    host.pendingTab = 0
    host.requestPending = false
    if host.shown and host.windows.panel != nil:
      discard host.calls.showWindow(host.windows.panel, SwHide)
    host.shown = false
  finally:
    host.hiding = false

proc isWithinPanel*(host: Win32Popover, window: HWND): bool {.raises: [].} =
  ## True when the window is the panel, a child of it, or owned by it.
  host.isWithin(window)

proc noteTemporaryHidden*(host: Win32Popover) {.raises: [].} =
  ## The owner hid or minimized the panel: the window is gone visually but the
  ## accepted state is unchanged. No pending tab may leak into a later accept.
  host.shown = false
  host.pendingTab = 0
  host.requestPending = false

proc isVisible*(host: Win32Popover): bool {.raises: [].} =
  host != nil and host.shown and host.windows.panel != nil and
    IsWindowVisible(host.windows.panel) != 0

proc focusInside*(host: Win32Popover): bool {.raises: [].} =
  host != nil and host.windows.panel != nil and host.isWithin(GetFocus())

proc takeDismiss*(host: Win32Popover, dismiss: var PopoverDismiss): bool {.raises: [].} =
  if host == nil or not host.hasDismiss: return false
  dismiss = host.dismiss
  host.hasDismiss = false
  true

proc hasTab*(host: Win32Popover): bool {.raises: [].} =
  host != nil and host.tabPending != 0

proc takeTab*(host: Win32Popover): int {.raises: [].} =
  if host == nil: return 0
  result = host.tabPending
  host.tabPending = 0



proc needsLayoutNow*(host: Win32Popover): bool {.raises: [].} =
  host != nil and host.needsLayout

proc clearNeedsLayout*(host: Win32Popover) {.raises: [].} =
  if host != nil: host.needsLayout = false

proc panelDead*(host: Win32Popover): bool {.raises: [].} =
  host != nil and host.windows.panel == nil

proc wake*(host: Win32Popover) {.raises: [].} =
  if host != nil and host.wakeWindow != nil:
    discard PostMessageW(host.wakeWindow, PopoverWake, 0, 0)

proc closeWindows*(host: Win32Popover): ref CatchableError {.raises: [].} =
  ## Idempotent cleanup that keeps a receipt for anything that failed.
  if host == nil: return nil
  var first: ref CatchableError
  try:
    host.hide()
  except CatchableError as error: first = error
  if host.windows.panel != nil:
    try:
      let panel = host.windows.panel
      if host.calls.destroyWindow(panel) == 0 and IsWindow(panel) != 0:
        nativeError("DestroyWindow popover panel")
      host.windows.panel = nil
    except CatchableError as error:
      if first == nil: first = error
  if host.windows.classRegistered and host.windows.panel == nil:
    try:
      if host.calls.unregisterClass(addr host.className[0], host.instance) == 0:
        nativeError("UnregisterClassW popover panel")
      host.windows.classRegistered = false
    except CatchableError as error:
      if first == nil: first = error
  if host.windows.rootPublished and host.windows.panel == nil and
      not host.windows.classRegistered:
    popovers.del(host.cookie)
    host.windows.rootPublished = false
  first

proc destroyWindows*(host: Win32Popover) {.raises: [CatchableError].} =
  host.ownerCheck()
  let failure = host.closeWindows()
  if failure != nil: raise failure
  host.closed = true

proc closePanelWindow*(host: Win32Popover): ref CatchableError {.raises: [].} =
  ## Close only the panel window (keep the class receipt) so a recreated owner
  ## can open a fresh window later without leaking the previous one.
  if host == nil or host.windows.panel == nil: return nil
  var first: ref CatchableError
  try: host.hide()
  except CatchableError as error: first = error
  try:
    let panel = host.windows.panel
    if host.calls.destroyWindow(panel) == 0 and IsWindow(panel) != 0:
      nativeError("DestroyWindow popover panel")
    host.windows.panel = nil
  except CatchableError as error:
    if first == nil: first = error
  first

proc resourcesReleased*(host: Win32Popover): bool {.raises: [].} =
  host != nil and host.windows.panel == nil and not host.windows.classRegistered and
    not host.windows.rootPublished

when defined(leafProtocolProbes):
  proc popoverReceiptsForTest*(): int {.raises: [].} =
    ## Probe-only: how many cookie->host receipts this thread still holds. This
    ## is the table the callback uses, not a mirror of the backend's counters.
    popovers.len
