## Optional stock-control skin. No input handling, business callbacks or owned
## GDI objects. Native EDIT/BUTTON windows retain their OS semantics.
when not defined(windows): {.error: "Win32 skin requires Windows".}
import std/[math, options]
import ../../ui/[tokens, appearance]
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
proc RemovePropW(window: HWND, name: WidePtr): HANDLE
proc SetPropW(window: HWND, name: WidePtr, value: HANDLE): BOOL
proc FillRect(dc: HDC, rect: ptr RECT, brush: HBRUSH): int32
proc RedrawWindow(window: HWND, update: ptr RECT, region: HRGN, flags: UINT): BOOL
proc BeginPaint(window: HWND, paint: ptr PaintStruct): HDC
proc EndPaint(window: HWND, paint: ptr PaintStruct): BOOL
proc GetWindowDC(window: HWND): HDC
proc ClientToScreen(window: HWND, point: ptr POINT): BOOL
proc ScreenToClient(window: HWND, point: ptr POINT): BOOL
proc GetWindow(window: HWND, command: UINT): HWND
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
proc IntersectClipRect(dc: HDC, left,top,right,bottom: int32): int32
proc MoveToEx(dc: HDC, x,y: int32, previous: ptr POINT): BOOL
proc LineTo(dc: HDC, x,y: int32): BOOL
proc CreatePen(style, width: int32, color: DWORD): HGDIOBJ
proc Arc(dc: HDC, left, top, right, bottom, xr1, yr1, xr2, yr2: int32): BOOL
proc SetArcDirection(dc: HDC, direction: int32): int32
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
  var dark: BOOL = if theme.isDarkTheme and not highContrastActive(): 1 else: 0
  discard DwmSetWindowAttribute(window, 20, addr dark, DWORD(sizeof(dark)))

proc semanticVariant*(window: HWND): ControlVariant {.raises: [].} =
  let marker = cast[uint](GetPropW(window, unsafeAddr PrimaryName[0]))
  if marker >= 10 and marker <= uint(ord(high(ControlVariant)))+10:
    return ControlVariant(marker-10)
  variantDefault

proc setSemanticVariant*(window: HWND, variant: ControlVariant): BOOL {.raises: [].} =
  SetPropW(window, unsafeAddr PrimaryName[0], cast[HANDLE](ord(variant)+10))

proc primaryButton*(window: HWND): bool {.raises: [].} =
  cast[uint](GetPropW(window, unsafeAddr PrimaryName[0])) == 1 or
    semanticVariant(window) == variantPrimary

