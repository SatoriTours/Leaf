## Shared GPUI run error/cleanup ownership. Kept separate from protocol code so
## removing the legacy JSON bridge does not lose error ownership.
import std/[options,json]
import ./core

type
  GpuiRunError* = object of RuntimeCleanupError
    ## Keep this owner until ordinary close succeeds, then release references.

proc gpuiRunErrorInternal*(primary:ref Exception,runtime:Runtime,status=none(int)):ref GpuiRunError=
  if primary of GpuiRunError:return cast[ref GpuiRunError](primary)
  result=newException(GpuiRunError,primary.msg)
  result.parent=primary
  result.cleanupRuntime=runtime
  result.exitStatus=status

proc tryCloseGpuiRuntimeInternal*(runtime:Runtime):ref Exception=
  ## One attempt, after protected host work has unwound. No automatic retries.
  try:runtime.closeRuntime()
  except Exception as cleanup:
    result=cleanup
    try:runtime.diagnostic("gpui","error",%*{"message":"GPUI cleanup: " & cleanup.msg})
    except Exception:discard

proc closeGpuiFailureInternal*(runtime:Runtime,primary:ref Exception):ref GpuiRunError=
  if primary of GpuiRunError:return cast[ref GpuiRunError](primary)
  let cleanup=runtime.tryCloseGpuiRuntimeInternal()
  gpuiRunErrorInternal(primary,if cleanup==nil:nil else:runtime)
