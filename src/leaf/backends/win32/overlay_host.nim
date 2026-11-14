## Owned modal windows for the standard Dialog/AlertDialog.
##
## One level is a non-topmost layered scrim plus the dialog surface. Both are
## real owned WS_POPUP windows of the window below this level, so nothing is
## clipped by the page and no layer is globally topmost. There is no second
## message pump: the owning Host dispatches every message, and this module only
## records one pending close request which the backend turns into a typed event
## at an ordinary turn.
##
## Every mutating OS step is taken through the injected `Win32Calls` table and
## leaves its own receipt (class registered, window created, root published,
## layered attributes set), so a failure anywhere keeps enough state for an
## explicit retry instead of losing the resource.
when not defined(windows): {.error: "Win32 modal overlays require Windows".}
import std/[tables, math, unicode]
import ../../[core, native_theme]
import ../../overlay_protocol
import ./[api, calls, skin]

type
  PaintStruct {.importc: "PAINTSTRUCT", header: "<windows.h>", bycopy.} = object
    hdc: HDC
    fErase: BOOL
    rcPaint: RECT
    fRestore, fIncUpdate: BOOL
    rgbReserved: array[32, uint8]
  MonitorInfo* = object
    ## Layout-compatible with the C MONITORINFO; declared locally so rcWork is
    ## the same Nim RECT type the layout math uses.
    cbSize: DWORD
    rcMonitor: RECT
    rcWork: RECT
    dwFlags: DWORD

  OverlayWindows* = object
    ## Per-step receipts. A true flag / non-nil handle is an owned resource that
    ## a retry must not create twice, so cleanup can be resumed exactly.
    surfaceClassRegistered*, scrimClassRegistered*, rootPublished*: bool
    layeredSet*: bool
    surface*, scrim*: HWND

  OverlayGeometryError* = object of CatchableError
    ## Pure geometry refusal: the requested size no longer fits the work area.
    ## Never used for a failed OS call, so callers can tell the two apart.

  OverlayPlacement* = object
    ## Pure placement math result: pixels, no OS mutation yet.
    x*, y*, widthPx*, heightPx*: int32
    scrimLeft*, scrimTop*, scrimRight*, scrimBottom*: int32
    clientWidth*, clientHeight*: float64
    owner*: HWND

  Win32Overlay* = ref object
    ownerThread: DWORD
    calls: Win32Calls
    theme: NativeTheme
    cookie: uint
    className, scrimClassName: seq[WCHAR]
    instance: HINSTANCE
    windows: OverlayWindows
    ownerWindow, wakeWindow: HWND
    title: string
    ## Per-step OS receipts. Target state and delivered state are separate: a
    ## partially completed show/hide keeps exactly the steps that really
    ## happened so a bounded retry can finish or clean up.
    scrimShown*, surfaceShown*: bool
    ownerDisabled*: bool
    publishDone*: bool
    surfaceLinked*, scrimLinked*: bool
    surfacePrevOwner*, scrimPrevOwner*: HWND
    dismissible, closed: bool
    requested*: OverlayDismiss
    hasRequest*: bool
    needsLayout*: bool
    # Scroll/tab requests recorded by the WndProc as scalars and consumed at an
    # ordinary turn. Wheel notches accumulate (never dropped); an absolute target
    # (thumb/Home/End) replaces any pending delta, latest wins.
    scrollNotches: float64
    scrollAbs: float64
    hasScrollAbs: bool
    tabPending: int      # 0 none, 1 forward, -1 backward
    scrollable: bool
    overlayBarV*, overlayBarH*: HWND          # standard SCROLLBAR children
    overlayBarShownV*, overlayBarShownH*: bool # per-step receipts
    overlayPendPx: float64                    # accumulated line delta (device px)
    overlayPendPage: int                      # +1/-1 page request
    overlayPendAbsPx: float64                 # absolute thumb/top/bottom (device px)
    overlayPendHasAbs: bool
    overlayPendVertical: bool               # which bar produced the pending request
    overlayPixelScale: float64                # device pixels per DIP

const
  WmEraseBackground = 0x0014'u32
  WmPaint = 0x000f'u32
  WmClose = 0x0010'u32
  WmNcCalcSize = 0x0083'u32
  WmNcHitTest = 0x0084'u32
  WmMouseActivate = 0x0021'u32
  WmLButtonDown = 0x0201'u32
  WmLButtonUp = 0x0202'u32
  WmWindowPosChanged = 0x0047'u32
  WmMouseWheel = 0x020a'u32
  VkPrior = 0x21'i32
  VkNext = 0x22'i32
  VkHome = 0x24'i32
  VkEnd = 0x23'i32
  VkTab = 0x09'i32
  VkShift = 0x10'i32
  WmSize = 0x0005'u32
  WmSettingChange = 0x001a'u32
  WmThemeChanged = 0x031e'u32
  WmDpiChanged = 0x02e0'u32
  WsPopup = 0x80000000'u32
  WsCaption = 0x00c00000'u32
  WsClipChildren = 0x02000000'u32
  WsClipSiblings = 0x04000000'u32
  SwHide = 0
  SwShowNoActivate = 4
  SwShow = 5
  MaNoActivate = 3
  HtClient = 1
  LayeredAlpha = 2'u32
  ExLayered = 0x00080000'u32
  ExToolWindow = 0x00000080'u32
  ExNoActivate = 0x08000000'u32
  RdwInvalidate = 0x0001'u32
  RdwErase = 0x0004'u32
  RdwAllChildren = 0x0080'u32
  ScrimAlpha = 128'u8
    ## Upstream DialogOverlay is bg-black/50 in both color modes.
  ModalMargin* = 16.0
    ## Keeps the surface inside the monitor work area; upstream caps the width
    ## at calc(100% - 2rem) with the same 16px margin.
  SwpNoActivate = 0x0010'u32
  SwpNoZOrder = 0x0004'u32
  SwpNoOwnerZOrder = 0x0200'u32
  SwpNoMove = 0x0002'u32
  SwpNoSize = 0x0001'u32
  GwlpUserData = -21'i32
  GwlStyle = -16'i32
  GwlExStyle = -20'i32
  GwlpHwndParent = -8'i32
  DcBrush = 18'i32
    ## DC_BRUSH stock object: its colour is per-DC, set by SetDCBrushColor.

