## Synchronous Android Views adapter. Only immutable typed operations and DIP
## geometry cross the platform seam; business closures stay in BackendSession.
## Containers, labels and buttons use the basic seam. Input/reset is enabled
## only by a platform that supplies the editor effects. A list platform must
## explicitly opt in to typed row geometry; the older ABI never gains it.
import std/[tables, algorithm, math, options]
import ../../[core, styles, backend, backend_session, native_layout, native_edit]
import ./[editors, list_layout, list_delivery, list_protection, protection_delivery]
export editors

type
  AndroidListGeometryError* = object of UiError
    recoveryFailed*: bool
  AndroidFrame* = object
    session*, mount*, revision*: uint64
    ops*: seq[UpdateOp]
    boxes*: seq[LayoutBox]
    editorWrites*: seq[AndroidEditorWrite]
    withControls*: bool
    withLists*: bool
    withNavigation*: bool
    listProjections*: seq[AndroidListProjection]
  AndroidPlatform* = object
    measure*: MeasureProc
    stage*: proc(frame: AndroidFrame) {.closure.}
    apply*, discardStage*, dispose*: proc() {.closure.}
    restore*: proc(frame: AndroidFrame) {.closure.}
    restoreGeometry*: proc(frame:AndroidFrame) {.closure.}
    rebind*: proc(session, mount: uint64) {.closure.}
    editEffects*: proc(write:AndroidEditorWrite) {.closure.}
    editorsActive*: proc(active:bool) {.closure.}
    editorSelection*: proc(handle:NodeHandle):Selection16 {.closure.}
    withControls*: bool
    withLists*: bool
    withNavigation*: bool
  PreparedFrame = ref object
    entities: Table[NodeHandle, MountedEntity]
    frame, replay: AndroidFrame
  AndroidState = ref object
    platform: AndroidPlatform
    size: DipSize
    session, mount: uint64
    accepted, pending, retired: PreparedFrame
    disposed: bool
    geometryFaulted: bool
    editors: AndroidEditors
    lists: AndroidLists
    protection: AndroidRowProtection
    protectionDelivery: AndroidProtectionDelivery
    scale: float64
    fontEpoch: uint64
  AndroidAdapter* = ref object
    protocol*: Backend
    state: AndroidState

proc androidCapabilities*(withEditors=false,withControls=false,withLists=false,withNavigation=false): BackendCapabilities =
  result=BackendCapabilities(kinds: {column, row, text, button},
    layouts: {lfGap, lfPadding, lfWidth, lfHeight, lfFlexGrow, lfAlign, lfJustify, lfOverflow},
    alignments: {alignStart, alignEnd, alignCenter, alignStretch},
    justifications: {justifyStart, justifyEnd, justifyCenter, justifyBetween},
    overflows: {overflowHidden}, variants: {variantDefault})
  if withEditors:
    result.kinds.incl(input)
    result.controls.incl(cfInputReset)
    if withControls:
      result.kinds=result.kinds+{checkbox,toggle,progress,tag,separator,spinner}
  if withLists:result.kinds.incl(virtualList)
  if withNavigation:result.kinds.incl(NodeKind.navigation)

proc checkSize(size: DipSize) =
  for value in [size.width, size.height]:
    if classify(value) in {fcNan, fcInf, fcNegInf} or value <= 0 or value > MaxStyleNumber:
      fail("Android content size must be finite and positive")

proc sortedEntities(entities: Table[NodeHandle, MountedEntity]): seq[MountedEntity] =
  var children = initTable[NodeHandle, seq[MountedEntity]]()
  for _, entity in entities: children.mgetOrPut(entity.parent, @[]).add(entity)
  for _, values in children.mpairs:
    values.sort(proc(a,b: MountedEntity): int = cmp(a.index,b.index))
  var ordered: seq[MountedEntity]
  proc visit(parent: NodeHandle, depth: int) =
    if depth > MaxDepth: fail("Android native tree exceeds depth budget")
    for entity in children.getOrDefault(parent):
      ordered.add(entity)
      visit(entity.handle, depth+1)
  visit(NoHandle, 0)
  if ordered.len != entities.len: fail("Android native tree contains unreachable entities")
  result = ordered

