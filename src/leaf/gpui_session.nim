## Typed, synchronous ABI 2 owner. All returned buffers are copied by Rust
## before the next request; no exception crosses the C calling convention.
import std/[options, unicode, os, math, tables, json]
import ./[core, backend, host_session, gpui_api, gpui_ffi_v2, watch_ipc,managed_runtime,task_contracts]
type
  GpuiSession* = ref object
    runtime*:Runtime
    api:GpuiApi
    host:HostSession
    renderer:LeafRendererApi
    rendererCtx:pointer
    id,hostOwnerToken:uint64
    taskCapable,tasksReady:bool
    running,detached,installed:bool
    lastError,viewportError,externalError:string
    renderingRecorded:bool
    lastRendering:tuple[scale,width,height:float64]
    readyCalls*:int
    onFrame*:proc(sample:LeafFrameSample):bool {.closure.}
    preparerToken:uint64
    viewports:Table[string,seq[string]]
    rowKeys:seq[string]
    rows:seq[LeafRow]
var nextSession:uint64
proc writeError(error:ptr LeafError,message:string) {.raises:[].}=
  if error==nil:return
  error.written=0
  if error.`ptr`==nil:return
  var length=min(uint64(message.len),error.capacity).int
  while length>0 and length<message.len and (uint8(message[length]) and 0xc0)==0x80:dec length
  if length>0:copyMem(error.`ptr`,unsafeAddr message[0],length)
  error.written=uint64(length)
proc checkedBytes(value:LeafBytes):string=
  if value.len>uint64(MaxStringBytes) or (value.len>0 and value.`ptr`==nil):fail("invalid ABI 2 string")
  result=newString(int(value.len))
  if result.len>0:copyMem(addr result[0],value.`ptr`,result.len)
  if validateUtf8(result)!= -1:fail("invalid ABI 2 UTF-8")
proc rendererError(status:int32,bytes:array[2048,uint8],error:LeafError)=
  if status==0:return
  var message=newString(int(min(error.written,uint64(bytes.len))))
  if message.len>0:copyMem(addr message[0],unsafeAddr bytes[0],message.len)
  fail("GPUI host rejected batch (" & $status & "): " & message)
proc attach(ctx:pointer,api:ptr LeafRendererApi,rendererCtx:pointer,error:ptr LeafError):int32 {.cdecl,raises:[].}=
  let session=cast[GpuiSession](ctx)
  try:
    if session==nil or session.detached or session.host!=nil or api==nil or api.abi!=2 or
        api.struct_size!=uint32(sizeof(LeafRendererApi)) or api.prepare==nil or api.apply==nil or
        api.accept==nil or api.`discard`==nil:fail("incompatible renderer callbacks")
    session.renderer=api[];session.rendererCtx=rendererCtx
    let sink=HostConsumer(sessionId:session.id)
    sink.prepare=proc(batch:HostBatch)=
      var owned=encodeBatch(batch)
      session.runtime.recordFfiBytes(owned.wireBytes)
      var bytes:array[2048,uint8]
      var error=LeafError(`ptr`:addr bytes[0],capacity:uint64(bytes.len))
      let status=session.renderer.prepare(session.rendererCtx,owned.borrow(),addr error)
      rendererError(status,bytes,error)
    sink.apply=proc()=
      var bytes:array[2048,uint8]
      var error=LeafError(`ptr`:addr bytes[0],capacity:uint64(bytes.len))
      let status=session.renderer.apply(session.rendererCtx,addr error)
      rendererError(status,bytes,error)
    sink.accept=proc(revision:uint64) {.raises:[].}=session.renderer.accept(session.rendererCtx,revision)
    sink.discardPrepared=proc() {.raises:[].}=session.renderer.`discard`(session.rendererCtx)
    session.host=attachHostSession(session.runtime,sink)
    session.hostOwnerToken=session.runtime.committerOwner
    # Managed candidates retain accepted rows and restore changed sources
    # transactionally in the driver. Only legacy root renders need replay.
    if not session.runtime.managed:
      session.preparerToken=session.runtime.installPreparer(proc(candidate:Runtime)=
        for id,keys in session.viewports:
          var target:MountedNode
          try:target=candidate.find(id)
          except UiError:continue
          let source=target.node.listSource
          if source==nil:continue
          var indices:Table[string,int]
          for index in 0..<source.len:indices[source.itemKey(index)]=index
          var active:seq[int]
          for key in keys:
            if indices.hasKey(key):active.add(indices[key])
          if active.len>0:discard candidate.materialize(id,0,0,active))
    session.installed=true
    0
  except Exception as failure:
    if session!=nil:session.lastError=failure.msg
    writeError(error,failure.msg)
    int32(LEAF_STATUS_REJECTED)
