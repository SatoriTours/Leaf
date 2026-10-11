## Owned system-font/GDI/theme measurement. Native acquisition is lazy, after lease.
import std/[math, unicode]
import ../../[core, styles, native_layout]
import ./[api, calls]

type
  PendingDC = object
    window: HWND
    dc: HDC
    old: HGDIOBJ
    selected: bool
  NativeMeasure* = ref object
    calls: Win32Calls
    parent: HWND
    font: HFONT
    dpi: int
    pending: seq[PendingDC]
    themes: seq[HTHEME]
    probes: seq[HWND]

const
  SmCxMenuCheck = 71'i32
  SmCyMenuCheck = 72'i32
  SmCyEdge = 46'i32
  BpCheckBox = 3'i32
  TsTrue = 1'i32
  TmtContentMargins = 3602'i32
  EditStyle = WS_CHILD or WS_BORDER or 0x80'u32 # ES_AUTOHSCROLL, as in backend

proc checkedWide*(text: string): seq[WCHAR] =
  if text.len > MaxStringBytes or validateUtf8(text) != -1 or '\0' in text:
    fail("invalid native UTF8 text or string budget")
  for rune in text.runes:
    let cp = int(rune)
    if cp <= 0xffff: result.add(WCHAR(cp))
    else:
      result.add(WCHAR(0xd800 + ((cp - 0x10000) shr 10)))
      result.add(WCHAR(0xdc00 + ((cp - 0x10000) and 0x3ff)))
  if result.len >= int(high(int32)): fail("native UTF16 length overflow")
  result.add(0)

proc error(operation: string) {.noreturn.} =
  fail(operation & " failed: " & $lastError())

proc hresultError(operation: string, code: int32) {.noreturn.} =
  fail(operation & " failed HRESULT: " & $code)

proc remember(primary: var ref CatchableError, secondary: ref CatchableError) =
  if primary == nil: primary = secondary
  else: primary.msg.add("; native measurement cleanup secondary: " & secondary.msg)

proc cleanResources(m: NativeMeasure) =
  ## Never discard a handle on failed release. Try independent owners even when
  ## another fails; don't release a DC until its original font is restored.
  var primary: ref CatchableError
  for item in m.pending.mitems:
    if item.dc == nil: continue
    try:
      if item.selected:
        let previous = m.calls.selectObject(item.dc, item.old)
        if previous == nil or cast[int](previous) == -1: error("SelectObject restore")
        item.selected = false
      if m.calls.releaseDC(item.window, item.dc) == 0: error("ReleaseDC")
      item.dc = nil
    except CatchableError as e: remember(primary, e)
  var keptDCs: seq[PendingDC]
  for item in m.pending:
    if item.dc != nil: keptDCs.add(item)
  m.pending = keptDCs
  for theme in m.themes.mitems:
    if theme == nil: continue
    try:
      let status = m.calls.closeTheme(theme)
      if status < 0: hresultError("CloseThemeData", status)
      theme = nil
    except CatchableError as e: remember(primary, e)
  var keptThemes: seq[HTHEME]
  for theme in m.themes:
    if theme != nil: keptThemes.add(theme)
  m.themes = keptThemes
  for probe in m.probes.mitems:
    if probe == nil: continue
    try:
      if m.calls.destroyWindow(probe) == 0: error("DestroyWindow measurement control")
      probe = nil
    except CatchableError as e: remember(primary, e)
  var keptProbes: seq[HWND]
  for probe in m.probes:
    if probe != nil: keptProbes.add(probe)
  m.probes = keptProbes
  if primary != nil: raise primary

proc finish(m: NativeMeasure, primary: var ref CatchableError) =
  try: m.cleanResources()
  except CatchableError as e: remember(primary, e)
  if primary != nil: raise primary

proc newNativeMeasure*(parent: HWND, calls: Win32Calls): NativeMeasure =
  let dpi = calls.dpi(parent)
  if dpi == 0: error("GetDpiForWindow")
  NativeMeasure(parent: parent, calls: calls, dpi: int(dpi))

