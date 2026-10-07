## Native-only process/independent HWND probe; never an automatic desktop test.
import std/[os, json, strutils]
import leaf
import leaf/[runner, windows_dpi]
when defined(windows):
  import std/[dynlib, winlean]
  proc moduleHandle(name: WideCString): Handle {.stdcall, importc: "GetModuleHandleW", dynlib: "kernel32".}
  type
    GetContext = proc(): pointer {.stdcall.}
    EqualContexts = proc(a, b: pointer): int32 {.stdcall.}
    GetAwareness = proc(a: pointer): int32 {.stdcall.}
    SetContext = proc(a: pointer): int32 {.stdcall.}
    WindowProc = proc(hwnd: Handle, parameter: int): int32 {.stdcall.}
    EnumProc = proc(callback: WindowProc, parameter: int): int32 {.stdcall.}
    WindowPid = proc(hwnd: Handle, pid: ptr uint32): uint32 {.stdcall.}
    WindowDpi = proc(hwnd: Handle): uint32 {.stdcall.}
    WindowContext = proc(hwnd: Handle): pointer {.stdcall.}
    Visible = proc(hwnd: Handle): int32 {.stdcall.}
  var targetPid: uint32
  var pidApi: WindowPid
  var dpiApi: WindowDpi
  var visibleApi: Visible
  var contextApi: WindowContext
  var equalApi: EqualContexts
  var awarenessApi: GetAwareness
  var found = 0
  proc reportWindow(hwnd: Handle, parameter: int): int32 {.stdcall.} =
    var pid: uint32
    discard pidApi(hwnd, addr pid)
    if pid == targetPid and visibleApi(hwnd) != 0:
      inc found
      let context=contextApi(hwnd)
      let awareness=if equalApi(context,cast[pointer](-4)) != 0:"per_monitor_v2"
        else:
          case awarenessApi(context)
          of 0:"unaware"
          of 1:"system"
          of 2:"per_monitor"
          else:"unknown"
      echo $(%*{"pid":pid,"hwnd":cast[uint](hwnd),"dpi_win32_measured":dpiApi(hwnd),"awareness_win32_measured":awareness})
    1

  proc main() =
    let mode = paramStr(1)
    if mode == "headless":
      let before = moduleHandle(newWideCString("user32.dll"))
      let app = Application(title: "Headless", width: 640, height: 480,
        render: proc(ctx: BuildContext): Node = text("中文"))
      doAssert run(app, @["--check"]) == 0
      doAssert moduleHandle(newWideCString("user32.dll")) == before
      echo "headless import/run did not load user32"
    let lib = loadLib("user32.dll")
    doAssert lib != nil
    defer: unloadLib(lib)
    if mode == "window":
      targetPid = uint32(parseUInt(paramStr(2)))
      pidApi = cast[WindowPid](lib.symAddr("GetWindowThreadProcessId"))
      dpiApi = cast[WindowDpi](lib.symAddr("GetDpiForWindow"))
      visibleApi = cast[Visible](lib.symAddr("IsWindowVisible"))
      contextApi = cast[WindowContext](lib.symAddr("GetWindowDpiAwarenessContext"))
      equalApi = cast[EqualContexts](lib.symAddr("AreDpiAwarenessContextsEqual"))
      awarenessApi = cast[GetAwareness](lib.symAddr("GetAwarenessFromDpiAwarenessContext"))
      doAssert contextApi != nil and equalApi != nil and awarenessApi != nil
      let enumerate = cast[EnumProc](lib.symAddr("EnumWindows"))
      doAssert pidApi != nil and dpiApi != nil and visibleApi != nil and enumerate != nil
      doAssert enumerate(reportWindow, 0) != 0
      doAssert found > 0, "No visible HWND belonging to requested PID"
    else:
      let query = cast[GetContext](lib.symAddr("GetThreadDpiAwarenessContext"))
      let equal = cast[EqualContexts](lib.symAddr("AreDpiAwarenessContextsEqual"))
      let awareness = cast[GetAwareness](lib.symAddr("GetAwarenessFromDpiAwarenessContext"))
      let setter = cast[SetContext](lib.symAddr("SetProcessDpiAwarenessContext"))
      doAssert query != nil and equal != nil and awareness != nil and setter != nil
      if mode in ["per_monitor_v2", "system", "per_monitor"]:
        let value = if mode == "system": -2 elif mode == "per_monitor": -3 else: -4
        doAssert setter(cast[pointer](value)) != 0
      let before = query()
      if mode == "headless":
        let app = Application(title: "Check context", width: 640, height: 480,
          render: proc(ctx: BuildContext): Node = text("OK"))
        doAssert run(app, @["--check"]) == 0
        doAssert equal(before, query()) != 0
      else:
        let r = initializeWindowsDpi()
        echo $(%*{"awareness":r.awareness,"status":r.status,"error_code":r.errorCode})
        if mode in ["system", "per_monitor"]:
          doAssert r.status == "host_context" and equal(before, query()) != 0
        else:
          doAssert r.status in ["initialized", "already_set"]
          doAssert equal(query(), cast[pointer](-4)) != 0
  main()

else:
  quit("Windows native probe requires Windows", 1)
