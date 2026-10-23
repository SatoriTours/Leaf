## Guarded C ABI for a retained mobile owner. Numeric IDs are registry keys,
## never Nim pointers. All entry points require the initialization UI thread.
## Startup/close failures keep their cleanup owner addressable by the same ID.
import std/[tables, math]
import ../../[core, backend, backend_session, mobile_host, native_layout, native_edit, native_ffi, navigation_protocol, app_resources]
import ./[backend, wire, list_protection]

type
  AndroidCommand* = proc(context:pointer, tag:uint32, data:ptr uint8, length:csize_t,
    width,height:cdouble, measured:ptr cdouble): int32 {.cdecl, raises:[].}
  AndroidCallbacks* {.bycopy.} = object
    abiVersion*, structSize*: uint32
    context*: pointer
    command*: AndroidCommand
  AndroidBackFact* {.bycopy.} = object
    session*, mount*, handle*, binding*, sequence*, revision*, request*: uint64
    router*, history*, current*, previous*: uint64
    depth*, phase*: uint32
  AndroidAssetRead* = proc(context:pointer, path:ptr uint8, length:csize_t,
    output:ptr uint8, capacity:csize_t, actual:ptr csize_t):int32 {.cdecl, raises:[].}
  AndroidResources* {.bycopy.} = object
    abiVersion*, structSize*:uint32
    context*:pointer
    readAsset*:AndroidAssetRead
    dataDirectory*:ptr uint8
    dataLength*:csize_t
    cacheDirectory*:ptr uint8
    cacheLength*:csize_t
  ResourceApplicationFactory* = proc(resources:HostResources):Application {.closure.}
  Owner = ref object
    resources: HostResources
    host: MobileHost
    cleanup: Runtime
    platform: AndroidPlatform
    orphan: Backend
    adapter: AndroidAdapter
    resumed: bool
    turning: bool

const
  AndroidRejected* = 5'i32
  AndroidFailure* = 6'i32
  AndroidResume* = 1'u32
  AndroidPause* = 2'u32
  AndroidTurn* = 3'u32
  AndroidDetach* = 4'u32

var factory: ApplicationFactory
var resourceFactory: ResourceApplicationFactory
var uiThread: int
var nextId: uint64
var owners: Table[uint64,Owner]
proc registerAndroidApplication*(value: ApplicationFactory) =
  if value == nil or factory != nil or resourceFactory != nil: fail("Android factory must be registered exactly once")
  factory = value
  uiThread = getThreadId()
proc registerAndroidApplication*(value: ResourceApplicationFactory) =
  if value == nil or factory != nil or resourceFactory != nil: fail("Android factory must be registered exactly once")
  resourceFactory = value
  uiThread = getThreadId()
proc onOwner(): bool {.raises:[].} =
  (factory != nil or resourceFactory != nil) and getThreadId() == uiThread

when defined(android):
  {.passL: "-landroid".} # Native AssetManager operations used by the JNI Host.


