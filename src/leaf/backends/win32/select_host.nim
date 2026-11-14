## Owned non-modal popup for the standard single select.
##
## One host owns one real WS_POPUP window, owned by the trigger's top-level
## window: nothing is clipped by the page, no layer is globally topmost and the
## popup disappears with its owner. There is no second message pump - the owning
## Host dispatches every message - and the window procedure only records scalars
## and one typed request, which the backend turns into a business event at an
## ordinary turn.
##
## Every mutating OS step leaves its own receipt (class registered, window
## created, root published, shown), so a failure keeps enough state for an
## explicit retry instead of losing the owned resource.
when not defined(windows): {.error: "Win32 select popups require Windows".}
import std/[tables, math, unicode]
import ../../[core, native_theme]
import ../../select_protocol
import ./[api, calls, skin, select_provider]

type
  PaintStruct {.importc: "PAINTSTRUCT", header: "<windows.h>", bycopy.} = object
    hdc: HDC
    fErase: BOOL
    rcPaint: RECT
    fRestore, fIncUpdate: BOOL
    rgbReserved: array[32, uint8]
  SelectMonitorInfo = object
    ## Layout-compatible with the C MONITORINFO; rcWork uses the same RECT.
    cbSize: DWORD
    rcMonitor: RECT
    rcWork: RECT
    dwFlags: DWORD

  SelectWindows* = object
    classRegistered*, rootPublished*: bool
    popup*: HWND

  Win32Select* = ref object
    ## Target state and delivered state are separate: shown is set only after
    ## ShowWindow really ran, and the class/window receipts stay explicit.
    ownerThread: DWORD
    calls: Win32Calls
    theme: NativeTheme
    cookie: uint
    className: seq[WCHAR]
    instance: HINSTANCE
    windows: SelectWindows
    ownerWindow*, wakeWindow*, triggerWindow*: HWND
    context: SelectContext
    provider*: SelectProvider
    popupProvider*: SelectProvider
    props*: SelectProps
    shown*, closed*: bool
    candidate*: int
    firstRow*: int
    rows*: int
    rowHeight*: float64
    scale*: float64
    placement*: SelectPlacement
    prefix: string
    notice*: SelectNotice
    hasNotice*: bool
    tabPending*: int      # 0 none, 1 forward, -1 backward
    needsLayout*: bool
    focusBefore: HWND
    captured: bool
    hiding: bool
      ## Set while this module hides/destroys the window, so the resulting
      ## focus change is not recorded as a user close request.

const
  WmEraseBackground = 0x0014'u32
  WmPaint = 0x000f'u32
  WmNcCalcSize = 0x0083'u32
  WmMouseActivate = 0x0021'u32
  WmLButtonDown = 0x0201'u32
  WmLButtonUp = 0x0202'u32
  WmMouseMove = 0x0200'u32
  WmMouseWheel = 0x020a'u32
  WmKeyDown = 0x0100'u32
  WmChar = 0x0102'u32
  WmKillFocus = 0x0008'u32
  WmActivateApp = 0x001c'u32
  WmSize = 0x0005'u32
  WmDpiChanged = 0x02e0'u32
  WmWindowPosChanged = 0x0047'u32
  WmThemeChanged = 0x031e'u32
  WmNcCreate = 0x0081'u32
  WmNcDestroy = 0x0082'u32
  WmGetDlgCode = 0x0087'u32
  WsPopup = 0x80000000'u32
  WsClipChildren = 0x02000000'u32
  ExToolWindow = 0x00000080'u32
  SwHide = 0
  SwShowNoActivate = 4
  MaNoActivate = 3
  RdwInvalidate = 0x0001'u32
  GwlpUserData = -21'i32
  GwlStyle = -16'i32
  GwlExStyle = -20'i32
  DcBrush = 18'i32
  DcPen = 19'i32
  VkTab = 0x09'i32
  VkReturn = 0x0d'i32
  VkEscape = 0x1b'i32
  VkSpace = 0x20'i32
  VkPrior = 0x21'i32
  VkNext = 0x22'i32
  VkEnd = 0x23'i32
  VkHome = 0x24'i32
  VkUp = 0x26'i32
  VkDown = 0x28'i32
  VkShift = 0x10'i32
  WmGetFont = 0x0031'u32