proc ensureFont*(m: NativeMeasure): HFONT =
  if m.font == nil:
    var ncm: NONCLIENTMETRICSW
    ncm.cbSize = UINT(sizeof(ncm))
    if m.calls.systemParameters(SPI_GETNONCLIENTMETRICS, ncm.cbSize,
        addr ncm, 0, UINT(m.dpi)) == 0: error("SystemParametersInfoForDpi")
    m.font = m.calls.createFont(addr ncm.lfMessageFont)
    if m.font == nil: error("CreateFontIndirectW")
  m.font

proc fontDC(m: NativeMeasure): HDC =
  let font = m.ensureFont()
  result = m.calls.getDC(m.parent)
  if result == nil: error("GetDC")
  m.pending.add(PendingDC(window: m.parent, dc: result))
  let old = m.calls.selectObject(result, cast[HGDIOBJ](font))
  if old == nil or cast[int](old) == -1: error("SelectObject")
  m.pending[^1].old = old
  m.pending[^1].selected = true

proc pixelsToDip*(m: NativeMeasure, pixels: float64): float64 =
  pixels * 96.0 / float64(m.dpi)

proc readMetrics(m: NativeMeasure, dc: HDC): TEXTMETRICW =
  if m.calls.textMetrics(dc, addr result) == 0: error("GetTextMetricsW")
  if result.tmHeight <= 0 or result.tmAveCharWidth <= 0 or result.tmExternalLeading < 0:
    fail("invalid native system font metrics")

proc fontMetrics*(m: NativeMeasure): TEXTMETRICW =
  ## Pixel metrics of the same owned DPI-specific message font used by controls.
  m.cleanResources()
  var primary: ref CatchableError
  try: result = m.readMetrics(m.fontDC())
  except CatchableError as e: primary = e
  m.finish(primary)

proc metricPixels(m: NativeMeasure, index: int32): int32 =
  result = m.calls.systemMetric(index, UINT(m.dpi))
  if result <= 0: fail("invalid native system metric " & $index & ": " & $result)

proc systemMetricDip*(m: NativeMeasure, index: int32): float64 =
  m.pixelsToDip(float64(m.metricPixels(index)))

proc textPixels(m: NativeMeasure, dc: HDC, value: seq[WCHAR]): SIZE =
  if m.calls.textExtent(dc, unsafeAddr value[0], int32(value.len - 1), addr result) == 0:
    error("GetTextExtentPoint32W")
  if result.cx < 0 or result.cy < 0: fail("invalid native text extent")

proc measureText*(m: NativeMeasure, text: string, width = 0.0): DipSize =
  let value = checkedWide(text)
  if classify(width) in {fcNan, fcInf, fcNegInf} or width < 0 or width > MaxStyleNumber:
    fail("native text width out of bounds")
  m.cleanResources()
  var primary: ref CatchableError
  try:
    let dc = m.fontDC()
    var extent: SIZE
    if width > 0 and text.len > 0:
      let pixelWidth = max(1.0, round(width * float64(m.dpi) / 96.0))
      if pixelWidth > float64(high(int32)): fail("native text pixel width overflow")
      var rect = RECT(right: int32(pixelWidth))
      if m.calls.drawText(dc, unsafeAddr value[0], int32(value.len - 1), addr rect,
          DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX) == 0: error("DrawTextW measurement")
      extent.cx = rect.right - rect.left
      extent.cy = rect.bottom - rect.top
    else: extent = m.textPixels(dc, value)
    result = DipSize(width: m.pixelsToDip(float64(extent.cx)),
      height: m.pixelsToDip(float64(extent.cy)))
  except CatchableError as e: primary = e
  m.finish(primary)

