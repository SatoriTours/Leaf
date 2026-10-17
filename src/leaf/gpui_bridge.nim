## Nim owns application state and the response buffer. GPUI calls on the UI thread.
import std/[json,os,tables,math,strutils]
import ./[core,diagnostics,watch_ipc,gpui_styles,managed_runtime,task_contracts]
type
  ActiveRow = tuple[key:string,index:int]
  Viewports = ref object
    rows: Table[string,seq[ActiveRow]]
  DesktopBridge* = ref object
    runtime*: Runtime
    response: string
    error: string
    viewportError: string
    externalError: string
    viewports: Viewports
    taskCapable,tasksReady:bool

proc rejectNativeResetSignals*(root: MountedNode) =
  ## The legacy GPUI bridge has no native reset signal. Reject the new explicit
  ## non-zero token here without enforcing the full native control-attribute
  ## rules; `gpui_styles` remains style-only.
  if root.node.kind == NodeKind.input and
      "input_reset_token" in root.node.attributes:
    let raw = root.node.attributes["input_reset_token"]
    var token = 0'u64
    try:
      token = uint64(parseBiggestUInt(raw))
    except ValueError:
      fail("GPUI does not support input reset token: " & raw)
    if token != 0: fail("GPUI does not support input reset token: " & raw)
  for child in root.children: rejectNativeResetSignals(child)

proc bridgeValidator(snapshot: Snapshot) =
  validateStyles(snapshot.root)
  rejectNativeResetSignals(snapshot.root)

proc newDesktopBridge*(app:Application,diagnostics:Diagnostics=nil,taskPumpSupported=false):DesktopBridge =
  let viewports=Viewports()
  result=DesktopBridge(runtime:newRuntime(app,validator=bridgeValidator,diagnostics=diagnostics),viewports:viewports)
  try:
    result.taskCapable=result.runtime.managed and taskPumpSupported
    try:result.runtime.configureTaskPumpInternal(result.taskCapable)
    except UiError as error:fail(error.msg & "; rebuild the GPUI bridge with task pump support")
    # Validate the current viewports inside core's isolated candidate before an
    # event publishes a replacement source. Failure retains rows and callbacks.
    result.runtime.setPreparer(proc(candidate:Runtime) =
      proc visit(mounted:MountedNode) =
        let source=mounted.node.listSource
        if source!=nil and mounted.id in viewports.rows and source.len>0:
          var indices:Table[string,int]
          for i in 0..<source.len:indices[source.itemKey(i)]=i
          var active:seq[int]
          for row in viewports.rows[mounted.id]:
            active.add(indices.getOrDefault(row.key,min(row.index,source.len-1)))
          discard candidate.materialize(mounted.id,0,0,active)
        for child in mounted.children:visit(child)
      visit(candidate.snapshot.root))
  except Exception:
    # newRuntime has accepted its initial owners. Installation has unwound;
    # ordinary close invalidates State and runs only final disposal callbacks.
    try:result.runtime.closeRuntime()
    except Exception as cleanup:
      try:result.runtime.diagnostic("gpui","error",%*{"message":"startup cleanup: " & cleanup.msg})
      except Exception:discard
    raise

proc recordRendering(host:DesktopBridge, value:JsonNode):bool =
  # Copy only numeric diagnostics; never forward arbitrary payload/editor data.
  if value == nil or value.kind != JObject:return false
  proc number(node:JsonNode):bool =
    node != nil and node.kind in {JInt,JFloat} and
      classify(node.getFloat) notin {fcNan,fcInf,fcNegInf} and node.getFloat>0
  let scale=value.getOrDefault("scale_factor")
  let logical=value.getOrDefault("logical_size")
  let device=value.getOrDefault("device_size_calculated")
  let dpi=value.getOrDefault("dpi_from_scale_calculated")
  if not number(scale) or not number(dpi):return false
  for dimensions in [logical,device]:
    if dimensions == nil or dimensions.kind != JObject:return false
    if not number(dimensions.getOrDefault("width")) or not number(dimensions.getOrDefault("height")):return false
  host.runtime.diagnostic("rendering","ok",%*{
    "scale_factor":scale,
    "logical_size":{"width":logical["width"],"height":logical["height"]},
    "device_size_calculated":{"width":device["width"],"height":device["height"]},
    "dpi_from_scale_calculated":dpi})
  true

