## Bare Win32 resource-control probe + message-font + text-extent/theme-query
## chain. No Leaf module is imported: this input isolates the remaining standard
## calls Leaf's measurement performs (measure.nim: GetTextExtentPoint32W and the
## uxtheme part/margins queries on the host window) on top of the frozen
## font sequence, and asks only whether that chain changes the per-stage process
## USER/GDI readings. It is not an ownership proof, does not close the frozen
## `<= baseline + 2` budget and never names a product defect.
##
## One fresh process, N = 3 identical cycles. Per cycle the fixed order is
## before -> setup(read-only PMv2/DPI/size/module) -> register -> create ->
## geometry(client/DPI) -> show -> sysparams -> font_create -> dc_get ->
## font_select -> metrics -> text_extent -> theme_open -> theme_part ->
## theme_margins -> theme_close -> font_restore -> dc_release -> font_delete ->
## destroy -> unregister, with a USER/GDI sample at every stage taken as
## SetLastError(0), GetGuiResources, GetLastError.
## Any API failure stops later cycles, keeps the original error and allows at
## most one own cleanup credential; a failed DestroyWindow is never followed by
## unregistering the class as if the window were gone.
## Ownership is explicit: the HFONT is private, the previously selected object is
## a borrowed stock handle that is never deleted, and the DC is a borrow. Flags
## change only after the real success; no DeleteDC, no stock deletion, no cache
## flush. The four uxtheme entry points are imported dynamically
## (stdcall, dynlib: "uxtheme.dll"), exactly like the product's api.nim block, so
## no uxtheme import library is required; SIZE/MARGINS remain official header
## structures. A failed theme open/query is diagnostic_incomplete; there is no
## fallback that would skip the path under test.
## Exit 0 means status=bare_theme_diagnostic_completed only.
when not defined(windows):
  {.error: "bare Win32 resource probe requires Windows".}
when defined(vcc):
  {.passL: "user32.lib".}
  {.passL: "gdi32.lib".}
else:
  {.passL: "-luser32".}
  {.passL: "-lgdi32".}

type
  HANDLE = pointer
  HWND = pointer
  HINSTANCE = pointer
  HICON = pointer
  HCURSOR = pointer
  HBRUSH = pointer
  HMENU = pointer
  HDC = pointer
  HGDIOBJ = pointer
  HFONT = pointer
  HTHEME = pointer
  ATOM = uint16
  WCHAR = uint16
  LPCWSTR = ptr WCHAR
  BOOL = int32
  UINT = uint32
  DWORD = uint32
  WPARAM = uint
  LPARAM = int
  LRESULT = int
  WNDPROC = proc (hwnd: HWND, message: UINT, wparam: WPARAM,
                  lparam: LPARAM): LRESULT {.stdcall.}

