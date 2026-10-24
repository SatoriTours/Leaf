## Internal Unicode Win32 ABI. No C shim, toolkit, Runtime or business callbacks.
when not defined(windows): {.error: "Win32 API requires Windows".}
import std/winlean as lean

type
  HWND* {.importc: "HWND", header: "<windows.h>".} = pointer
  HANDLE* {.importc: "HANDLE", header: "<windows.h>".} = pointer
  HINSTANCE* {.importc: "HINSTANCE", header: "<windows.h>".} = pointer
  HMENU* {.importc: "HMENU", header: "<windows.h>".} = pointer
  HICON* {.importc: "HICON", header: "<windows.h>".} = pointer
  HCURSOR* {.importc: "HCURSOR", header: "<windows.h>".} = pointer
  HBRUSH* {.importc: "HBRUSH", header: "<windows.h>".} = pointer
  DWORD* = uint32
  UINT* = uint32
  BOOL* = int32
  LONG* = int32
  WCHAR* = uint16
  ATOM* = uint16
  UINT_PTR* = uint
  DWORD_PTR* = uint
  WPARAM* = uint
  LPARAM* = int
  LRESULT* = int
  WidePtr* = ptr WCHAR
  WNDPROC* = proc(hwnd: HWND, message: UINT, wparam: WPARAM,
                  lparam: LPARAM): LRESULT {.stdcall, raises: [].}
  SUBCLASSPROC* = proc(hwnd: HWND, message: UINT, wparam: WPARAM,
    lparam: LPARAM, subclassId: UINT_PTR, refData: DWORD_PTR): LRESULT {.stdcall, raises: [].}
  TIMERPROC* = proc(hwnd: HWND, message: UINT, timer: UINT_PTR,
                   time: DWORD) {.stdcall, raises: [].}
  POINT* = object
    x*, y*: LONG
  RECT* = object
    left*, top*, right*, bottom*: LONG
  MSG* = object
    hwnd*: HWND
    message*: UINT
    wParam*: WPARAM
    lParam*: LPARAM
    time*: DWORD
    pt*: POINT
  SCROLLINFO* = object
    cbSize*: UINT
    fMask*: UINT
    nMin*, nMax*: int32
    nPage*: UINT
    nPos*, nTrackPos*: int32
  WNDCLASSEXW* = object
    cbSize*, style*: UINT
    lpfnWndProc*: WNDPROC
    cbClsExtra*, cbWndExtra*: int32
    hInstance*: HINSTANCE
    hIcon*: HICON
    hCursor*: HCURSOR
    hbrBackground*: HBRUSH
    lpszMenuName*, lpszClassName*: WidePtr
    hIconSm*: HICON
  CREATESTRUCTW* = object
    lpCreateParams*: pointer
    hInstance*: HINSTANCE
    hMenu*: HMENU
    hwndParent*: HWND
    cy*, cx*, y*, x*: int32
    style*: LONG
    lpszName*, lpszClass*: WidePtr
    dwExStyle*: DWORD

const
  WM_NCCREATE* = 0x0081'u32
  WM_NCDESTROY* = 0x0082'u32
  WM_CLOSE* = 0x0010'u32
  WM_SIZE* = 0x0005'u32
  WM_TIMER* = 0x0113'u32
  WM_DPICHANGED* = 0x02E0'u32
  WM_QUIT* = 0x0012'u32
  WM_APP* = 0x8000'u32
  WM_HOST_TICK* = WM_APP + 17
  WM_HOST_TASK_TICK* = WM_APP + 18
  WM_VSCROLL* = 0x0115'u32
  WM_MOUSEWHEEL* = 0x020A'u32
  WHEEL_DELTA* = 120'i32
  SB_LINEUP* = 0
  SB_LINEDOWN* = 1
  SB_PAGEUP* = 2
  SB_PAGEDOWN* = 3
  SB_THUMBPOSITION* = 4
  SB_THUMBTRACK* = 5
  SB_TOP* = 6
  SB_BOTTOM* = 7
  SB_ENDSCROLL* = 8
  SB_HORZ* = 0
  SB_VERT* = 1
  SB_CTL* = 2
  GWLP_USERDATA* = -21'i32
  PM_REMOVE* = 1'u32
  WS_OVERLAPPEDWINDOW* = 0x00CF0000'u32
  WS_VISIBLE* = 0x10000000'u32
  SW_SHOW* = 5'i32
  SWP_NOZORDER* = 0x0004'u32
  SWP_NOACTIVATE* = 0x0010'u32