proc viewportRows(session:GpuiSession,handle:NodeHandle,reply:ptr LeafReply)=
  let record=session.host.record(handle)
  if record.isNone:fail("unknown accepted list handle")
  let accepted=session.runtime.find(record.get.nodeId)
  let source=accepted.node.listSource
  if source==nil:fail("accepted viewport target is not a list")
  session.rows.setLen(0);session.rowKeys.setLen(0)
  for child in accepted.children:session.rowKeys.add(source.itemKey(child.listIndex))
  for i,child in accepted.children:
    let key=session.rowKeys[i]
    session.rows.add(LeafRow(handle:session.host.handleFor(child.id).raw,index:uint64(child.listIndex),
      key:LeafBytes(`ptr`:(if key.len==0:nil else:cast[ptr uint8](unsafeAddr session.rowKeys[i][0])),len:uint64(key.len))))
  session.viewports[record.get.nodeId]=session.rowKeys
  reply.rows_len=uint64(session.rows.len)
  reply.rows=if session.rows.len==0:nil else:addr session.rows[0]
  session.viewportError=""
proc request(ctx:pointer,raw:ptr LeafRequest,reply:ptr LeafReply,error:ptr LeafError):int32 {.cdecl,raises:[].}=
  let session=cast[GpuiSession](ctx)
  let before=if session==nil:0'u64 else:session.runtime.acceptedRevision
  try:
    if session==nil or session.detached or session.host==nil or raw==nil or reply==nil or
        raw.struct_size!=uint32(sizeof(LeafRequest)) or reply.struct_size!=uint32(sizeof(LeafReply)):
      fail("invalid typed request")
    if raw.session_id!=session.id:fail("foreign request session")
    reply[]=LeafReply(struct_size:uint32(sizeof(LeafReply)),accepted_revision:before)
    case raw.tag
    of uint32(LEAF_REQUEST_TASKS):
      if not session.taskCapable or not session.tasksReady:fail("typed task pump was not negotiated")
      let report=session.runtime.pumpTasks()
      if report.failed>0:fail("task delivery failed; see lifecycle diagnostics")
      session.lastError=""
    of uint32(LEAF_REQUEST_EVENT):
      if raw.kind>uint32(ord(high(EventKind))) or raw.composition>uint32(ord(high(CompositionPhase))) or raw.checked>1:
        fail("invalid event enum")
      let dispatched=session.host.dispatch(NodeHandle(raw.handle),raw.sequence,raw.revision,raw.generation,raw.binding_generation,
        Event(kind:EventKind(raw.kind),composition:CompositionPhase(raw.composition),checked:raw.checked==1,value:checkedBytes(raw.value)))
      if not dispatched:reply.status=uint32(LEAF_STATUS_STALE)
      session.lastError=""
    of uint32(LEAF_REQUEST_VIEWPORT):
      let record=session.host.record(NodeHandle(raw.handle))
      if record.isNone or record.get.props.list.isNone or record.get.props.list.get.sourceGeneration!=raw.generation:
        fail("stale viewport source")
      if raw.first>raw.finish or raw.finish>uint64(MaxListItems) or raw.protected_len>uint64(MaxNodes) or
          (raw.protected_len>0 and raw.protected_rows==nil):fail("invalid viewport range")
      let target=session.runtime.find(record.get.nodeId)
      let source=target.node.listSource
      var protected:seq[int]
      let entries=cast[ptr UncheckedArray[LeafProtected]](raw.protected_rows)
      for i in 0..<int(raw.protected_len):
        let key=checkedBytes(entries[i].key)
        if entries[i].index<uint64(source.len) and source.itemKey(int(entries[i].index))==key:protected.add(int(entries[i].index))
        else:
          for index in 0..<source.len:
            if source.itemKey(index)==key:protected.add(index);break
      discard session.runtime.materialize(record.get.nodeId,int(raw.first),int(raw.finish),protected)
      session.viewportRows(NodeHandle(raw.handle),reply)
    of uint32(LEAF_REQUEST_READY):
      if session.lastError.len>0 or session.viewportError.len>0:fail("initial typed viewport failed")
      let path=getEnv("LEAF_WATCH_READY")
      if path.len>0:writeReady(path,getEnv("LEAF_WATCH_TOKEN"),getCurrentProcessId())
      inc session.readyCalls
      session.tasksReady=session.taskCapable
    of uint32(LEAF_REQUEST_STATUS):
      let status=readStatus(getEnv("LEAF_WATCH_STATUS"))
      if status.valid:
        session.externalError=status.message
        reply.flags=2
        reply.value=LeafBytes(`ptr`:(if session.externalError.len==0:nil else:cast[ptr uint8](unsafeAddr session.externalError[0])),
          len:uint64(session.externalError.len))
    of uint32(LEAF_REQUEST_LOCATE):
      let record=session.host.record(NodeHandle(raw.handle))
      if record.isNone:fail("unknown list handle")
      let source=session.runtime.find(record.get.nodeId).node.listSource
      if source==nil:fail("locate target is not a list")
      let key=checkedBytes(raw.value)
      reply.x= -1
      for i in 0..<source.len:
        if source.itemKey(i)==key:reply.x=float64(i);break
    of uint32(LEAF_REQUEST_RENDERING),uint32(LEAF_REQUEST_FRAME):
      if not (raw.scale>0 and raw.width>0 and raw.height>0) or classify(raw.scale) in {fcNan,fcInf,fcNegInf} or
          classify(raw.width) in {fcNan,fcInf,fcNegInf} or classify(raw.height) in {fcNan,fcInf,fcNegInf}:
        fail("invalid rendering dimensions")
      if raw.tag==uint32(LEAF_REQUEST_RENDERING):
        let deviceWidth=raw.width*raw.scale
        let deviceHeight=raw.height*raw.scale
        let dpi=96.0*raw.scale
        for n in [deviceWidth,deviceHeight,dpi]:
          if not (n>0) or classify(n) in {fcNan,fcInf,fcNegInf}:fail("invalid calculated rendering dimensions")
        let dimensions=(scale:raw.scale,width:raw.width,height:raw.height)
        if not session.renderingRecorded or dimensions!=session.lastRendering:
          session.runtime.diagnostic("rendering","ok",%*{
            "scale_factor":raw.scale,
            "logical_size":{"width":raw.width,"height":raw.height},
            "device_size_calculated":{"width":deviceWidth,"height":deviceHeight},
            "dpi_from_scale_calculated":dpi})
          session.lastRendering=dimensions
          session.renderingRecorded=true
      if raw.tag==uint32(LEAF_REQUEST_FRAME) and session.onFrame!=nil:
        if raw.value.len!=uint64(sizeof(LeafFrameSample)) or raw.value.`ptr`==nil:fail("invalid frame sample")
        var sample:LeafFrameSample
        copyMem(addr sample,raw.value.`ptr`,sizeof(sample))
        for n in [sample.elapsed_ms,sample.draw_ms,sample.rust_prepare_ms,sample.rust_apply_ms]:
          if n<0 or classify(n) in {fcNan,fcInf,fcNegInf}:fail("invalid frame timing")
        if session.onFrame(sample):reply.flags=1
    else:fail("unknown typed request")
    reply.accepted_revision=session.runtime.acceptedRevision
    if session.taskCapable and session.runtime.taskPumpPending():reply.flags=reply.flags or LEAF_REPLY_TASKS_PENDING
    int32(reply.status)
  except Exception as failure:
    if session!=nil:
      let phase=if raw!=nil and raw.tag==uint32(LEAF_REQUEST_RENDERING):"rendering" else:"gpui"
      try:session.runtime.diagnostic(phase,"error",%*{"message":failure.msg})
      except Exception:discard
    writeError(error,failure.msg)
    var status=uint32(LEAF_STATUS_REJECTED)
    if session!=nil:
      if raw!=nil and raw.tag==uint32(LEAF_REQUEST_VIEWPORT):session.viewportError=failure.msg
      elif raw==nil or raw.tag!=uint32(LEAF_REQUEST_RENDERING):session.lastError=failure.msg
      if session.runtime.acceptedRevision>before:
        status=uint32(LEAF_STATUS_ACCEPTED_SCOPE_ERROR)
        if raw!=nil and reply!=nil and raw.tag==uint32(LEAF_REQUEST_VIEWPORT):
          # Acceptance already published; return those rows without replaying
          # the builder when application scope cleanup reports an error.
          try:
            session.viewportRows(NodeHandle(raw.handle),reply)
            session.viewportError=failure.msg
          except Exception:discard
    if reply!=nil:
      reply.status=status
      if session!=nil:
        reply.accepted_revision=session.runtime.acceptedRevision
        try:
          if session.taskCapable and session.runtime.taskPumpPending():reply.flags=reply.flags or LEAF_REPLY_TASKS_PENDING
        except Exception:discard
    int32(status)
