## Platform-only single-owner bridge; no concrete Backend dependency.
import ./api
import ../../[backend, backend_session]
type
  NativeInvalidation* = enum
    geometryChanged, fontChanged, themeChanged
  HostBackendBridge* = object
    syncFocusTraversal*: proc(target: HWND) {.closure.}
      ## Optional native-only preparation before USER32 routes a mouse click;
      ## called again with actual focus after dispatch, including ignored clicks.
    capture*: proc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): bool {.closure, raises: [].}
    invalidate*: proc(context: HostContext, reasons: set[NativeInvalidation]) {.closure, raises: [].}
    nativeTick*: proc() {.closure.}
    localBusy*, resourcesReleased*: proc(): bool {.closure, raises: [].}
    matchesSession*: proc(session: BackendSession): bool {.closure, raises: [].}
    modalTarget*: proc(): HWND {.closure, raises: [].}
    pointerButton*: proc(window: HWND) {.closure, raises: [].}
      ## Called from the production dispatch for a real mouse-button press with
      ## the window the message targeted. Owned-scope decisions stay in the backend.
    modalScrollable*: proc(): bool {.closure, raises: [].}
      ## The top modal level scrolls its content. Tab then belongs to the modal's
      ## logical focus order instead of USER32's traversal, which cannot reach a
      ## control that the scroll pass hid.
      ## Optional topmost modal window. USER32's dialog routing (Tab cycling,
      ## Esc/Enter translation) then applies to that window instead of the
      ## page, so background controls stay out of the tab scope.
    closeStartup*: proc() {.closure.}
  HostBackendLease* = ref object
    ## Opaque identity; only the owning Host interprets it.