proc fullFrame(s: AndroidState, entities: Table[NodeHandle, MountedEntity],
               revision: uint64, boxes: seq[LayoutBox],
               projections:seq[AndroidListProjection] = @[]): AndroidFrame =
  result = AndroidFrame(session:s.session, mount:s.mount, revision:revision,
    boxes:boxes,withControls:s.platform.withControls,withLists:s.platform.withLists,withNavigation:s.platform.withNavigation,
    listProjections:projections)
  for entity in sortedEntities(entities):
    result.ops.add(UpdateOp(kind:opCreate, handle:entity.handle, parent:entity.parent,
      index:entity.index, nodeId:entity.nodeId, nodeKind:entity.kind, props:entity.props,
      list:entity.list,row:entity.row,navigation:entity.navigation))

proc validBinding(s:AndroidState,handle:NodeHandle,generation:uint64):bool

proc protectedRows(s:AndroidState,entities:Table[NodeHandle,MountedEntity]):
    Table[NodeHandle,seq[int]] =
  s.protection.snapshotProtectedRows(s.mount,entities,
    proc(handle:NodeHandle,binding:uint64):bool = s.validBinding(handle,binding))

proc prepare(s: AndroidState, batch: UpdateBatch) =
  if s.disposed or s.geometryFaulted or s.pending != nil:
    fail("Android backend is disposed, faulted or already prepared")
  s.retired = nil # Destruction is outside the publish window.
  let candidate = PreparedFrame()
  if s.accepted != nil:
    for handle, entity in s.accepted.entities: candidate.entities[handle] = entity
  for op in batch.ops:
    case op.kind
    of opCreate:
      if candidate.entities.hasKey(op.handle): fail("Android duplicate native handle")
      if op.nodeKind notin androidCapabilities(s.platform.editEffects!=nil,
          s.platform.withControls,s.platform.withLists,s.platform.withNavigation).kinds:
        fail("Android node kind is not implemented")
      candidate.entities[op.handle] = MountedEntity(handle:op.handle,parent:op.parent,
        index:op.index,nodeId:op.nodeId,kind:op.nodeKind,props:op.props,list:op.list,row:op.row,navigation:op.navigation)
    of opUpdate:
      if not candidate.entities.hasKey(op.handle): fail("Android update of missing handle")
      candidate.entities[op.handle].props = op.props
      candidate.entities[op.handle].navigation = op.navigation
      candidate.entities[op.handle].list = op.list
      candidate.entities[op.handle].row = op.row
    of opMove:
      if not candidate.entities.hasKey(op.handle): fail("Android move of missing handle")
      candidate.entities[op.handle].parent = op.parent
      candidate.entities[op.handle].index = op.index
      candidate.entities[op.handle].row = op.row
    of opRemove: candidate.entities.del(op.handle)
  for order in batch.finalOrders:
    for index, handle in order.children:
      if not candidate.entities.hasKey(handle): fail("Android child order references missing handle")
      candidate.entities[handle].parent = order.parent
      candidate.entities[handle].index = index
  if candidate.entities.len > MaxNodes: fail("Android node budget exceeded")
  for handle,entity in candidate.entities:
    if (entity.kind==NodeKind.navigation)!=entity.navigation.isSome or
        (entity.props.control.hasBack and entity.kind!=NodeKind.navigation):
      fail("Android navigation metadata does not match its kind")
    if entity.navigation.isSome:
      let reason=entity.navigation.get.invalidReason(MaxNodes)
      if reason.len!=0:fail(reason)
      var children=0
      for child in candidate.entities.values:
        if child.parent==handle:inc children
      if children!=1:fail("Android navigation requires one active page")
  # Validate reachability before measurement/platform preparation.
  discard sortedEntities(candidate.entities)
  var boxes:seq[LayoutBox]
  var projections:seq[AndroidListProjection]
  try:
    if s.lists!=nil:
      let layout=s.lists.prepareListLayout(candidate.entities,s.size,
        s.platform.measure,s.scale,s.fontEpoch,s.protectedRows(candidate.entities))
      boxes=layout.boxes
      projections=layout.projections
    else:boxes=layoutTree(candidate.entities,s.size,s.platform.measure)
    candidate.frame = AndroidFrame(session:s.session,mount:s.mount,revision:batch.revision,
      ops:batch.ops,boxes:boxes,withControls:s.platform.withControls,
      withLists:s.platform.withLists,withNavigation:s.platform.withNavigation,listProjections:projections)
    candidate.replay = s.fullFrame(candidate.entities,batch.revision,boxes,projections)
  except CatchableError:
    if s.lists!=nil:s.lists.discardListLayout()
    raise
  # Retain the candidate even if staging fails: discard owns any partial native
  # preparation, while BackendSession retains this backend until disposal.
  s.pending = candidate
  if s.editors!=nil:
    if s.accepted!=nil and s.platform.editorSelection!=nil:
      for handle,entity in s.accepted.entities:
        if entity.kind==input and candidate.entities.hasKey(handle):
          s.editors.observeSelection(handle,s.platform.editorSelection(handle))
    candidate.frame.editorWrites=s.editors.prepareEditors(candidate.entities)
    candidate.replay.editorWrites=s.editors.preparedReplayWrites()
  s.platform.stage(candidate.frame)

