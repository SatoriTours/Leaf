## GPUI Kit bridge is loaded only when a desktop window is requested.
import std/[dynlib,os,strutils]
import ./[core,native_library,sdk]
type
  GpuiCallback* = proc(context:pointer,data:ptr uint8,len:csize_t):cstring {.cdecl.}
  GpuiApi* = ref object
    library:LibHandle
    abi*:proc():cuint {.cdecl.}
    frames*:proc(data:ptr uint8,len:csize_t,callback:GpuiCallback,context:pointer):cint {.cdecl.}
    run*:proc(data:ptr uint8,len:csize_t,callback:GpuiCallback,context:pointer):cint {.cdecl.}
const GpuiLibraryName* = when defined(windows):"leaf_gpui.dll"
  elif defined(macosx):"libleaf_gpui.dylib"
  else:"libleaf_gpui.so"
const FrameworkRoot* = currentSourcePath().parentDir.parentDir.parentDir
var cachedApi:GpuiApi
var cachedOverride:string
proc loadGpui*(path=""):GpuiApi =
  if cachedApi!=nil and path.len==0 and cachedOverride==getEnv("LEAF_GPUI_LIBRARY"):return cachedApi
  let override=if path.len>0:path else:getEnv("LEAF_GPUI_LIBRARY")
  let installed = sdkRoot()
  let candidates=if override.len>0: @[override] else: @[
    getAppDir()/GpuiLibraryName] & (if installed.len > 0: @[
      installed/"lib"/GpuiLibraryName] else: @[
      FrameworkRoot/"target/release"/GpuiLibraryName, FrameworkRoot/"target/debug"/GpuiLibraryName])
  for name in candidates:
    let library=openNativeLibrary(name)
    if library==nil:continue
    let abi=cast[typeof(result.abi)](symAddr(library,"leaf_gpui_abi_version"))
    let run=cast[typeof(result.run)](symAddr(library,"leaf_gpui_run"))
    let frames=cast[typeof(result.frames)](symAddr(library,"leaf_gpui_run_frames"))
    if abi==nil or run==nil or abi()!=1:
      unloadLib(library)
      fail("incompatible GPUI bridge: " & name)
    result=GpuiApi(library:library,abi:abi,run:run,frames:frames)
    if path.len==0:
      cachedApi=result
      cachedOverride=getEnv("LEAF_GPUI_LIBRARY")
    return
  fail("GPUI bridge could not be loaded: " & candidates.join(", ") &
    "; run cargo build -p leaf-gpui or set LEAF_GPUI_LIBRARY")
