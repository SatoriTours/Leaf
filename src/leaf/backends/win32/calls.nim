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

  immContext*: proc(window: HWND): HIMC {.closure, raises: [CatchableError].}
  immRelease*: proc(window: HWND, context: HIMC): BOOL {.closure, raises: [CatchableError].}
  immNotify*: proc(context: HIMC, action, index, value: DWORD): BOOL {.closure, raises: [CatchableError].}
  createFont*: proc(font: ptr LOGFONTW): HFONT {.closure, raises: [CatchableError].}
  deleteObject*: proc(obj: HGDIOBJ): BOOL {.closure, raises: [CatchableError].}
  setSubclass*: proc(window: HWND, callback: SUBCLASSPROC, id: UINT_PTR, data: DWORD_PTR): BOOL {.closure, raises: [CatchableError].}
  removeSubclass*: proc(window: HWND, callback: SUBCLASSPROC, id: UINT_PTR): BOOL {.closure, raises: [CatchableError].}
  defaultSubclass*: proc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): LRESULT {.closure, raises: [CatchableError].}
  setText*: proc(window: HWND, text: WidePtr): BOOL {.closure, raises: [CatchableError].}
  invalidate*: proc(window: HWND, rect: pointer, erase: BOOL): BOOL {.closure, raises: [CatchableError].}
  enable*: proc(window: HWND, enabled: BOOL): BOOL {.closure, raises: [CatchableError].}
  send*: proc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): LRESULT {.closure, raises: [CatchableError].}
  getDC*: proc(window: HWND): HDC {.closure, raises: [CatchableError].}
  releaseDC*: proc(window: HWND, dc: HDC): int32 {.closure, raises: [CatchableError].}
  selectObject*: proc(dc: HDC, obj: HGDIOBJ): HGDIOBJ {.closure, raises: [CatchableError].}
  textMetrics*: proc(dc: HDC, metric: ptr TEXTMETRICW): BOOL {.closure, raises: [CatchableError].}
  textExtent*: proc(dc: HDC, text: WidePtr, count: int32, size: ptr SIZE): BOOL {.closure, raises: [CatchableError].}
  drawText*: proc(dc: HDC, text: WidePtr, count: int32, rect: ptr RECT, flags: UINT): int32 {.closure, raises: [CatchableError].}
  systemParameters*: proc(action,param: UINT, value: pointer, flags,dpi: UINT): BOOL {.closure, raises: [CatchableError].}
  systemMetric*: proc(index: int32, dpi: UINT): int32 {.closure, raises: [CatchableError].}
  openTheme*: proc(window: HWND, classList: WidePtr, dpi: UINT): HTHEME {.closure, raises: [CatchableError].}
  closeTheme*: proc(theme: HTHEME): int32 {.closure, raises: [CatchableError].}
  themePartSize*: proc(theme: HTHEME, dc: HDC, part,state: int32, rect: ptr RECT, mode: int32, size: ptr SIZE): int32 {.closure, raises: [CatchableError].}
  themeMargins*: proc(theme: HTHEME, dc: HDC, part,state,property: int32, rect: ptr RECT, margins: ptr MARGINS): int32 {.closure, raises: [CatchableError].}
  rectRegion*: proc(left,top,right,bottom: int32): HRGN {.closure, raises: [CatchableError].}
  setRegion*: proc(window: HWND, region: HRGN, redraw: BOOL): int32 {.closure, raises: [CatchableError].}

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

  result.immContext = proc(window: HWND): HIMC = ImmGetContext(window)
  result.immRelease = proc(window: HWND, context: HIMC): BOOL = ImmReleaseContext(window, context)
  result.immNotify = proc(context: HIMC, action, index, value: DWORD): BOOL = ImmNotifyIME(context, action, index, value)
  result.createFont = proc(font: ptr LOGFONTW): HFONT = CreateFontIndirectW(font)
  result.deleteObject = proc(obj: HGDIOBJ): BOOL = DeleteObject(obj)
  result.setSubclass = proc(window: HWND, callback: SUBCLASSPROC, id: UINT_PTR, data: DWORD_PTR): BOOL = SetWindowSubclass(window,callback,id,data)
  result.removeSubclass = proc(window: HWND, callback: SUBCLASSPROC, id: UINT_PTR): BOOL = RemoveWindowSubclass(window,callback,id)
  result.defaultSubclass = proc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): LRESULT = DefSubclassProc(window,message,wp,lp)
  result.setText = proc(window: HWND, text: WidePtr): BOOL = SetWindowTextW(window,text)
  result.invalidate = proc(window: HWND, rect: pointer, erase: BOOL): BOOL = InvalidateRect(window,rect,erase)
  result.enable = proc(window: HWND, enabled: BOOL): BOOL = EnableWindow(window,enabled)
  result.send = proc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): LRESULT = SendMessageW(window,message,wp,lp)
  result.getDC = proc(window: HWND): HDC = GetDC(window)
  result.releaseDC = proc(window: HWND, dc: HDC): int32 = ReleaseDC(window,dc)
  result.selectObject = proc(dc: HDC, obj: HGDIOBJ): HGDIOBJ = SelectObject(dc,obj)
  result.textMetrics = proc(dc: HDC, metric: ptr TEXTMETRICW): BOOL = GetTextMetricsW(dc,metric)
  result.textExtent = proc(dc: HDC, text: WidePtr, count: int32, size: ptr SIZE): BOOL = GetTextExtentPoint32W(dc,text,count,size)
  result.drawText = proc(dc: HDC, text: WidePtr, count: int32, rect: ptr RECT, flags: UINT): int32 = DrawTextW(dc,text,count,rect,flags)
  result.systemParameters = proc(action,param: UINT, value: pointer, flags,dpi: UINT): BOOL = SystemParametersInfoForDpi(action,param,value,flags,dpi)
  result.systemMetric = proc(index: int32, dpi: UINT): int32 = GetSystemMetricsForDpi(index,dpi)
  result.openTheme = proc(window: HWND, classList: WidePtr, dpi: UINT): HTHEME = OpenThemeDataForDpi(window,classList,dpi)
  result.closeTheme = proc(theme: HTHEME): int32 = CloseThemeData(theme)
  result.themePartSize = proc(theme: HTHEME, dc: HDC, part,state: int32, rect: ptr RECT, mode: int32, size: ptr SIZE): int32 = GetThemePartSize(theme,dc,part,state,rect,mode,size)
  result.themeMargins = proc(theme: HTHEME, dc: HDC, part,state,property: int32, rect: ptr RECT, margins: ptr MARGINS): int32 = GetThemeMargins(theme,dc,part,state,property,rect,margins)
  result.rectRegion = proc(left,top,right,bottom: int32): HRGN = CreateRectRgn(left,top,right,bottom)
  result.setRegion = proc(window: HWND, region: HRGN, redraw: BOOL): int32 = SetWindowRgn(window,region,redraw)