var overlays {.threadvar.}: Table[uint, Win32Overlay]
var nextCookie {.threadvar.}: uint

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

proc surfaceFill(theme: NativeTheme): uint32 {.raises: [].} =
  if theme == systemTheme: return 0x00ffffff'u32
  try: colorRef(theme.palette.surface)
  except CatchableError: 0x00ffffff'u32

proc ownerCheck(host: Win32Overlay) {.raises: [CatchableError].} =
  if host == nil: fail("Win32 overlay is nil")
  if GetCurrentThreadId() != host.ownerThread:
    fail("Win32 overlay must run on its owning UI thread")

proc noteRequest(host: Win32Overlay, source: OverlayDismiss) {.raises: [].} =
  ## WndProc path: scalars only. No allocation, no callback, no OS call.
  if host.closed: return
  if source == scrim and not host.dismissible: return
  host.hasRequest = true
  host.requested = source

proc paintBackground(host: Win32Overlay, window: HWND, dc: HDC): bool {.raises: [].} =
  if dc == nil: return false
  var rect: RECT
  try:
    if host.calls.clientRect(window, addr rect) == 0: return false
    let rgb = if window == host.windows.scrim: 0'u32 else: surfaceFill(host.theme)
    discard host.calls.setDCBrushColor(dc, colorRef(rgb))
    # A real DC_BRUSH handle: the stock index is not itself an HBRUSH.
    let brush = host.calls.getStockObject(DcBrush)
    if brush == nil: return false
    discard host.calls.fillRect(dc, addr rect, cast[HBRUSH](brush))
    true
  except CatchableError: false

