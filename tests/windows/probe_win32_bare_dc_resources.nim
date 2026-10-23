## Bare Win32 resource-control probe + one GetDC/ReleaseDC pair. No Leaf module
## is imported: this input isolates the standard borrowed-DC pair that Leaf's
## measurement uses on the host window (measure.nim getDC/releaseDC) on top of the
## frozen bare sequence, and asks only whether that single variable changes the
## per-stage process USER/GDI readings. It is not an ownership proof, does not
## close the frozen `<= baseline + 2` budget and never names a product defect.
##
## One fresh process, N = 3 identical cycles. Per cycle the fixed order is
## before -> setup(read-only PMv2/DPI/size/module) -> register -> create ->
## geometry(client/DPI) -> show -> dc_get -> dc_release -> destroy -> unregister,
## with a USER/GDI sample at every stage taken as SetLastError(0),
## GetGuiResources, GetLastError.
## Any API failure stops later cycles, keeps the original error and allows at
## most one own cleanup credential; a failed DestroyWindow is never followed by
## unregistering the class as if the window were gone.
## The borrowed DC is not ownership: no DeleteDC, no stock deletion, no cache
## flush; only a successful ReleaseDC clears the borrow flag, and an unreturned
## borrow is never presented as released.
## Exit 0 means status=bare_dc_diagnostic_completed only.
when not defined(windows):
  {.error: "bare Win32 resource probe requires Windows".}
when defined(vcc):
  {.passL: "user32.lib".}
else:
  {.passL: "-luser32".}

type
  HANDLE = pointer
  HWND = pointer
  HINSTANCE = pointer
  HICON = pointer
  HCURSOR = pointer
  HBRUSH = pointer
  HMENU = pointer
  HDC = pointer
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
{.pop.}

proc bareWndProc(hwnd: HWND, message: UINT, wparam: WPARAM,
                 lparam: LPARAM): LRESULT {.stdcall.} =
  ## No captures, no allocation, no PostQuitMessage.
  DefWindowProcW(hwnd, message, wparam, lparam)

const
  Cycles = 3
  Stages = 10
  StageNames = ["before", "setup", "register", "create", "geometry", "show",
    "dc_get", "dc_release", "destroy", "unregister"]
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
    dcGetOk, dcRelease: int32
    dcReleaseErr: uint32          # raw DWORD from GetLastError
    dcHandle: HDC
    dcBorrowed: bool
    cleanupReleaseAttempted, cleanupDestroyAttempted: bool
    cleanupUnregisterAttempted: bool
    cleanupRelease, cleanupDestroy, cleanupUnregister: int32
    cleanupReleaseErr, cleanupDestroyErr, cleanupUnregisterErr: uint32

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
  var instance: HINSTANCE = nil
  var name: array[32, WCHAR]
  var title: array[32, WCHAR]
  fillWide(name, "BareResC" & $cycle)
  fillWide(title, "BareRes")

  template bail(message: string) =
    r.reason = message
    r.complete = false
    # One own cleanup, in order: borrowed DC, window, class. Every attempt and
    # its real return/error is recorded, even when the BOOL is 0.
    if r.dcBorrowed and window != nil:
      r.cleanupReleaseAttempted = true
      SetLastError(0)
      r.cleanupRelease = int32(ReleaseDC(window, dc))
      r.cleanupReleaseErr = GetLastError()
      if r.cleanupRelease != 0: r.dcBorrowed = false
    if windowOwned and window != nil and not r.dcBorrowed:
      r.cleanupDestroyAttempted = true
      SetLastError(0)
      r.cleanupDestroy = int32(DestroyWindow(window))
      r.cleanupDestroyErr = GetLastError()
      if r.cleanupDestroy != 0: windowOwned = false
    if classOwned and not windowOwned and not r.dcBorrowed:
      r.cleanupUnregisterAttempted = true
      SetLastError(0)
      r.cleanupUnregister = int32(UnregisterClassW(addr name[0], instance))
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

  # Single variable: one borrowed DC on our own host window, exactly the pair
  # Leaf's measurement performs; error captured immediately after each call.
  SetLastError(0)
  dc = GetDC(window)
  let dcGetErr = GetLastError()
  r.dcGetOk = int32(ord(dc != nil))
  r.dcHandle = dc
  if dc != nil: r.dcBorrowed = true
  reason = takeStage(cycle, r, 6)
  if reason.len != 0: bail(reason)
  if dc == nil:
    failureLastError = dcGetErr
    bail("GetDC failed err=" & $dcGetErr)

  SetLastError(0)
  r.dcRelease = int32(ReleaseDC(window, dc))
  r.dcReleaseErr = GetLastError()          # raw DWORD, no narrowing
  if r.dcRelease != 0: r.dcBorrowed = false
  reason = takeStage(cycle, r, 7)
  if reason.len != 0: bail(reason)
  if r.dcRelease == 0:
    failureLastError = r.dcReleaseErr
    bail("ReleaseDC failed err=" & $r.dcReleaseErr)

  r.destroyOk = int32(DestroyWindow(window))
  if r.destroyOk == 0:
    failureLastError = GetLastError()
    bail("DestroyWindow failed err=" & $failureLastError)
  windowOwned = false
  reason = takeStage(cycle, r, 8)
  if reason.len != 0: bail(reason)

  r.unregisterOk = int32(UnregisterClassW(addr name[0], instance))
  if r.unregisterOk == 0:
    failureLastError = GetLastError()
    bail("UnregisterClassW failed err=" & $failureLastError)
  classOwned = false
  reason = takeStage(cycle, r, 9)
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
  echo "probe_win32_bare_dc_resources cycles=", Cycles,
    " wndclassexw_size=", sizeof(WNDCLASSEXW), " style=0x00CF0000",
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
      r.atom, " show_prev=", r.showPrev, " dc=", cast[uint](r.dcHandle),
      " dc_get_ok=", r.dcGetOk, " dc_release=", r.dcRelease,
      " dc_release_err=", r.dcReleaseErr, " dc_borrowed=", r.dcBorrowed,
      " destroy=", r.destroyOk, " unregister=", r.unregisterOk
    if r.cleanupReleaseAttempted or r.cleanupDestroyAttempted or
        r.cleanupUnregisterAttempted:
      echo "cycle", cycle, " cleanup_attempted release=",
        r.cleanupReleaseAttempted, " ret=", r.cleanupRelease, " err=",
        r.cleanupReleaseErr, " destroy=", r.cleanupDestroyAttempted, " ret=",
        r.cleanupDestroy, " err=", r.cleanupDestroyErr, " unregister=",
        r.cleanupUnregisterAttempted, " ret=", r.cleanupUnregister, " err=",
        r.cleanupUnregisterErr
    if r.complete:
      let before = r.stages[0]
      for stage in [3, 5, 6, 7, 8, 9]:
        let s = r.stages[stage]
        echo "cycle", cycle, " delta before->", StageNames[stage], " user=",
          int64(s.user) - int64(before.user), " gdi=",
          int64(s.gdi) - int64(before.gdi)
    else:
      echo "cycle", cycle, " complete=false reason=", r.reason
  if failureLastError != 0:
    echo "last_error_at_failure=", failureLastError
  if completed == Cycles:
    echo "probe_win32_bare_dc_resources status=bare_dc_diagnostic_completed"
    return 0
  echo "probe_win32_bare_dc_resources status=diagnostic_incomplete completed=",
    completed
  3

when isMainModule:
  quit(main())