type
  RECT {.importc: "RECT", header: "<windows.h>", bycopy.} = object
    left, top, right, bottom: int32

  LOGFONTW {.importc: "LOGFONTW", header: "<windows.h>", bycopy.} = object
    lfHeight, lfWidth, lfEscapement, lfOrientation, lfWeight: int32
    lfItalic, lfUnderline, lfStrikeOut, lfCharSet: uint8
    lfOutPrecision, lfClipPrecision, lfQuality, lfPitchAndFamily: uint8
    lfFaceName: array[32, WCHAR]

  NONCLIENTMETRICSW {.importc: "NONCLIENTMETRICSW", header: "<windows.h>",
    bycopy.} = object
    cbSize: UINT
    iBorderWidth, iScrollWidth, iScrollHeight: int32
    iCaptionWidth, iCaptionHeight: int32
    lfCaptionFont: LOGFONTW
    iSmCaptionWidth, iSmCaptionHeight: int32
    lfSmCaptionFont: LOGFONTW
    iMenuWidth, iMenuHeight: int32
    lfMenuFont: LOGFONTW
    lfStatusFont: LOGFONTW
    lfMessageFont: LOGFONTW
    iPaddedBorderWidth: int32

  TEXTMETRICW {.importc: "TEXTMETRICW", header: "<windows.h>", bycopy.} = object
    tmHeight, tmAscent, tmDescent: int32
    tmInternalLeading, tmExternalLeading: int32
    tmAveCharWidth, tmMaxCharWidth, tmWeight, tmOverhang: int32
    tmDigitizedAspectX, tmDigitizedAspectY: int32
    tmFirstChar, tmLastChar, tmDefaultChar, tmBreakChar: WCHAR
    tmItalic, tmUnderlined, tmStruckOut, tmPitchAndFamily, tmCharSet: uint8

  SIZE {.importc: "SIZE", header: "<windows.h>", bycopy.} = object
    cx, cy: int32

  MARGINS {.importc: "MARGINS", header: "<uxtheme.h>", bycopy.} = object
    cxLeftWidth, cxRightWidth, cyTopHeight, cyBottomHeight: int32

  WNDCLASSEXW {.importc: "WNDCLASSEXW", header: "<windows.h>", bycopy.} = object
    cbSize: UINT
    style: UINT
    lpfnWndProc: WNDPROC
    cbClsExtra: int32
    cbWndExtra: int32
    hInstance: HINSTANCE
    hIcon: HICON
    hCursor: HCURSOR
    hbrBackground: HBRUSH
    lpszMenuName: LPCWSTR
    lpszClassName: LPCWSTR
    hIconSm: HICON

{.push importc, header: "<windows.h>", stdcall.}
proc GetCurrentProcess(): HANDLE
proc SetLastError(code: DWORD)
proc GetLastError(): DWORD
proc GetGuiResources(process: HANDLE, flags: DWORD): DWORD
proc GetModuleHandleW(name: LPCWSTR): HINSTANCE
proc GetThreadDpiAwarenessContext(): HANDLE
proc AreDpiAwarenessContextsEqual(first, second: HANDLE): BOOL
proc GetAwarenessFromDpiAwarenessContext(context: HANDLE): int32
proc GetDpiForSystem(): UINT
proc AdjustWindowRectExForDpi(rect: ptr RECT, style: DWORD, menu: BOOL,
    exStyle: DWORD, dpi: UINT): BOOL
proc RegisterClassExW(windowClass: ptr WNDCLASSEXW): ATOM
proc UnregisterClassW(name: LPCWSTR, instance: HINSTANCE): BOOL
proc CreateWindowExW(exStyle: DWORD, className, windowName: LPCWSTR,
    style: DWORD, x, y, width, height: int32, parent: HWND, menu: HMENU,
    instance: HINSTANCE, param: pointer): HWND
proc DefWindowProcW(hwnd: HWND, message: UINT, wparam: WPARAM,
    lparam: LPARAM): LRESULT
proc GetClientRect(hwnd: HWND, rect: ptr RECT): BOOL
proc GetDpiForWindow(hwnd: HWND): UINT
proc ShowWindow(hwnd: HWND, command: int32): BOOL
proc DestroyWindow(hwnd: HWND): BOOL
proc GetDC(hwnd: HWND): HDC
proc ReleaseDC(hwnd: HWND, dc: HDC): int32
proc SystemParametersInfoForDpi(action, param: UINT, value: pointer,
    flags, dpi: UINT): BOOL
proc CreateFontIndirectW(font: ptr LOGFONTW): HFONT
proc SelectObject(dc: HDC, obj: HGDIOBJ): HGDIOBJ
proc GetTextMetricsW(dc: HDC, metric: ptr TEXTMETRICW): BOOL
proc DeleteObject(obj: HGDIOBJ): BOOL
proc GetTextExtentPoint32W(dc: HDC, text: LPCWSTR, count: int32,
    size: ptr SIZE): BOOL
{.pop.}
{.push stdcall, dynlib: "uxtheme.dll", importc, raises: [].}
proc OpenThemeDataForDpi(hwnd: HWND, classList: LPCWSTR, dpi: UINT): HTHEME
proc CloseThemeData(theme: HTHEME): int32
proc GetThemePartSize(theme: HTHEME, dc: HDC, part, state: int32,
    rect: ptr RECT, mode: int32, size: ptr SIZE): int32