proc releaseSession(session:GpuiSession,terminal:bool) {.raises:[].}=
  if session==nil or session.detached:return
  let current=session.hostOwnerToken!=0 and session.runtime.committerOwner==session.hostOwnerToken
  session.detached=true
  session.tasksReady=false
  # Token equality protects a replacement binding from stale/late callbacks.
  if terminal and current and session.runtime.runtimeDriver!=nil:
    session.runtime.runtimeDriver.retireDeferred()
  session.runtime.retirePreparerOwner(session.preparerToken)
  session.host.retire()
  session.rendererCtx=nil
  session.renderer=default(LeafRendererApi)
proc detach(ctx:pointer) {.cdecl,raises:[].}=
  cast[GpuiSession](ctx).releaseSession(true)
proc openGpuiSession*(runtime:Runtime,api:GpuiApi):GpuiSession=
  if runtime==nil or api==nil or api.v2.isNone:fail("GPUI ABI 2 is unavailable")
  let capable=runtime.managed and api.supportsTaskPump()
  try:runtime.configureTaskPumpInternal(capable)
  except UiError as error:
    let message=error.msg & "; rebuild the GPUI bridge with task pump support"
    try:runtime.closeRuntime()
    except Exception as cleanup:
      try:runtime.diagnostic("gpui","error",%*{"message":"startup cleanup: " & cleanup.msg})
      except Exception:discard
    fail(message)
  inc nextSession
  GpuiSession(runtime:runtime,api:api,id:nextSession,taskCapable:capable)
