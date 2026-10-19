## HostBatch -> native delta adapter. Final sibling indices are assigned once;
## accepted entities remain in one persistent CommitMap. The accepted delta and
## its maps are prepared before apply, so accept only moves values into the
## pre-sized maps. A full metadata Table is an explicit compatibility cost for
## backends without acceptedDelta and is built during prepare, never accept.
import std/[tables,sets,algorithm]
import ./[core,backend,host_session,commit_map]
var nextNativeConsumer:uint64=1000
when defined(leafProtocolProbes):
  var nativeAcceptAllocations*:int

proc probeAllocCount():int=
  when defined(nimAllocStats):
    let stats=getAllocStats()
    for name,value in fieldPairs(stats):
      when name=="allocCount":result=value
  else:0

proc materializeEntities(entities:CommitMap[NodeHandle,MountedEntity]):Table[NodeHandle,MountedEntity]=
  ## Explicit query / fault-restore snapshot only; never a normal commit step.
  for handle,entity in entities.pairs:result[handle]=entity

proc nativeHostConsumer*(backend:Backend,sessionId=0'u64,
    onAccepted:proc(delta:HostAcceptedDelta) {.closure,raises:[].}=nil,
    onRecover:proc() {.closure.}=nil,
    onFault:proc(reason:string) {.closure,raises:[].}=nil,
    mode=compatible):HostConsumer=
  if backend==nil or backend.prepare==nil or backend.apply==nil:fail("incomplete native consumer")
  var id=sessionId
  if id==0:inc nextNativeConsumer;id=nextNativeConsumer
  var entities=initCommitMap[NodeHandle,MountedEntity](id)
  var ids=initCommitMap[string,NodeHandle](id)
  var edits:Table[NodeHandle,MountedEntity]
  var removed:seq[NodeHandle]
  var pendingRemovals:seq[NodeHandle]
  var pendingUpserts:seq[MountedEntity]
  var pendingOrders:seq[HostChildOrder]
  var pendingIssues:seq[CapabilityIssue]
  var entityPatch:PreparedMapPatch[NodeHandle,MountedEntity]
  var idPatch:PreparedMapPatch[string,NodeHandle]
  var fullAccepted:Table[NodeHandle,MountedEntity]
  var batch:UpdateBatch
  var applied=false
  var faulted=false
  result=HostConsumer(sessionId:id)
  let self=result
  result.entityQuery=proc(handle:NodeHandle,value:var MountedEntity):bool {.closure,raises:[].}=
    if entities.hasKey(handle):
      value=entities.getOrDefault(handle);true
    else:false
  result.nodeIdQuery=proc(nodeId:string):NodeHandle {.closure,raises:[].}=
    ids.getOrDefault(nodeId,NoHandle)
  result.acceptedCount=proc():int {.closure,raises:[].}=entities.len
  result.materializeAccepted=proc():Table[NodeHandle,MountedEntity] {.closure.}=
    materializeEntities(entities)
  result.prepare=proc(wire:HostBatch)=
    if faulted:fail("native consumer is faulted")
    edits.clear();removed.setLen(0);pendingRemovals.setLen(0);pendingUpserts.setLen(0)
    pendingOrders.setLen(0);pendingIssues.setLen(0);applied=false
    batch=UpdateBatch(revision:wire.nextRevision,isDelta:true)
    var created:HashSet[NodeHandle]
    for op in wire.ops:
      case op.kind
      of HostOpKind.create,HostOpKind.update:
        pendingIssues.add(checkTypedCapabilities(op.nodeId,op.nodeKind,op.props.normalized,backend.capabilities,mode))
        var entity=entities.getOrDefault(op.handle)
        entity.handle=op.handle;entity.parent=op.parent;entity.nodeId=op.nodeId;entity.kind=op.nodeKind
        entity.props=effectiveProps(backend.capabilities,op.props.normalized)
        edits[op.handle]=entity
        if op.kind==HostOpKind.create:created.incl(op.handle)
      of HostOpKind.setChildren:pendingOrders.add(HostChildOrder(parent:op.handle,children:op.children))
      of HostOpKind.remove:removed.add(op.handle)
      else:discard
    for order in pendingOrders:
      for index,handle in order.children:
        var entity=if edits.hasKey(handle):edits.getOrDefault(handle) else:entities.getOrDefault(handle)
        if entity.handle==NoHandle:fail("unknown child in native order")
        if entity.parent!=order.parent or entity.index!=index or handle in created:
          entity.parent=order.parent;entity.index=index;edits[handle]=entity
    for handle,entity in edits:
      let old=entities.getOrDefault(handle)
      if handle in created:
        batch.ops.add(UpdateOp(kind:opCreate,handle:handle,parent:entity.parent,index:entity.index,
          nodeId:entity.nodeId,nodeKind:entity.kind,props:entity.props))
      else:
        if old.props!=entity.props:
          batch.ops.add(UpdateOp(kind:opUpdate,handle:handle,parent:entity.parent,index:entity.index,
            nodeId:entity.nodeId,nodeKind:entity.kind,props:entity.props))
        if old.parent!=entity.parent or old.index!=entity.index:
          batch.ops.add(UpdateOp(kind:opMove,handle:handle,parent:entity.parent,index:entity.index,
            nodeId:entity.nodeId,nodeKind:entity.kind,props:entity.props))
    proc depth(op:UpdateOp):int=
      var parent=op.parent
      while parent!=NoHandle:
        inc result
        if result>MaxDepth:fail("native parent cycle")
        let entity=if edits.hasKey(parent):edits.getOrDefault(parent) else:entities.getOrDefault(parent)
        parent=entity.parent
    batch.ops.sort(proc(a,b:UpdateOp):int=
      if a.kind==opCreate and b.kind==opCreate:cmp(depth(a),depth(b))
      elif a.kind==opCreate: -1
      elif b.kind==opCreate:1
      else:0)
    removed.sort(proc(a,b:NodeHandle):int=
      cmp(depth(UpdateOp(parent:entities.getOrDefault(b).parent)),depth(UpdateOp(parent:entities.getOrDefault(a).parent))))
    for handle in removed:batch.ops.add(UpdateOp(kind:opRemove,handle:handle))
    batch.finalOrders=pendingOrders
    # Prepare the accepted entity/id deltas here. `accept` moves these values
    # into pre-sized maps; it never grows a table or builds a sequence.
    var idRemovals:seq[string]
    var idUpserts:seq[(string,NodeHandle)]
    var patchRemovals:seq[NodeHandle]
    var patchEntries:seq[(NodeHandle,MountedEntity)]
    pendingRemovals=move(removed)
    for handle in pendingRemovals:
      patchRemovals.add(handle)
      if entities.hasKey(handle):idRemovals.add(entities.getOrDefault(handle).nodeId)
    for handle,entity in edits:
      let present=entities.hasKey(handle)
      if present:
        let oldId=entities.getOrDefault(handle).nodeId
        if oldId!=entity.nodeId:
          idRemovals.add(oldId)
          idUpserts.add((entity.nodeId,handle))
      else:
        idUpserts.add((entity.nodeId,handle))
      pendingUpserts.add(entity)
      patchEntries.add((handle,entity))
    entityPatch=entities.preparePatch(patchRemovals,patchEntries,MaxNodes)
    idPatch=ids.preparePatch(idRemovals,idUpserts,MaxNodes)
    if backend.acceptedDelta==nil and backend.accepted!=nil:
      # Compatibility metadata for backends without a typed delta: build the
      # full table during prepare so accept performs no allocation.
      fullAccepted.clear()
      for handle,entity in entities.pairs:fullAccepted[handle]=entity
      for handle in pendingRemovals:fullAccepted.del(handle)
      for entity in pendingUpserts:fullAccepted[entity.handle]=entity
    backend.prepare(batch)
    if self.prepareAcceptedMetadata!=nil:self.prepareAcceptedMetadata(pendingIssues)
  result.apply=proc()=
    try:
      backend.apply(batch);applied=true
    except CatchableError as primary:
      try:
        backend.restore(materializeEntities(entities))
        if onRecover!=nil:onRecover()
      except CatchableError as secondary:
        faulted=true
        if onFault!=nil:onFault(secondary.msg)
        primary.msg.add("; restore failed: " & secondary.msg)
      raise primary
  result.accept=proc(revision:uint64) {.raises:[].}=
    when defined(leafProtocolProbes) and defined(nimAllocStats):
      let allocBefore=probeAllocCount()
    var delta=HostAcceptedDelta(revision:revision,removals:move(pendingRemovals),
      orders:move(pendingOrders),issues:move(pendingIssues),upserts:move(pendingUpserts))
    entities.publishValidated(entityPatch)
    ids.publishValidated(idPatch)
    if backend.acceptedDelta!=nil:backend.acceptedDelta(delta)
    elif backend.accepted!=nil:backend.accepted(fullAccepted,revision)
    if onAccepted!=nil:onAccepted(delta)
    if self.acceptAcceptedMetadata!=nil:self.acceptAcceptedMetadata()
    entityPatch=nil;idPatch=nil
    when defined(leafProtocolProbes) and defined(nimAllocStats):
      nativeAcceptAllocations=probeAllocCount()-allocBefore
    applied=false;edits.clear()
  result.discardPrepared=proc() {.raises:[].}=
    if self.discardAcceptedMetadata!=nil:self.discardAcceptedMetadata()
    discardPrepared(entityPatch)
    discardPrepared(idPatch)
    entityPatch=nil;idPatch=nil
    try:
      if applied:
        backend.restore(materializeEntities(entities))
        if onRecover!=nil:onRecover()
      if backend.discardPrepared!=nil:backend.discardPrepared()
    except Exception as error:
      faulted=true
      if onFault!=nil:onFault(error.msg)
    applied=false;edits.clear();pendingRemovals.setLen(0);pendingUpserts.setLen(0)
    pendingOrders.setLen(0);pendingIssues.setLen(0)
  result.faultPrepared=proc() {.raises:[].}=
    if self.discardAcceptedMetadata!=nil:self.discardAcceptedMetadata()
    faulted=true
    if onFault!=nil:onFault("native installation rollback scope refused entry")