proc lastError*(): DWORD {.raises: [].} = cast[DWORD](lean.getLastError())
proc setLastError*(value: DWORD) {.raises: [].} = lean.setLastError(cast[int32](value))
proc GetCurrentThreadId*(): DWORD {.stdcall, dynlib: "kernel32.dll", importc, raises: [].}
proc GetModuleHandleW*(name: WidePtr): HINSTANCE {.stdcall, dynlib: "kernel32.dll", importc, raises: [].}

{.push stdcall, dynlib: "user32.dll", importc, raises: [].}
proc RegisterClassExW*(windowClass: ptr WNDCLASSEXW): ATOM
proc UnregisterClassW*(name: WidePtr, instance: HINSTANCE): BOOL
proc GetClassInfoExW*(instance: HINSTANCE, name: WidePtr, info: ptr WNDCLASSEXW): BOOL
proc GetClassNameW*(window: HWND, name: WidePtr, size: int32): int32
proc CreateWindowExW*(exStyle: DWORD, className, title: WidePtr, style: DWORD,
  x,y,width,height: int32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: pointer): HWND
proc DestroyWindow*(window: HWND): BOOL
proc DefWindowProcW*(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM): LRESULT
proc SetWindowLongPtrW*(window: HWND, index: int32, value: int): int
proc GetWindowLongPtrW*(window: HWND, index: int32): int
proc GetClientRect*(window: HWND, rect: ptr RECT): BOOL
proc GetDpiForSystem*(): UINT
proc AdjustWindowRectExForDpi*(rect: ptr RECT, style: DWORD, menu: BOOL, exStyle: DWORD, dpi: UINT): BOOL
proc GetDpiForWindow*(window: HWND): UINT
proc SetWindowPos*(window, after: HWND, x,y,width,height: int32, flags: UINT): BOOL
proc ShowWindow*(window: HWND, command: int32): BOOL
proc GetMessageW*(message: ptr MSG, window: HWND, first, last: UINT): BOOL
proc PeekMessageW*(message: ptr MSG, window: HWND, first, last, remove: UINT): BOOL
proc TranslateMessage*(message: ptr MSG): BOOL
proc DispatchMessageW*(message: ptr MSG): LRESULT
proc IsDialogMessageW*(window: HWND, message: ptr MSG): BOOL
proc PostMessageW*(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM): BOOL
proc SendMessageW*(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM): LRESULT
proc PostQuitMessage*(code: int32)
proc SetTimer*(window: HWND, timer: UINT_PTR, interval: UINT, callback: TIMERPROC): UINT_PTR
proc KillTimer*(window: HWND, timer: UINT_PTR): BOOL
proc IsWindow*(window: HWND): BOOL
proc GetWindowTextW*(window: HWND, text: WidePtr, size: int32): int32
proc GetWindowTextLengthW*(window: HWND): int32
{.pop.}


# Stock controls and GDI/theme measurement, all native Windows ABI.
type
  HFONT* {.importc: "HFONT", header: "<windows.h>".} = ptr object
  HDC* {.importc: "HDC", header: "<windows.h>".} = ptr object
  HGDIOBJ* {.importc: "HGDIOBJ", header: "<windows.h>".} = ptr object
  HRGN* {.importc: "HRGN", header: "<windows.h>".} = ptr object
  HTHEME* {.importc: "HTHEME", header: "<uxtheme.h>".} = ptr object
  SIZE* = object
    cx*, cy*: LONG
  LOGFONTW* = object
    lfHeight*, lfWidth*, lfEscapement*, lfOrientation*, lfWeight*: LONG
    lfItalic*, lfUnderline*, lfStrikeOut*, lfCharSet*: uint8
    lfOutPrecision*, lfClipPrecision*, lfQuality*, lfPitchAndFamily*: uint8
    lfFaceName*: array[32, WCHAR]
  TEXTMETRICW* = object
    tmHeight*, tmAscent*, tmDescent*, tmInternalLeading*, tmExternalLeading*: LONG
    tmAveCharWidth*, tmMaxCharWidth*, tmWeight*, tmOverhang*: LONG
    tmDigitizedAspectX*, tmDigitizedAspectY*: LONG
    tmFirstChar*, tmLastChar*, tmDefaultChar*, tmBreakChar*: WCHAR
    tmItalic*, tmUnderlined*, tmStruckOut*, tmPitchAndFamily*, tmCharSet*: uint8
  NONCLIENTMETRICSW* = object
    cbSize*: UINT
    iBorderWidth*, iScrollWidth*, iScrollHeight*, iCaptionWidth*, iCaptionHeight*: int32
    lfCaptionFont*: LOGFONTW
    iSmCaptionWidth*, iSmCaptionHeight*: int32
    lfSmCaptionFont*: LOGFONTW
    iMenuWidth*, iMenuHeight*: int32
    lfMenuFont*, lfStatusFont*, lfMessageFont*: LOGFONTW
    iPaddedBorderWidth*: int32
  INITCOMMONCONTROLSEX* = object
    dwSize*, dwICC*: DWORD
  MARGINS* = object
    cxLeftWidth*, cxRightWidth*, cyTopHeight*, cyBottomHeight*: int32
  WNDENUMPROC* = proc(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].}
