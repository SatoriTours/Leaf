## Public native Windows launch boundary; application closures stay in Nim.
when not defined(windows): {.error: "leafNativeWin32 requires Windows".}
import std/options
import ../[core, styles, backend_session, native_layout, ui_thread, diagnostics]
import ./win32/[api, host, backend]
export host.Win32RunError

proc runNative*(app: Application, diagnostics: Diagnostics = nil,
                cleanupOwner: ptr Runtime = nil): int =
  if cleanupOwner != nil and cleanupOwner[] != nil:
    fail("Win32 cleanup owner slot must be empty")
  let activity = newUiScopeActivity()
  let guarded = guardUiApplication(app, proc(): uint64 = uint64(GetCurrentThreadId()), activity)
  var runtime: Runtime
  try:
    runtime = newRuntime(guarded, validator = proc(snapshot: Snapshot) = validateProps(snapshot.root),
      diagnostics = diagnostics)
  except RuntimeCleanupError as failure:
    if cleanupOwner != nil and failure.cleanupRuntime != nil:
      cleanupOwner[] = failure.cleanupRuntime
    raise
  var window: Win32Host
  var primary: ref CatchableError
  var status = none(int)
  try:
    window = createHost(app.title, DipSize(width: float64(app.width), height: float64(app.height)))
    window.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or runtime.installingHook)
    let native = newWin32Backend(window)
    let session = native.attachWin32Backend(runtime)
    native.bindSession(session)
    window.bindSession(session, proc(): bool = activity.busy)
    window.setSafeTick(proc() = native.safeListTurn())
    result = window.pump()
    status = some(result)
  except CatchableError as error:
    primary = error

  var hostOwner: Win32Host
  # createHost has already attempted its own partial-resource cleanup. Preserve
  # that retry owner without immediately repeating the same failed attempt.
  if primary of Win32RunError:
    hostOwner = cast[ref Win32RunError](primary).cleanupHost
  if hostOwner == nil and window != nil and not window.resourcesReleasedInternal():
    if window.cleanupFailureInternal() != nil:
      hostOwner = window
      if primary == nil: primary = window.cleanupFailureInternal()
    else:
      try: window.destroyHost()
      except CatchableError as cleanup:
        hostOwner = window
        if primary == nil: primary = cleanup
  var runtimeOwner: Runtime
  if hostOwner != nil:
    # Host/native resources must precede pool reclamation. Metadata retirement
    # closes delivery without dropping the independent pool pin or joining.
    let driver = runtime.runtimeDriver
    if driver != nil: driver.retireDeferred()
    runtimeOwner = runtime
  else:
    try: runtime.closeRuntime()
    except CatchableError as cleanup:
      runtimeOwner = runtime
      if primary == nil: primary = cleanup
      # An original business/startup exception stays primary, including cause.

  if runtimeOwner != nil and cleanupOwner != nil: cleanupOwner[] = runtimeOwner
  if primary != nil:
    # A bare Runtime cleanup refusal after an integer return has the approved
    # output channel. Host failures and original exceptions always still throw.
    if status.isSome and hostOwner == nil and runtimeOwner != nil and cleanupOwner != nil:
      return status.get()
    let failure = if primary of Win32RunError: cast[ref Win32RunError](primary)
                  else: newException(Win32RunError, primary.msg)
    if not (primary of Win32RunError): failure.parent = primary
    failure.cleanupHost = hostOwner
    failure.cleanupRuntime = runtimeOwner
    failure.exitStatus = status
    raise failure
  result = status.get()
