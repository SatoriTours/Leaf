## Nim application runtime hosted by GPUI through the typed ABI 2 protocol.
import std/[json,options]
import ./[core,gpui_api,gpui_errors,gpui_session,diagnostics,windows_dpi]
export gpui_errors.GpuiRunError

proc transferFailure(error:ref RuntimeCleanupError,cleanupOwner:ptr Runtime)=
  if cleanupOwner!=nil and error.cleanupRuntime!=nil:cleanupOwner[]=error.cleanupRuntime

proc finishRun(runtime:Runtime,status:int,cleanupOwner:ptr Runtime,alreadyAttempted=false,
    cleanupError:ref Exception=nil):int=
  let failure=if alreadyAttempted:cleanupError else:runtime.tryCloseGpuiRuntimeInternal()
  if failure!=nil:
    if cleanupOwner!=nil:cleanupOwner[]=runtime
    else:raise gpuiRunErrorInternal(failure,runtime,some(status))
  status

proc runDesktop*(app:Application,diagnostics:Diagnostics=nil,cleanupOwner:ptr Runtime=nil):int =
  if cleanupOwner!=nil and cleanupOwner[]!=nil:fail("GPUI cleanup owner slot must be empty")
  let dpi=initializeWindowsDpi()
  diagnostics.record("dpi",dpi.status,%*{"awareness":dpi.awareness,"error_code":dpi.errorCode})
  if dpi.status in ["failed","host_context"]:
    stderr.writeLine("leaf: DPI " & dpi.status & " awareness=" & dpi.awareness & " error=" & $dpi.errorCode)
  let api=loadGpui()
  var runtime: Runtime
  try: runtime = newRuntime(app, diagnostics=diagnostics)
  except RuntimeCleanupError as failure:
    failure.transferFailure(cleanupOwner)
    raise
  var session:GpuiSession
  try:
    session=openGpuiSession(runtime,api)
    result=session.run()
  except GpuiRunError as failure:
    failure.transferFailure(cleanupOwner)
    raise
  except Exception as primary:
    let failure=runtime.closeGpuiFailureInternal(primary)
    failure.transferFailure(cleanupOwner)
    raise failure
  return finishRun(runtime,result,cleanupOwner,session.cleanupAttempted,session.cleanupError)
