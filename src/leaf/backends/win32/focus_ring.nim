## One non-activating owned adornment per backend, not a child of a clipped
## layout container. It never owns focus, input, application state or GDI objects.
## All creation/placement occurs at ordinary native turns, not in a WndProc.
when not defined(windows): {.error: "Focus adornment requires Windows".}
import std/math
import ../../[core,native_theme,backend]
import ./[api,calls,resource_owner]

type
  FocusRing* = ref object
    entry: ResEntry
    calls: Win32Calls
    color: uint32
    inset, radius: int32
    rect: RECT
    shown, layeredReady: bool
  PaintStruct {.importc:"PAINTSTRUCT",header:"<windows.h>",bycopy.} = object
    hdc: HDC
    fErase: BOOL
    rcPaint: RECT
    fRestore,fIncUpdate: BOOL
    rgbReserved: array[32,uint8]

const
  RingSubclass = 0x4c4652'u
  TransparentKey = 0xff00ff'u32

{.push stdcall,dynlib:"user32.dll",importc,raises:[].}
proc SetLayeredWindowAttributes(window: HWND, key: DWORD, alpha: uint8, flags: DWORD): BOOL
proc BeginPaint(window: HWND, paint: ptr PaintStruct): HDC
proc EndPaint(window: HWND, paint: ptr PaintStruct): BOOL
proc FillRect(dc: HDC, rect: ptr RECT, brush: HBRUSH): int32
{.pop.}
{.push stdcall,dynlib:"gdi32.dll",importc,raises:[].}
proc GetStockObject(index: int32): HGDIOBJ
proc SaveDC(dc: HDC): int32
proc RestoreDC(dc: HDC, saved: int32): BOOL
proc SetDCBrushColor(dc: HDC, color: DWORD): DWORD
proc SetDCPenColor(dc: HDC, color: DWORD): DWORD
proc RoundRect(dc: HDC, left,top,right,bottom,width,height: int32): BOOL
{.pop.}

proc windowHandle*(ring: FocusRing): HWND =
  if ring!=nil and ring.entry!=nil and ring.entry.phase!=epEnded:
    cast[HWND](ring.entry.window)
  else: nil

proc failNative(operation: string) {.noreturn.} =
  fail(operation & " focus adornment failed: " & $lastError())

proc ringProc(window: HWND,message: UINT,wp: WPARAM,lp: LPARAM,
    id: UINT_PTR,data: DWORD_PTR): LRESULT {.stdcall,raises:[].} =
  # This resource owner is pinned by Win32Backend for the entire HWND lifetime.
  # Unlike control metadata, this callback stores no business model or closure.
  let ring=cast[FocusRing](data)
  if ring==nil: return DefSubclassProc(window,message,wp,lp)
  case message
  of WM_NCDESTROY:
    let value=DefSubclassProc(window,message,wp,lp)
    noteWindowEnded(ring.entry)
    ring.shown=false
    return value
  of 0x0084'u32: return -1 # HTTRANSPARENT: pass to same-thread underlying HWND
  of 0x0021'u32: return 3  # MA_NOACTIVATE
  of 0x0014'u32: return 1 # painting fills the entire color-keyed client
  of 0x000f'u32:
    var paint: PaintStruct
    let dc=BeginPaint(window,addr paint)
    if dc==nil: return 0
    defer: discard EndPaint(window,addr paint)
    let saved=SaveDC(dc)
    if saved==0: return 0
    defer: discard RestoreDC(dc,saved)
    let brush=GetStockObject(18)
    let pen=GetStockObject(19)
    if brush==nil or pen==nil: return 0
    discard SelectObject(dc,brush)
    discard SelectObject(dc,pen)
    var rect: RECT
    if GetClientRect(window,addr rect)==0: return 0
    discard SetDCBrushColor(dc,colorRef(TransparentKey))
    discard FillRect(dc,addr rect,cast[HBRUSH](brush))
    discard SetDCBrushColor(dc,colorRef(ring.color))
    discard SetDCPenColor(dc,colorRef(ring.color))
    discard RoundRect(dc,0,0,rect.right,rect.bottom,
      ring.radius+2*ring.inset,ring.radius+2*ring.inset)
    discard SetDCBrushColor(dc,colorRef(TransparentKey))
    discard SetDCPenColor(dc,colorRef(TransparentKey))
    discard RoundRect(dc,ring.inset,ring.inset,rect.right-ring.inset,
      rect.bottom-ring.inset,ring.radius,ring.radius)
    return 0
  else: return DefSubclassProc(window,message,wp,lp)