proc run*(session:GpuiSession):int=
  if session.running or session.detached:fail("GPUI session already used")
  session.running=true
  defer:session.running=false
  let snapshot=session.runtime.applicationConfig
  var config=LeafConfig(struct_size:uint32(sizeof(LeafConfig)),session_id:session.id,width:uint32(snapshot.width),height:uint32(snapshot.height),
    title:LeafBytes(`ptr`:cast[ptr uint8](snapshot.title.cstring),len:uint64(snapshot.title.len)))
  if session.onFrame!=nil:config.flags=1
  if session.taskCapable:config.flags=config.flags or uint32(LEAF_CONFIG_TASK_PUMP)
  var callbacks=LeafHostCallbacks(struct_size:uint32(sizeof(LeafHostCallbacks)),attach:attach,request:request,detach:detach)
  var bytes:array[2048,uint8]
  var error=LeafError(`ptr`:addr bytes[0],capacity:uint64(bytes.len))
  try:result=int(session.api.v2.get.run(addr config,addr callbacks,cast[pointer](session),addr error))
  finally:
    session.releaseSession(false)
    if result!=0 and not session.installed:
      # Installation failed. Cleanup is outside the protected C attach.
      try:session.runtime.closeRuntime()
      except Exception as cleanup:
        try:session.runtime.diagnostic("gpui","error",%*{"message":"startup cleanup: " & cleanup.msg})
        except Exception:discard
proc close*(session:GpuiSession)=
  if session.running:fail("cannot close a running GPUI session outside detach")
  session.releaseSession(false)