proc GetThemeMargins(theme: HTHEME, dc: HDC, part, state, prop: int32,
    rect: ptr RECT, margins: ptr MARGINS): int32
{.pop.}

proc bareWndProc(hwnd: HWND, message: UINT, wparam: WPARAM,
                 lparam: LPARAM): LRESULT {.stdcall.} =
  ## No captures, no allocation, no PostQuitMessage.
  DefWindowProcW(hwnd, message, wparam, lparam)

const
  Cycles = 3
  Stages = 21
  StageNames = ["before", "setup", "register", "create", "geometry", "show",
    "sysparams", "font_create", "dc_get", "font_select", "metrics",
    "text_extent", "theme_open", "theme_part", "theme_margins", "theme_close",
    "font_restore", "dc_release", "font_delete", "destroy", "unregister"]
  SpiGetNonClientMetrics = 0x0029'u32
  BpCheckBox = 3'i32
  CbsUncheckedNormal = 1'i32
  ThemeSizeTrue = 1'i32
  TmtContentMargins = 3602'i32
  Style = 0x00CF0000'u32        # WS_OVERLAPPEDWINDOW
  SwShow = 5'i32
  StockWindowBrush = 6          # COLOR_WINDOW + 1: stock brush, no object made

type
  StageRec = object
    taken: bool
    user, gdi, userErr, gdiErr: uint32

  CycleRec = object
    complete: bool
    reason: string
    stages: array[Stages, StageRec]
    pmv2, awareness: int32
    dpi, windowDpi: uint32
    atom: uint32
    frameW, frameH, clientW, clientH: int32
    showPrev, destroyOk, unregisterOk: int32
    ncmCbSize: uint32
    fontCreateOk: int32
    dcGetOk, selectOk, metricsOk, restoreOk: int32
    tmHeight, tmAscent, tmDescent, tmAveCharWidth: int32
    dcRelease: int32
    dcReleaseErr: uint32          # raw DWORD from GetLastError
    fontDelete: int32
    fontDeleteErr: uint32
    textExtentOk, extentX, extentY: int32
    themeOpenOk: int32
    themeHandle: uint64
    partHr, partX, partY: int32
    marginsHr, marginLeft, marginRight, marginTop, marginBottom: int32
    themeCloseHr: int32
    themeOwned: bool
    dcHandle, fontHandle, oldFontHandle, restoreHandle: uint64
    dcBorrowed, fontOwned, fontSelected: bool
    cleanupCloseAttempted: bool
    cleanupCloseHr: int32
    cleanupRestoreAttempted, cleanupReleaseAttempted: bool
    cleanupDeleteAttempted, cleanupDeleteSkipped: bool
    cleanupDestroyAttempted, cleanupUnregisterAttempted: bool
    cleanupRestore, cleanupDestroy, cleanupUnregister: int64
    cleanupRestoreErr, cleanupReleaseErr, cleanupDestroyErr: uint32
    cleanupUnregisterErr, cleanupDeleteErr: uint32
    cleanupRelease, cleanupDelete: int32

var
  cycles: array[Cycles, CycleRec]
  failureLastError: uint32

proc takeStage(cycle: int, r: var CycleRec, stage: int): string =
  ## Safe stage boundary: SetLastError(0) then one count and its error each.
  var rec: StageRec
  SetLastError(0)
  rec.user = GetGuiResources(GetCurrentProcess(), 1)   # GR_USEROBJECTS
  rec.userErr = GetLastError()
  SetLastError(0)
  rec.gdi = GetGuiResources(GetCurrentProcess(), 0)    # GR_GDIOBJECTS
  rec.gdiErr = GetLastError()
  rec.taken = true
  r.stages[stage] = rec
  if rec.user == 0 and rec.userErr != 0:
    return "GetGuiResources(USER) failed err=" & $rec.userErr
  if rec.gdi == 0 and rec.gdiErr != 0:
    return "GetGuiResources(GDI) failed err=" & $rec.gdiErr
  ""