proc platform(callbacks: AndroidCallbacks): AndroidPlatform =
  result.withControls=callbacks.abiVersion>=3
  result.withLists=callbacks.abiVersion>=4
  result.withNavigation=callbacks.abiVersion>=5
  proc command(tag: uint32, payload = "", width=0.0,height=0.0,
               measured:ptr cdouble=nil) =
    let data = if payload.len == 0: nil else: cast[ptr uint8](unsafeAddr payload[0])
    if callbacks.command(callbacks.context,tag,data,csize_t(payload.len),width,height,measured) != 0:
      fail("Android native command failed: " & $tag)
  result.measure = proc(entity: MountedEntity, available: DipSize): DipSize =
    var size: array[2,cdouble]
    command(1, encodeAndroidMeasure(entity,callbacks.abiVersion>=3,callbacks.abiVersion>=4,callbacks.abiVersion>=5), available.width, available.height, addr size[0])
    for value in size:
      if classify(value) in {fcNan,fcInf,fcNegInf} or value < 0:
        fail("Android measurement is not finite and nonnegative")
    DipSize(width:size[0],height:size[1])
  result.stage = proc(frame:AndroidFrame) = command(2,encodeAndroidFrame(frame))
  result.apply = proc() = command(3)
  result.discardStage = proc() = command(4)
  result.restore = proc(frame:AndroidFrame) = command(5,encodeAndroidFrame(frame))
  if callbacks.abiVersion>=4:
    result.restoreGeometry = proc(frame:AndroidFrame) = command(12,encodeAndroidFrame(frame))
  result.rebind = proc(session,mount:uint64) =
    command(6,encodeAndroidFrame(AndroidFrame(session:session,mount:mount)))
  result.dispose = proc() = command(7)
  if callbacks.abiVersion>=2:
    result.editEffects = proc(write:AndroidEditorWrite) =
      command(8,encodeAndroidFrame(AndroidFrame(editorWrites: @[write],withControls:callbacks.abiVersion>=3)))
    result.editorsActive = proc(active:bool) = command(if active: 9'u32 else: 10'u32)
    result.editorSelection = proc(handle:NodeHandle):Selection16 =
      var values:array[2,cdouble]
      command(11,encodeAndroidFrame(AndroidFrame(ops: @[UpdateOp(kind:opUpdate,handle:handle)])),
        measured=addr values[0])
      for value in values:
        if classify(value) in {fcNan,fcInf,fcNegInf} or value<0 or value>float64(high(int32)) or floor(value)!=value:
          fail("Android selection is not a nonnegative UTF16 position")
      Selection16(anchor:int(values[0]),caret:int(values[1]))