proc measureButton*(m: NativeMeasure, text: string, enabled = true): DipSize =
  ## Use a hidden stock pushbutton with the actual message font. The v6 common
  ## controls manifest is required by BCM_GETIDEALSIZE; failure is not estimated.
  let title = checkedWide(text)
  m.cleanResources()
  var primary: ref CatchableError
  try:
    let font = m.ensureFont()
    let cls = checkedWide("BUTTON")
    let button = m.calls.createWindow(0, unsafeAddr cls[0], unsafeAddr title[0],
      WS_CHILD or WS_TABSTOP, 0, 0, 0, 0, m.parent, nil, GetModuleHandleW(nil), nil)
    if button == nil: error("CreateWindowExW measurement BUTTON")
    m.probes.add(button) # owner before font/state setup or query can fail
    discard m.calls.send(button, WM_SETFONT, cast[WPARAM](font), 0)
    # EnableWindow returns the previous disabled state, not a success flag.
    discard m.calls.enable(button, BOOL(ord(enabled)))
    var ideal: SIZE # cx=cy=0: ask the system for both unconstrained dimensions
    if m.calls.send(button, BCM_GETIDEALSIZE, 0, cast[LPARAM](addr ideal)) == 0:
      error("BCM_GETIDEALSIZE")
    if ideal.cx < 0 or ideal.cy < 0: fail("invalid native button ideal size")
    result = DipSize(width: m.pixelsToDip(float64(ideal.cx)),
      height: m.pixelsToDip(float64(ideal.cy)))
  except CatchableError as e: primary = e
  m.finish(primary)

proc measureInput*(m: NativeMeasure, value, placeholder: string,
                   window: HWND = nil): DipSize =
  ## window, when supplied, must be a real EDIT with this measurement's font/DPI.
  ## Otherwise use one hidden stock EDIT, never mutate a visible editor to measure.
  let text = checkedWide(value)
  let hint = checkedWide(placeholder)
  m.cleanResources()
  var primary: ref CatchableError
  try:
    let dc = m.fontDC()
    let fm = m.readMetrics(dc)
    let contentWidth = max(20.0 * float64(fm.tmAveCharWidth),
      max(float64(m.textPixels(dc, text).cx), float64(m.textPixels(dc, hint).cx)))
    var edit = window
    if edit == nil:
      let cls = checkedWide("EDIT")
      edit = m.calls.createWindow(0, unsafeAddr cls[0], nil, EditStyle,
        0, 0, 0, 0, m.parent, nil, GetModuleHandleW(nil), nil)
      if edit == nil: error("CreateWindowExW measurement EDIT")
      m.probes.add(edit)
      discard m.calls.send(edit, WM_SETFONT, cast[WPARAM](m.font), 0)
    let margins = cast[uint](m.calls.send(edit, EM_GETMARGINS, 0, 0))
    let horizontalMargins = float64((margins and 0xffff) + ((margins shr 16) and 0xffff))
    var border: RECT
    if m.calls.adjustRect(addr border, EditStyle, 0, 0, UINT(m.dpi)) == 0:
      error("AdjustWindowRectExForDpi EDIT")
    # Theme content margins describe the inner padding. In classic mode reserve
    # the system border units; never use a fixed DIP padding or font-height guess.
    var contentMargins: MARGINS
    let themeClass = checkedWide("EDIT")
    let theme = m.calls.openTheme(m.parent, unsafeAddr themeClass[0], UINT(m.dpi))
    var themedMargins = false
    if theme != nil:
      m.themes.add(theme)
      themedMargins = m.calls.themeMargins(theme, dc, 1, 1, TmtContentMargins,
        nil, addr contentMargins) >= 0
    let leading = if themedMargins:
        float64(max(0'i32, contentMargins.cyTopHeight)) + float64(max(0'i32, contentMargins.cyBottomHeight))
      else: 2.0 * float64(m.metricPixels(SM_CYBORDER))
    result = DipSize(
      width: m.pixelsToDip(contentWidth + horizontalMargins + float64(border.right) - float64(border.left)),
      height: m.pixelsToDip(float64(fm.tmHeight) + float64(fm.tmExternalLeading) + leading +
        float64(border.bottom) - float64(border.top)))
  except CatchableError as e: primary = e
  m.finish(primary)

