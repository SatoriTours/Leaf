## Nim application runtime hosted by GPUI and GPUI Kit through the C ABI.
import std/json
import ./[core,gpui_api,gpui_bridge,diagnostics,windows_dpi]
proc runDesktop*(app:Application,diagnostics:Diagnostics=nil):int =
  let dpi=initializeWindowsDpi()
  diagnostics.record("dpi",dpi.status,%*{"awareness":dpi.awareness,"error_code":dpi.errorCode})
  if dpi.status in ["failed","host_context"]:
    stderr.writeLine("leaf: DPI " & dpi.status & " awareness=" & dpi.awareness & " error=" & $dpi.errorCode)
  let api=loadGpui()
  let host=newDesktopBridge(app,diagnostics)
  let snapshot = $host.runtime.snapshot.toJson()
  # Synchronous run keeps the Nim owner and its response buffer alive throughout.
  int(api.run(cast[ptr uint8](snapshot.cstring),csize_t(snapshot.len),desktopCallback,cast[pointer](host)))
