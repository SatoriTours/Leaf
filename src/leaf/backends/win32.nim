## Public native Windows launch boundary; application closures stay in Nim.
when not defined(windows): {.error: "leafNativeWin32 requires Windows".}
import ../[core, styles, backend_session, native_layout, ui_thread, diagnostics]
import ./win32/[api, host, backend]
proc runNative*(app: Application, diagnostics: Diagnostics = nil): int =
  let activity = newUiScopeActivity()
  let guarded = guardUiApplication(app, proc(): uint64 = uint64(GetCurrentThreadId()), activity)
  let runtime = newRuntime(guarded, validator = proc(snapshot: Snapshot) = validateProps(snapshot.root),
    diagnostics = diagnostics)
  let window = createHost(app.title, DipSize(width: float64(app.width), height: float64(app.height)))
  defer: window.destroyHost()
  window.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or runtime.installingHook)
  let native = newWin32Backend(window)
  let session = native.attachWin32Backend(runtime)
  native.bindSession(session)
  window.bindSession(session, proc(): bool = activity.busy)
  window.setSafeTick(proc() = session.drainEvents())
  window.pump()