proc measureCheckbox*(m: NativeMeasure, text: string, checked = false,
                      disabled = false): DipSize =
  let value = checkedWide(text)
  m.cleanResources()
  var primary: ref CatchableError
  try:
    let dc = m.fontDC()
    let fm = m.readMetrics(dc)
    let extent = m.textPixels(dc, value)
    var glyph: SIZE
    var margins: MARGINS
    let cls = checkedWide("BUTTON")
    let theme = m.calls.openTheme(m.parent, unsafeAddr cls[0], UINT(m.dpi))
    if theme != nil:
      m.themes.add(theme) # owner before any fallible query
      let state = if checked: (if disabled: 8'i32 else: 5'i32)
                  else: (if disabled: 4'i32 else: 1'i32)
      if m.calls.themePartSize(theme, dc, BpCheckBox, state, nil, TsTrue, addr glyph) < 0:
        glyph = SIZE() # absent/invalid theme part: use classic system dimensions
      if m.calls.themeMargins(theme, dc, BpCheckBox, state, TmtContentMargins, nil, addr margins) < 0:
        margins = MARGINS()
    if glyph.cx <= 0 or glyph.cy <= 0:
      glyph = SIZE(cx: m.metricPixels(SmCxMenuCheck), cy: m.metricPixels(SmCyMenuCheck))
    # A measured space separates text from the glyph. System border units reserve
    # the stock focus rectangle; theme content margins, if present, also apply.
    let gap = if text.len == 0: 0.0 else: float64(m.textPixels(dc, checkedWide(" ")).cx)
    let horizontal = float64(max(0'i32, margins.cxLeftWidth)) + float64(max(0'i32, margins.cxRightWidth))
    let vertical = float64(max(0'i32, margins.cyTopHeight)) + float64(max(0'i32, margins.cyBottomHeight))
    result = DipSize(
      width: m.pixelsToDip(float64(glyph.cx) + float64(extent.cx) + gap + horizontal +
        2.0 * float64(m.metricPixels(SM_CXBORDER))),
      height: m.pixelsToDip(max(float64(glyph.cy), float64(max(fm.tmHeight, extent.cy))) + vertical +
        2.0 * float64(m.metricPixels(SM_CYBORDER))))
  except CatchableError as e: primary = e
  m.finish(primary)

proc measureProgress*(m: NativeMeasure): DipSize =
  let fm = m.fontMetrics()
  DipSize(width: m.pixelsToDip(20.0 * float64(fm.tmAveCharWidth)),
    height: m.systemMetricDip(SM_CYHSCROLL))

proc measureSeparator*(m: NativeMeasure): DipSize =
  let fm = m.fontMetrics()
  DipSize(width: m.pixelsToDip(20.0 * float64(fm.tmAveCharWidth)),
    height: m.systemMetricDip(SmCyEdge))

proc close*(m: NativeMeasure) =
  if m == nil: return
  var primary: ref CatchableError
  try: m.cleanResources()
  except CatchableError as e: primary = e
  # Pending DCs/probes can still reference the font. Keep it until they are gone.
  if m.font != nil and m.pending.len == 0 and m.probes.len == 0:
    try:
      if m.calls.deleteObject(cast[HGDIOBJ](m.font)) == 0: error("DeleteObject font")
      m.font = nil
    except CatchableError as e: remember(primary, e)
  if primary != nil: raise primary

proc liveFonts*(m: NativeMeasure): int = ord(m.font != nil)
proc liveDCs*(m: NativeMeasure): int = m.pending.len
proc liveThemes*(m: NativeMeasure): int = m.themes.len
proc liveMeasureWindows*(m: NativeMeasure): int = m.probes.len