const
  WM_COMMAND* = 0x0111'u32
  WM_SETTINGCHANGE* = 0x001A'u32
  WM_THEMECHANGED* = 0x031A'u32
  WM_SETFONT* = 0x0030'u32
  WM_GETFONT* = 0x0031'u32
  WM_SETTEXT* = 0x000C'u32
  WS_CHILD* = 0x40000000'u32
  WS_TABSTOP* = 0x00010000'u32
  WS_VSCROLL* = 0x00200000'u32
  WS_CLIPCHILDREN* = 0x02000000'u32
  WS_CLIPSIBLINGS* = 0x04000000'u32
  WS_BORDER* = 0x00800000'u32
  BS_AUTOCHECKBOX* = 3'u32
  SS_NOPREFIX* = 0x80'u32
  SS_ETCHEDHOR* = 0x10'u32
  PBS_MARQUEE* = 8'u32
  BM_GETCHECK* = 0x00F0'u32
  BM_SETCHECK* = 0x00F1'u32
  BM_CLICK* = 0x00F5'u32
  BCM_GETIDEALSIZE* = 0x1601'u32
  EM_GETSEL* = 0x00B0'u32
  EM_SETSEL* = 0x00B1'u32
  EM_GETRECT* = 0x00B2'u32
  EM_GETMARGINS* = 0x00D4'u32
  EM_SETCUEBANNER* = 0x1501'u32
  EM_GETCUEBANNER* = 0x1502'u32
  PBM_SETRANGE32* = 0x0406'u32
  PBM_SETPOS* = 0x0402'u32
  PBM_GETPOS* = 0x0408'u32
  PBM_SETMARQUEE* = 0x040A'u32
  SW_HIDE* = 0'i32
  GWL_STYLE* = -16'i32
  GWL_ID* = -12'i32
  SIF_RANGE* = 0x0001'u32
  SIF_PAGE* = 0x0002'u32
  SIF_POS* = 0x0004'u32
  SIF_DISABLENOSCROLL* = 0x0008'u32
  SIF_TRACKPOS* = 0x0010'u32
  SIF_ALL* = 0x0017'u32
  SPI_GETWHEELSCROLLLINES* = 0x0068'u32
  WHEEL_PAGESCROLL* = 0xFFFFFFFF'i32
  SPI_GETNONCLIENTMETRICS* = 0x0029'u32
  DT_WORDBREAK* = 0x0010'u32
  DT_CALCRECT* = 0x0400'u32
  DT_NOPREFIX* = 0x0800'u32
  ICC_PROGRESS_CLASS* = 0x20'u32
  SM_CXBORDER* = 5'i32
  SM_CYBORDER* = 6'i32
  SM_CYHSCROLL* = 3'i32
{.push stdcall, dynlib: "user32.dll", importc, raises: [].}
proc SetWindowTextW*(window: HWND, text: WidePtr): BOOL
proc InvalidateRect*(window: HWND, rect: pointer, erase: BOOL): BOOL
proc EnableWindow*(window: HWND, enabled: BOOL): BOOL
proc IsWindowEnabled*(window: HWND): BOOL
proc IsWindowVisible*(window: HWND): BOOL
proc GetParent*(window: HWND): HWND
proc GetScrollInfo*(window: HWND, bar: int32, info: ptr SCROLLINFO): BOOL
proc SetScrollInfo*(window: HWND, bar: int32, info: ptr SCROLLINFO, redraw: BOOL): int32
proc GetFocus*(): HWND
proc SetFocus*(window: HWND): HWND
proc GetDlgCtrlID*(window: HWND): int32
proc GetWindowRect*(window: HWND, rect: ptr RECT): BOOL
proc EnumChildWindows*(parent: HWND, callback: WNDENUMPROC, data: LPARAM): BOOL
proc MapWindowPoints*(source, target: HWND, points: ptr POINT, count: UINT): int32
proc GetWindowLongW*(window: HWND, index: int32): LONG
proc GetDC*(window: HWND): HDC
proc ReleaseDC*(window: HWND, dc: HDC): int32
proc DrawTextW*(dc: HDC, text: WidePtr, count: int32, rect: ptr RECT, format: UINT): int32
proc SystemParametersInfoForDpi*(action, param: UINT, value: pointer, flags, dpi: UINT): BOOL
# Plain (non-DPI) variant. `SystemParametersInfoForDpi` only supports a subset of
# actions and fails for `SPI_GETWHEELSCROLLLINES`; the line count is not a
# per-DPI quantity, so it is queried through this API instead. Read-only GET use.
proc SystemParametersInfoW*(action, param: UINT, value: pointer, flags: UINT): BOOL
proc GetSystemMetricsForDpi*(index: int32, dpi: UINT): int32
proc SetWindowRgn*(window: HWND, region: HRGN, redraw: BOOL): int32
proc GetGuiResources*(process: HANDLE, flags: DWORD): DWORD
{.pop.}
{.push stdcall, dynlib: "gdi32.dll", importc, raises: [].}
proc CreateFontIndirectW*(font: ptr LOGFONTW): HFONT
proc DeleteObject*(obj: HGDIOBJ): BOOL
proc SelectObject*(dc: HDC, obj: HGDIOBJ): HGDIOBJ
proc GetTextMetricsW*(dc: HDC, metric: ptr TEXTMETRICW): BOOL
proc GetTextExtentPoint32W*(dc: HDC, text: WidePtr, count: int32, size: ptr SIZE): BOOL
proc GetObjectW*(obj: HGDIOBJ, size: int32, value: pointer): int32
proc GetObjectType*(obj: HGDIOBJ): DWORD
proc CreateRectRgn*(left,top,right,bottom: int32): HRGN
{.pop.}
{.push stdcall, dynlib: "comctl32.dll", importc, raises: [].}
proc SetWindowSubclass*(window: HWND, callback: SUBCLASSPROC, id: UINT_PTR, data: DWORD_PTR): BOOL
proc RemoveWindowSubclass*(window: HWND, callback: SUBCLASSPROC, id: UINT_PTR): BOOL
proc GetWindowSubclass*(window: HWND, callback: SUBCLASSPROC, id: UINT_PTR, data: ptr DWORD_PTR): BOOL
proc DefSubclassProc*(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): LRESULT
{.pop.}
{.push stdcall, dynlib: "uxtheme.dll", importc, raises: [].}
proc OpenThemeDataForDpi*(window: HWND, classList: WidePtr, dpi: UINT): HTHEME
proc CloseThemeData*(theme: HTHEME): int32
proc GetThemePartSize*(theme: HTHEME, dc: HDC, part,state: int32, rect: ptr RECT, mode: int32, size: ptr SIZE): int32
proc GetThemeMargins*(theme: HTHEME, dc: HDC, part,state,property: int32, rect: ptr RECT, margins: ptr MARGINS): int32
{.pop.}
proc GetCurrentProcess*(): HANDLE {.stdcall, dynlib: "kernel32.dll", importc, raises: [].}