var selects {.threadvar.}: Table[uint, Win32Select]
var nextSelectCookie {.threadvar.}: uint

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

proc ownerCheck(host: Win32Select) {.raises: [CatchableError].} =
  if host == nil: fail("Win32 select popup is nil")
  if GetCurrentThreadId() != host.ownerThread:
    fail("Win32 select popup must run on its owning UI thread")

proc popupFill(theme: NativeTheme): uint32 {.raises: [].} =
  if theme.isShadcn:
    try: colorRef(theme.palette.surface)
    except CatchableError: 0x00ffffff'u32
  else: 0x00ffffff'u32

proc popupBorder(theme: NativeTheme): uint32 {.raises: [].} =
  if theme.isShadcn:
    try: colorRef(theme.palette.line)
    except CatchableError: 0'u32
  else: 0'u32

proc itemColors(theme: NativeTheme, disabled, selected, candidate: bool):
    tuple[fill, text: uint32] {.raises: [].} =
  if not theme.isShadcn: return (popupFill(theme), 0'u32)
  try:
    if selected or candidate:
      (colorRef(theme.palette.accentSoft), colorRef(theme.palette.ink))
    elif disabled:
      (popupFill(theme), colorRef(theme.palette.muted))
    else:
      (popupFill(theme), colorRef(theme.palette.ink))
  except CatchableError:
    (popupFill(theme), 0'u32)

proc rowStart(host: Win32Select): float64 =
  ## One device row inset so the border never overlaps the first item.
  host.scale

proc rowRect(host: Win32Select, ordinal: int): RECT =
  let top = rowStart(host) + float64(ordinal) * host.rowHeight
  result = RECT(left: int32(round(host.scale)), top: int32(round(top)),
    right: int32(round(host.placement.width * host.scale - host.scale)),
    bottom: int32(round(top + host.rowHeight)))

proc measureRowHeight(host: Win32Select) {.raises: [CatchableError].} =
  ## Text height from the trigger's own native font plus the item insets, so the
  ## popup never invents a second font or a private GDI object.
  let scale = if host.scale > 0.0: host.scale else: 1.0
  var textHeight = 16.0
  let dc = host.calls.getDC(host.triggerWindow)
  if dc != nil:
    let font = cast[HGDIOBJ](host.calls.send(host.triggerWindow, WmGetFont, 0, 0))
    var previous: HGDIOBJ
    if font != nil: previous = host.calls.selectObject(dc, font)
    var metrics: TEXTMETRICW
    if host.calls.textMetrics(dc, addr metrics) != 0:
      textHeight = float64(metrics.tmHeight)
    if font != nil: discard host.calls.selectObject(dc, previous)
    discard host.calls.releaseDC(host.triggerWindow, dc)
  host.rowHeight = max(DefaultSelectItemHeight * scale, textHeight + 14.0 * scale)

{.push stdcall, dynlib: "gdi32.dll", importc, raises: [].}
proc MoveToEx(dc: HDC, x, y: int32, previous: ptr POINT): BOOL
proc LineTo(dc: HDC, x, y: int32): BOOL
{.pop.}

proc paintPopup(host: Win32Select, window: HWND, dc: HDC): bool {.raises: [].} =
  if dc == nil or host == nil: return false
  try:
    var client: RECT
    if host.calls.clientRect(window, addr client) == 0: return false
    let brush = host.calls.getStockObject(DcBrush)
    if brush == nil: return false
    discard host.calls.setDCBrushColor(dc, popupFill(host.theme))
    discard host.calls.fillRect(dc, addr client, cast[HBRUSH](brush))
    let font = cast[HGDIOBJ](host.calls.send(host.triggerWindow, WmGetFont, 0, 0))
    var previousFont: HGDIOBJ
    if font != nil: previousFont = host.calls.selectObject(dc, font)
    # Transparent glyph background: DrawText otherwise fills its own opaque
    # background box, which showed as white blocks over the dark surface.
    discard host.calls.setBkMode(dc, 1) # TRANSPARENT
    let visible = visibleRows(host.firstRow, host.rows, host.props.options.len)
    var ordinal = 0
    for index in visible.first ..< visible.last:
      let option = host.props.options[index]
      var rect = host.rowRect(ordinal)
      inc ordinal
      let selected = host.props.value == option.key
      let colors = itemColors(host.theme, option.disabled, selected,
        host.candidate == index)
      discard host.calls.setDCBrushColor(dc, colors.fill)
      discard host.calls.fillRect(dc, addr rect, cast[HBRUSH](brush))
      var bounds = RECT(left: rect.left + int32(round(12.0 * host.scale)),
        top: rect.top, right: rect.right - int32(round(24.0 * host.scale)),
        bottom: rect.bottom)
      let label = wide(option.label)
      discard host.calls.setTextColor(dc, colors.text)
      discard host.calls.drawText(dc, unsafeAddr label[0], int32(label.len - 1),
        addr bounds, 4'u32 or 0x20 or 0x8000) # vcenter/singleline/ellipsis
      if selected:
        # A real check mark instead of a second text glyph.
        let pen = host.calls.getStockObject(DcPen)
        if pen != nil:
          discard host.calls.selectObject(dc, pen)
          discard host.calls.setDCPenColor(dc, colors.text)
          let mid = (rect.top + rect.bottom) div 2
          let left = rect.left + int32(round(4.0 * host.scale))
          discard MoveToEx(dc, left, mid, nil)
          discard LineTo(dc, left + int32(round(3.0 * host.scale)),
            mid + int32(round(3.0 * host.scale)))
          discard LineTo(dc, left + int32(round(9.0 * host.scale)),
            mid - int32(round(4.0 * host.scale)))
    if host.placement.scrollRange > 0:
      # Slim owned scroll indicator: no extra SCROLLBAR window to own or tear
      # down, and it never covers a candidate row.
      discard host.calls.setDCBrushColor(dc, popupBorder(host.theme))
      let total = host.props.options.len
      let visibleCount = min(host.rows, total)
      if total > 0:
        var thumb = RECT(left: client.right - int32(round(3.0 * host.scale)),
          top: client.top, right: client.right, bottom: client.bottom)
        thumb.top = client.top + int32(round(float64(client.bottom - client.top) *
          float64(host.firstRow) / float64(total)))
        thumb.bottom = thumb.top + int32(round(float64(client.bottom - client.top) *
          float64(visibleCount) / float64(total)))
        discard host.calls.fillRect(dc, addr thumb, cast[HBRUSH](brush))
    if previousFont != nil: discard host.calls.selectObject(dc, previousFont)
    # One device-pixel frame on the four edges.
    discard host.calls.setDCBrushColor(dc, popupBorder(host.theme))
    var edge = RECT(left: client.left, top: client.top, right: client.right,
      bottom: client.top + 1)
    discard host.calls.fillRect(dc, addr edge, cast[HBRUSH](brush))
    edge = RECT(left: client.left, top: client.bottom - 1, right: client.right,
      bottom: client.bottom)
    discard host.calls.fillRect(dc, addr edge, cast[HBRUSH](brush))
    edge = RECT(left: client.left, top: client.top, right: client.left + 1,
      bottom: client.bottom)
    discard host.calls.fillRect(dc, addr edge, cast[HBRUSH](brush))
    edge = RECT(left: client.right - 1, top: client.top, right: client.right,
      bottom: client.bottom)
    discard host.calls.fillRect(dc, addr edge, cast[HBRUSH](brush))
    true
  except CatchableError: false

proc noteNotice(host: Win32Select, kind: SelectNoticeKind, optionKey = "") {.raises: [].} =
  ## Window-procedure path: scalars only. No allocation, no callback, and the
  ## wake post is the same one the owner loop already handles.
  if host == nil or host.closed or kind == snNone: return
  if host.hasNotice: return # one typed request per turn, the first one wins
  host.notice = SelectNotice(kind: kind, optionKey: optionKey,
    stage: host.notice.stage)
  host.hasNotice = true
  if host.wakeWindow != nil:
    discard PostMessageW(host.wakeWindow, 0x0400'u32 + 1'u32, 0, 0)

proc ensureCandidateVisible(host: Win32Select) =
  host.firstRow = scrollToCandidate(host.candidate, host.firstRow, host.rows,
    host.props.options.len)

proc setCandidate(host: Win32Select, index: int) {.raises: [].} =
  if index < 0 or index == host.candidate: return
  host.candidate = index
  host.ensureCandidateVisible()
  if host.windows.popup != nil:
    try:
      discard host.calls.invalidate(host.windows.popup, nil, 0)
      discard host.calls.redrawWindow(host.windows.popup, nil, nil, RdwInvalidate)
    except CatchableError: discard

proc keyDown(host: Win32Select, key: int32) {.raises: [].} =
  ## Every navigation decision comes from the pure contract; this procedure only
  ## maps keys to it and never commits by moving the candidate.
  case key
  of VkDown: host.setCandidate(host.props.stepCandidate(host.candidate, 1))
  of VkUp: host.setCandidate(host.props.stepCandidate(host.candidate, -1))
  of VkHome: host.setCandidate(host.props.edgeCandidate(false))
  of VkEnd: host.setCandidate(host.props.edgeCandidate(true))
  of VkPrior:
    host.setCandidate(host.props.moveCandidate(host.candidate, -pageStep(host.rows)))
  of VkNext:
    host.setCandidate(host.props.moveCandidate(host.candidate, pageStep(host.rows)))
  of VkReturn, VkSpace:
    let value = host.props.candidateValue(host.candidate)
    if value.len != 0: host.noteNotice(snCommit, value)
  of VkEscape: host.noteNotice(snClose)
  of VkTab:
    host.tabPending = if (GetKeyState(VkShift) and 0x8000'i16) != 0: -1 else: 1
    host.noteNotice(snClose)
  else: discard

proc typeahead(host: Win32Select, code: int32) {.raises: [].} =
  if code < 0x20 or code == 0x7f or code > 0xffff: return
  let text = $char(code and 0xff)
  let previous = host.candidate
  var prefix = host.prefix & text
  var candidate = typeaheadCandidate(host.props, prefix, previous)
  if candidate == previous and prefix.len > 1:
    # A further character that matches nothing restarts the search.
    prefix = text
    candidate = typeaheadCandidate(host.props, prefix, previous)
  host.prefix = prefix
  host.setCandidate(candidate)

proc selectProc(window: HWND, message: UINT, wp: WPARAM,
                lp: LPARAM): LRESULT {.stdcall, raises: [].} =
  ## The popup procedure paints, records one typed request and keeps the
  ## geometry; it never calls business code and never allocates a Node.
  try:
    var raw = cast[uint](GetWindowLongPtrW(window, GwlpUserData))
    if message == WmNcCreate:
      let creation = cast[ptr CREATESTRUCTW](lp)
      if creation == nil: return 0
      raw = cast[uint](creation.lpCreateParams)
      if raw == 0: return 0
      discard SetWindowLongPtrW(window, GwlpUserData, cast[int](raw))
      return DefWindowProcW(window, message, wp, lp)
    let cookie = raw shr 1
    if cookie == 0 or not selects.hasKey(cookie):
      return DefWindowProcW(window, message, wp, lp)
    let host = selects[cookie]
    if message == 0x003D and cast[int32](lp) == -25 and host.shown:
      # The popup is its own fragment root; UIA gets the List element here, and
      # only while it is really shown.
      if host.popupProvider != nil:
        let answer = host.popupProvider.objectResult(wp, lp)
        if answer != 0: return answer
    case message
    of WmNcCalcSize:
      if wp != 0: return 0
      var frame = cast[ptr RECT](lp)[]
      let style = DWORD(GetWindowLongW(window, GwlStyle))
      let exStyle = DWORD(GetWindowLongW(window, GwlExStyle))
      let dpi = GetDpiForWindow(window)
      if dpi != 0 and AdjustWindowRectExForDpi(addr frame, style, 0, exStyle, dpi) != 0:
        cast[ptr RECT](lp)[] = frame
        return 0
      return DefWindowProcW(window, message, wp, lp)
    of WmEraseBackground:
      if paintPopup(host, window, cast[HDC](wp)): return 1
      return DefWindowProcW(window, message, wp, lp)
    of WmPaint:
      var paint: PaintStruct
      let dc = BeginPaint(window, addr paint)
      if dc != nil: discard paintPopup(host, window, dc)
      discard EndPaint(window, addr paint)
      return 0
    of WmMouseActivate: return MaNoActivate
    of WmKeyDown:
      host.keyDown(int32(wp))
      return 0
    of WmChar:
      host.typeahead(int32(wp))
      return 0
    of WmGetDlgCode:
      return LRESULT(0x0001'u32 or 0x0080'u32) # DLGC_WANTARROWS|WANTCHARS
    of WmMouseWheel:
      let rawDelta = cast[int16](uint16((wp shr 16) and 0xffff))
      let notches = -float64(rawDelta) / 120.0
      let steps = int(round(notches * 3.0))
      if steps != 0:
        let maxFirst = max(0, host.props.options.len - host.rows)
        host.firstRow = max(0, min(host.firstRow + steps, maxFirst))
        discard host.calls.invalidate(window, nil, 0)
      return 0
    of WmLButtonDown:
      host.captured = true
      discard SetCapture(window)
      return 0
    of WmLButtonUp:
      let x = int32(cast[int16](lp and 0xffff))
      let y = int32(cast[int16]((lp shr 16) and 0xffff))
      if host.captured:
        host.captured = false
        discard ReleaseCapture()
      var client: RECT
      if host.calls.clientRect(window, addr client) == 0: return 0
      if x < client.left or x >= client.right or y < client.top or y >= client.bottom:
        host.noteNotice(snClose)
        return 0
      let ordinal = rowAt(float64(y), rowStart(host), host.rowHeight, host.rows)
      if ordinal < 0: return 0
      let index = host.firstRow + ordinal
      let chosen = host.props.candidateValue(index)
      if chosen.len != 0:
        host.candidate = index
        host.noteNotice(snCommit, chosen)
      return 0
    of WmMouseMove:
      if GetCapture() == window: return 0
      return DefWindowProcW(window, message, wp, lp)
    of WmKillFocus:
      # Closing on focus loss never steals focus back: the owner decides where
      # focus went and the accepted state decides whether the popup stays open.
      # A focus change caused by our own hide is not a user request.
      if not host.hiding and cast[HWND](wp) != window: host.noteNotice(snClose)
      return 0
    of WmActivateApp:
      if wp == 0: host.noteNotice(snClose)
      return 0
    of WmSize, WmDpiChanged, WmWindowPosChanged, WmThemeChanged:
      host.needsLayout = true
      if host.wakeWindow != nil:
        discard PostMessageW(host.wakeWindow, 0x0400'u32 + 1'u32, 0, 0)
      return DefWindowProcW(window, message, wp, lp)
    of WmNcDestroy:
      try:
        discard SetWindowLongPtrW(window, GwlpUserData, 0)
      finally:
        if window == host.windows.popup: host.windows.popup = nil
      return DefWindowProcW(window, message, wp, lp)
    else: discard
    return DefWindowProcW(window, message, wp, lp)
  except CatchableError:
    return 0

proc workArea*(calls: Win32Calls, window: HWND):
    tuple[x, y, width, height: float64, known: bool] {.raises: [CatchableError].} =
  ## Work area of the monitor owning the window, in DIP, with its origin so the
  ## pure placement math can clamp on both axes.
  if window == nil: return (0.0, 0.0, 0.0, 0.0, false)
  var info = SelectMonitorInfo(cbSize: DWORD(sizeof(SelectMonitorInfo)))
  let monitor = calls.monitorFromWindow(window, 2'u32)
  if monitor == nil or calls.getMonitorInfo(monitor, addr info) == 0:
    return (0.0, 0.0, 0.0, 0.0, false)
  if info.rcWork.right <= info.rcWork.left or info.rcWork.bottom <= info.rcWork.top:
    return (0.0, 0.0, 0.0, 0.0, false)
  let dpi = calls.dpi(window)
  if dpi == 0: return (0.0, 0.0, 0.0, 0.0, false)
  let scale = float64(dpi) / 96.0
  (float64(info.rcWork.left) / scale, float64(info.rcWork.top) / scale,
   float64(info.rcWork.right - info.rcWork.left) / scale,
   float64(info.rcWork.bottom - info.rcWork.top) / scale, true)

proc newSelect*(calls: Win32Calls, ownerWindow, wakeWindow, triggerWindow: HWND,
                theme: NativeTheme, props: SelectProps,
                context: SelectContext): Win32Select {.raises: [CatchableError].} =
  ## Pure allocation: no OS resource yet, so the caller keeps this object as the
  ## retry receipt before any native step runs.
  if ownerWindow == nil or triggerWindow == nil:
    fail("select popup requires an owner and a trigger")
  inc nextSelectCookie
  if nextSelectCookie == 0: fail("select popup cookie space exhausted")
  result = Win32Select(ownerThread: GetCurrentThreadId(), calls: calls,
    theme: theme, cookie: nextSelectCookie, ownerWindow: ownerWindow,
    wakeWindow: wakeWindow, triggerWindow: triggerWindow, props: props,
    candidate: props.initialCandidate, context: context)
  result.className = wide("LeafSelectPopup-" & $result.ownerThread & "-" & $result.cookie)
  result.instance = GetModuleHandleW(nil)
  if result.instance == nil: nativeError("GetModuleHandleW")

proc openWindows*(host: Win32Select) {.raises: [CatchableError].} =
  ## Creates the trigger element provider. Idempotent: the trigger element lives
  ## as long as the accepted select root does, independently of the popup.
  host.ownerCheck()
  if host.closed: fail("select popup is closed")
  if host.provider == nil:
    host.provider = newTrigger(host.context, host.triggerWindow)

proc openPopupWindow*(host: Win32Select) {.raises: [CatchableError].} =
  ## Creates the popup window and its List provider. Resumable: every completed
  ## step is recorded immediately, so a retry never creates a second window.
  host.ownerCheck()
  if host.closed: fail("select popup is closed")
  if not host.windows.classRegistered:
    var cls = WNDCLASSEXW(cbSize: UINT(sizeof(WNDCLASSEXW)), style: 3,
      lpfnWndProc: selectProc, hInstance: host.instance, hbrBackground: nil,
      lpszClassName: addr host.className[0])
    if host.calls.registerClass(addr cls) == 0:
      nativeError("RegisterClassExW select popup")
    host.windows.classRegistered = true
  if not host.windows.rootPublished:
    selects[host.cookie] = host
    host.windows.rootPublished = true
  if host.windows.popup == nil:
    let popup = host.calls.createWindow(ExToolWindow, addr host.className[0], nil,
      WsPopup or WsClipChildren, 0, 0, 0, 0, host.ownerWindow, nil,
      host.instance, cast[pointer](host.cookie shl 1))
    if popup == nil: nativeError("CreateWindowExW select popup")
    host.windows.popup = popup
  if host.popupProvider == nil:
    host.popupProvider = newPopup(host.context, host.windows.popup)
    host.provider.link(host.popupProvider)

proc closePopupWindow*(host: Win32Select): ref CatchableError {.raises: [].} =
  ## Retires the popup element and destroys its window while the trigger element
  ## stays live: a closed select owns no popup resource and the trigger still
  ## answers UIA.
  if host == nil: return nil
  var first: ref CatchableError
  if host.popupProvider != nil:
    var popup = host.popupProvider
    host.popupProvider = nil
    try: popup.detach()
    except CatchableError as error: first = error
  if host.windows.popup != nil:
    try:
      let popup = host.windows.popup
      if host.calls.destroyWindow(popup) == 0 and IsWindow(popup) != 0:
        nativeError("DestroyWindow select popup")
      host.windows.popup = nil
    except CatchableError as error:
      if first == nil: first = error
  if host.windows.classRegistered and host.windows.popup == nil:
    try:
      if host.calls.unregisterClass(addr host.className[0], host.instance) == 0:
        nativeError("UnregisterClassW select popup")
      host.windows.classRegistered = false
    except CatchableError as error:
      if first == nil: first = error
  if host.windows.rootPublished and host.windows.popup == nil and
      not host.windows.classRegistered:
    selects.del(host.cookie)
    host.windows.rootPublished = false
  host.shown = false
  first

proc closeWindows*(host: Win32Select): ref CatchableError {.raises: [].} =
  ## Final teardown of one select root: popup window + provider first, then the
  ## trigger element. Idempotent and receipt-preserving.
  if host == nil: return nil
  var first = host.closePopupWindow()
  if host.provider != nil:
    var trigger = host.provider
    host.provider = nil
    try: trigger.detach()
    except CatchableError as error:
      if first == nil: first = error
  first

proc destroyWindows*(host: Win32Select) {.raises: [CatchableError].} =
  host.ownerCheck()
  let failure = host.closeWindows()
  if failure != nil: raise failure
  host.closed = true

proc resourcesReleased*(host: Win32Select): bool =
  host != nil and host.windows.popup == nil and not host.windows.classRegistered and
    host.provider == nil and host.popupProvider == nil

proc applyProps*(host: Win32Select, props: SelectProps, theme: NativeTheme) =
  if host.closed: return
  host.theme = theme
  host.props = props
  if not props.usable(host.candidate):
    host.candidate = props.initialCandidate
  host.ensureCandidateVisible()

proc planPlacement*(host: Win32Select, placement: SelectPlacement) =
  ## Store the pure candidate plan; no OS mutation happens here.
  if host.closed: return
  host.placement = placement
  host.rows = placement.rows
  host.rowHeight = placement.height / float64(max(1, placement.rows))
  host.firstRow = scrollToCandidate(host.candidate, host.firstRow, host.rows,
    host.props.options.len)

proc setScale*(host: Win32Select, scale: float64) {.raises: [CatchableError].} =
  host.scale = if scale > 0.0: scale else: 1.0
  host.measureRowHeight()

proc rowHeightOf*(host: Win32Select): float64 = host.rowHeight

proc showPopup*(host: Win32Select, pixelX, pixelY, pixelWidth, pixelHeight: int32,
                focus: bool) {.raises: [CatchableError].} =
  ## The only OS mutation of the prepared geometry. ShowWindow returns the
  ## previous visibility, so only a failed call is treated as a failure.
  host.ownerCheck()
  if host.windows.popup == nil: host.openPopupWindow()
  if host.windows.popup == nil: fail("select popup is not live")
  if host.calls.windowPos(host.windows.popup, nil, pixelX, pixelY,
      pixelWidth, pixelHeight, 0x0010'u32 or 0x0200'u32) == 0:
    nativeError("SetWindowPos select popup")
  discard host.calls.showWindow(host.windows.popup, SwShowNoActivate)
  host.shown = true
  if focus:
    host.focusBefore = GetFocus()
    discard host.calls.setFocus(host.windows.popup)
  discard host.calls.invalidate(host.windows.popup, nil, 0)
  discard host.calls.redrawWindow(host.windows.popup, nil, nil, RdwInvalidate)

proc hidePopup*(host: Win32Select) {.raises: [CatchableError].} =
  host.ownerCheck()
  if host.windows.popup == nil:
    host.shown = false
    return
  if host.captured:
    host.captured = false
    if GetCapture() == host.windows.popup: discard ReleaseCapture()
  host.hiding = true
  try:
    discard host.calls.showWindow(host.windows.popup, SwHide)
  finally:
    host.hiding = false
  host.shown = false

proc placePopup*(host: Win32Select, pixelX, pixelY, pixelWidth,
    pixelHeight: int32) {.raises: [CatchableError].} =
  ## Reposition only: the popup stays visible and keeps focus. A moved or
  ## scrolled anchor republishes geometry without a show/hide cycle.
  host.ownerCheck()
  if host.windows.popup == nil: fail("select popup is not live")
  if host.calls.windowPos(host.windows.popup, nil, pixelX, pixelY, pixelWidth,
      pixelHeight, 0x0010'u32 or 0x0200'u32) == 0:
    nativeError("SetWindowPos select popup")
  discard host.calls.invalidate(host.windows.popup, nil, 0)
  discard host.calls.redrawWindow(host.windows.popup, nil, nil, RdwInvalidate)

proc isVisible*(host: Win32Select): bool
proc focusInside*(host: Win32Select): bool

proc triggerObjectResult*(host: Win32Select, wp: WPARAM, lp: LPARAM): LRESULT =
  if host == nil or host.provider == nil: 0
  else: host.provider.objectResult(wp, lp)

proc publishState*(host: Win32Select, open, enabled: bool, name, value,
                   listName: string, items: seq[SelectItemState],
                   selectedIndex, firstRow, rows, rowHeightPx: int) =
  ## Publish the accepted semantics for both elements. Staging is a no-op when
  ## nothing changed, so this is safe to call on every ordinary turn.
  if host == nil or host.closed: return
  let focused = host.focusInside()
  let visible = host.isVisible
  if host.provider != nil:
    host.provider.stage(open, enabled, name, value, items, selectedIndex, focused,
      visible, firstRow, rows, rowHeightPx)
    host.provider.accept()
    discard host.provider.publish()
  if host.popupProvider != nil:
    host.popupProvider.stage(open, true, listName, "", items, selectedIndex,
      focused, visible, firstRow, rows, rowHeightPx)
    host.popupProvider.accept()
    discard host.popupProvider.publish()

proc focusCandidate*(host: Win32Select, index: int) =
  ## A legal UIA focus request: -1 focuses the trigger, -2 the popup, otherwise
  ## the candidate becomes the transient keyboard position (never a selection).
  if host == nil or host.closed: return
  if index >= 0:
    host.setCandidate(index)
    if host.windows.popup != nil: discard SetFocus(host.windows.popup)
  elif index == -2:
    if host.windows.popup != nil: discard SetFocus(host.windows.popup)
  else:
    discard SetFocus(host.triggerWindow)

proc setTheme*(host: Win32Select, theme: NativeTheme) =
  ## A window theme change repaints an open popup without touching its state.
  if host == nil or host.closed or host.theme == theme: return
  host.theme = theme
  if host.windows.popup != nil:
    try:
      discard host.calls.invalidate(host.windows.popup, nil, 0)
      discard host.calls.redrawWindow(host.windows.popup, nil, nil, RdwInvalidate)
    except CatchableError: discard

proc reclaimSnapshots*(host: Win32Select) =
  ## Owner-thread reclamation of retired snapshot state for BOTH providers. Runs
  ## in the ordinary turn, so the last reader leaving can be collected without a
  ## new publish; a closed/detached host owns nothing to reclaim.
  if host == nil or host.closed: return
  if host.provider != nil: host.provider.reclaim()
  if host.popupProvider != nil: host.popupProvider.reclaim()

proc isVisible*(host: Win32Select): bool =
  host != nil and host.shown and host.windows.popup != nil and
    host.calls.isWindowVisible(host.windows.popup) != 0

proc popupHandle*(host: Win32Select): HWND =
  if host == nil: nil else: host.windows.popup

proc popupWindowDead*(host: Win32Select): bool =
  ## The owner (a dialog surface) may be destroyed while our receipts still
  ## mention the popup; the caller retires those receipts before retrying.
  host != nil and host.windows.popup != nil and IsWindow(host.windows.popup) == 0

proc takeNotice*(host: Win32Select, notice: var SelectNotice): bool =
  if host == nil or not host.hasNotice: return false
  notice = host.notice
  host.hasNotice = false
  result = true

proc takeTab*(host: Win32Select): int =
  result = host.tabPending
  host.tabPending = 0

proc resetCandidate*(host: Win32Select) =
  if host.closed: return
  host.candidate = host.props.initialCandidate
  host.firstRow = 0
  host.prefix = ""
  host.ensureCandidateVisible()

proc focusInside*(host: Win32Select): bool =
  host != nil and host.windows.popup != nil and GetFocus() == host.windows.popup

proc previousFocus*(host: Win32Select): HWND = host.focusBefore

proc selectedCandidate*(host: Win32Select): int = host.candidate