proc fillWide(buffer: var array[32, WCHAR], text: string) =
  for i in 0 ..< text.len:
    if i < buffer.len - 1: buffer[i] = WCHAR(ord(text[i]))
  buffer[text.len] = 0'u16

proc runCycle(cycle: int) =
  var r: CycleRec
  defer: cycles[cycle] = r
  var classOwned = false
  var windowOwned = false
  var window: HWND = nil
  var dc: HDC = nil
  var font: HFONT = nil
  var oldFont: HGDIOBJ = nil
  var theme: HTHEME = nil
  var instance: HINSTANCE = nil
  var name: array[32, WCHAR]
  var title: array[32, WCHAR]
  fillWide(name, "BareResC" & $cycle)
  fillWide(title, "BareRes")
  var extentText: array[32, WCHAR]
  var buttonClass: array[32, WCHAR]
  fillWide(extentText, "chk 0")
  fillWide(buttonClass, "BUTTON")

  template bail(message: string) =
    r.reason = message
    r.complete = false
    # One own cleanup, strict order: restore the borrowed stock object, release
    # the borrowed DC, delete our own font, then window and class. Every attempt
    # records its real return/error; a selection or an outstanding borrow blocks
    # the steps that would depend on them.
    if r.themeOwned and theme != nil:
      r.cleanupCloseAttempted = true
      SetLastError(0)
      r.cleanupCloseHr = int32(CloseThemeData(theme))
      if r.cleanupCloseHr >= 0: r.themeOwned = false
    if r.fontSelected and dc != nil:
      r.cleanupRestoreAttempted = true
      SetLastError(0)
      r.cleanupRestore = int64(cast[uint](SelectObject(dc, oldFont)))
      r.cleanupRestoreErr = GetLastError()
      if cast[HGDIOBJ](r.cleanupRestore) != nil and
          cast[HGDIOBJ](r.cleanupRestore) != cast[HGDIOBJ](-1):
        r.fontSelected = false
    if r.dcBorrowed and window != nil:
      r.cleanupReleaseAttempted = true
      SetLastError(0)
      r.cleanupRelease = int32(ReleaseDC(window, dc))
      r.cleanupReleaseErr = GetLastError()
      if r.cleanupRelease != 0: r.dcBorrowed = false
    if r.fontOwned and font != nil:
      if r.fontSelected or r.dcBorrowed:
        r.cleanupDeleteSkipped = true
      else:
        r.cleanupDeleteAttempted = true
        SetLastError(0)
        r.cleanupDelete = int32(DeleteObject(cast[HGDIOBJ](font)))
        r.cleanupDeleteErr = GetLastError()
        if r.cleanupDelete != 0: r.fontOwned = false
    if windowOwned and window != nil and not r.dcBorrowed and not r.fontSelected:
      r.cleanupDestroyAttempted = true
      SetLastError(0)
      r.cleanupDestroy = int64(int32(DestroyWindow(window)))
      r.cleanupDestroyErr = GetLastError()
      if r.cleanupDestroy != 0: windowOwned = false
    if classOwned and not windowOwned and not r.dcBorrowed and not r.fontSelected:
      r.cleanupUnregisterAttempted = true
      SetLastError(0)
      r.cleanupUnregister = int64(int32(UnregisterClassW(addr name[0], instance)))
      r.cleanupUnregisterErr = GetLastError()
      if r.cleanupUnregister != 0: classOwned = false
    return

  var reason = takeStage(cycle, r, 0)   # before: first cycle precedes any call
  if reason.len != 0: bail(reason)

  let context = GetThreadDpiAwarenessContext()
  if context == nil: bail("GetThreadDpiAwarenessContext returned nil")
  r.pmv2 = int32(AreDpiAwarenessContextsEqual(context, cast[HANDLE](-4)))
  r.awareness = GetAwarenessFromDpiAwarenessContext(context)
  if r.pmv2 != 1:
    bail("thread DPI awareness is not PMv2 (awareness=" & $r.awareness & ")")
  r.dpi = GetDpiForSystem()
  if r.dpi == 0:
    failureLastError = GetLastError()
    bail("GetDpiForSystem failed err=" & $failureLastError)
  var bounds = RECT(
    right: int32(0.5 + 480.0 * float64(r.dpi) / 96.0),
    bottom: int32(0.5 + 320.0 * float64(r.dpi) / 96.0))
  if AdjustWindowRectExForDpi(addr bounds, Style, 0, 0, r.dpi) == 0:
    failureLastError = GetLastError()
    bail("AdjustWindowRectExForDpi failed err=" & $failureLastError)
  r.frameW = bounds.right - bounds.left
  r.frameH = bounds.bottom - bounds.top
  if r.frameW <= 0 or r.frameH <= 0: bail("non-positive frame size")
  instance = GetModuleHandleW(nil)
  if instance == nil:
    failureLastError = GetLastError()
    bail("GetModuleHandleW failed err=" & $failureLastError)
  reason = takeStage(cycle, r, 1)
  if reason.len != 0: bail(reason)

  var cls: WNDCLASSEXW
  cls.cbSize = UINT(sizeof(WNDCLASSEXW))
  cls.style = 3
  cls.lpfnWndProc = bareWndProc
  cls.hInstance = instance
  cls.hbrBackground = cast[HBRUSH](StockWindowBrush)
  cls.lpszClassName = addr name[0]
  r.atom = uint32(RegisterClassExW(addr cls))
  if r.atom == 0:
    failureLastError = GetLastError()
    bail("RegisterClassExW failed err=" & $failureLastError)
  classOwned = true
  reason = takeStage(cycle, r, 2)
  if reason.len != 0: bail(reason)

  window = CreateWindowExW(0, addr name[0], addr title[0], Style, 0, 0,
    r.frameW, r.frameH, nil, nil, instance, nil)
  if window == nil:
    failureLastError = GetLastError()
    bail("CreateWindowExW failed err=" & $failureLastError)
  windowOwned = true
  reason = takeStage(cycle, r, 3)
  if reason.len != 0: bail(reason)

  var client: RECT
  if GetClientRect(window, addr client) == 0:
    failureLastError = GetLastError()
    bail("GetClientRect failed err=" & $failureLastError)
  r.clientW = client.right - client.left
  r.clientH = client.bottom - client.top
  r.windowDpi = GetDpiForWindow(window)
  if r.windowDpi == 0:
    failureLastError = GetLastError()
    bail("GetDpiForWindow failed err=" & $failureLastError)
  reason = takeStage(cycle, r, 4)
  if reason.len != 0: bail(reason)

  r.showPrev = int32(ShowWindow(window, SwShow))  # 0 = previously hidden
  reason = takeStage(cycle, r, 5)
  if reason.len != 0: bail(reason)

  # Single variable: the standard message-font measurement chain Leaf performs.
  var ncm: NONCLIENTMETRICSW
  ncm.cbSize = UINT(sizeof(NONCLIENTMETRICSW))
  r.ncmCbSize = ncm.cbSize
  SetLastError(0)
  let ncmOk = SystemParametersInfoForDpi(SpiGetNonClientMetrics, ncm.cbSize,
    addr ncm, 0, r.dpi)
  let ncmErr = GetLastError()
  reason = takeStage(cycle, r, 6)
  if reason.len != 0: bail(reason)
  if ncmOk == 0:
    failureLastError = ncmErr
    bail("SystemParametersInfoForDpi failed err=" & $ncmErr)

  SetLastError(0)
  font = CreateFontIndirectW(addr ncm.lfMessageFont)
  let fontErr = GetLastError()
  r.fontCreateOk = int32(ord(font != nil))
  r.fontHandle = cast[uint64](font)
  if font != nil: r.fontOwned = true
  reason = takeStage(cycle, r, 7)
  if reason.len != 0: bail(reason)
  if font == nil:
    failureLastError = fontErr
    bail("CreateFontIndirectW failed err=" & $fontErr)

  SetLastError(0)
  dc = GetDC(window)
  let dcGetErr = GetLastError()
  r.dcGetOk = int32(ord(dc != nil))
  r.dcHandle = cast[uint64](dc)
  if dc != nil: r.dcBorrowed = true
  reason = takeStage(cycle, r, 8)
  if reason.len != 0: bail(reason)
  if dc == nil:
    failureLastError = dcGetErr
    bail("GetDC failed err=" & $dcGetErr)

  SetLastError(0)
  oldFont = SelectObject(dc, cast[HGDIOBJ](font))  # borrowed stock object
  let selectErr = GetLastError()
  r.selectOk = int32(ord(oldFont != nil and oldFont != cast[HGDIOBJ](-1)))
  r.oldFontHandle = cast[uint64](oldFont)
  if r.selectOk != 0: r.fontSelected = true
  reason = takeStage(cycle, r, 9)
  if reason.len != 0: bail(reason)
  if r.selectOk == 0:
    failureLastError = selectErr
    bail("SelectObject(font) failed err=" & $selectErr)

  var metrics: TEXTMETRICW
  SetLastError(0)
  let metricsOk = GetTextMetricsW(dc, addr metrics)
  let metricsErr = GetLastError()
  r.metricsOk = int32(metricsOk)
  r.tmHeight = metrics.tmHeight
  r.tmAscent = metrics.tmAscent
  r.tmDescent = metrics.tmDescent
  r.tmAveCharWidth = metrics.tmAveCharWidth
  reason = takeStage(cycle, r, 10)
  if reason.len != 0: bail(reason)
  if metricsOk == 0 or r.tmHeight <= 0:
    failureLastError = metricsErr
    bail("GetTextMetricsW failed err=" & $metricsErr)

  var extent: SIZE
  SetLastError(0)
  let extentOk = GetTextExtentPoint32W(dc, addr extentText[0], 5, addr extent)
  let extentErr = GetLastError()
  r.textExtentOk = int32(extentOk)
  r.extentX = extent.cx
  r.extentY = extent.cy
  reason = takeStage(cycle, r, 11)
  if reason.len != 0: bail(reason)
  if extentOk == 0 or r.extentX <= 0 or r.extentY <= 0:
    failureLastError = extentErr
    bail("GetTextExtentPoint32W failed err=" & $extentErr)

  SetLastError(0)
  theme = OpenThemeDataForDpi(window, addr buttonClass[0], r.dpi)
  let themeErr = GetLastError()
  r.themeOpenOk = int32(ord(theme != nil))
  r.themeHandle = cast[uint64](theme)
  if theme != nil: r.themeOwned = true
  reason = takeStage(cycle, r, 12)
  if reason.len != 0: bail(reason)
  if theme == nil:
    failureLastError = themeErr
    bail("OpenThemeDataForDpi returned nil err=" & $themeErr)

  var part: SIZE
  r.partHr = int32(GetThemePartSize(theme, dc, BpCheckBox,
    CbsUncheckedNormal, nil, ThemeSizeTrue, addr part))
  r.partX = part.cx
  r.partY = part.cy
  reason = takeStage(cycle, r, 13)
  if reason.len != 0: bail(reason)
  if r.partHr < 0 or r.partX <= 0 or r.partY <= 0:
    bail("GetThemePartSize hr=" & $r.partHr)

  var margins: MARGINS
  r.marginsHr = int32(GetThemeMargins(theme, dc, BpCheckBox,
    CbsUncheckedNormal, TmtContentMargins, nil, addr margins))
  r.marginLeft = margins.cxLeftWidth
  r.marginRight = margins.cxRightWidth
  r.marginTop = margins.cyTopHeight
  r.marginBottom = margins.cyBottomHeight
  reason = takeStage(cycle, r, 14)
  if reason.len != 0: bail(reason)
  if r.marginsHr < 0:
    bail("GetThemeMargins hr=" & $r.marginsHr)

  r.themeCloseHr = int32(CloseThemeData(theme))   # HRESULT, not a BOOL
  if r.themeCloseHr >= 0: r.themeOwned = false
  reason = takeStage(cycle, r, 15)
  if reason.len != 0: bail(reason)
  if r.themeCloseHr < 0:
    bail("CloseThemeData hr=" & $r.themeCloseHr)

  SetLastError(0)
  let restored = SelectObject(dc, oldFont)   # restore the borrowed stock font
  let restoreErr = GetLastError()
  r.restoreOk = int32(ord(restored != nil and restored != cast[HGDIOBJ](-1)))
  r.restoreHandle = cast[uint64](restored)
  if r.restoreOk != 0: r.fontSelected = false
  reason = takeStage(cycle, r, 16)
  if reason.len != 0: bail(reason)
  if r.restoreOk == 0:
    failureLastError = restoreErr
    bail("SelectObject(restore) failed err=" & $restoreErr)

  SetLastError(0)
  r.dcRelease = int32(ReleaseDC(window, dc))
  r.dcReleaseErr = GetLastError()          # raw DWORD, no narrowing
  if r.dcRelease != 0: r.dcBorrowed = false
  reason = takeStage(cycle, r, 17)
  if reason.len != 0: bail(reason)
  if r.dcRelease == 0:
    failureLastError = r.dcReleaseErr
    bail("ReleaseDC failed err=" & $r.dcReleaseErr)

  SetLastError(0)
  r.fontDelete = int32(DeleteObject(cast[HGDIOBJ](font)))
  r.fontDeleteErr = GetLastError()
  if r.fontDelete != 0: r.fontOwned = false
  reason = takeStage(cycle, r, 18)
  if reason.len != 0: bail(reason)
  if r.fontDelete == 0:
    failureLastError = r.fontDeleteErr
    bail("DeleteObject(font) failed err=" & $r.fontDeleteErr)

  r.destroyOk = int32(DestroyWindow(window))
  if r.destroyOk == 0:
    failureLastError = GetLastError()
    bail("DestroyWindow failed err=" & $failureLastError)
  windowOwned = false
  reason = takeStage(cycle, r, 19)
  if reason.len != 0: bail(reason)

  r.unregisterOk = int32(UnregisterClassW(addr name[0], instance))
  if r.unregisterOk == 0:
    failureLastError = GetLastError()
    bail("UnregisterClassW failed err=" & $failureLastError)
  classOwned = false
  reason = takeStage(cycle, r, 20)
  if reason.len != 0: bail(reason)
  r.complete = true