proc validBinding(s:AndroidState,handle:NodeHandle,generation:uint64):bool =
  if s.accepted==nil or not s.accepted.entities.hasKey(handle): return false
  if s.accepted.entities.getOrDefault(handle).kind in {input,checkbox,toggle}:
    return s.editors!=nil and s.editors.bindingReady(handle) and
      generation==s.editors.bindingGeneration(handle)
  generation==1

proc newAndroidAdapter*(platform: AndroidPlatform, size: DipSize,
    scale=1.0,fontEpoch=1'u64): AndroidAdapter =
  checkSize(size)
  if classify(scale) in {fcNan,fcInf,fcNegInf} or scale<=0:
    fail("Android scale must be finite and positive")
  if platform.withControls and platform.editEffects==nil:
    fail("Android checked controls require editor effects")
  if platform.withLists and platform.restoreGeometry==nil:
    fail("Android lists require geometry replay on existing views")
  if platform.measure == nil or platform.stage == nil or platform.apply == nil or
      platform.discardStage == nil or platform.restore == nil or platform.rebind == nil or
      platform.dispose == nil:
    fail("Android platform requires every synchronous callback")
  let s = AndroidState(platform:platform,size:size,scale:scale,fontEpoch:fontEpoch)
  if platform.editEffects!=nil: s.editors=newAndroidEditors()
  if platform.withLists:
    s.lists=newAndroidLists()
    s.protection=newAndroidRowProtection()
    s.protectionDelivery=newAndroidProtectionDelivery()
  let protocol=Backend(capabilities:androidCapabilities(s.editors!=nil,
    platform.withControls,platform.withLists,platform.withNavigation))
  result=AndroidAdapter(protocol:protocol,state:s)
  protocol.prepare = proc(batch: UpdateBatch) = s.prepare(batch)
  protocol.apply = proc(batch: UpdateBatch) =
    if s.pending == nil or s.pending.frame.revision != batch.revision:
      fail("Android apply has no matching preparation")
    s.platform.apply()
  protocol.accepted = proc(entities: Table[NodeHandle, MountedEntity], revision: uint64) {.raises:[].} =
    # All tables/geometry/replay descriptions were prepared. Do not copy the
    # incoming table or call Java here. Retired state pins old strings/arrays.
    swap(s.retired, s.accepted)
    swap(s.accepted, s.pending)
    if s.lists!=nil:discard s.lists.publishListLayout()
    if s.editors!=nil: s.editors.acceptEditors(revision)
  protocol.discardPrepared = proc() =
    s.platform.discardStage()
    s.pending = nil
    if s.lists!=nil:s.lists.discardListLayout()
    if s.editors!=nil: s.editors.discardEditors()
  protocol.restore = proc(entities: Table[NodeHandle, MountedEntity]) =
    # Session's authoritative accepted descriptions must match this prepared
    # replay. The initial failed mount can legitimately have no accepted frame.
    var replay = AndroidFrame(session:s.session,mount:s.mount,withNavigation:s.platform.withNavigation)
    if s.accepted != nil: replay = s.accepted.replay
    s.platform.restore(replay)
    if s.editors!=nil: s.editors.replayEditors()
  protocol.rebind = proc(session, mount: uint64) =
    s.platform.rebind(session,mount)
    s.session = session
    s.mount = mount
  protocol.bindingValid = proc(handle: NodeHandle, generation: uint64): bool =
    s.validBinding(handle,generation)
  protocol.settle = proc(value:EventSettlement) =
    if s.editors!=nil and s.validBinding(value.handle,value.bindingGeneration) and
        s.editors.bindingReady(value.handle):
      if s.platform.editorSelection!=nil and s.accepted.entities.getOrDefault(value.handle).kind==input:
        s.editors.observeSelection(value.handle,s.platform.editorSelection(value.handle))
      s.editors.settleEdit(value.handle,value.sequence,
        proc(handle:NodeHandle,effects:seq[EditEffect]) =
          s.platform.editEffects(AndroidEditorWrite(handle:handle,
            binding:s.editors.bindingGeneration(handle),effects:effects)))
  protocol.dispose = proc() =
    if s.disposed: return
    s.platform.dispose() # Keep every owner if native cleanup throws.
    s.pending = nil
    s.accepted = nil
    s.retired = nil
    s.editors = nil
    s.lists = nil
    s.protection = nil
    s.protectionDelivery = nil
    s.disposed = true

proc newAndroidBackend*(platform:AndroidPlatform,size:DipSize,
    scale=1.0,fontEpoch=1'u64):Backend =
  newAndroidAdapter(platform,size,scale,fontEpoch).protocol

proc acceptedListLayout*(adapter:AndroidAdapter):AndroidListLayout =
  if not adapter.state.disposed and adapter.state.lists!=nil:
    adapter.state.lists.acceptedListLayout
  else:nil

proc queueProtectionViewports*(adapter:AndroidAdapter,session:BackendSession):
    AndroidProtectionQueueResult =
  let s=adapter.state
  if s.disposed or s.geometryFaulted or s.lists==nil or s.accepted==nil or session==nil or
      not session.ownsBackend(adapter.protocol):return
  s.protection.reconcileProtection(s.mount,s.accepted.entities,
    proc(handle:NodeHandle,binding:uint64):bool = s.validBinding(handle,binding))
  s.protectionDelivery.queueProtectionViewports(s.lists,s.protection,session,
    proc(handle:NodeHandle,binding:uint64):bool = s.validBinding(handle,binding))

proc queueListViewports*(adapter:AndroidAdapter,session:BackendSession):int =
  let s=adapter.state
  if s.disposed or s.geometryFaulted or s.lists==nil or session==nil or
      not session.ownsBackend(adapter.protocol):return 0
  let protected=adapter.queueProtectionViewports(session)
  protected.queued+s.lists.queueListViewports(session)

proc recordRowProtection*(adapter:AndroidAdapter,handle:NodeHandle,
    mount,sequence,binding:uint64,reasons:set[AndroidProtectionReason]):bool =
  let s=adapter.state
  if s.disposed or s.geometryFaulted or s.lists==nil or s.accepted==nil:return false
  let before=s.protectedRows(s.accepted.entities)
  if not s.protection.recordProtection(AndroidProtectionFact(handle:handle,
      mount:mount,sequence:sequence,binding:binding,reasons:reasons),s.mount,
      s.accepted.entities,
      proc(h:NodeHandle,b:uint64):bool = s.validBinding(h,b)):return false
  let after=s.protectedRows(s.accepted.entities)
  for projection in s.lists.acceptedListLayout.projections:
    if before.getOrDefault(projection.handle)!=after.getOrDefault(projection.handle):
      discard s.lists.requestProtectionProjection(projection.handle)
  true

proc requestListOffset*(adapter:AndroidAdapter,handle:NodeHandle,
    sourceGeneration:uint64,offset:float64):bool =
  let s=adapter.state
  not s.disposed and not s.geometryFaulted and s.lists!=nil and
    s.lists.requestListOffset(handle,sourceGeneration,offset)

proc recordListOffset*(adapter:AndroidAdapter,handle:NodeHandle,
    sourceGeneration,mount,sequence:uint64,offset:float64):bool =
  let s=adapter.state
  not s.disposed and not s.geometryFaulted and s.lists!=nil and
    s.lists.recordListOffset(handle,sourceGeneration,mount,sequence,offset)

proc flushListGeometry*(adapter:AndroidAdapter):bool =
  ## One ordinary geometry pass, with no Runtime commit or row materialization.
  ## Geometry rollback reuses existing views and does not change event epochs.
  let s=adapter.state
  if s.disposed or s.geometryFaulted or s.lists==nil or s.accepted==nil or
      s.pending!=nil or not s.lists.listProjectionNeeded:return false
  let attempt=s.lists.captureListAttempt()
  let previous=s.accepted
  var nativeStarted=false
  try:
    s.retired=nil
    let layout=s.lists.prepareListLayout(previous.entities,s.size,s.platform.measure,
      s.scale,s.fontEpoch,s.protectedRows(previous.entities))
    let candidate=PreparedFrame(entities:previous.entities)
    candidate.frame=AndroidFrame(session:s.session,mount:s.mount,
      revision:previous.frame.revision,boxes:layout.boxes,
      withControls:s.platform.withControls,withLists:true,withNavigation:s.platform.withNavigation,listProjections:layout.projections)
    candidate.replay=s.fullFrame(previous.entities,previous.frame.revision,
      layout.boxes,layout.projections)
    candidate.replay.editorWrites=previous.replay.editorWrites
    s.pending=candidate
    nativeStarted=true
    s.platform.stage(candidate.frame)
    s.platform.apply()
    # All objects, arrays and replay descriptions are already prepared.
    discard s.lists.publishListLayout()
    swap(s.retired,s.accepted)
    swap(s.accepted,s.pending)
    return true
  except CatchableError as primary:
    var cleanup=""
    var unrecovered=false
    if nativeStarted:
      try:s.platform.discardStage()
      except CatchableError as error:
        unrecovered=true
        cleanup.add("; discard: " & error.msg)
      try:
        s.platform.restoreGeometry(AndroidFrame(session:s.session,mount:s.mount,
          revision:previous.frame.revision,boxes:previous.frame.boxes,
          withControls:s.platform.withControls,withLists:true,withNavigation:s.platform.withNavigation,
          listProjections:previous.frame.listProjections))
      except CatchableError as error:
        unrecovered=true
        cleanup.add("; geometry replay: " & error.msg)
    s.lists.discardListLayout()
    attempt.blockListAttempt()
    s.pending=nil
    s.geometryFaulted=unrecovered
    let error=newException(AndroidListGeometryError,primary.msg & cleanup)
    error.recoveryFailed=unrecovered
    raise error
  except Defect:
    # A broken framework/native contract is not a retryable geometry intent.
    # Retain the adapter and accepted frame for explicit disposal by its owner.
    s.geometryFaulted=true
    raise

proc canObserveInput*(adapter:AndroidAdapter,handle:NodeHandle,sequence:uint64,
    event:Event,selection:Selection16):bool =
  let s=adapter.state
  let isCheck=s.accepted!=nil and s.accepted.entities.getOrDefault(handle).kind in {checkbox,toggle}
  not s.disposed and s.editors!=nil and event.kind in {change,submit} and
    (not isCheck or event.kind==change) and
    s.editors.canObserveEdit(handle,sequence,ControlValue(text:event.value,checked:event.checked,
      isCheck:isCheck),event.composition,selection)

proc observeInput*(adapter:AndroidAdapter,handle:NodeHandle,sequence:uint64,
    event:Event,selection:Selection16):bool =
  if not adapter.canObserveInput(handle,sequence,event,selection): return false
  let isCheck=adapter.state.accepted.entities.getOrDefault(handle).kind in {checkbox,toggle}
  adapter.state.editors.observeEdit(handle,sequence,
    ControlValue(text:event.value,checked:event.checked,isCheck:isCheck),event.composition,selection)

proc isCheckedControl*(adapter:AndroidAdapter,handle:NodeHandle):bool =
  let s=adapter.state
  not s.disposed and s.platform.withControls and s.accepted!=nil and
    s.accepted.entities.hasKey(handle) and s.accepted.entities.getOrDefault(handle).kind in {checkbox,toggle}

proc flushEditorEffects*(adapter:AndroidAdapter) =
  let s=adapter.state
  if s.disposed or s.editors==nil: return
  s.editors.flushEditorResets(proc(handle:NodeHandle,effects:seq[EditEffect]) =
    s.platform.editEffects(AndroidEditorWrite(handle:handle,
      binding:s.editors.bindingGeneration(handle),effects:effects)))

proc setEditorsActive*(adapter:AndroidAdapter,active:bool) =
  let s=adapter.state
  # Preserve the lifecycle state even before the first dynamic input appears.
  if not s.disposed and s.platform.editorsActive!=nil: s.platform.editorsActive(active)