proc hideFocusRing*(ring: FocusRing) =
  if ring==nil or ring.windowHandle==nil or not ring.shown: return
  discard ring.calls.showWindow(ring.windowHandle,0)
  ring.shown=false

proc closeFocusRing*(ring: FocusRing) =
  if ring==nil or ring.windowHandle==nil: return
  # Retain the NCDESTROY observer across a failed destroy. Removing it first
  # would leave stale ownership if the host later destroys its owned popup.
  if ring.calls.destroyWindow(ring.windowHandle)==0: failNative("DestroyWindow")
  # NCDESTROY normally records this; the BOOL also covers failed subclass setup.
  noteWindowEnded(ring.entry)
  ring.shown=false

proc showFocusRing*(ring: var FocusRing,owner,anchor: HWND,color: uint32,
    calls=systemWin32Calls(),radiusDip=6.0,anchorWidthDip=0.0,anchorHeightDip=0.0) =
  if owner==nil or anchor==nil: fail("focus adornment needs live owner and anchor")
  # Publish the owner BEFORE any native allocation: failures remain retryable.
  if ring==nil: ring=FocusRing(calls:calls,entry:newEntry(nil,cast[pointer](owner),NoHandle,0,0,false))
  if ring.windowHandle==nil:
    const cls=[0x53'u16,0x54,0x41,0x54,0x49,0x43,0]
    let window=ring.calls.createWindow(0x080800a0'u32,unsafeAddr cls[0],nil,
      0x80000000'u32,0,0,0,0,owner,nil,GetModuleHandleW(nil),nil)
    if window==nil: failNative("CreateWindowExW")
    setEntryWindow(ring.entry,cast[pointer](window),cast[pointer](owner))
    ring.entry.phase=epOwned
    ring.layeredReady=false
  if not ring.entry.subclassed:
    if ring.calls.setSubclass(ring.windowHandle,ringProc,RingSubclass,cast[DWORD_PTR](ring))==0:
      failNative("SetWindowSubclass")
    noteSubclassInstalled(ring.entry,RingSubclass,cast[uint](ringProc))
  if not ring.layeredReady:
    if SetLayeredWindowAttributes(ring.windowHandle,colorRef(TransparentKey),255,1)==0:
      failNative("SetLayeredWindowAttributes")
    ring.layeredReady=true
  var bounds: RECT
  if GetWindowRect(anchor,addr bounds)==0: failNative("GetWindowRect")
  let scale=float64(GetDpiForWindow(anchor))/96
  # Boolean controls retain a caption-inclusive native hit target, but the
  # shadcn focus decoration surrounds only their centered leading glyph.
  # Default zeros leave existing Button/EDIT and resource lifecycle unchanged.
  if anchorWidthDip>0 and anchorHeightDip>0:
    let width=max(1'i32,int32(round(anchorWidthDip*scale)))
    let height=max(1'i32,int32(round(anchorHeightDip*scale)))
    bounds.top+=max(0'i32,(bounds.bottom-bounds.top-height) div 2)
    bounds.right=bounds.left+width
    bounds.bottom=bounds.top+height
  let inset=max(1'i32,int32(round(3*scale)))
  let radius=max(2'i32,int32(round(2*radiusDip*scale)))
  let outer=RECT(left:bounds.left-inset,top:bounds.top-inset,
    right:bounds.right+inset,bottom:bounds.bottom+inset)
  if ring.shown and IsWindowVisible(ring.windowHandle)!=0 and
      ring.rect==outer and ring.color==color and ring.radius==radius: return
  ring.color=color
  ring.inset=inset
  ring.radius=radius
  if ring.calls.windowPos(ring.windowHandle,nil,outer.left,outer.top,
      outer.right-outer.left,outer.bottom-outer.top,0x0050'u32)==0:
    failNative("SetWindowPos")
  ring.rect=outer
  ring.shown=true
  if ring.calls.invalidate(ring.windowHandle,nil,1)==0: failNative("InvalidateRect")
