## Optional stock-control skin. No input handling, business callbacks or owned
## GDI objects. Native EDIT/BUTTON windows retain their OS semantics.
when not defined(windows): {.error: "Win32 skin requires Windows".}
import std/math
import ../../[native_theme, styles]
import ./api

const
  SkinCtlColorEdit* = 0x0133'u32
  SkinCtlColorStatic = 0x0138'u32
  SkinCtlColorButton = 0x0135'u32
  SkinEraseBackground = 0x0014'u32
  SkinNotify = 0x004e'u32
  PrimaryName = [0x4c'u16, 0x65, 0x61, 0x66, 0x2e, 0x4d, 0x61, 0x74,
    0x73, 0x75, 0x2e, 0x50, 0x72, 0x69, 0x6d, 0x61, 0x72, 0x79, 0]

type
  HighContrast {.importc: "HIGHCONTRASTW", header: "<windows.h>", bycopy.} = object
    cbSize: UINT
    dwFlags: DWORD
    lpszDefaultScheme: WidePtr
  NotifyHeader {.importc: "NMHDR", header: "<commctrl.h>", bycopy.} = object
    hwndFrom: HWND
    idFrom: UINT_PTR
    code: UINT
  PaintStruct {.importc: "PAINTSTRUCT", header: "<windows.h>", bycopy.} = object
    hdc: HDC
    fErase: BOOL
    rcPaint: RECT
    fRestore, fIncUpdate: BOOL
    rgbReserved: array[32, uint8]
  CustomDraw {.importc: "NMCUSTOMDRAW", header: "<commctrl.h>", bycopy.} = object
    hdr: NotifyHeader
    dwDrawStage: DWORD
    hdc: HDC
    rc: RECT
    dwItemSpec: DWORD_PTR
    uItemState: UINT
    lItemlParam: LPARAM

{.push stdcall, dynlib: "user32.dll", importc, raises: [].}
proc GetPropW(window: HWND, name: WidePtr): HANDLE
proc SetPropW(window: HWND, name: WidePtr, value: HANDLE): BOOL
proc FillRect(dc: HDC, rect: ptr RECT, brush: HBRUSH): int32
proc RedrawWindow(window: HWND, update: ptr RECT, region: HRGN, flags: UINT): BOOL
proc BeginPaint(window: HWND, paint: ptr PaintStruct): HDC
proc EndPaint(window: HWND, paint: ptr PaintStruct): BOOL
proc GetWindowDC(window: HWND): HDC
proc ClientToScreen(window: HWND, point: ptr POINT): BOOL
{.pop.}
proc SetWindowTheme(window: HWND, subApp, subId: WidePtr): int32
  {.stdcall, dynlib: "uxtheme.dll", importc, raises: [].}