proc createOwner(callbacks:ptr AndroidCallbacks, output:ptr uint64,
    resources:HostResources=nil):int32 {.raises:[].} =
  if not onOwner() or callbacks == nil or output == nil or output[] != 0 or
      callbacks.abiVersion notin [1'u32,2'u32,3'u32,4'u32,5'u32] or callbacks.structSize != uint32(sizeof(AndroidCallbacks)) or
      callbacks.command == nil: return 1
  if resourceFactory != nil and resources == nil: return AndroidRejected
  if nextId == high(uint64): return AndroidFailure
  inc nextId
  let id = nextId
  try:
    let slot = Owner(platform:platform(callbacks[]), resources:resources)
    owners[id] = slot
    try:
      var build = factory
      if resourceFactory != nil:
        build = proc():Application = resourceFactory(resources)
      slot.host = newMobileHost(build)
      output[] = id
      return 0
    except RuntimeCleanupError as error:
      slot.cleanup = error.cleanupRuntime
      if slot.cleanup != nil: output[] = id
      else: owners.del(id)
      return AndroidFailure
    except Exception:
      owners.del(id)
      return AndroidFailure
  except Exception: return AndroidFailure

proc leaf_android_create*(callbacks:ptr AndroidCallbacks, output:ptr uint64):int32
    {.exportc,dynlib,cdecl,raises:[].} =
  createOwner(callbacks,output)

proc resourcePath(data:ptr uint8,length:csize_t):string =
  if length == 0 or length > csize_t(MaxResourcePathBytes): fail("invalid resource root length")
  var owned:NativeBytes
  if leaf_native_utf8_copy(data,length,addr owned) != NativeOk: fail("invalid resource root UTF8")
  defer:leaf_native_bytes_release(addr owned)
  result=newString(int(length))
  copyMem(addr result[0],owned.data,int(length))
  if '\0' in result: fail("resource root contains NUL")

proc leaf_android_create_with_resources*(callbacks:ptr AndroidCallbacks,
    input:ptr AndroidResources, output:ptr uint64):int32
    {.exportc,dynlib,cdecl,raises:[].} =
  if not onOwner() or input == nil or input.abiVersion != 1 or
      input.structSize != uint32(sizeof(AndroidResources)) or input.readAsset == nil or
      output == nil or output[] != 0: return 1
  var resources:HostResources
  try:
    let dataRoot=resourcePath(input.dataDirectory,input.dataLength)
    let cacheRoot=resourcePath(input.cacheDirectory,input.cacheLength)
    let read=input.readAsset
    let context=input.context # Copy callback/context only; no borrowed path slots.
    resources=newHostResources(proc(relative:string,maxBytes:int):string =
      let path=cast[ptr uint8](unsafeAddr relative[0])
      var length:csize_t
      if read(context,path,csize_t(relative.len),nil,0,addr length) != 0:
        fail("Android asset length query failed")
      if length > csize_t(maxBytes): fail("Android asset exceeds byte budget")
      result=newString(int(length))
      let output=if length==0:nil else:cast[ptr uint8](addr result[0])
      var actual:csize_t
      if read(context,path,csize_t(relative.len),output,length,addr actual) != 0 or actual != length:
        fail("Android asset read failed or length changed"), dataRoot,cacheRoot)
  except Exception: return 1
  result=createOwner(callbacks,output,resources)
  if output[] == 0:
    try: resources.close()
    except Exception: discard

proc leaf_android_attach*(id:uint64,width,height,scale:cdouble,output:ptr uint64):int32
    {.exportc,dynlib,cdecl,raises:[].} =
  if not onOwner() or not owners.hasKey(id) or output == nil or output[] != 0: return 1
  let slot = owners.getOrDefault(id)
  try:
    if slot.host == nil or slot.orphan != nil or slot.host.state != mobileDetached: return AndroidRejected
    # Even invalid geometry has a native context whose ownership was transferred
    # by the caller. Keep a backend owner until its dispose has succeeded.
    slot.orphan = Backend(dispose:slot.platform.dispose)
    slot.adapter = newAndroidAdapter(slot.platform,DipSize(width:width,height:height),scale)
    let native = slot.adapter.protocol
    slot.orphan = native
    try:
      output[] = slot.host.attach(native,width,height,scale).generation
      slot.orphan = nil # BackendSession is now its authoritative cleanup owner.
      return 0
    finally:
      let mount = slot.host.currentMount
      if slot.host.backendSession(mount) != nil:
        output[] = mount.generation
        slot.orphan = nil
  except Exception:
    if slot.orphan != nil:
      try:
        slot.orphan.dispose()
        slot.orphan = nil
      except Exception: discard # Kept for explicit close; never forgotten.
    return AndroidFailure

proc leaf_android_phase*(id,mount:uint64,phase:uint32):int32
    {.exportc,dynlib,cdecl,raises:[].} =
  if not onOwner() or not owners.hasKey(id): return AndroidRejected
  let slot = owners.getOrDefault(id)
  if slot.host == nil or slot.turning: return AndroidRejected
  slot.turning=true
  defer:slot.turning=false
  try:
    let token = MobileMount(hostIdentity:slot.host.identity,generation:mount)
    var accepted:bool
    proc editorEffects(body:proc() {.closure.}) =
      try: body()
      except CatchableError as error:
        let session=slot.host.backendSession(token)
        if session!=nil and slot.adapter!=nil:
          session.faultBackendEffects(slot.adapter.protocol,"Android editor effects failed: " & error.msg)
        raise
    case phase
    of AndroidResume:
      accepted = slot.host.resume(token)
      if accepted:
        slot.resumed=true
        editorEffects(proc() = slot.adapter.setEditorsActive(true))
    of AndroidPause:
      accepted = slot.host.pause(token)
      if accepted:
        slot.resumed=false
        editorEffects(proc() = slot.adapter.setEditorsActive(false))
    of AndroidTurn:
      # Pending reset bindings block old queued events. Flush only after a real
      # foreground turn; paused/stale calls must produce no native effects.
      let session=slot.host.backendSession(token)
      if session!=nil and slot.resumed and slot.host.state==mobileAttached and
          not session.disposed and not session.closing and not session.faulted and
          not session.frozen and not session.runtime.eventsFrozen:
        # Replace an earlier unprotected request before safeTurn consumes it.
        # This only queues data, including a retry after queue backpressure.
        discard slot.adapter.queueProtectionViewports(session)
      accepted = slot.host.safeTurn(token)
      if accepted and slot.resumed and slot.host.state==mobileAttached and not session.faulted:
        try:
          discard slot.adapter.flushListGeometry()
        except AndroidListGeometryError as error:
          if error.recoveryFailed:
            session.faultBackendEffects(slot.adapter.protocol,"Android list geometry replay failed: " & error.msg)
          raise
        except Defect:
          session.faultBackendEffects(slot.adapter.protocol,"Android list geometry contract failed")
          raise
        # No loop: a fact recorded here is materialized on a later ordinary
        # turn. Native bind/layout callbacks never invoke the row builder.
        discard slot.adapter.queueListViewports(session)
        editorEffects(proc() = slot.adapter.flushEditorEffects())
    of AndroidDetach:
      accepted = slot.host.detach(token)
      if accepted:
        slot.adapter=nil
        slot.resumed=false
    else: return 1
    if accepted: 0 else: AndroidRejected
  except Exception: AndroidFailure

proc leaf_android_back*(id,activityMount:uint64,fact:ptr AndroidBackFact):int32
    {.exportc,dynlib,cdecl,raises:[].} =
  if not onOwner() or not owners.hasKey(id) or fact==nil: return AndroidRejected
  let slot=owners.getOrDefault(id)
  if slot.host==nil or not slot.platform.withNavigation or not slot.resumed or
      fact.phase>uint32(ord(high(NavigationBackPhase))) or fact.depth>uint32(MaxNodes):
    return AndroidRejected
  try:
    let owned=NavigationBackFact(sessionId:fact.session,mountGeneration:fact.mount,
      handle:fact.handle,bindingGeneration:fact.binding,sequence:fact.sequence,
      observedRevision:fact.revision,requestId:fact.request,
      navigation:HostNavigationProps(routerId:fact.router,historyRevision:fact.history,
        currentEntryId:fact.current,previousEntryId:fact.previous,depth:int(fact.depth)),
      phase:NavigationBackPhase(fact.phase))
    let token=MobileMount(hostIdentity:slot.host.identity,generation:activityMount)
    if slot.host.queueNavigation(token,owned): 0 else: AndroidRejected
  except Exception: AndroidFailure

proc leaf_android_scroll*(id,activityMount,session,eventMount,handle,sequence,
    revision,sourceGeneration:uint64,offset:cdouble):int32
    {.exportc,dynlib,cdecl,raises:[].} =
  if not onOwner() or not owners.hasKey(id):return AndroidRejected
  let slot=owners.getOrDefault(id)
  if slot.host==nil or slot.adapter==nil or not slot.resumed:return AndroidRejected
  try:
    if slot.host.state!=mobileAttached:return AndroidRejected
    let token=MobileMount(hostIdentity:slot.host.identity,generation:activityMount)
    let current=slot.host.backendSession(token)
    if current==nil or current.disposed or current.closing or current.faulted or current.frozen or
        current.runtime.eventsFrozen or not current.ownsBackend(slot.adapter.protocol) or
        current.sessionId!=session or current.mountGeneration!=eventMount or
        revision>current.runtime.acceptedRevision:return AndroidRejected
    if slot.adapter.recordListOffset(NodeHandle(handle),sourceGeneration,eventMount,sequence,offset):0
    else:AndroidRejected
  except Exception:AndroidFailure

proc leaf_android_protect*(id,activityMount,session,eventMount,handle,sequence,
    revision,binding:uint64,reasons:uint32):int32
    {.exportc,dynlib,cdecl,raises:[].} =
  if not onOwner() or not owners.hasKey(id) or reasons>3:return AndroidRejected
  let slot=owners.getOrDefault(id)
  if slot.host==nil or slot.adapter==nil or not slot.resumed:return AndroidRejected
  try:
    if slot.host.state!=mobileAttached:return AndroidRejected
    let token=MobileMount(hostIdentity:slot.host.identity,generation:activityMount)
    let current=slot.host.backendSession(token)
    if current==nil or current.disposed or current.closing or current.faulted or current.frozen or
        current.runtime.eventsFrozen or not current.ownsBackend(slot.adapter.protocol) or
        current.sessionId!=session or current.mountGeneration!=eventMount or
        revision>current.runtime.acceptedRevision:return AndroidRejected
    var mask:set[AndroidProtectionReason]
    if (reasons and 1)!=0:mask.incl(rowFocused)
    if (reasons and 2)!=0:mask.incl(rowComposing)
    if not slot.adapter.recordRowProtection(NodeHandle(handle),eventMount,sequence,binding,mask):
      return AndroidRejected
    discard slot.adapter.queueProtectionViewports(current)
    0
  except Exception:AndroidFailure

proc leaf_android_input*(id,activityMount,session,eventMount,handle,sequence,revision,binding:uint64,
    kind:uint32,data:ptr uint8,length:csize_t,phase:uint32,anchor,caret:int32):int32
    {.exportc,dynlib,cdecl,raises:[].} =
  if not onOwner() or not owners.hasKey(id) or kind notin [uint32(ord(change)),uint32(ord(submit))] or
      phase>uint32(ord(high(CompositionPhase))) or anchor<0 or caret<0: return AndroidRejected
  let slot=owners.getOrDefault(id)
  if slot.host==nil or slot.adapter==nil: return AndroidRejected
  if slot.adapter.isCheckedControl(NodeHandle(handle)): return AndroidRejected
  var owned:NativeBytes
  let copied=leaf_native_utf8_copy(data,length,addr owned)
  if copied!=NativeOk: return copied
  try:
    var value=newString(int(owned.length))
    if owned.length>0: copyMem(addr value[0],owned.data,int(owned.length))
    let event=Event(kind:EventKind(kind),value:value,composition:CompositionPhase(phase))
    let selection=Selection16(anchor:int(anchor),caret:int(caret))
    let key=NodeHandle(handle)
    if not slot.adapter.canObserveInput(key,sequence,event,selection): return AndroidRejected
    let token=MobileMount(hostIdentity:slot.host.identity,generation:activityMount)
    if not slot.host.enqueue(token,EventEnvelope(session:session,mountGeneration:eventMount,
        handle:key,sequence:sequence,observedRevision:revision,bindingGeneration:binding,event:event)):
      return AndroidRejected
    # enqueue only records data; no business/platform code runs between this
    # validation and observation. Rejected epochs never mutate editor facts.
    if not slot.adapter.observeInput(key,sequence,event,selection): return AndroidFailure
    0
  except Exception: AndroidFailure
  finally: leaf_native_bytes_release(addr owned)

proc leaf_android_event*(id,activityMount,session,eventMount,handle,sequence,revision,binding:uint64,
                        kind:uint32):int32 {.exportc,dynlib,cdecl,raises:[].} =
  if not onOwner() or not owners.hasKey(id) or kind != uint32(ord(click)): return AndroidRejected
  let slot = owners.getOrDefault(id)
  if slot.host == nil: return AndroidRejected
  try:
    let token = MobileMount(hostIdentity:slot.host.identity,generation:activityMount)
    if slot.host.enqueue(token,EventEnvelope(session:session,mountGeneration:eventMount,
        handle:NodeHandle(handle),sequence:sequence,observedRevision:revision,bindingGeneration:binding,
        event:Event(kind:click))): 0 else: AndroidRejected
  except Exception: AndroidFailure

proc leaf_android_checked*(id,activityMount,session,eventMount,handle,sequence,revision,binding:uint64,
    checked:uint32):int32 {.exportc,dynlib,cdecl,raises:[].} =
  if not onOwner() or not owners.hasKey(id) or checked>1: return AndroidRejected
  let slot=owners.getOrDefault(id)
  let key=NodeHandle(handle)
  if slot.host==nil or slot.adapter==nil or not slot.adapter.isCheckedControl(key): return AndroidRejected
  try:
    let event=Event(kind:change,checked:checked==1)
    if not slot.adapter.canObserveInput(key,sequence,event,Selection16()): return AndroidRejected
    let token=MobileMount(hostIdentity:slot.host.identity,generation:activityMount)
    if not slot.host.enqueue(token,EventEnvelope(session:session,mountGeneration:eventMount,
        handle:key,sequence:sequence,observedRevision:revision,bindingGeneration:binding,event:event)):
      return AndroidRejected
    if not slot.adapter.observeInput(key,sequence,event,Selection16()): return AndroidFailure
    0
  except Exception: AndroidFailure

proc leaf_android_close*(id:uint64):int32 {.exportc,dynlib,cdecl,raises:[].} =
  if not onOwner() or not owners.hasKey(id): return AndroidRejected
  let slot = owners.getOrDefault(id)
  if slot.turning:return AndroidRejected
  try:
    if slot.orphan != nil:
      slot.orphan.dispose()
      slot.orphan = nil
    if slot.host != nil: slot.host.close()
    elif slot.cleanup != nil: slot.cleanup.closeRuntime()
    if slot.resources != nil: slot.resources.close()
    owners.del(id)
    0
  except Exception: AndroidFailure