proc main(): int =
  static:
    doAssert sizeof(pointer) == 8, "this bare probe is Win64 only"
  var completed = 0
  for cycle in 0 ..< Cycles:
    runCycle(cycle)
    if cycles[cycle].complete: inc completed
    else: break
  echo "probe_win32_bare_theme_resources cycles=", Cycles,
    " wndclassexw_size=", sizeof(WNDCLASSEXW),
    " ncm_size=", sizeof(NONCLIENTMETRICSW), " tm_size=", sizeof(TEXTMETRICW),
    " lf_size=", sizeof(LOGFONTW), " size_size=", sizeof(SIZE),
    " margins_size=", sizeof(MARGINS), " style=0x00CF0000",
    " hbr=6-stock no-cursor/icon/brush"
  for cycle in 0 ..< Cycles:
    let r = cycles[cycle]
    for stage in 0 ..< Stages:
      let s = r.stages[stage]
      if s.taken:
        echo "cycle", cycle, " stage=", StageNames[stage], " taken=true user=",
          s.user, " user_err=", s.userErr, " gdi=", s.gdi, " gdi_err=",
          s.gdiErr
      else:
        echo "cycle", cycle, " stage=", StageNames[stage], " taken=false"
    echo "cycle", cycle, " cred pmv2=", r.pmv2, " awareness=", r.awareness,
      " dpi=", r.dpi, " frame=", r.frameW, "x", r.frameH, " client=",
      r.clientW, "x", r.clientH, " window_dpi=", r.windowDpi, " atom=",
      r.atom, " show_prev=", r.showPrev, " ncm_cb=", r.ncmCbSize,
      " font_ok=", r.fontCreateOk, " font=", r.fontHandle,
      " dc=", r.dcHandle, " dc_get_ok=", r.dcGetOk,
      " old_font=", r.oldFontHandle, " select_ok=", r.selectOk,
      " metrics_ok=", r.metricsOk, " tm_height=", r.tmHeight,
      " tm_ascent=", r.tmAscent, " tm_descent=", r.tmDescent,
      " tm_ave=", r.tmAveCharWidth, " extent_ok=", r.textExtentOk,
      " extent=", r.extentX, "x", r.extentY,
      " theme_ok=", r.themeOpenOk, " theme=", r.themeHandle,
      " part_hr=", r.partHr, " part=", r.partX, "x", r.partY,
      " margins_hr=", r.marginsHr, " margins=", r.marginLeft, "/",
      r.marginRight, "/", r.marginTop, "/", r.marginBottom,
      " theme_close_hr=", r.themeCloseHr, " theme_owned=", r.themeOwned,
      " restore_ok=", r.restoreOk,
      " restore_back=", r.restoreHandle, " dc_release=", r.dcRelease,
      " dc_release_err=", r.dcReleaseErr, " font_delete=", r.fontDelete,
      " font_delete_err=", r.fontDeleteErr, " borrowed_dc=", r.dcBorrowed,
      " font_owned=", r.fontOwned, " font_selected=", r.fontSelected,
      " destroy=", r.destroyOk, " unregister=", r.unregisterOk
    if r.cleanupCloseAttempted or r.cleanupRestoreAttempted or
        r.cleanupReleaseAttempted or
        r.cleanupDeleteAttempted or r.cleanupDeleteSkipped or
        r.cleanupDestroyAttempted or r.cleanupUnregisterAttempted:
      echo "cycle", cycle, " cleanup close_theme=", r.cleanupCloseAttempted,
        " hr=", r.cleanupCloseHr, " restore=", r.cleanupRestoreAttempted,
        " ret=", r.cleanupRestore, " err=", r.cleanupRestoreErr,
        " release=", r.cleanupReleaseAttempted, " ret=", r.cleanupRelease,
        " err=", r.cleanupReleaseErr, " delete=", r.cleanupDeleteAttempted,
        " ret=", r.cleanupDelete, " err=", r.cleanupDeleteErr,
        " delete_skipped=", r.cleanupDeleteSkipped,
        " destroy=", r.cleanupDestroyAttempted, " ret=", r.cleanupDestroy,
        " err=", r.cleanupDestroyErr, " unregister=",
        r.cleanupUnregisterAttempted, " ret=", r.cleanupUnregister,
        " err=", r.cleanupUnregisterErr
    if r.complete:
      let before = r.stages[0]
      for stage in [3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]:
        let s = r.stages[stage]
        echo "cycle", cycle, " delta before->", StageNames[stage], " user=",
          int64(s.user) - int64(before.user), " gdi=",
          int64(s.gdi) - int64(before.gdi)
    else:
      echo "cycle", cycle, " complete=false reason=", r.reason
  if failureLastError != 0:
    echo "last_error_at_failure=", failureLastError
  if completed == Cycles:
    echo "probe_win32_bare_theme_resources status=bare_theme_diagnostic_completed"
    return 0
  echo "probe_win32_bare_theme_resources status=diagnostic_incomplete completed=",
    completed
  3

when isMainModule:
  quit(main())
