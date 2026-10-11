## Platform-only single-owner bridge; no concrete Backend dependency.
import ./api
import ../../[backend, backend_session]
type
  NativeInvalidation* = enum
    geometryChanged, fontChanged, themeChanged
  HostBackendBridge* = object
    capture*: proc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): bool {.closure, raises: [].}
    invalidate*: proc(context: HostContext, reasons: set[NativeInvalidation]) {.closure, raises: [].}
    nativeTick*: proc() {.closure.}
    localBusy*, resourcesReleased*: proc(): bool {.closure, raises: [].}
    matchesSession*: proc(session: BackendSession): bool {.closure, raises: [].}
    closeStartup*: proc() {.closure.}
  HostBackendLease* = ref object
    ## Opaque identity; only the owning Host interprets it.
