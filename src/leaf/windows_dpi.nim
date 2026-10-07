## DPI is process policy: only the desktop entry point invokes this backend.
when defined(windows): import std/dynlib

type
  DpiApi* = object
    current*: proc(): string
    setPerMonitorV2*: proc(): tuple[success: bool, errorCode: int]
  DpiResult* = object
    awareness*, status*: string
    errorCode*: int

proc ensureDpi*(api: DpiApi): DpiResult =
  result.awareness = api.current()
  case result.awareness
  of "per_monitor_v2": result.status = "already_set"
  of "system", "per_monitor": result.status = "host_context"
  of "unaware":
    let attempt = api.setPerMonitorV2()
    result.errorCode = attempt.errorCode
    result.awareness = api.current()
    if result.awareness == "per_monitor_v2":
      result.status = if attempt.success: "initialized" else: "already_set"
    else: result.status = "failed"
  else: result.status = "failed"

proc initializeWindowsDpi*(): DpiResult =
  when defined(windows):
    # Explicit loading here avoids user32 loading merely through import leaf.
    type
      GetContext = proc(): pointer {.stdcall.}
      EqualContexts = proc(a, b: pointer): int32 {.stdcall.}
      GetAwareness = proc(context: pointer): int32 {.stdcall.}
      SetContext = proc(context: pointer): int32 {.stdcall.}
      LastError = proc(): uint32 {.stdcall.}
    let user32 = loadLib("user32.dll")
    if user32 == nil: return DpiResult(awareness: "unknown", status: "failed", errorCode: 126)
    defer: unloadLib(user32)
    let kernel32 = loadLib("kernel32.dll")
    if kernel32 == nil: return DpiResult(awareness: "unknown", status: "failed", errorCode: 126)
    defer: unloadLib(kernel32)
    let current = cast[GetContext](user32.symAddr("GetThreadDpiAwarenessContext"))
    let equal = cast[EqualContexts](user32.symAddr("AreDpiAwarenessContextsEqual"))
    let awareness = cast[GetAwareness](user32.symAddr("GetAwarenessFromDpiAwarenessContext"))
    let setter = cast[SetContext](user32.symAddr("SetProcessDpiAwarenessContext"))
    let lastError = cast[LastError](kernel32.symAddr("GetLastError"))
    if current == nil or equal == nil or awareness == nil or setter == nil or lastError == nil:
      return DpiResult(awareness: "unknown", status: "failed", errorCode: 127)
    let pmv2 = cast[pointer](-4)
    return ensureDpi(DpiApi(current: proc(): string =
      let context = current()
      if context == nil: return "unknown"
      if equal(context, pmv2) != 0: return "per_monitor_v2"
      case awareness(context)
      of 0: "unaware"
      of 1: "system"
      of 2: "per_monitor"
      else: "unknown",
      setPerMonitorV2: proc(): tuple[success: bool, errorCode: int] =
        let ok = setter(pmv2) != 0
        let code = if ok: 0 else: int(lastError())
        (ok, code)))
  else:
    return DpiResult(awareness: "not_applicable", status: "not_applicable")
