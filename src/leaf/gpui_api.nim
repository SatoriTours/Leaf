## GPUI Kit bridge is loaded only when a desktop window is requested.
import std/[dynlib,os,strutils,options]
import ./[core,native_library,sdk,gpui_ffi_v2]
type
  GpuiCallback* = proc(context:pointer,data:ptr uint8,len:csize_t):cstring {.cdecl.}
  GpuiApi* = ref object
    library:LibHandle
    v2*:Option[LeafGpuiApiV2]
    taskPumpVersion*:proc():cuint {.cdecl.}
    abi*:proc():cuint {.cdecl.}
    frames*:proc(data:ptr uint8,len:csize_t,callback:GpuiCallback,context:pointer):cint {.cdecl.}
    run*:proc(data:ptr uint8,len:csize_t,callback:GpuiCallback,context:pointer):cint {.cdecl.}
const GpuiLibraryName* = when defined(windows):"leaf_gpui.dll"
  elif defined(macosx):"libleaf_gpui.dylib"
  else:"libleaf_gpui.so"
const FrameworkRoot* = currentSourcePath().parentDir.parentDir.parentDir
var cachedApi:GpuiApi
var cachedOverride:string
var cachedSelection:string
proc loadGpui*(path=""):GpuiApi =
  let selection=getEnv("LEAF_GPUI_ABI","auto")
  if selection notin ["auto","1","2"]:fail("LEAF_GPUI_ABI must be auto, 1 or 2")
  if cachedApi!=nil and path.len==0 and cachedOverride==getEnv("LEAF_GPUI_LIBRARY") and cachedSelection==selection:return cachedApi
  let override=if path.len>0:path else:getEnv("LEAF_GPUI_LIBRARY")
  let installed = sdkRoot()
  let candidates=if override.len>0: @[override] else: @[
    getAppDir()/GpuiLibraryName] & (if installed.len > 0: @[
      installed/"lib"/GpuiLibraryName] else: @[
      FrameworkRoot/"target/release"/GpuiLibraryName, FrameworkRoot/"target/debug"/GpuiLibraryName])
  var failures: seq[string]
  for name in candidates:
    var error: string
    let library=openNativeLibrary(name, error)
    if library==nil:
      failures.add(name & " (" & error & ")")
      continue
    let abi=cast[typeof(result.abi)](symAddr(library,"leaf_gpui_abi_version"))
    let run=cast[typeof(result.run)](symAddr(library,"leaf_gpui_run"))
    let frames=cast[typeof(result.frames)](symAddr(library,"leaf_gpui_run_frames"))
    if abi==nil or run==nil or abi()!=1:
      unloadLib(library)
      fail("incompatible GPUI bridge: " & name)
    result=GpuiApi(library:library,abi:abi,run:run,frames:frames)
    result.taskPumpVersion=cast[typeof(result.taskPumpVersion)](symAddr(library,"leaf_gpui_task_pump_version"))
    if selection!="1":
      type QueryV2=proc(abi:uint32,api:ptr LeafGpuiApiV2,size:uint64,error:ptr LeafError):int32 {.cdecl.}
      let query=cast[QueryV2](symAddr(library,"leaf_gpui_query_v2"))
      if query==nil:
        if selection=="2":
          unloadLib(library)
          fail("GPUI ABI 2 entry is missing: " & name)
      else:
        var table:LeafGpuiApiV2
        var bytes:array[1024,uint8]
        var error=LeafError(`ptr`:addr bytes[0],capacity:uint64(bytes.len))
        let status=query(2,addr table,uint64(sizeof(table)),addr error)
        if status!=0 or table.struct_size!=uint32(sizeof(table)) or table.abi!=2 or table.run==nil:
          unloadLib(library)
          fail("incompatible GPUI ABI 2 contract: " & name)
        result.v2=some(table)
    if path.len==0:
      cachedApi=result
      cachedOverride=getEnv("LEAF_GPUI_LIBRARY")
      cachedSelection=selection
    return
  fail("GPUI bridge could not be loaded: " & failures.join(", ") &
    "; run cargo build -p leaf-gpui or set LEAF_GPUI_LIBRARY")

proc supportsTaskPump*(api:GpuiApi):bool=
  if api==nil:return false
  if api.v2.isSome:(api.v2.get.capabilities and LEAF_CAP_TASK_PUMP)!=0
  else:api.taskPumpVersion!=nil and api.taskPumpVersion()==1