const SurfaceName = [0x4c'u16, 0x65, 0x61, 0x66, 0x2e, 0x53, 0x75, 0x72, 0x66, 0x61, 0x63, 0x65, 0]

proc setSurfaceVariant*(window: HWND, variant: ControlVariant): BOOL {.raises: [].} =
  SetPropW(window, unsafeAddr SurfaceName[0], cast[HANDLE](
    if variant == variantPrimary: 1 elif variant == variantSecondary: 2 else: 3))

type SetPropProc* = proc(window: HWND, name: WidePtr, data: HANDLE): BOOL
  {.closure, raises: [CatchableError].}

proc markPanelSurface*(window: HWND, setProp: SetPropProc): BOOL
    {.raises: [CatchableError].} =
  ## Mark an owned panel window as the primary surface through the caller's
  ## SetProp entry point, so the failure is a real and reportable native error.
  ## plainSurfaceColor walks up from every child to this mark, so the panel fill
  ## and the body/text backgrounds resolve through one source instead of
  ## surface-vs-canvas drift.
  setProp(window, unsafeAddr SurfaceName[0], cast[HANDLE](1))


func propertyName(name: static[string]): auto =
  var value: array[name.len+1, WCHAR]
  for i, c in name: value[i] = WCHAR(ord(c))
  value
const
  UiRoleName = propertyName("Leaf.Ui.Role")
  UiVariantName = propertyName("Leaf.Ui.Variant")
  UiStateName = propertyName("Leaf.Ui.State")
  UiOpacityName = propertyName("Leaf.Ui.Opacity")
  UiAngleName = propertyName("Leaf.Ui.Angle")

proc standardRole*(window: HWND): Option[UiRole] {.raises: [].} =
  let value = cast[uint](GetPropW(window, unsafeAddr UiRoleName[0]))
  if value > 0 and value <= uint(ord(high(UiRole)))+1:
    return some(UiRole(value-1))

proc inputGroupOf*(window:HWND):HWND {.raises:[].} =
  var current=window
  for depth in 0..64:
    if current==nil:return nil
    if standardRole(current)==some(UiRole.inputGroup):return current
    current=GetParent(current)

proc inputGroupEditor*(group:HWND):HWND {.raises:[].} =
  if group==nil:return nil
  var child=GetWindow(group,5)
  while child!=nil:
    if standardRole(child)==some(UiRole.input):return child
    child=GetWindow(child,2)

proc invalidateInputGroup*(group:HWND):BOOL {.raises:[].} =
  if group==nil:return 1
  if InvalidateRect(group,nil,0)==0:return 0
  # The inset addon HWNDs own a few curved-edge pixels. Invalidate only these
  # local surfaces; the real EDIT keeps its own client/selection paint path.
  var child=GetWindow(group,5)
  while child!=nil:
    if standardRole(child)==some(UiRole.inputGroupAddon) and InvalidateRect(child,nil,0)==0:return 0
    child=GetWindow(child,2)
  1

proc standardVariant(window: HWND): UiVariant {.raises: [].} =
  let value = cast[uint](GetPropW(window, unsafeAddr UiVariantName[0]))
  if value <= uint(ord(high(UiVariant))): return UiVariant(value)
  UiVariant.default

proc standardSize*(window: HWND): UiSize {.raises: [].} =
  let value=cast[uint](GetPropW(window,unsafeAddr UiStateName[0])) shr 2
  if value<=uint(ord(high(UiSize))):return UiSize(value)
  UiSize.normal

proc standardInvalid(window: HWND): bool {.raises: [].} =
  (cast[uint](GetPropW(window, unsafeAddr UiStateName[0])) and 1) != 0

proc setStandardUi*(window: HWND, props: Option[StandardUiProps]): BOOL {.raises: [].} =
  let role = if props.isSome: ord(props.get.role)+1 else: 0
  let variant = if props.isSome: ord(props.get.variant) else: 0
  let flags = if props.isSome: ord(props.get.invalid) or (ord(props.get.loading) shl 1) or (ord(props.get.size) shl 2) else: 0
  if SetPropW(window, unsafeAddr UiRoleName[0], cast[HANDLE](role)) == 0: return 0
  if SetPropW(window, unsafeAddr UiVariantName[0], cast[HANDLE](variant)) == 0: return 0
  if SetPropW(window, unsafeAddr UiStateName[0], cast[HANDLE](flags))==0:return 0
  if props.isSome and props.get.opacityPermille.isSome:
    discard SetPropW(window,unsafeAddr UiOpacityName[0],cast[HANDLE](props.get.opacityPermille.get))
  else:
    discard RemovePropW(window,unsafeAddr UiOpacityName[0])
  if props.isSome and props.get.angleDegrees.isSome:
    discard SetPropW(window,unsafeAddr UiAngleName[0],cast[HANDLE](props.get.angleDegrees.get))
  else:
    discard RemovePropW(window,unsafeAddr UiAngleName[0])
  1

proc footerColor(theme: NativeTheme): uint32 =
  if theme==shadcnLight: return 0xfafafa
  let p=palette(theme)
  let base=p.surface
  rgb24(composite(srgb(1,1,1,0.012),srgb(
    float64((base shr 16) and 255)/255,
    float64((base shr 8) and 255)/255,float64(base and 255)/255)))

proc plainSurfaceColor(theme: NativeTheme, window: HWND): uint32 =
  let p = palette(theme)
  var current = window
  for depth in 0 .. 64:
    if current == nil: break
    if theme.isShadcn and standardRole(current)==some(UiRole.cardFooter): return footerColor(theme)
    if standardRole(current) in [some(UiRole.card),some(UiRole.alert)]: return p.surface
    case cast[uint](GetPropW(current, unsafeAddr SurfaceName[0]))
    of 1: return p.surface
    of 2: return p.panel
    else: discard
    current = GetParent(current)
  p.canvas

proc surfaceColor*(theme: NativeTheme, window: HWND): uint32 =
  ## Exported so an owned surface (the popover panel) paints exactly the color
  ## its children resolve.
  let base=plainSurfaceColor(theme,window)
  if theme==shadcnDark and inputGroupOf(window)!=nil:
    let input=neutralPalette(UiColorMode.dark)[UiColorToken.input]
    return rgb24(composite(srgb(input.r,input.g,input.b,input.a*0.3),
      srgb(float64((base shr 16) and 255)/255,float64((base shr 8) and 255)/255,float64(base and 255)/255)))
  base

proc uiMode(theme: NativeTheme): UiColorMode =
  if theme == shadcnDark: UiColorMode.dark else: UiColorMode.light

proc surfaceRgb(theme: NativeTheme, window: HWND): SrgbColor =
  let rgb = surfaceColor(theme, window)
  srgb(float64((rgb shr 16) and 255)/255,
    float64((rgb shr 8) and 255)/255, float64(rgb and 255)/255)

proc editBackground(theme: NativeTheme, window: HWND): uint32 =
  if standardRole(window).isNone: return palette(theme).surface
  if inputGroupOf(window)!=nil:return surfaceColor(theme,window)
  let surface = surfaceRgb(theme, GetParent(window))
  if theme == shadcnDark:
    let input = neutralPalette(UiColorMode.dark)[UiColorToken.input]
    return rgb24(composite(srgb(input.r,input.g,input.b,input.a*0.3),surface))
  rgb24(surface)

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

proc standardFocusColor*(theme: NativeTheme, window: HWND): uint32 =
  let group=inputGroupOf(window)
  let surface=surfaceRgb(theme,GetParent(if group!=nil:group else:window))
  if standardRole(window) in [some(UiRole.button), some(UiRole.dialogClose),
      some(UiRole.alertDialogCancel), some(UiRole.alertDialogAction),
      some(UiRole.selectTrigger), some(UiRole.popoverTrigger),
      some(UiRole.popoverClose)]:
    return buttonAppearance(uiMode(theme),standardVariant(window),surface).ring
  if standardRole(window) in [some(UiRole.checkbox),some(UiRole.switch),
      some(UiRole.radioGroupItem)]:
    return checkAppearance(uiMode(theme),standardRole(window).get,surface,
      invalid=standardInvalid(window)).ring
  let p=neutralPalette(uiMode(theme))
  let invalid=standardInvalid(window)
  let base=p[if invalid: UiColorToken.destructive else: UiColorToken.ring]
  let alpha=if invalid: (if theme==shadcnDark:0.4 else:0.2) else:0.5
  rgb24(composite(srgb(base.r,base.g,base.b,base.a*alpha),surface))

proc drawStandardButton(theme: NativeTheme, draw: ptr CustomDraw): bool =
  let window = draw.hdr.hwndFrom
  let role = standardRole(window)
  if not theme.isShadcn or role notin [some(UiRole.button),
      some(UiRole.dialogClose), some(UiRole.alertDialogCancel),
      some(UiRole.alertDialogAction), some(UiRole.selectTrigger),
      some(UiRole.popoverTrigger), some(UiRole.popoverClose)]: return false
  let saved = SaveDC(draw.hdc)
  if saved == 0: return false
  defer: discard RestoreDC(draw.hdc, saved)
  let dc = draw.hdc
  let brush = GetStockObject(18)
  let pen = GetStockObject(19)
  if brush == nil or pen == nil: return false
  discard SelectObject(dc,brush)
  discard SelectObject(dc,pen)
  let scale = float64(GetDpiForWindow(window))/96
  # The trigger reuses the outline button surface: the upstream SelectTrigger is
  # a bordered control, not a filled action button.
  let variant = if role in [some(UiRole.selectTrigger), some(UiRole.popoverTrigger)]:
      UiVariant.outline
    else: standardVariant(window)
  let trigger = role in [some(UiRole.selectTrigger), some(UiRole.popoverTrigger)]
  let colors = buttonAppearance(uiMode(theme),variant,
    surfaceRgb(theme,GetParent(window)),hot=(draw.uItemState and 0x41) != 0,
    disabled=IsWindowEnabled(window)==0)
  discard SetDCBrushColor(dc,colorRef(surfaceColor(theme,GetParent(window))))
  discard FillRect(dc,addr draw.rc,cast[HBRUSH](brush))
  let uiState = SendMessageW(window,0x0129,0,0)
  # The shared owned adornment paints outside the face, across parent clips.
  discard SetDCBrushColor(dc,colorRef(colors.fill))
  discard SetDCPenColor(dc,colorRef(colors.border))
  let radius = int32(round(2*UiControlRadius*scale))
  var left=draw.rc.left
  var right=draw.rc.right
  var joinedRight=false
  let parent=GetParent(window)
  if standardRole(parent)==some(UiRole.buttonGroup):
    var own:RECT
    if GetWindowRect(window,addr own)!=0:
      # Native sibling order can differ after a logical move. Compare actual
      # adjacent HWND rectangles, not GroupBox bounds (which may stretch).
      var sibling=GetWindow(parent,5) # GW_CHILD
      while sibling!=nil:
        if sibling!=window and standardRole(sibling)==some(UiRole.button):
          var other:RECT
          if GetWindowRect(sibling,addr other)!=0 and other.top==own.top and other.bottom==own.bottom:
            if other.right==own.left:left=draw.rc.left-radius
            if other.left==own.right:
              right=draw.rc.right+radius
              joinedRight=true
        sibling=GetWindow(sibling,2) # GW_HWNDNEXT
  discard RoundRect(dc,left,draw.rc.top,right,draw.rc.bottom,radius,radius)
  if joinedRight:
    discard MoveToEx(dc,draw.rc.right-1,draw.rc.top,nil)
    discard LineTo(dc,draw.rc.right-1,draw.rc.bottom)
  let font = cast[HGDIOBJ](SendMessageW(window,WM_GETFONT,0,0))
  if font != nil: discard SelectObject(dc,font)
  discard SetBkMode(dc,1)
  discard SetTextColor(dc,colorRef(colors.text))
  var caption: array[1024,WCHAR]
  var count = GetWindowTextW(window,addr caption[0],int32(caption.len))
  if count>0 and caption[count-1] in 0xd800'u16..0xdbff'u16: dec count
  var bounds = RECT(left:draw.rc.left+int32(round((if trigger: 12 else: 4)*scale)),
    top:draw.rc.top,right:draw.rc.right-int32(round((if trigger: 30 else: 4)*scale)),
    bottom:draw.rc.bottom)
  # DT_LEFT is 0: only the trigger drops the centered bit, so its accepted
  # value reads as a form field instead of a centered action button.
  var flags = (if trigger: 0'u32 else: 1'u32) or 4 or 0x20 or 0x8000
  if (uiState and 2)!=0: flags = flags or 0x00100000
  discard DrawTextW(dc,addr caption[0],count,addr bounds,flags)
  if trigger:
    # Chevron on the trailing edge, drawn with the same DC colours.
    discard SetDCPenColor(dc,colorRef(colors.text))
    let midX = draw.rc.right-int32(round(14*scale))
    let midY = (draw.rc.top+draw.rc.bottom) div 2
    let half = int32(round(4*scale))
    discard MoveToEx(dc,midX-half,midY-int32(round(1.5*scale)),nil)
    discard LineTo(dc,midX,midY+int32(round(2.5*scale)))
    discard LineTo(dc,midX+half,midY-int32(round(1.5*scale)))
  if standardVariant(window)==UiVariant.link and (draw.uItemState and 0x40)!=0:
    # Link is a button visual variant, not an HTML anchor/navigation contract.
    discard SetDCPenColor(dc,colorRef(colors.text))
    let y = draw.rc.bottom-int32(round(8*scale))
    discard MoveToEx(dc,bounds.left,y,nil)
    discard LineTo(dc,bounds.right,y)
  true

proc drawStandardCheck(theme: NativeTheme, draw: ptr CustomDraw): bool =
  let window=draw.hdr.hwndFrom
  let role=standardRole(window)
  if not theme.isShadcn or role.isNone or
      role.get notin {UiRole.checkbox,UiRole.switch,UiRole.radioGroupItem}:
    return false
  let dc=draw.hdc
  let saved=SaveDC(dc)
  if saved==0:return false
  defer:discard RestoreDC(dc,saved)
  let brush=GetStockObject(18)
  let pen=GetStockObject(19)
  if brush==nil or pen==nil:return false
  discard SelectObject(dc,brush)
  discard SelectObject(dc,pen)
  let scale=float64(GetDpiForWindow(window))/96
  let glyph=checkMetrics(role.get,standardSize(window))
  let checked=SendMessageW(window,BM_GETCHECK,0,0)==1
  let colors=checkAppearance(uiMode(theme),role.get,surfaceRgb(theme,GetParent(window)),
    checked=checked,disabled=IsWindowEnabled(window)==0,invalid=standardInvalid(window))
  discard SetDCBrushColor(dc,colorRef(surfaceColor(theme,GetParent(window))))
  discard FillRect(dc,addr draw.rc,cast[HBRUSH](brush))
  let width=max(1'i32,int32(round(glyph.width*scale)))
  let height=max(1'i32,int32(round(glyph.height*scale)))
  let left=draw.rc.left
  let top=draw.rc.top+max(0'i32,(draw.rc.bottom-draw.rc.top-height) div 2)
  let uiState=SendMessageW(window,0x0129,0,0)
  var border=colors.border
  if GetFocus()==window and IsWindowEnabled(window)!=0 and (uiState and 1)==0 and
      not standardInvalid(window):
    border=rgb24(neutralPalette(uiMode(theme))[UiColorToken.ring])
  discard SetDCBrushColor(dc,colorRef(colors.fill))
  discard SetDCPenColor(dc,colorRef(border))
  let diameter=int32(round(2*glyph.radius*scale))
  discard RoundRect(dc,left,top,left+width,top+height,diameter,diameter)
  if role.get==UiRole.radioGroupItem:
    # Neutral radio: a real circle ring with an inner mark, never the tick.
    if checked:
      let dot=max(2'i32,int32(round(6*scale)))
      let x=left+(width-dot) div 2
      let y=top+(height-dot) div 2
      discard SetDCBrushColor(dc,colorRef(colors.mark))
      discard SetDCPenColor(dc,colorRef(colors.mark))
      discard RoundRect(dc,x,y,x+dot,y+dot,dot,dot)
  elif role.get==UiRole.switch:
    let dot=max(1'i32,int32(round(glyph.thumb*scale)))
    let inset=max(1'i32,int32(round(scale)))
    let x=left+(if checked:width-dot-inset else:inset)
    let y=top+(height-dot) div 2
    discard SetDCBrushColor(dc,colorRef(colors.mark))
    discard SetDCPenColor(dc,colorRef(colors.mark))
    discard RoundRect(dc,x,y,x+dot,y+dot,dot,dot)
  elif checked:
    # Local check stroke, no icon asset, allocation or replacement HWND.
    discard SetDCPenColor(dc,colorRef(colors.mark))
    for offset in 0..<max(1,int(round(2*scale))):
      discard MoveToEx(dc,left+int32(round(3*scale)),top+int32(round(8*scale))+int32(offset),nil)
      discard LineTo(dc,left+int32(round(6*scale)),top+int32(round(11*scale))+int32(offset))
      discard LineTo(dc,left+int32(round(12*scale)),top+int32(round(5*scale))+int32(offset))
  let font=cast[HGDIOBJ](SendMessageW(window,WM_GETFONT,0,0))
  if font!=nil:discard SelectObject(dc,font)
  discard SetBkMode(dc,1)
  discard SetTextColor(dc,colorRef(colors.text))
  var caption:array[1024,WCHAR]
  var count=GetWindowTextW(window,addr caption[0],int32(caption.len))
  if count>0 and caption[count-1] in 0xd800'u16..0xdbff'u16:dec count
  var bounds=RECT(left:left+width+int32(round(8*scale)),top:draw.rc.top,
    right:draw.rc.right,bottom:draw.rc.bottom)
  # Literal labels, not application-defined accelerators. Full caption stays
  # on the stock BUTTON for its native accessible name and TogglePattern.
  discard DrawTextW(dc,addr caption[0],count,addr bounds,4 or 0x20 or 0x800 or 0x8000)
  true

proc alertOwner(window: HWND): HWND =
  var current = GetParent(window)
  for depth in 0..64:
    if current == nil: break
    if standardRole(current) == some(UiRole.alert): return current
    current = GetParent(current)

proc alertInk(theme: NativeTheme, window: HWND): uint32 =
  let p = palette(theme)
  let parent = alertOwner(window)
  if parent != nil and standardVariant(parent) == UiVariant.destructive:
    if standardRole(window) == some(UiRole.alertDescription):
      let color = neutralPalette(uiMode(theme))[UiColorToken.destructive]
      return rgb24(composite(srgb(color.r,color.g,color.b,0.9),surfaceRgb(theme,parent)))
    return p.danger
  if standardRole(window) == some(UiRole.alertDescription): p.muted else: p.ink

proc drawStandardAlert(theme: NativeTheme, window: HWND, dc: HDC): bool =
  let saved = SaveDC(dc)
  if saved == 0: return false
  defer: discard RestoreDC(dc,saved)
  let brush=GetStockObject(18);let pen=GetStockObject(19)
  if brush==nil or pen==nil:return false
  var bounds:RECT
  if GetClientRect(window,addr bounds)==0:return false
  discard SelectObject(dc,brush);discard SelectObject(dc,pen)
  discard SetDCBrushColor(dc,colorRef(surfaceColor(theme,GetParent(window))))
  discard FillRect(dc,addr bounds,cast[HBRUSH](brush))
  let p=palette(theme)
  discard SetDCBrushColor(dc,colorRef(p.surface));discard SetDCPenColor(dc,colorRef(p.line))
  let diameter=int32(round(16*float64(GetDpiForWindow(window))/96))
  discard RoundRect(dc,0,0,bounds.right,bounds.bottom,diameter,diameter)
  true

proc drawStandardCard(theme: NativeTheme, window: HWND): bool =
  if not theme.isShadcn or standardRole(window)!=some(UiRole.card): return false
  var paint: PaintStruct
  let dc = BeginPaint(window,addr paint)
  if dc == nil: return false
  defer: discard EndPaint(window,addr paint)
  let saved = SaveDC(dc)
  if saved == 0: return false
  defer: discard RestoreDC(dc,saved)
  let brush = GetStockObject(18)
  let pen = GetStockObject(19)
  if brush == nil or pen == nil: return false
  discard SelectObject(dc,brush)
  discard SelectObject(dc,pen)
  var rect: RECT
  if GetClientRect(window,addr rect)==0: return false
  discard SetDCBrushColor(dc,colorRef(surfaceColor(theme,GetParent(window))))
  discard FillRect(dc,addr rect,cast[HBRUSH](brush))
  let p = palette(theme)
  discard SetDCBrushColor(dc,colorRef(p.surface))
  discard SetDCPenColor(dc,colorRef(p.line))
  let diameter = int32(round(28*float64(GetDpiForWindow(window))/96))
  discard RoundRect(dc,0,0,rect.right,rect.bottom,diameter,diameter)
  # Paint a full-bleed footer on the Card itself. Its real child controls stay
  # safely inset from the rounded outline; no new HWND/region/GDI owner needed.
  var child=GetWindow(window,5) # GW_CHILD
  for index in 0..<1024:
    if child==nil: break
    if standardRole(child)==some(UiRole.cardFooter):
      var bounds:RECT
      if GetWindowRect(child,addr bounds)!=0:
        var point=POINT(x:bounds.left,y:bounds.top)
        if ScreenToClient(window,addr point)!=0:
          let top=max(1'i32,point.y-int32(round(16*float64(GetDpiForWindow(window))/96)))
          discard IntersectClipRect(dc,0,top,rect.right,rect.bottom)
          discard SetDCBrushColor(dc,colorRef(footerColor(theme)))
          discard RoundRect(dc,0,0,rect.right,rect.bottom,diameter,diameter)
          discard MoveToEx(dc,1,top,nil)
          discard LineTo(dc,rect.right-1,top)
      break
    child=GetWindow(child,2) # GW_HWNDNEXT
  true

proc drawButton(theme: NativeTheme, draw: ptr CustomDraw): bool =
  if draw.dwDrawStage != 1: return false # CDDS_PREPAINT
  if drawStandardButton(theme, draw): return true
  if drawStandardCheck(theme, draw): return true
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
  var colors = buttonColors(theme, primary=primaryButton(window),
    hot=(draw.uItemState and 0x40) != 0,
    pressed=(draw.uItemState and 1) != 0,
    disabled=IsWindowEnabled(window) == 0)
  if semanticVariant(window) == variantGhost:
    let fill = if (draw.uItemState and 0x41) != 0: p.accentSoft
      else: surfaceColor(theme, GetParent(window))
    colors = NativeButtonColors(fill: fill, border: fill,
      text: (if IsWindowEnabled(window) == 0: p.muted else: p.ink))
  discard SetDCBrushColor(dc, colorRef(surfaceColor(theme, GetParent(window))))
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
  var flags = 4'u32 or 0x20 or 0x8000 # vcenter/singleline/ellipsis
  if semanticVariant(window) != variantGhost: flags = flags or 1 # center
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

proc drawInputGroupSurface(theme:NativeTheme,window:HWND,dc:HDC):bool =
  let group=inputGroupOf(window)
  if group==nil:return false
  var whole,own:RECT
  if GetWindowRect(group,addr whole)==0 or GetWindowRect(window,addr own)==0:return false
  let saved=SaveDC(dc)
  if saved==0:return false
  defer:discard RestoreDC(dc,saved)
  let brush=GetStockObject(18);let pen=GetStockObject(19)
  if brush==nil or pen==nil:return false
  discard SelectObject(dc,brush);discard SelectObject(dc,pen)
  var bounds=RECT(right:own.right-own.left,bottom:own.bottom-own.top)
  discard SetDCBrushColor(dc,colorRef(surfaceColor(theme,GetParent(group))))
  discard FillRect(dc,addr bounds,cast[HBRUSH](brush))
  let fill=surfaceColor(theme,group)
  let base=srgb(float64((fill shr 16) and 255)/255,float64((fill shr 8) and 255)/255,float64(fill and 255)/255)
  let palette=neutralPalette(uiMode(theme))
  let editor=inputGroupEditor(group)
  let border=if standardInvalid(editor):rgb24(palette[UiColorToken.destructive])
    elif GetFocus()==editor:rgb24(palette[UiColorToken.ring])
    else:rgb24(composite(palette[UiColorToken.input],base))
  discard SetDCBrushColor(dc,colorRef(fill));discard SetDCPenColor(dc,colorRef(border))
  let diameter=int32(round(12.0*float64(GetDpiForWindow(group))/96))
  RoundRect(dc,whole.left-own.left,whole.top-own.top,whole.right-own.left,whole.bottom-own.top,diameter,diameter)!=0

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
  if inputGroupOf(window)!=nil:return drawInputGroupSurface(theme,window,dc)
  discard SelectObject(dc, brush)
  discard SelectObject(dc, pen)
  let p = palette(theme)
  var bounds = RECT(right: outer.right-outer.left, bottom: outer.bottom-outer.top)
  discard SetDCBrushColor(dc, colorRef(surfaceColor(theme, GetParent(window))))
  if FillRect(dc, addr bounds, cast[HBRUSH](brush)) == 0: return false
  discard SetDCBrushColor(dc, colorRef(if standardRole(window).isSome: editBackground(theme,window)
    elif IsWindowEnabled(window) == 0: p.panel else: p.surface))
  let standard = standardRole(window).isSome
  let standardBorder = if standard:
      (if standardInvalid(window): p.danger
       elif GetFocus()==window: rgb24(neutralPalette(uiMode(theme))[UiColorToken.ring])
       else:
         let rgb=editBackground(theme,window)
         let base=srgb(float64((rgb shr 16) and 255)/255,float64((rgb shr 8) and 255)/255,float64(rgb and 255)/255)
         rgb24(composite(neutralPalette(uiMode(theme))[UiColorToken.input],base)))
    else: 0'u32
  discard SetDCPenColor(dc, colorRef(if standard: standardBorder
    elif semanticVariant(window) == variantDanger: p.danger
    elif GetFocus() == window: p.accent
    elif semanticVariant(window) in {variantPrimary, variantGhost}: p.surface
    else: p.controlLine))
  let diameter = max(2'i32, int32(round((if standard: 12.0 else: 10.0) * float64(GetDpiForWindow(window)) / 96)))
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
  discard SetDCBrushColor(dc, colorRef(if standardRole(window).isSome: editBackground(theme,window)
    elif IsWindowEnabled(window) == 0: p.panel else: p.surface))
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
    let multiline = (GetWindowLongW(window, GWL_STYLE) and 4) != 0
    if multiline:
      discard DefSubclassProc(window, message, wp, lp)
    let vertical = if multiline: max(1'i32, int32(round((if standardRole(window)==some(UiRole.textarea): 8.0 else: 12.0)*scale)))
      else: max(1'i32, (height-line) div 2)
    let horizontal = min((width-1) div 2, max(1'i32, int32(round((if standardRole(window).isSome: 12.0 else: 10.0)*scale))))
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
    let group=inputGroupOf(window)
    if group!=nil:discard invalidateInputGroup(group)
    return true
  else: discard
  false

proc drawStandardProgress(theme: NativeTheme, window: HWND, dc: HDC): bool =
  if not theme.isShadcn or standardRole(window)!=some(UiRole.progress):return false
  let saved=SaveDC(dc)
  if saved==0:return false
  defer:discard RestoreDC(dc,saved)
  let brush=GetStockObject(18);let pen=GetStockObject(19)
  if brush==nil or pen==nil:return false
  discard SelectObject(dc,brush);discard SelectObject(dc,pen)
  var r:RECT
  if GetClientRect(window,addr r)==0:return false
  let surface=surfaceRgb(theme,GetParent(window))
  let primary=neutralPalette(uiMode(theme))[UiColorToken.primary]
  let track=composite(srgb(primary.r,primary.g,primary.b,0.2),surface)
  discard SetDCBrushColor(dc,colorRef(rgb24(surface)))
  discard FillRect(dc,addr r,cast[HBRUSH](brush))
  discard SetDCBrushColor(dc,colorRef(rgb24(track)))
  discard SetDCPenColor(dc,colorRef(rgb24(track)))
  discard RoundRect(dc,0,0,r.right,r.bottom,r.bottom,r.bottom)
  let pos=SendMessageW(window,0x0408,0,0)
  let width=int32(round(float64(r.right)*float64(max(0,min(100,pos)))/100))
  if width>0:
    # Clip the filled full capsule at its current percent, preserving a flat
    # moving edge and the outer rounded track, as the upstream overflow clip.
    discard IntersectClipRect(dc,0,0,width,r.bottom)
    discard SetDCBrushColor(dc,colorRef(rgb24(primary)))
    discard SetDCPenColor(dc,colorRef(rgb24(primary)))
    discard RoundRect(dc,0,0,r.right,r.bottom,r.bottom,r.bottom)
  true

proc drawProgress(theme: NativeTheme, window: HWND, dc: HDC): bool =
  if drawStandardProgress(theme,window,dc):return true
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

proc drawStandardDisplay(theme: NativeTheme, window: HWND, dc: HDC): bool =
  let role=standardRole(window)
  if not theme.isShadcn or role notin [some(UiRole.badge),some(UiRole.kbd),some(UiRole.skeleton),some(UiRole.separator),some(UiRole.spinner)]:return false
  let saved=SaveDC(dc)
  if saved==0:return false
  defer:discard RestoreDC(dc,saved)
  var bounds:RECT
  if GetClientRect(window,addr bounds)==0:return false
  let brush=GetStockObject(18)
  let pen=GetStockObject(19)
  if brush==nil or pen==nil:return false
  discard SelectObject(dc,brush);discard SelectObject(dc,pen)
  let surface=surfaceRgb(theme,GetParent(window))
  if role==some(UiRole.separator):
    let color=rgb24(composite(neutralPalette(uiMode(theme))[UiColorToken.border],surface))
    discard SetDCBrushColor(dc,colorRef(color))
    return FillRect(dc,addr bounds,cast[HBRUSH](brush))!=0
  if role==some(UiRole.skeleton):
    let opacity=float64(cast[uint](GetPropW(window,unsafeAddr UiOpacityName[0])))/1000
    let accent=neutralPalette(uiMode(theme))[UiColorToken.accent]
    let fill=rgb24(composite(srgb(accent.r,accent.g,accent.b,opacity),surface))
    discard SetDCBrushColor(dc,colorRef(rgb24(surface)))
    discard FillRect(dc,addr bounds,cast[HBRUSH](brush))
    discard SetDCBrushColor(dc,colorRef(fill));discard SetDCPenColor(dc,colorRef(fill))
    let diameter=int32(round(16.0*float64(GetDpiForWindow(window))/96))
    discard RoundRect(dc,0,0,bounds.right,bounds.bottom,diameter,diameter)
    return true
  if role==some(UiRole.spinner):
    discard SetDCBrushColor(dc,colorRef(rgb24(surface)))
    discard FillRect(dc,addr bounds,cast[HBRUSH](brush))
    let angleVal = cast[uint](GetPropW(window,unsafeAddr UiAngleName[0]))
    let angle = float64(angleVal)
    let scale = float64(GetDpiForWindow(window)) / 96.0
    let cx = (bounds.left + bounds.right) div 2
    let cy = (bounds.top + bounds.bottom) div 2
    let r = max(2'i32, int32(round(6.0 * scale)))
    let penWidth = max(1'i32, int32(round(1.5 * scale)))
    let strokeColor = rgb24(composite(neutralPalette(uiMode(theme))[UiColorToken.foreground], surface))
    let hPen = CreatePen(0, penWidth, colorRef(strokeColor))
    if hPen != nil:
      let oldPen = SelectObject(dc, hPen)
      let startAngle = angle * PI / 180.0
      let endAngle = (angle + 270.0) * PI / 180.0
      let x1 = cx + int32(round(100.0 * cos(startAngle)))
      let y1 = cy + int32(round(100.0 * sin(startAngle)))
      let x2 = cx + int32(round(100.0 * cos(endAngle)))
      let y2 = cy + int32(round(100.0 * sin(endAngle)))
      discard SetArcDirection(dc, 2) # clockwise in screen coordinates: 270, not 90 degrees
      discard Arc(dc, cx - r, cy - r, cx + r + 1, cy + r + 1, x1, y1, x2, y2)
      discard SelectObject(dc, oldPen)
      discard DeleteObject(hPen)
    return true
  let keyboard=role==some(UiRole.kbd)
  let palette=neutralPalette(uiMode(theme))
  let colors=if keyboard:UiPaintColors(fill:rgb24(palette[UiColorToken.muted]),
      border:rgb24(palette[UiColorToken.muted]),text:rgb24(palette[UiColorToken.mutedForeground]))
    else:badgeAppearance(uiMode(theme),standardVariant(window),surface)
  discard SetDCBrushColor(dc,colorRef(rgb24(surface)))
  discard FillRect(dc,addr bounds,cast[HBRUSH](brush))
  discard SetDCBrushColor(dc,colorRef(colors.fill))
  discard SetDCPenColor(dc,colorRef(colors.border))
  let height=if keyboard:int32(round(12.0*float64(GetDpiForWindow(window))/96))
    else:bounds.bottom-bounds.top
  discard RoundRect(dc,bounds.left,bounds.top,bounds.right,bounds.bottom,height,height)
  let font=cast[HGDIOBJ](SendMessageW(window,WM_GETFONT,0,0))
  if font!=nil:discard SelectObject(dc,font)
  discard SetTextColor(dc,colorRef(colors.text));discard SetBkMode(dc,1)
  var caption:array[1024,WCHAR]
  var count=GetWindowTextW(window,addr caption[0],int32(caption.len))
  if count>0 and caption[count-1] in 0xd800'u16..0xdbff'u16:dec count
  let inset=int32(round((if keyboard:4.0 else:9.0)*float64(GetDpiForWindow(window))/96))
  bounds.left+=inset;bounds.right-=inset
  discard DrawTextW(dc,addr caption[0],count,addr bounds,1 or 4 or 0x20 or 0x800 or 0x8000)
  true

proc skinMessage*(theme: NativeTheme, window: HWND, message: UINT,
                  wp: WPARAM, lp: LPARAM, reply: var LRESULT): bool =
  if theme == systemTheme or message notin [SkinCtlColorEdit, SkinCtlColorStatic,
      SkinCtlColorButton, SkinEraseBackground, SkinNotify, 0x0083'u32, 0x0084'u32,
      0x0085'u32, WM_SETFONT, 0x02e3'u32, 0x031a'u32, 0x001a'u32,
      0x0007'u32, 0x0008'u32, 0x000a'u32, 0x000f'u32, 0x0318'u32]: return false
  # Recalculate non-client geometry even when entering high contrast: the
  # resulting WM_NCCALCSIZE then takes the system path and restores its border.
  let editor = classIs(window, "Edit")
  if editor and message in [WM_SETFONT, 0x02e3'u32, 0x031a'u32, 0x001a'u32] and
      editSkinMessage(theme, window, message, wp, lp, reply): return true
  if not themeEnabled(theme, highContrastActive()): return false
  if theme.isShadcn and standardRole(window) in [some(UiRole.badge),some(UiRole.kbd),some(UiRole.skeleton),some(UiRole.separator),some(UiRole.spinner)] and
      message in [0x000f'u32,0x0318'u32]:
    if message==0x0318 and wp!=0:
      if drawStandardDisplay(theme,window,cast[HDC](wp)):
        reply=0;return true
    elif message==0x000f:
      var paint:PaintStruct
      let dc=BeginPaint(window,addr paint)
      if dc!=nil:
        discard drawStandardDisplay(theme,window,dc)
        discard EndPaint(window,addr paint)
        reply=0;return true
  if theme.isShadcn and standardRole(window)==some(UiRole.alert) and message in [0x000f'u32,0x0318'u32]:
    var paint:PaintStruct
    let dc=if message==0x0318:cast[HDC](wp) else:BeginPaint(window,addr paint)
    if dc!=nil:
      discard drawStandardAlert(theme,window,dc)
      if message==0x000f:discard EndPaint(window,addr paint)
      reply=0;return true
  if standardRole(window)==some(UiRole.buttonGroup) and message in [0x000f'u32,0x0318'u32]:
    # Keep the real GroupBox proxy, suppress only its visual caption/frame.
    # At high contrast the earlier theme gate leaves native painting intact.
    var paint:PaintStruct
    let dc=if message==0x0318:cast[HDC](wp) else:BeginPaint(window,addr paint)
    if dc!=nil:
      var bounds:RECT
      if GetClientRect(window,addr bounds)!=0:
        let saved=SaveDC(dc)
        if saved!=0:
          discard SetDCBrushColor(dc,colorRef(surfaceColor(theme,GetParent(window))))
          discard FillRect(dc,addr bounds,cast[HBRUSH](GetStockObject(18)))
          discard RestoreDC(dc,saved)
      if message==0x000f:discard EndPaint(window,addr paint)
      reply=0;return true
  if standardRole(window) in [some(UiRole.inputGroup),some(UiRole.inputGroupAddon),some(UiRole.inputGroupText)] and message==0x0084:
    reply=1;return true # HTCLIENT: addon backgrounds are real focus targets.
  if standardRole(window) in [some(UiRole.inputGroup),some(UiRole.inputGroupAddon)] and message in [0x000f'u32,0x0318'u32]:
    var paint:PaintStruct
    let dc=if message==0x0318:cast[HDC](wp) else:BeginPaint(window,addr paint)
    if dc!=nil:
      discard drawInputGroupSurface(theme,window,dc)
      if message==0x000f:discard EndPaint(window,addr paint)
      reply=0;return true
  if message == 0x000f and drawStandardCard(theme,window):
    reply=0
    return true
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
        (if standardRole(child).isSome: editBackground(theme,child)
         elif IsWindowEnabled(child) == 0: p.panel else: p.surface)
      else: surfaceColor(theme, child)
    let ink = if IsWindowEnabled(child) == 0: p.muted
      elif theme.isShadcn and standardRole(child) in [some(UiRole.alertTitle),some(UiRole.alertDescription)]: alertInk(theme,child)
      elif standardRole(child) in [some(UiRole.cardDescription),some(UiRole.fieldDescription),some(UiRole.emptyDescription),some(UiRole.inputGroupText)]: p.muted
      elif standardRole(child)==some(UiRole.fieldError): p.danger
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
    discard SetDCBrushColor(dc, colorRef(surfaceColor(theme, window)))
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