proc overlayProc(window: HWND, message: UINT, wp: WPARAM,
                 lp: LPARAM): LRESULT {.stdcall, raises: [].} =
  ## Raw-view/control-view role is decided by the window style bits, so this
  ## procedure only paints, records one request and keeps the full-client
  ## geometry. It never calls business code and never allocates.
  var host: Win32Overlay
  try:
    var raw = cast[uint](GetWindowLongPtrW(window, GwlpUserData))
    if message == WM_NCCREATE:
      let creation = cast[ptr CREATESTRUCTW](lp)
      if creation == nil: return 0
      raw = cast[uint](creation.lpCreateParams)
      if raw == 0: return 0
      discard SetWindowLongPtrW(window, GwlpUserData, cast[int](raw))
    let cookie = raw shr 1
    if cookie == 0 or not overlays.hasKey(cookie):
      return DefWindowProcW(window, message, wp, lp)
    host = overlays[cookie]
    if message == WM_NCCREATE:
      return DefWindowProcW(window, message, wp, lp)
    let isScrim = (raw and 1) == 1
    # The modal surface must reuse the same skin protocol as the page, otherwise
    # its direct children fall back to the stock WM_CTLCOLORSTATIC colours and
    # keep stale light pixels after a theme change.
    var skinReply: LRESULT
    if not isScrim and skinMessage(host.theme, window, message, wp, lp, skinReply):
      return skinReply
    case message
    of WmNcCalcSize:
      # Make the client area equal the whole window while the caption style bit
      # is kept (that bit is what gives UIA Window + WindowPattern).
      # wParam != 0: rgb[0] already holds the *proposed window rect*, so the
      # correct handling is to keep it and return 0 - never overwrite it with a
      # read-back of the current (still old) window rect.
      # wParam == 0: lParam holds the *proposed client rect*; expand it by the
      # real frame metrics to recover the proposed window rect.
      if wp != 0:
        return 0
      var frame = cast[ptr RECT](lp)[]
      let style = DWORD(GetWindowLongW(window, GwlStyle))
      let exStyle = DWORD(GetWindowLongW(window, GwlExStyle))
      let dpi = GetDpiForWindow(window)
      if dpi != 0 and AdjustWindowRectExForDpi(addr frame, style, 0, exStyle, dpi) != 0:
        cast[ptr RECT](lp)[] = frame
        return 0
      var current: RECT
      if GetWindowRect(window, addr current) != 0:
        cast[ptr RECT](lp)[] = current
        return 0
      return DefWindowProcW(window, message, wp, lp)
    of WmClose:
      if not isScrim: host.noteRequest(systemClose)
      return 0
    of WM_COMMAND:
      # IsDialogMessage turns Esc into IDCANCEL for the modal target. IDOK is
      # swallowed: it must never become an implicit business confirmation.
      if not isScrim and UINT(wp and 0xffff) == 2:
        host.noteRequest(escapeKey)
      return 0
    of WmEraseBackground:
      if paintBackground(host, window, cast[HDC](wp)): return 1
      return DefWindowProcW(window, message, wp, lp)
    of WmPaint:
      var paint: PaintStruct
      let dc = BeginPaint(window, addr paint)
      if dc != nil: discard paintBackground(host, window, dc)
      discard EndPaint(window, addr paint)
      return 0
    of WmNcHitTest: return HtClient
    of WM_VSCROLL, WM_HSCROLL:
      if not isScrim and (cast[HWND](lp) == host.overlayBarV or
          cast[HWND](lp) == host.overlayBarH):
        let code = int(UINT(wp and 0xffff))
        let bar = cast[HWND](lp)
        host.overlayPendVertical = (bar == host.overlayBarV)
        var info: SCROLLINFO
        let step = 24.0 * (if host.overlayPixelScale > 0.0:
          host.overlayPixelScale else: 1.0)
        case code
        of SB_LINEUP: host.overlayPendPx -= step
        of SB_LINEDOWN: host.overlayPendPx += step
        of SB_PAGEUP: host.overlayPendPage = -1
        of SB_PAGEDOWN: host.overlayPendPage = 1
        of SB_TOP:
          host.overlayPendHasAbs = true
          host.overlayPendAbsPx = 0.0
        of SB_BOTTOM:
          host.overlayPendHasAbs = true
          host.overlayPendAbsPx = 1.0e12 # owner clamps to its own range
        of SB_THUMBTRACK, SB_THUMBPOSITION:
          info.cbSize = UINT(sizeof(SCROLLINFO))
          info.fMask = SIF_TRACKPOS
          if host.calls.scrollInfo(bar, SB_CTL, addr info) != 0:
            host.overlayPendHasAbs = true
            host.overlayPendAbsPx = float64(info.nTrackPos)
        else: discard
        return 0
      return DefWindowProcW(window, message, wp, lp)
    of WmMouseWheel:
      if not isScrim and host.scrollable:
        # The surface itself received the wheel (no child consumed it).
        # The high word is a signed 16-bit wheel delta: reinterpret the bits,
        # never a range-checked numeric conversion (0xFF88 must become -120).
        let raw = cast[int16](uint16((wp shr 16) and 0xffff))
        let notches = -float64(raw) / 120.0
        host.scrollNotches += notches
        host.hasScrollAbs = false
        return 0
      return DefWindowProcW(window, message, wp, lp)
    of WM_KEYDOWN:
      if not isScrim and host.scrollable:
        let key = int32(wp)
        if key == VkTab:
          let shift = (GetKeyState(VkShift) and 0x8000'i16) != 0
          host.tabPending = if shift: -1 else: 1
          return 0
        elif key in [VkPrior, VkNext, VkHome, VkEnd]:
          host.hasScrollAbs = true
          host.scrollAbs = if key == VkPrior or key == VkHome: -1.0 else: 1.0
          return 0
      return DefWindowProcW(window, message, wp, lp)
    of WmMouseActivate:
      if isScrim: return MaNoActivate
      return DefWindowProcW(window, message, wp, lp)
    of WmLButtonDown:
      if isScrim: return 0
      return DefWindowProcW(window, message, wp, lp)
    of WmLButtonUp:
      if isScrim:
        host.noteRequest(scrim)
        return 0
      return DefWindowProcW(window, message, wp, lp)
    of WmSize, WmDpiChanged, WmSettingChange, WmThemeChanged, WmWindowPosChanged:
      host.needsLayout = true
      if host.wakeWindow != nil:
        discard PostMessageW(host.wakeWindow, WM_HOST_TICK, 0, 0)
      if message in {WmDpiChanged, WmWindowPosChanged}:
        return DefWindowProcW(window, message, wp, lp)
      return 0
    of WM_NCDESTROY:
      try:
        discard SetWindowLongPtrW(window, GwlpUserData, 0)
      finally:
        if window == host.windows.surface: host.windows.surface = nil
        elif window == host.windows.scrim: host.windows.scrim = nil
      return DefWindowProcW(window, message, wp, lp)
    else: discard
    return DefWindowProcW(window, message, wp, lp)
  except CatchableError:
    return 0

proc monitorWorkArea*(calls: Win32Calls, window: HWND): tuple[width, height: float64, known: bool]
    {.raises: [CatchableError].} =
  ## Work area of the monitor owning `window` in DIP. Unknown geometry is
  ## reported explicitly so callers do not reject a legal dialog by accident.
  if window == nil: return (0.0, 0.0, false)
  var info = MonitorInfo(cbSize: DWORD(sizeof(MonitorInfo)))
  let monitor = calls.monitorFromWindow(window, 2'u32)
  if monitor == nil or calls.getMonitorInfo(monitor, addr info) == 0:
    return (0.0, 0.0, false)
  if info.rcWork.right <= info.rcWork.left or info.rcWork.bottom <= info.rcWork.top:
    return (0.0, 0.0, false)
  let dpi = calls.dpi(window)
  if dpi == 0: return (0.0, 0.0, false)
  let scale = float64(dpi) / 96.0
  (float64(info.rcWork.right - info.rcWork.left) / scale,
   float64(info.rcWork.bottom - info.rcWork.top) / scale, true)

proc newOverlay*(calls: Win32Calls, ownerWindow, wakeWindow: HWND, title: string,
                 theme: NativeTheme, dismissible: bool): Win32Overlay {.raises: [CatchableError].} =
  ## Pure allocation: no OS resource yet, so a caller can keep the object as the
  ## retry receipt before any native step runs.
  if ownerWindow == nil: fail("overlay requires an owning window")
  inc nextCookie
  if nextCookie == 0: fail("overlay cookie space exhausted")
  result = Win32Overlay(ownerThread: GetCurrentThreadId(), calls: calls,
    theme: theme, cookie: nextCookie, ownerWindow: ownerWindow,
    wakeWindow: wakeWindow, title: title, dismissible: dismissible)
  result.className = wide("LeafOverlaySurface-" & $result.ownerThread & "-" & $result.cookie)
  result.scrimClassName = wide("LeafOverlayScrim-" & $result.ownerThread & "-" & $result.cookie)
  result.instance = GetModuleHandleW(nil)
  if result.instance == nil: nativeError("GetModuleHandleW")

proc openWindows*(host: Win32Overlay) {.raises: [CatchableError].} =
  ## Idempotent and resumable: every completed step is recorded immediately, so
  ## a retry after a failure continues instead of creating a second resource.
  host.ownerCheck()
  if host.closed: fail("overlay is closed")
  if not host.windows.surfaceClassRegistered:
    var cls = WNDCLASSEXW(cbSize: UINT(sizeof(WNDCLASSEXW)), style: 3,
      lpfnWndProc: overlayProc, hInstance: host.instance,
      hbrBackground: nil, lpszClassName: addr host.className[0])
    if host.calls.registerClass(addr cls) == 0: nativeError("RegisterClassExW overlay surface")
    host.windows.surfaceClassRegistered = true
  if not host.windows.scrimClassRegistered:
    var cls = WNDCLASSEXW(cbSize: UINT(sizeof(WNDCLASSEXW)), style: 3,
      lpfnWndProc: overlayProc, hInstance: host.instance,
      hbrBackground: nil, lpszClassName: addr host.scrimClassName[0])
    if host.calls.registerClass(addr cls) == 0: nativeError("RegisterClassExW overlay scrim")
    host.windows.scrimClassRegistered = true
  if not host.windows.rootPublished:
    overlays[host.cookie] = host
    host.windows.rootPublished = true
  if host.windows.scrim == nil:
    let scrim = host.calls.createWindow(ExLayered or ExToolWindow or ExNoActivate,
      addr host.scrimClassName[0], nil, WsPopup, 0, 0, 0, 0,
      host.ownerWindow, nil, host.instance,
      cast[pointer](host.cookie shl 1 or 1))
    if scrim == nil: nativeError("CreateWindowExW scrim")
    host.windows.scrim = scrim
  if not host.windows.layeredSet:
    if host.calls.setLayeredWindowAttributes(host.windows.scrim, 0, ScrimAlpha,
        LayeredAlpha) == 0:
      nativeError("SetLayeredWindowAttributes scrim")
    host.windows.layeredSet = true
  if host.windows.surface == nil:
    let title = wide(host.title)
    let surface = host.calls.createWindow(0, addr host.className[0],
      unsafeAddr title[0], WsPopup or WsCaption or WsClipChildren or WsClipSiblings,
      0, 0, 0, 0, host.ownerWindow, nil, host.instance,
      cast[pointer](host.cookie shl 1))
    if surface == nil: nativeError("CreateWindowExW overlay surface")
    host.windows.surface = surface
  # Deliberately no SetWindowTheme("") on the surface: it disables the visual
  # style for the surface subtree, so child BUTTON controls stop sending
  # NM_CUSTOMDRAW and fall back to the classic grey paint.
  discard host

proc hideOverlay*(host: Win32Overlay) {.raises: [CatchableError].}

proc destroyOverlayScrollbars*(host: Win32Overlay, first: var ref CatchableError) {.raises: [].}

proc reconcileOverlayScrollbars*(host: Win32Overlay) {.raises: [].} =
  ## A refused child destroy can still be fulfilled by destroying its parent:
  ## once the surface is gone the OS has removed the bar, so its receipt is
  ## cleared here instead of leaving a dead handle (or a false failure) behind.
  for vertical in [true, false]:
    let bar = if vertical: host.overlayBarV else: host.overlayBarH
    if bar == nil: continue
    if IsWindow(bar) == 0:
      if vertical:
        host.overlayBarV = nil
        host.overlayBarShownV = false
      else:
        host.overlayBarH = nil
        host.overlayBarShownH = false

proc closeWindows*(host: Win32Overlay): ref CatchableError {.raises: [].} =
  ## Idempotent cleanup that keeps a receipt for anything that failed, so a
  ## later retry only retries what is still owned.
  if host == nil: return nil
  var first: ref CatchableError
  var barError: ref CatchableError
  # Children first: the surface owns the scrollbar windows, so destroying it
  # would invalidate their handles before this step could report per-bar state.
  host.destroyOverlayScrollbars(barError)
  try:
    # Always run the step-wise cleanup: a partially completed show must be undone
    # even when the level never reached a fully visible state.
    host.hideOverlay()
  except CatchableError as error: first = error
  if host.windows.surface != nil:
    try:
      let surface = host.windows.surface
      if host.calls.destroyWindow(surface) == 0 and IsWindow(surface) != 0:
        nativeError("DestroyWindow overlay surface")
      # A refused destroy can be fulfilled later by an owner teardown: once the
      # window is really gone the receipt is cleared instead of failing forever.
      host.windows.surface = nil
    except CatchableError as error:
      if first == nil: first = error
  # The parent may have reaped a bar whose own destroy was refused; only a bar
  # that is still a live window counts as a teardown failure.
  host.reconcileOverlayScrollbars()
  if barError != nil and (host.overlayBarV != nil or host.overlayBarH != nil):
    if first == nil: first = barError
  if host.windows.scrim != nil:
    try:
      let scrim = host.windows.scrim
      if host.calls.destroyWindow(scrim) == 0 and IsWindow(scrim) != 0:
        nativeError("DestroyWindow scrim")
      host.windows.scrim = nil
    except CatchableError as error:
      if first == nil: first = error
  # Each class is unregistered only while its own receipt says it is ours.
  if host.windows.surfaceClassRegistered and host.windows.surface == nil:
    try:
      if host.calls.unregisterClass(addr host.className[0], host.instance) == 0:
        nativeError("UnregisterClassW overlay surface")
      host.windows.surfaceClassRegistered = false
    except CatchableError as error:
      if first == nil: first = error
  if host.windows.scrimClassRegistered and host.windows.scrim == nil:
    try:
      if host.calls.unregisterClass(addr host.scrimClassName[0], host.instance) == 0:
        nativeError("UnregisterClassW overlay scrim")
      host.windows.scrimClassRegistered = false
    except CatchableError as error:
      if first == nil: first = error
  if host.windows.rootPublished and host.windows.surface == nil and
      host.windows.scrim == nil and not host.windows.surfaceClassRegistered and
      not host.windows.scrimClassRegistered and host.overlayBarV == nil and
      host.overlayBarH == nil:
    overlays.del(host.cookie)
    host.windows.rootPublished = false
  first

proc destroyOverlayScrollbars*(host: Win32Overlay,
    first: var ref CatchableError) {.raises: [].} =
  for vertical in [true, false]:
    let bar = if vertical: host.overlayBarV else: host.overlayBarH
    if bar == nil: continue
    try:
      if host.calls.destroyWindow(bar) == 0:
        # 1400 = ERROR_INVALID_HANDLE: the child already died with a parent that
        # was destroyed earlier, so the receipt is cleared rather than failed.
        if IsWindow(bar) != 0:
          nativeError("DestroyWindow overlay scrollbar")
      if vertical:
        host.overlayBarV = nil
        host.overlayBarShownV = false
      else:
        host.overlayBarH = nil
        host.overlayBarShownH = false
    except CatchableError as error:
      if first == nil: first = error

proc destroyWindows*(host: Win32Overlay) {.raises: [CatchableError].} =
  host.ownerCheck()
  let failure = host.closeWindows()
  if failure != nil: raise failure
  host.closed = true

proc resourcesReleased*(host: Win32Overlay): bool =
  ## A level is released only when every task resource receipt is cleared: the
  ## two windows, both class registrations and both scrollbar handles.
  host != nil and host.windows.surface == nil and host.windows.scrim == nil and
    not host.windows.surfaceClassRegistered and not host.windows.scrimClassRegistered and
    host.overlayBarV == nil and host.overlayBarH == nil

proc setOwnerWindow(host: Win32Overlay, owner: HWND) {.raises: [CatchableError].} =
  ## Two HWNDs are re-owned independently and each success is recorded before
  ## the next call, so a failure on the second one never leaves a half-applied
  ## field: the retry continues with the window that is still unlinked, and an
  ## explicit rollback restores only the windows that really changed.
  if host.closed or owner == nil: return
  if owner == host.ownerWindow and host.surfaceLinked and host.scrimLinked: return
  if owner != host.ownerWindow:
    # A new target invalidates both link receipts; the previous targets remain
    # recorded so a failure can be rolled back to them.
    host.ownerWindow = owner
    host.surfaceLinked = false
    host.scrimLinked = false
  proc link(window: HWND, linked: var bool, previous: var HWND)
      {.raises: [CatchableError].} =
    if window == nil or linked: return
    var prior: HWND
    if host.windows.surface == window: prior = host.surfacePrevOwner
    else: prior = host.scrimPrevOwner
    setLastError(0)
    if host.calls.setWindowData(window, GwlpHwndParent, cast[int](owner)) == 0 and
        lastError() != 0:
      # Roll back only the links this call already performed.
      if host.surfaceLinked:
        discard host.calls.setWindowData(host.windows.surface, GwlpHwndParent,
          cast[int](host.surfacePrevOwner))
        host.surfaceLinked = false
      if host.scrimLinked:
        discard host.calls.setWindowData(host.windows.scrim, GwlpHwndParent,
          cast[int](host.scrimPrevOwner))
        host.scrimLinked = false
      nativeError("SetWindowLongPtrW overlay owner")
    previous = prior
    linked = true
  try:
    link(host.windows.scrim, host.scrimLinked, host.scrimPrevOwner)
    link(host.windows.surface, host.surfaceLinked, host.surfacePrevOwner)
  except CatchableError as error:
    error.msg.add("; overlay owner link kept for retry")
    raise error

proc setTitle*(host: Win32Overlay, title: string) {.raises: [CatchableError].} =
  host.ownerCheck()
  if host.closed or host.windows.surface == nil or host.title == title: return
  let text = wide(title)
  if host.calls.setText(host.windows.surface, addr text[0]) == 0:
    nativeError("SetWindowTextW overlay surface")
  host.title = title

proc placeOrder(host: Win32Overlay) {.raises: [CatchableError].} =
  ## Strict non-topmost order: this level's scrim sits directly below its own
  ## surface, and the whole pair is owned by the level below (so it stays above
  ## that level and never above another application).
  if host.windows.scrim == nil or host.windows.surface == nil: return
  if host.calls.windowPos(host.windows.scrim, host.windows.surface, 0, 0, 0, 0,
      SwpNoActivate or SwpNoMove or SwpNoSize or SwpNoOwnerZOrder) == 0:
    nativeError("SetWindowPos scrim order")

proc placementFor*(host: Win32Overlay, widthDip, heightDip: float64,
                   ownerWindow: HWND): OverlayPlacement {.raises: [CatchableError].} =
  ## Strict variant: the caller has already validated that this size fits, so
  ## the result is never silently narrowed. A size that no longer fits fails
  ## explicitly instead of being clamped in a second stage.
  ## Pure geometry, no OS mutation: the scrim covers the whole owning window and
  ## the surface is centered in it, clamped to the monitor work area as a last
  ## safety net (the caller already rejected content that cannot fit).
  host.ownerCheck()
  let owner = if ownerWindow != nil: ownerWindow else: host.ownerWindow
  if owner == nil: fail("overlay placement requires an owning window")
  var frame: RECT
  if host.calls.windowRect(owner, addr frame) == 0: nativeError("GetWindowRect owner")
  let dpi = host.calls.dpi(owner)
  if dpi == 0: nativeError("GetDpiForWindow overlay")
  let scale = float64(dpi) / 96.0
  var work: RECT
  var info = MonitorInfo(cbSize: DWORD(sizeof(MonitorInfo)))
  let monitor = host.calls.monitorFromWindow(owner, 2'u32)
  let hasWork = monitor != nil and host.calls.getMonitorInfo(monitor, addr info) != 0 and
    info.rcWork.right > info.rcWork.left and info.rcWork.bottom > info.rcWork.top
  if hasWork: work = info.rcWork
  var widthPx = int32(round(widthDip * scale))
  var heightPx = int32(round(heightDip * scale))
  if widthPx < 1: widthPx = 1
  if heightPx < 1: heightPx = 1
  if hasWork:
    let margin = int32(round(ModalMargin * scale))
    let availableWidth = work.right - work.left - margin * 2
    let availableHeight = work.bottom - work.top - margin * 2
    if availableWidth > 0 and widthPx > availableWidth:
      raise newException(OverlayGeometryError,
        "modal overlay width no longer fits the work area")
    if availableHeight > 0 and heightPx > availableHeight:
      raise newException(OverlayGeometryError,
        "modal overlay height no longer fits the work area")
  var x = frame.left + ((frame.right - frame.left) - widthPx) div 2
  var y = frame.top + ((frame.bottom - frame.top) - heightPx) div 2
  if hasWork:
    if x < work.left: x = work.left
    if y < work.top: y = work.top
    if x + widthPx > work.right: x = work.right - widthPx
    if y + heightPx > work.bottom: y = work.bottom - heightPx
  result = OverlayPlacement(x: x, y: y, widthPx: widthPx, heightPx: heightPx,
    scrimLeft: frame.left, scrimTop: frame.top,
    scrimRight: frame.right, scrimBottom: frame.bottom,
    clientWidth: float64(widthPx) / scale, clientHeight: float64(heightPx) / scale,
    owner: owner)

proc clampedPlacementFor*(host: Win32Overlay, widthDip, heightDip: float64,
                          ownerWindow: HWND): OverlayPlacement {.raises: [CatchableError].} =
  ## Runtime shrink fallback: clamp the surface into the work area and report
  ## the client size that really exists, so the caller can pin the safe actions
  ## instead of silently clipping them away.
  host.ownerCheck()
  let owner = if ownerWindow != nil: ownerWindow else: host.ownerWindow
  if owner == nil: fail("overlay placement requires an owning window")
  var frame: RECT
  if host.calls.windowRect(owner, addr frame) == 0: nativeError("GetWindowRect owner")
  let dpi = host.calls.dpi(owner)
  if dpi == 0: nativeError("GetDpiForWindow overlay")
  let scale = float64(dpi) / 96.0
  var work: RECT
  var info = MonitorInfo(cbSize: DWORD(sizeof(MonitorInfo)))
  let monitor = host.calls.monitorFromWindow(owner, 2'u32)
  let hasWork = monitor != nil and host.calls.getMonitorInfo(monitor, addr info) != 0 and
    info.rcWork.right > info.rcWork.left and info.rcWork.bottom > info.rcWork.top
  if hasWork: work = info.rcWork
  var widthPx = int32(round(widthDip * scale))
  var heightPx = int32(round(heightDip * scale))
  if widthPx < 1: widthPx = 1
  if heightPx < 1: heightPx = 1
  if hasWork:
    let margin = int32(round(ModalMargin * scale))
    let availableWidth = work.right - work.left - margin * 2
    let availableHeight = work.bottom - work.top - margin * 2
    if availableWidth > 0 and widthPx > availableWidth: widthPx = availableWidth
    if availableHeight > 0 and heightPx > availableHeight: heightPx = availableHeight
  var x = frame.left + ((frame.right - frame.left) - widthPx) div 2
  var y = frame.top + ((frame.bottom - frame.top) - heightPx) div 2
  if hasWork:
    if x < work.left: x = work.left
    if y < work.top: y = work.top
    if x + widthPx > work.right: x = work.right - widthPx
    if y + heightPx > work.bottom: y = work.bottom - heightPx
  result = OverlayPlacement(x: x, y: y, widthPx: widthPx, heightPx: heightPx,
    scrimLeft: frame.left, scrimTop: frame.top,
    scrimRight: frame.right, scrimBottom: frame.bottom,
    clientWidth: float64(widthPx) / scale, clientHeight: float64(heightPx) / scale,
    owner: owner)

proc applyPlacement*(host: Win32Overlay, placement: OverlayPlacement) {.raises: [CatchableError].} =
  ## The only OS mutation of the prepared geometry: scrim rect plus surface rect.
  host.ownerCheck()
  if host.windows.surface == nil or host.windows.scrim == nil:
    fail("overlay windows are not live")
  if host.calls.windowPos(host.windows.scrim, nil, placement.scrimLeft,
      placement.scrimTop, placement.scrimRight - placement.scrimLeft,
      placement.scrimBottom - placement.scrimTop,
      SwpNoActivate or SwpNoZOrder or SwpNoOwnerZOrder) == 0:
    nativeError("SetWindowPos scrim")
  if host.calls.windowPos(host.windows.surface, nil, placement.x, placement.y,
      placement.widthPx, placement.heightPx, SwpNoActivate or SwpNoZOrder) == 0:
    nativeError("SetWindowPos overlay surface")
  host.placeOrder()
  host.needsLayout = false

proc showOverlay*(host: Win32Overlay, ownerWindow: HWND) {.raises: [CatchableError].} =
  ## Each step records its own receipt immediately. ShowWindow's return value is
  ## the *previous* visibility, so 0 is normal and never treated as an error; a
  ## raised native failure keeps the receipts of the steps that did happen.
  host.ownerCheck()
  if host.closed: fail("overlay is closed")
  if host.windows.surface == nil or host.windows.scrim == nil:
    fail("overlay windows are not live")
  if ownerWindow != nil: host.setOwnerWindow(ownerWindow)
  host.hasRequest = false
  # A visible window is not a finished publish: the z-order, the owner disable
  # and the caller's stack/focus activation all have to happen too. Only the
  # completed receipt lets a retry exit early.
  if host.publishDone and host.scrimShown and host.surfaceShown: return
  host.placeOrder()
  if not host.scrimShown:
    discard host.calls.showWindow(host.windows.scrim, SwShowNoActivate)
    if IsWindowVisible(host.windows.scrim) == 0:
      fail("overlay scrim did not become visible")
    host.scrimShown = true
  if not host.surfaceShown:
    discard host.calls.showWindow(host.windows.surface, SwShow)
    if IsWindowVisible(host.windows.surface) == 0:
      fail("overlay surface did not become visible")
    host.surfaceShown = true
  host.placeOrder()
  if not host.ownerDisabled:
    # EnableWindow returns nonzero when the window was *previously disabled*, so
    # only a zero return means this level disabled the owner and is therefore
    # the only level allowed to re-enable it. The real post-state decides.
    discard host.calls.enable(host.ownerWindow, 0)
    if host.ownerWindow != nil and IsWindowEnabled(host.ownerWindow) != 0:
      fail("overlay owner was not disabled")
    host.ownerDisabled = true
  host.publishDone = true
  host.needsLayout = false

proc published*(host: Win32Overlay): bool {.raises: [].} =
  host != nil and host.publishDone

proc hideOverlay*(host: Win32Overlay) {.raises: [CatchableError].} =
  ## Cleanup always walks every step that happened, in reverse order, and clears
  ## a receipt only after that step succeeded. A failure keeps the remaining
  ## receipts so a bounded retry neither skips the owner re-enable nor claims a
  ## hidden window that is still visible.
  host.ownerCheck()
  if host.closed: return
  host.hasRequest = false
  if host.surfaceShown and host.windows.surface != nil:
    discard host.calls.showWindow(host.windows.surface, SwHide)
    host.surfaceShown = false
  if host.scrimShown and host.windows.scrim != nil:
    discard host.calls.showWindow(host.windows.scrim, SwHide)
    host.scrimShown = false
  if host.ownerDisabled and host.ownerWindow != nil:
    discard host.calls.enable(host.ownerWindow, 1)
    host.ownerDisabled = false
  host.publishDone = false

proc surfaceHandle*(host: Win32Overlay): HWND {.raises: [CatchableError].} =
  host.ownerCheck()
  host.windows.surface

proc scrimHandle*(host: Win32Overlay): HWND {.raises: [CatchableError].} =
  host.ownerCheck()
  host.windows.scrim

proc ensureOverlayScrollbar*(host: Win32Overlay,
    vertical: bool): HWND {.raises: [CatchableError].} =
  ## One standard SCROLLBAR child, created lazily. The non-nil handle is the
  ## creation receipt; a failure leaves it nil so the next attempt retries.
  if vertical:
    if host.overlayBarV != nil: return host.overlayBarV
  else:
    if host.overlayBarH != nil: return host.overlayBarH
  if host.windows.surface == nil: fail("overlay surface is not live")
  let name = wide("SCROLLBAR")
  let style = WS_CHILD or WS_VISIBLE or UINT(if vertical: SBS_VERT else: SBS_HORZ)
  let bar = host.calls.createWindow(0, addr name[0], nil, style, 0, 0, 0, 0,
    host.windows.surface, nil, host.instance, nil)
  if bar == nil: nativeError("CreateWindowExW overlay scrollbar")
  if vertical: host.overlayBarV = bar else: host.overlayBarH = bar
  discard host.calls.showWindow(bar, SwHide)
  bar

proc placeOverlayScrollbar*(host: Win32Overlay, vertical: bool,
    x, y, width, height: int32) {.raises: [CatchableError].} =
  ## Position, then show, recording each step: a partial commit keeps a
  ## retryable receipt instead of claiming the bar is fully published.
  let bar = host.ensureOverlayScrollbar(vertical)
  if bar == nil: fail("overlay scrollbar is not live")
  if host.calls.windowPos(bar, nil, x, y, width, height,
      SwpNoActivate or SwpNoZOrder) == 0:
    nativeError("SetWindowPos overlay scrollbar")
  # ShowWindow returns the previous visibility, never success: the receipt is
  # set only after the window is actually visible.
  discard host.calls.showWindow(bar, SwShowNoActivate)
  if IsWindowVisible(bar) == 0:
    fail("overlay scrollbar did not become visible")
  if vertical: host.overlayBarShownV = true else: host.overlayBarShownH = true

proc hideOverlayScrollbar*(host: Win32Overlay,
    vertical: bool) {.raises: [CatchableError].} =
  if vertical:
    if host.overlayBarV == nil or not host.overlayBarShownV: return
    discard host.calls.showWindow(host.overlayBarV, SwHide)
    # The receipt is cleared only when the window really is hidden; a blocked
    # hide keeps it so the retry does not believe the bar is gone.
    if IsWindowVisible(host.overlayBarV) != 0:
      fail("overlay scrollbar did not hide")
    host.overlayBarShownV = false
  else:
    if host.overlayBarH == nil or not host.overlayBarShownH: return
    discard host.calls.showWindow(host.overlayBarH, SwHide)
    if IsWindowVisible(host.overlayBarH) != 0:
      fail("overlay scrollbar did not hide")
    host.overlayBarShownH = false

proc hideOverlayScrollbars*(host: Win32Overlay) {.raises: [CatchableError].} =
  host.hideOverlayScrollbar(true)
  host.hideOverlayScrollbar(false)

proc applyOverlayScrollInfo*(host: Win32Overlay, vertical: bool,
    rangePx, pagePx, posPx: int32) {.raises: [CatchableError].} =
  ## 32-bit scroll metadata. Win32 derives the last reachable position from the
  ## inclusive nMax and nPage, so the page term is added back: the maximum
  ## position stays exactly at rangePx and the bottom-right content is reachable.
  let bar = if vertical: host.overlayBarV else: host.overlayBarH
  if bar == nil: return
  var info = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)),
    fMask: SIF_RANGE or SIF_PAGE or SIF_POS)
  let units = int64(max(0'i32, rangePx))
  let page = int64(max(1'i32, pagePx))
  info.nMin = 0
  info.nMax = int32(clamp(units + max(0'i64, page - 1), 0'i64, int64(high(int32))))
  info.nPage = UINT(clamp(page, 0'i64, int64(high(UINT))))
  info.nPos = int32(clamp(int64(posPx), 0'i64, units))
  discard host.calls.setScrollInfo(bar, SB_CTL, addr info, 1)
  # SetScrollInfo returns the previous position, not a success flag: the only
  # proof is reading the state back. A rejected configuration must fail here so
  # the level keeps its target and retries on the next ordinary turn.
  var applied = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)),
    fMask: SIF_RANGE or SIF_PAGE or SIF_POS)
  if host.calls.scrollInfo(bar, SB_CTL, addr applied) == 0:
    fail("overlay scrollbar metadata could not be read back")
  if applied.nMax != info.nMax or applied.nPos != info.nPos:
    fail("overlay scrollbar metadata did not apply")

proc takeOverlayScrollbar*(host: Win32Overlay): tuple[px: float64, pageDir: int,
    absolutePx: float64, hasAbsolutePx: bool,
    vertical: bool] {.raises: [CatchableError].} =
  host.ownerCheck()
  result = (host.overlayPendPx, host.overlayPendPage,
    host.overlayPendAbsPx, host.overlayPendHasAbs, host.overlayPendVertical)
  host.overlayPendPx = 0
  host.overlayPendPage = 0
  host.overlayPendHasAbs = false
  host.overlayPendVertical = false

proc overlayScrollbarHandles*(host: Win32Overlay):
    tuple[vertical, horizontal: HWND] =
  (host.overlayBarV, host.overlayBarH)

proc setOverlayPixelScale*(host: Win32Overlay,
    scale: float64) {.raises: [].} =
  host.overlayPixelScale = scale

proc setScrollable*(host: Win32Overlay, value: bool) {.raises: [CatchableError].} =
  host.ownerCheck()
  host.scrollable = value
  if not value:
    host.scrollNotches = 0
    host.hasScrollAbs = false
    host.tabPending = 0

proc addWheel*(host: Win32Overlay, notches: float64) {.raises: [CatchableError].} =
  ## Wheel notches accumulate so no event is silently dropped.
  host.ownerCheck()
  host.scrollNotches += notches
  host.hasScrollAbs = false

proc noteTab*(host: Win32Overlay, shift: bool) {.raises: [CatchableError].} =
  host.ownerCheck()
  host.tabPending = if shift: -1 else: 1

proc takeScroll*(host: Win32Overlay): tuple[notches, absolute: float64,
    hasAbsolute: bool] {.raises: [CatchableError].} =
  host.ownerCheck()
  result = (host.scrollNotches, host.scrollAbs, host.hasScrollAbs)
  host.scrollNotches = 0
  host.hasScrollAbs = false

proc isScrollable*(host: Win32Overlay): bool {.raises: [CatchableError].} =
  host.ownerCheck()
  host.scrollable

proc takeTab*(host: Win32Overlay): int {.raises: [CatchableError].} =
  host.ownerCheck()
  result = host.tabPending
  host.tabPending = 0

proc isVisible*(host: Win32Overlay): bool {.raises: [CatchableError].} =
  host.ownerCheck()
  host.surfaceShown or host.scrimShown

proc ownsDisabledOwner*(host: Win32Overlay): bool {.raises: [CatchableError].} =
  host.ownerCheck()
  host.ownerDisabled

proc visibleSteps*(host: Win32Overlay): tuple[scrim, surface: bool,
    ownerDisabled, surfaceLinked, scrimLinked: bool] {.raises: [CatchableError].} =
  ## Test/diagnostic view of the real per-step receipts.
  host.ownerCheck()
  (host.scrimShown, host.surfaceShown, host.ownerDisabled, host.surfaceLinked,
   host.scrimLinked)

proc overlayTheme*(host: Win32Overlay, theme: NativeTheme) {.raises: [CatchableError].} =
  host.ownerCheck()
  if host.theme == theme: return
  host.theme = theme
  if host.windows.surface != nil and (host.surfaceShown or host.scrimShown):
    # Repaint the surface *and every child* with the new theme; a surface-only
    # invalidation leaves stale light pixels inside the modal.
    if host.calls.redrawWindow(host.windows.surface, nil, nil,
        RdwInvalidate or RdwErase or RdwAllChildren) == 0:
      nativeError("RedrawWindow overlay theme")

proc takeRequest*(host: Win32Overlay, source: var OverlayDismiss): bool {.raises: [CatchableError].} =
  ## Ordinary-turn consumption of at most one recorded close request.
  host.ownerCheck()
  if host.hasRequest:
    source = host.requested
    host.hasRequest = false
    return true
  false

proc needsLayout*(host: Win32Overlay): bool {.raises: [CatchableError].} =
  host.ownerCheck()
  host.needsLayout

proc ownerWindowOf*(host: Win32Overlay): HWND {.raises: [CatchableError].} =
  host.ownerCheck()
  host.ownerWindow

proc titleOf*(host: Win32Overlay): string {.raises: [CatchableError].} =
  host.ownerCheck()
  host.title

proc liveOverlays*(): int =
  overlays.len