proc useSystemCheckColors*(window: HWND): int32 {.raises: [].} =
  ## Classic stock check glyph, themed text colors: do not leave dark labels
  ## black on dark backgrounds. High contrast still uses native system colors.
  const empty = [0'u16]
  let status = SetWindowTheme(window, unsafeAddr empty[0], unsafeAddr empty[0])
  if status < 0: return status
  if SetPropW(window, unsafeAddr PrimaryName[0], cast[HANDLE](3)) == 0: return -1
  0

proc checkColorsPrepared*(window: HWND): bool {.raises: [].} =
  cast[uint](GetPropW(window, unsafeAddr PrimaryName[0])) in [3'u, 4'u]

proc setToggleSkin*(window: HWND): BOOL {.raises: [].} =
  SetPropW(window, unsafeAddr PrimaryName[0], cast[HANDLE](4))

proc refreshSkin*(window: HWND): BOOL {.raises: [].} =
  RedrawWindow(window, nil, nil, 1 or 4 or 0x80 or 0x400) # invalidate/erase/all children
{.push stdcall, dynlib: "gdi32.dll", importc, raises: [].}
proc GetStockObject(index: int32): HGDIOBJ
proc SaveDC(dc: HDC): int32
proc RestoreDC(dc: HDC, saved: int32): BOOL
proc SetDCBrushColor(dc: HDC, color: DWORD): DWORD
proc SetDCPenColor(dc: HDC, color: DWORD): DWORD
proc SetTextColor(dc: HDC, color: DWORD): DWORD
proc SetBkColor(dc: HDC, color: DWORD): DWORD
proc SetBkMode(dc: HDC, mode: int32): int32
proc RoundRect(dc: HDC, left,top,right,bottom,width,height: int32): BOOL
proc ExcludeClipRect(dc: HDC, left,top,right,bottom: int32): int32
{.pop.}

proc highContrastActive*(): bool {.raises: [].} =
  var setting = HighContrast(cbSize: UINT(sizeof(HighContrast)))
  # Failure conservatively leaves native system painting in charge.
  SystemParametersInfoW(0x0042, setting.cbSize, addr setting, 0) == 0 or
    (setting.dwFlags and 1) != 0

proc syncCaptionTheme*(theme: NativeTheme, window: HWND) {.raises: [].} =
  ## Optional documented DWM dark caption. Unsupported systems retain their
  ## native frame; never make this decoration a startup/cleanup failure.
  if theme == systemTheme: return
  proc DwmSetWindowAttribute(window: HWND, attr: DWORD, value: pointer,
      size: DWORD): int32 {.stdcall, dynlib: "dwmapi.dll", importc, raises: [].}
  var dark: BOOL = if theme == matsuDark and not highContrastActive(): 1 else: 0
  discard DwmSetWindowAttribute(window, 20, addr dark, DWORD(sizeof(dark)))

proc semanticVariant*(window: HWND): ControlVariant {.raises: [].} =
  let marker = cast[uint](GetPropW(window, unsafeAddr PrimaryName[0]))
  if marker >= 10 and marker <= uint(ord(high(ControlVariant)))+10:
    return ControlVariant(marker-10)
  variantDefault

proc setSemanticVariant*(window: HWND, variant: ControlVariant): BOOL {.raises: [].} =
  SetPropW(window, unsafeAddr PrimaryName[0], cast[HANDLE](ord(variant)+10))

proc primaryButton*(window: HWND): bool {.raises: [].} =
  cast[uint](GetPropW(window, unsafeAddr PrimaryName[0])) == 1

proc setPrimaryButton*(window: HWND, primary: bool): BOOL {.raises: [].} =
  ## Only a borrowed scalar marker, never an object pointer/resource handle.
  ## The OS removes the window property on HWND destruction.
  SetPropW(window, unsafeAddr PrimaryName[0], cast[HANDLE](if primary: 1 else: 2))

proc classIs(window: HWND, name: string): bool {.raises: [].} =
  var buffer: array[64, WCHAR]
  let size = GetClassNameW(window, addr buffer[0], int32(buffer.len))
  if int(size) != name.len: return false
  for i in 0 ..< name.len:
    var a = int(buffer[i])
    var b = ord(name[i])
    if a in 65..90: a += 32
    if b in 65..90: b += 32
    if a != b: return false
  true

proc drawToggle(theme: NativeTheme, draw: ptr CustomDraw): bool =
  let window = draw.hdr.hwndFrom
  if cast[uint](GetPropW(window, unsafeAddr PrimaryName[0])) != 4: return false
  let dc = draw.hdc
  let saved = SaveDC(dc)
  if saved == 0: return false
  defer: discard RestoreDC(dc, saved)
  let brush = GetStockObject(18)
  let pen = GetStockObject(19)
  if brush == nil or pen == nil: return false
  discard SelectObject(dc, brush)
  discard SelectObject(dc, pen)
  let p = palette(theme)
  let scale = float64(GetDpiForWindow(window)) / 96
  let enabled = IsWindowEnabled(window) != 0
  let checked = SendMessageW(window, BM_GETCHECK, 0, 0) == 1
  let track = if not enabled: p.line elif checked: p.accent else: p.controlLine
  discard SetDCBrushColor(dc, colorRef(p.canvas))
  discard FillRect(dc, addr draw.rc, cast[HBRUSH](brush))
  let height = max(2'i32, int32(round(20*scale)))
  let width = int32(round(36*scale))
  let top = draw.rc.top + max(0'i32, (draw.rc.bottom-draw.rc.top-height) div 2)
  discard SetDCBrushColor(dc, colorRef(track))
  discard SetDCPenColor(dc, colorRef(track))
  discard RoundRect(dc, draw.rc.left, top, draw.rc.left+width, top+height, height, height)
  let inset = max(1'i32, int32(round(3*scale)))
  let dot = height-2*inset
  let left = draw.rc.left + (if checked: width-dot-inset else: inset)
  let thumb = if enabled and checked: p.onAccent else: p.surface
  discard SetDCBrushColor(dc, colorRef(thumb))
  discard SetDCPenColor(dc, colorRef(thumb))
  discard RoundRect(dc, left, top+inset, left+dot, top+inset+dot, dot, dot)
  let font = cast[HGDIOBJ](SendMessageW(window, WM_GETFONT, 0, 0))
  if font != nil: discard SelectObject(dc, font)
  discard SetTextColor(dc, colorRef(if enabled: p.ink else: p.muted))
  discard SetBkMode(dc, 1)
  var caption: array[1024, WCHAR]
  var count = GetWindowTextW(window, addr caption[0], int32(caption.len))
  if count > 0 and caption[count-1] in 0xd800'u16..0xdbff'u16: dec count
  var bounds = RECT(left: draw.rc.left+int32(round(48*scale)), top: draw.rc.top,
    right: draw.rc.right, bottom: draw.rc.bottom)
  let uiState = SendMessageW(window, 0x0129, 0, 0)
  var flags = 4'u32 or 0x20 or 0x8000 # vcenter/singleline/ellipsis
  if (uiState and 2) != 0: flags = flags or 0x00100000
  discard DrawTextW(dc, addr caption[0], count, addr bounds, flags)
  if (draw.uItemState and 0x10) != 0 and (uiState and 1) == 0:
    discard SelectObject(dc, GetStockObject(5))
    discard SetDCPenColor(dc, colorRef(p.accent))
    discard RoundRect(dc, draw.rc.left, draw.rc.top, draw.rc.right,
      draw.rc.bottom, 4, 4)
  true

proc drawButton(theme: NativeTheme, draw: ptr CustomDraw): bool =
  if draw.dwDrawStage != 1: return false # CDDS_PREPAINT
  let window = draw.hdr.hwndFrom
  if not classIs(window, "Button"): return false
  if (GetWindowLongW(window, GWL_STYLE) and 0xf) == int32(BS_AUTOCHECKBOX):
    return drawToggle(theme, draw)
  if (GetWindowLongW(window, GWL_STYLE) and 0xf) notin [0'i32, 1'i32]: return false
  let dc = draw.hdc
  let saved = SaveDC(dc)
  if saved == 0: return false
  defer: discard RestoreDC(dc, saved)
  let brush = GetStockObject(18) # DC_BRUSH, borrowed
  let pen = GetStockObject(19) # DC_PEN, borrowed
  if brush == nil or pen == nil: return false
  discard SelectObject(dc, brush)
  discard SelectObject(dc, pen)
  let p = palette(theme)
  let colors = buttonColors(theme, primary=primaryButton(window),
    hot=(draw.uItemState and 0x40) != 0,
    pressed=(draw.uItemState and 1) != 0,
    disabled=IsWindowEnabled(window) == 0)
  discard SetDCBrushColor(dc, colorRef(p.canvas))
  if FillRect(dc, addr draw.rc, cast[HBRUSH](brush)) == 0: return false
  discard SetDCBrushColor(dc, colorRef(colors.fill))
  discard SetDCPenColor(dc, colorRef(colors.border))
  let scale = float64(GetDpiForWindow(window)) / 96.0
  let diameter = max(2'i32, int32(round(2 * NativeButtonRadius * scale)))
  if RoundRect(dc, draw.rc.left, draw.rc.top, draw.rc.right, draw.rc.bottom,
      diameter, diameter) == 0: return false
  let uiState = SendMessageW(window, 0x0129, 0, 0) # WM_QUERYUISTATE
  if (draw.uItemState and 0x10) != 0 and (uiState and 1) == 0:
    let inset = max(2'i32, int32(round(3 * scale)))
    discard SelectObject(dc, GetStockObject(5)) # NULL_BRUSH
    discard SetDCPenColor(dc, colorRef(colors.text))
    discard RoundRect(dc, draw.rc.left+inset, draw.rc.top+inset,
      draw.rc.right-inset, draw.rc.bottom-inset, diameter, diameter)
  let font = cast[HGDIOBJ](SendMessageW(window, WM_GETFONT, 0, 0))
  if font != nil: discard SelectObject(dc, font)
  discard SetBkMode(dc, 1) # TRANSPARENT
  discard SetTextColor(dc, colorRef(colors.text))
  # Bounded display buffer; the full caption remains on the native HWND for
  # accessibility. Avoid splitting a UTF-16 surrogate at the display boundary.
  var caption: array[1024, WCHAR]
  var count = GetWindowTextW(window, addr caption[0], int32(caption.len))
  if count > 0 and caption[count-1] in 0xd800'u16..0xdbff'u16: dec count
  # NMCUSTOMDRAW.rc is the SDK's RECT; api.RECT is a layout-compatible Nim
  # ABI record, not the same C typedef. Copy fields rather than C struct-assign.
  var bounds = RECT(left: draw.rc.left, top: draw.rc.top,
    right: draw.rc.right, bottom: draw.rc.bottom)
  let inset = max(4'i32, int32(round(NativeButtonInset * scale)))
  bounds.left += inset; bounds.right -= inset
  var flags = 1'u32 or 4 or 0x20 or 0x8000 # center/vcenter/singleline/ellipsis
  if (uiState and 2) != 0: flags = flags or 0x00100000 # hide accelerators
  discard DrawTextW(dc, addr caption[0], count, addr bounds, flags)
  true

proc editLineHeight(window: HWND): int32 =
  let dc = GetDC(window)
  if dc == nil: return 0
  defer: discard ReleaseDC(window, dc)
  let saved = SaveDC(dc)
  if saved == 0: return 0
  defer: discard RestoreDC(dc, saved)
  let font = cast[HGDIOBJ](SendMessageW(window, WM_GETFONT, 0, 0))
  if font != nil: discard SelectObject(dc, font)
  var metric: TEXTMETRICW
  if GetTextMetricsW(dc, addr metric) != 0: result = metric.tmHeight

proc drawEditFrame(theme: NativeTheme, window: HWND): bool =
  # Paint only the non-client padding/border. The real EDIT owns its entire
  # client area, caret, selection, horizontal scrolling and IME rendering.
  var outer, client: RECT
  var origin: POINT
  if GetWindowRect(window, addr outer) == 0 or
      GetClientRect(window, addr client) == 0 or
      ClientToScreen(window, addr origin) == 0: return false
  let dc = GetWindowDC(window)
  if dc == nil: return false
  defer: discard ReleaseDC(window, dc)
  let saved = SaveDC(dc)
  if saved == 0: return false
  defer: discard RestoreDC(dc, saved)
  let brush = GetStockObject(18)
  let pen = GetStockObject(19)
  if brush == nil or pen == nil: return false
  let x = origin.x - outer.left
  let y = origin.y - outer.top
  discard ExcludeClipRect(dc, x, y, x+client.right, y+client.bottom)
  discard SelectObject(dc, brush)
  discard SelectObject(dc, pen)
  let p = palette(theme)
  var bounds = RECT(right: outer.right-outer.left, bottom: outer.bottom-outer.top)
  discard SetDCBrushColor(dc, colorRef(p.canvas))
  if FillRect(dc, addr bounds, cast[HBRUSH](brush)) == 0: return false
  discard SetDCBrushColor(dc, colorRef(if IsWindowEnabled(window) == 0: p.panel else: p.surface))
  discard SetDCPenColor(dc, colorRef(if semanticVariant(window) == variantDanger: p.danger
    elif GetFocus() == window: p.accent else: p.controlLine))
  let diameter = max(2'i32, int32(round(10 * float64(GetDpiForWindow(window)) / 96)))
  RoundRect(dc, 0, 0, bounds.right, bounds.bottom, diameter, diameter) != 0

proc drawEditCue(theme: NativeTheme, window: HWND, dc: HDC) =
  # Only the placeholder is recolored. Keep the full hint stored on the real
  # EDIT, and let its native text, focused caret, selection and IME paint alone.
  # Our backend sets EM_SETCUEBANNER with show-when-focused=false.
  if GetFocus() == window or SendMessageW(window, 0x000e, 0, 0) != 0: return
  var cue: array[1024, WCHAR]
  if SendMessageW(window, 0x1502, cast[WPARAM](addr cue[0]), cue.len) == 0: return
  var count = 0
  while count < cue.len-1 and cue[count] != 0: inc count
  if count > 0 and cue[count-1] in 0xd800'u16..0xdbff'u16: dec count
  if count == 0: return
  let saved = SaveDC(dc)
  if saved == 0: return
  defer: discard RestoreDC(dc, saved)
  let brush = GetStockObject(18)
  if brush == nil: return
  var bounds: RECT
  if GetClientRect(window, addr bounds) == 0: return
  let p = palette(theme)
  discard SetDCBrushColor(dc, colorRef(if IsWindowEnabled(window) == 0: p.panel else: p.surface))
  if FillRect(dc, addr bounds, cast[HBRUSH](brush)) == 0: return
  let font = cast[HGDIOBJ](SendMessageW(window, WM_GETFONT, 0, 0))
  if font != nil: discard SelectObject(dc, font)
  discard SetTextColor(dc, colorRef(p.muted))
  discard SetBkMode(dc, 1)
  discard DrawTextW(dc, addr cue[0], int32(count), addr bounds, 4 or 0x20 or 0x800 or 0x8000)

proc editSkinMessage(theme: NativeTheme, window: HWND, message: UINT,
                     wp: WPARAM, lp: LPARAM, reply: var LRESULT): bool =
  case message
  of 0x0083'u32: # WM_NCCALCSIZE; RECT or NCCALCSIZE_PARAMS.rgrc[0] prefix
    if lp == 0: return false
    let bounds = cast[ptr RECT](lp)
    let scale = float64(GetDpiForWindow(window)) / 96
    let height = bounds.bottom - bounds.top
    let width = bounds.right - bounds.left
    let line = editLineHeight(window)
    if line <= 0 or height < line+2 or width < 4: return false
    let vertical = max(1'i32, (height-line) div 2)
    let horizontal = min((width-1) div 2, max(1'i32, int32(round(10*scale))))
    bounds.left += horizontal; bounds.right -= horizontal
    bounds.top += vertical; bounds.bottom -= vertical
    reply = 0
    return true
  of 0x000f'u32, 0x0318'u32: # WM_PAINT / WM_PRINTCLIENT
    reply = DefSubclassProc(window, message, wp, lp)
    if message == 0x0318:
      if wp != 0: drawEditCue(theme, window, cast[HDC](wp))
    else:
      let dc = GetDC(window)
      if dc != nil:
        drawEditCue(theme, window, dc)
        discard ReleaseDC(window, dc)
    return true
  of 0x0085'u32: # WM_NCPAINT
    if drawEditFrame(theme, window):
      reply = 0
      return true
  of WM_SETFONT, 0x02e3'u32, 0x031a'u32, 0x001a'u32: # font/DPI/theme/settings
    reply = DefSubclassProc(window, message, wp, lp)
    let current = GetWindowLongW(window, GWL_STYLE)
    let desired = if highContrastActive(): current or int32(WS_BORDER)
      else: current and not int32(WS_BORDER)
    if current != desired:
      discard SetWindowLongPtrW(window, GWL_STYLE, int(desired))
    # Recompute padding using the actual new font/DPI, never hold an HFONT.
    discard SetWindowPos(window, nil, 0, 0, 0, 0, 0x0037)
    discard RedrawWindow(window, nil, nil, 1 or 4 or 0x400) # include frame
    return true
  of 0x0007'u32, 0x0008'u32, 0x000a'u32: # focus/blur/enabled
    reply = DefSubclassProc(window, message, wp, lp)
    discard RedrawWindow(window, nil, nil, 1 or 4 or 0x400)
    return true
  else: discard
  false

proc drawProgress(theme: NativeTheme, window: HWND, dc: HDC): bool =
  let saved = SaveDC(dc)
  if saved == 0: return false
  defer: discard RestoreDC(dc, saved)
  let brush = GetStockObject(18)
  let pen = GetStockObject(19)
  if brush == nil or pen == nil: return false
  discard SelectObject(dc, brush)
  discard SelectObject(dc, pen)
  var bounds: RECT
  if GetClientRect(window, addr bounds) == 0: return false
  let p = palette(theme)
  discard SetDCBrushColor(dc, colorRef(p.canvas))
  discard FillRect(dc, addr bounds, cast[HBRUSH](brush))
  let height = min(bounds.bottom, max(2'i32,
    int32(round(6 * float64(GetDpiForWindow(window)) / 96))))
  let top = (bounds.bottom-height) div 2
  discard SetDCBrushColor(dc, colorRef(p.line))
  discard SetDCPenColor(dc, colorRef(p.line))
  discard RoundRect(dc, 0, top, bounds.right, top+height, height, height)
  let low = SendMessageW(window, 0x0407, 1, 0) # PBM_GETRANGE lower
  let high = SendMessageW(window, 0x0407, 0, 0)
  let pos = SendMessageW(window, 0x0408, 0, 0) # PBM_GETPOS, native/UIA value
  if high > low and pos > low:
    let width = int32(round(float64(bounds.right) *
      float64(min(high, pos)-low) / float64(high-low)))
    if width > 0:
      let fill = if IsWindowEnabled(window) == 0: p.muted else: p.accent
      discard SetDCBrushColor(dc, colorRef(fill))
      discard SetDCPenColor(dc, colorRef(fill))
      discard RoundRect(dc, 0, top, width, top+height, height, height)
  true

proc skinMessage*(theme: NativeTheme, window: HWND, message: UINT,
                  wp: WPARAM, lp: LPARAM, reply: var LRESULT): bool =
  if theme == systemTheme or message notin [SkinCtlColorEdit, SkinCtlColorStatic,
      SkinCtlColorButton, SkinEraseBackground, SkinNotify, 0x0083'u32,
      0x0085'u32, WM_SETFONT, 0x02e3'u32, 0x031a'u32, 0x001a'u32,
      0x0007'u32, 0x0008'u32, 0x000a'u32, 0x000f'u32, 0x0318'u32]: return false
  # Recalculate non-client geometry even when entering high contrast: the
  # resulting WM_NCCALCSIZE then takes the system path and restores its border.
  let editor = classIs(window, "Edit")
  if editor and message in [WM_SETFONT, 0x02e3'u32, 0x031a'u32, 0x001a'u32] and
      editSkinMessage(theme, window, message, wp, lp, reply): return true
  if not themeEnabled(theme, highContrastActive()): return false
  if editor and editSkinMessage(theme, window, message, wp, lp, reply): return true
  # Leave indeterminate/marquee animation to the real system progress control.
  if message in [0x000f'u32, 0x0318'u32] and classIs(window, "msctls_progress32") and
      (GetWindowLongW(window, GWL_STYLE) and int32(PBS_MARQUEE)) == 0:
    if message == 0x0318 and wp != 0: # WM_PRINTCLIENT
      if drawProgress(theme, window, cast[HDC](wp)):
        reply = 0
        return true
    elif message == 0x000f:
      var paint: PaintStruct
      let dc = BeginPaint(window, addr paint)
      if dc != nil:
        discard drawProgress(theme, window, dc)
        discard EndPaint(window, addr paint)
        reply = 0
        return true
  let p = palette(theme)
  case message
  of SkinCtlColorEdit, SkinCtlColorStatic, SkinCtlColorButton:
    let child = cast[HWND](lp)
    if child == nil or GetParent(child) != window: return false
    let editor = classIs(child, "Edit")
    if not editor and not classIs(child, "Static") and not classIs(child, "Button"):
      return false
    let dc = cast[HDC](wp)
    let brush = GetStockObject(18)
    if dc == nil or brush == nil: return false
    let background = if editor:
        (if IsWindowEnabled(child) == 0: p.panel else: p.surface)
      else: p.canvas
    let ink = if IsWindowEnabled(child) == 0: p.muted
      elif not editor and semanticVariant(child) == variantSecondary: p.muted
      elif not editor and semanticVariant(child) == variantDanger: p.danger
      else: p.ink
    discard SetTextColor(dc, colorRef(ink))
    discard SetBkColor(dc, colorRef(background))
    discard SetBkMode(dc, if editor: 2 else: 1)
    discard SetDCBrushColor(dc, colorRef(background))
    reply = cast[LRESULT](brush)
    return true
  of SkinEraseBackground:
    if not classIs(window, "Static") and GetParent(window) != nil: return false
    let dc = cast[HDC](wp)
    let saved = SaveDC(dc)
    if saved == 0: return false
    defer: discard RestoreDC(dc, saved)
    let brush = GetStockObject(18)
    if brush == nil: return false
    var bounds: RECT
    if GetClientRect(window, addr bounds) == 0: return false
    discard SetDCBrushColor(dc, colorRef(p.canvas))
    if FillRect(dc, addr bounds, cast[HBRUSH](brush)) == 0: return false
    reply = 1
    return true
  of SkinNotify:
    if lp == 0: return false
    let draw = cast[ptr CustomDraw](lp)
    if draw.hdr.code != cast[UINT](-12'i32) or # NM_CUSTOMDRAW
        GetParent(draw.hdr.hwndFrom) != window: return false
    if drawButton(theme, draw):
      reply = 4 # CDRF_SKIPDEFAULT
      return true
  else: discard
  false
