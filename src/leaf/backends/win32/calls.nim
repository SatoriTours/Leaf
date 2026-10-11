## Internal per-host call table. System defaults forward every call to Win32.
import ./api

type Win32Calls* = object
  registerClass*: proc(windowClass: ptr WNDCLASSEXW): ATOM {.closure, raises: [CatchableError].}
  unregisterClass*: proc(name: WidePtr, instance: HINSTANCE): BOOL {.closure, raises: [CatchableError].}
  createWindow*: proc(exStyle: DWORD, className, title: WidePtr, style: DWORD, x,y,width,height: int32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: pointer): HWND {.closure, raises: [CatchableError].}
  destroyWindow*: proc(window: HWND): BOOL {.closure, raises: [CatchableError].}
  defWindowProc*: proc(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM): LRESULT {.closure, raises: [CatchableError].}
  setWindowData*: proc(window: HWND, index: int32, value: int): int {.closure, raises: [CatchableError].}
  getWindowData*: proc(window: HWND, index: int32): int {.closure, raises: [CatchableError].}
  clientRect*: proc(window: HWND, rect: ptr RECT): BOOL {.closure, raises: [CatchableError].}
  systemDpi*: proc(): UINT {.closure, raises: [CatchableError].}
  adjustRect*: proc(rect: ptr RECT, style: DWORD, menu: BOOL, exStyle: DWORD, dpi: UINT): BOOL {.closure, raises: [CatchableError].}
  dpi*: proc(window: HWND): UINT {.closure, raises: [CatchableError].}
  windowPos*: proc(window, after: HWND, x,y,width,height: int32, flags: UINT): BOOL {.closure, raises: [CatchableError].}
  showWindow*: proc(window: HWND, command: int32): BOOL {.closure, raises: [CatchableError].}
  getMessage*: proc(message: ptr MSG, window: HWND, first,last: UINT): BOOL {.closure, raises: [CatchableError].}
  peekMessage*: proc(message: ptr MSG, window: HWND, first,last,remove: UINT): BOOL {.closure, raises: [CatchableError].}
  translateMessage*: proc(message: ptr MSG): BOOL {.closure, raises: [CatchableError].}
  dispatchMessage*: proc(message: ptr MSG): LRESULT {.closure, raises: [CatchableError].}
  dialogMessage*: proc(window: HWND, message: ptr MSG): BOOL {.closure, raises: [CatchableError].}
  postMessage*: proc(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM): BOOL {.closure, raises: [CatchableError].}
  setTimer*: proc(window: HWND, timer: UINT_PTR, interval: UINT, callback: TIMERPROC): UINT_PTR {.closure, raises: [CatchableError].}
  killTimer*: proc(window: HWND, timer: UINT_PTR): BOOL {.closure, raises: [CatchableError].}

proc systemWin32Calls*(): Win32Calls =
  result.registerClass = proc(windowClass: ptr WNDCLASSEXW): ATOM = RegisterClassExW(windowClass)
  result.unregisterClass = proc(name: WidePtr, instance: HINSTANCE): BOOL = UnregisterClassW(name, instance)
  result.createWindow = proc(exStyle: DWORD, className, title: WidePtr, style: DWORD, x,y,width,height: int32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: pointer): HWND = CreateWindowExW(exStyle,className,title,style,x,y,width,height,parent,menu,instance,param)
  result.destroyWindow = proc(window: HWND): BOOL = DestroyWindow(window)
  result.defWindowProc = proc(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM): LRESULT = DefWindowProcW(window,message,wparam,lparam)
  result.setWindowData = proc(window: HWND, index: int32, value: int): int = SetWindowLongPtrW(window,index,value)
  result.getWindowData = proc(window: HWND, index: int32): int = GetWindowLongPtrW(window,index)
  result.clientRect = proc(window: HWND, rect: ptr RECT): BOOL = GetClientRect(window,rect)
  result.systemDpi = proc(): UINT = GetDpiForSystem()
  result.adjustRect = proc(rect: ptr RECT, style: DWORD, menu: BOOL, exStyle: DWORD, dpi: UINT): BOOL = AdjustWindowRectExForDpi(rect,style,menu,exStyle,dpi)
  result.dpi = proc(window: HWND): UINT = GetDpiForWindow(window)
  result.windowPos = proc(window, after: HWND, x,y,width,height: int32, flags: UINT): BOOL = SetWindowPos(window,after,x,y,width,height,flags)
  result.showWindow = proc(window: HWND, command: int32): BOOL = ShowWindow(window,command)
  result.getMessage = proc(message: ptr MSG, window: HWND, first,last: UINT): BOOL = GetMessageW(message,window,first,last)
  result.peekMessage = proc(message: ptr MSG, window: HWND, first,last,remove: UINT): BOOL = PeekMessageW(message,window,first,last,remove)
  result.translateMessage = proc(message: ptr MSG): BOOL = TranslateMessage(message)
  result.dispatchMessage = proc(message: ptr MSG): LRESULT = DispatchMessageW(message)
  result.dialogMessage = proc(window: HWND, message: ptr MSG): BOOL = IsDialogMessageW(window,message)
  result.postMessage = proc(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM): BOOL = PostMessageW(window,message,wparam,lparam)
  result.setTimer = proc(window: HWND, timer: UINT_PTR, interval: UINT, callback: TIMERPROC): UINT_PTR = SetTimer(window,timer,interval,callback)
  result.killTimer = proc(window: HWND, timer: UINT_PTR): BOOL = KillTimer(window,timer)