proc request*(host:DesktopBridge,message:JsonNode):JsonNode =
  var rows=newJArray()
  var located = -1
  var readySucceeded=false
  var diagnosticError=""
  let taskTick=message.getOrDefault("op").getStr=="tasks"
  let beforeOps=host.runtime.updateStats.ops
  try:
    case message["op"].getStr
    of "tasks":
      if not host.tasksReady:fail("GPUI task pump was not negotiated")
      let report=host.runtime.pumpTasks()
      if report.failed>0:fail("task delivery failed; see lifecycle diagnostics")
      host.error=""
    of "event":
      let kind=case message["kind"].getStr
        of "click":click
        of "change":change
        of "submit":submit
        else:fail("unknown GPUI event")
      discard host.runtime.dispatch(message["id"].getStr,Event(kind:kind,
        value:message.getOrDefault("value").getStr,checked:message.getOrDefault("checked").getBool))
      host.error=""
      var removed:seq[string]
      for id in host.viewports.rows.keys:
        try:
          if host.runtime.find(id).node.listSource==nil:removed.add(id)
        except UiError:removed.add(id)
      for id in removed:host.viewports.rows.del(id)
    of "list":
      var protected:seq[int]
      for index in message.getOrDefault("protected"):protected.add(index.getInt)
      let target=host.runtime.find(message["id"].getStr)
      let source=target.node.listSource
      let protectedKeys=message.getOrDefault("protected_keys")
      if protectedKeys != nil:
        for entry in protectedKeys:
          let key=entry["key"].getStr
          let index=entry["index"].getInt
          if index>=0 and index<source.len and source.itemKey(index)==key:protected.add(index)
          else:
            for i in 0..<source.len:
              if source.itemKey(i)==key:
                protected.add(i)
                break
      let items=host.runtime.materialize(message["id"].getStr,message["first"].getInt,message["finish"].getInt,protected)
      var active:seq[ActiveRow]
      for item in host.runtime.find(message["id"].getStr).children:
        active.add((source.itemKey(item.listIndex),item.listIndex))
      host.viewports.rows[target.id]=active
      for item in items:
        let value=item.toJson()
        value["item_key"] = %source.itemKey(item.listIndex)
        rows.add(value)
      host.viewportError=""
    of "locate":
      let source=host.runtime.find(message["id"].getStr).node.listSource
      for i in 0..<source.len:
        if source.itemKey(i)==message["key"].getStr:
          located=i
          break
    of "status":
      let status=readStatus(getEnv("LEAF_WATCH_STATUS"))
      if status.valid:host.externalError=status.message
    of "rendering":
      if not host.recordRendering(message.getOrDefault("rendering")):
        diagnosticError="invalid rendering diagnostics"
        host.runtime.diagnostic("rendering","error",%*{"message":diagnosticError})
    of "ready":
      if host.error.len>0 or host.viewportError.len>0:fail("GPUI initial viewport failed")
      let path=getEnv("LEAF_WATCH_READY")
      if path.len>0:writeReady(path,getEnv("LEAF_WATCH_TOKEN"),getCurrentProcessId())
      readySucceeded=true
      let sample=message.getOrDefault("rendering")
      if sample != nil:discard host.recordRendering(sample)
    else:fail("unknown GPUI request")
  except Exception as error:
    if message.getOrDefault("op").getStr=="rendering":diagnosticError=error.msg
    elif message.getOrDefault("op").getStr=="list":host.viewportError=error.msg
    else:host.error=error.msg
    host.runtime.diagnostic("gpui","error",%*{"message":error.msg})
  result = %*{"tasks_pending":host.runtime.taskPumpPending()}
  if not taskTick or host.runtime.updateStats.ops!=beforeOps:
    result["snapshot"]=host.runtime.snapshot.toJson()
    result["rows"]=rows
  if located>=0:result["index"] = %located
  let error=host.error & (if host.viewportError.len>0:"\n" & host.viewportError else:"") & (if host.externalError.len>0:"\n" & host.externalError else:"")
  if error.len>0:result["error"] = %error
  elif diagnosticError.len>0:result["error"] = %diagnosticError
  elif readySucceeded:
    host.tasksReady=host.taskCapable
    result["capabilities"] = %*{"rendering_diagnostics":true,"task_pump":host.tasksReady}

proc desktopCallback*(context:pointer,data:ptr uint8,len:csize_t):cstring {.cdecl.} =
  let host=cast[DesktopBridge](context)
  try:
    if data==nil or len>32*1024*1024:fail("invalid GPUI request buffer")
    var message=newString(int(len))
    if len>0:copyMem(addr message[0],data,int(len))
    host.response = $host.request(parseJson(message))
  except Exception as error:
    # Never unwind a Nim exception through Rust/C ABI.
    host.response = $(%*{"snapshot":host.runtime.snapshot.toJson(),"rows":[],"error":error.msg})
  host.response.cstring
