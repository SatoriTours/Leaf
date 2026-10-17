## Nim application runtime hosted by GPUI and GPUI Kit through the C ABI.
import std/[json,options]
import ./[core,gpui_api,gpui_bridge,gpui_session,diagnostics,windows_dpi]
proc runDesktop*(app:Application,diagnostics:Diagnostics=nil):int =
  let dpi=initializeWindowsDpi()
  diagnostics.record("dpi",dpi.status,%*{"awareness":dpi.awareness,"error_code":dpi.errorCode})
  if dpi.status in ["failed","host_context"]:
    stderr.writeLine("leaf: DPI " & dpi.status & " awareness=" & dpi.awareness & " error=" & $dpi.errorCode)
  let api=loadGpui()
  if api.v2.isSome:
    let runtime=newRuntime(app,diagnostics=diagnostics)
    try:return openGpuiSession(runtime,api).run()
    finally:runtime.closeRuntime()
  let host=newDesktopBridge(app,diagnostics,taskPumpSupported=api.supportsTaskPump())
  try:
    let snapshot = $host.runtime.snapshot.toJson()
    # Synchronous run keeps Nim and its response buffer live through all calls.
    int(api.run(cast[ptr uint8](snapshot.cstring),csize_t(snapshot.len),desktopCallback,cast[pointer](host)))
  finally:host.runtime.closeRuntime()