const
  WM_KEYDOWN* = 0x0100'u32
  WM_CHAR* = 0x0102'u32
  WM_GETDLGCODE* = 0x0087'u32
  DLGC_WANTARROWS* = 1'i64      ## accept arrow keys (and Home/End/PageUp/PageDown)
  DLGC_WANTALLKEYS* = 4'i64     ## accept every key: deliberately NOT used by lists
  VK_END* = 0x23'u32
  VK_HOME* = 0x24'u32
  VK_UP* = 0x26'u32
  VK_DOWN* = 0x28'u32
  VK_PRIOR* = 0x21'u32          ## VK_PRIOR = Page Up
  VK_NEXT* = 0x22'u32           ## VK_NEXT = Page Down
  WM_IME_STARTCOMPOSITION* = 0x010D'u32
  WM_IME_ENDCOMPOSITION* = 0x010E'u32
  WM_IME_COMPOSITION* = 0x010F'u32
type HIMC* = pointer
{.push stdcall, dynlib: "imm32.dll", importc, raises: [].}
proc ImmGetContext*(window: HWND): HIMC
proc ImmReleaseContext*(window: HWND, context: HIMC): BOOL
proc ImmNotifyIME*(context: HIMC, action, index, value: DWORD): BOOL
{.pop.}

proc initControls*(init: ptr INITCOMMONCONTROLSEX): BOOL {.stdcall, dynlib: "comctl32.dll", importc: "InitCommonControlsEx", raises: [].}
