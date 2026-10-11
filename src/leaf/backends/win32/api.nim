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
