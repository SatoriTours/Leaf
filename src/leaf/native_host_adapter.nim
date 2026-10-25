## HostBatch -> native delta adapter. Final sibling indices are assigned once;
## accepted entities remain in one persistent CommitMap. The accepted delta and
## its maps are prepared before apply, so accept only moves values into the
## pre-sized maps. A full metadata Table is an explicit compatibility cost for
## backends without acceptedDelta and is built during prepare, never accept.
import std/[tables,sets,algorithm,options]
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
        if (op.nodeKind == NodeKind.navigation) != op.props.navigation.isSome:
          fail("navigation metadata must belong to a navigation host")
        if op.props.navigation.isSome:
          let reason = op.props.navigation.get.invalidReason(MaxNodes)
          if reason.len != 0: fail(reason)
        if op.nodeKind != NodeKind.navigation and
            (op.props.eventMask and EventBackMask) != 0:
          fail("back handler requires a navigation host")
        if op.props.list.isSome:
          let reason=invalidReason(op.props.list.get,MaxListItems)
          if reason.len!=0:fail("host list metadata rejected: " & reason)
        pendingIssues.add(checkTypedCapabilities(op.nodeId,op.nodeKind,op.props.normalized,backend.capabilities,mode))
        var entity=entities.getOrDefault(op.handle)
        entity.handle=op.handle;entity.parent=op.parent;entity.nodeId=op.nodeId;entity.kind=op.nodeKind
        entity.props=effectiveProps(backend.capabilities,op.props.normalized,some(op.nodeKind))
        entity.navigation=op.props.navigation
        entity.list=op.props.list
        entity.row=op.row
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
          nodeId:entity.nodeId,nodeKind:entity.kind,props:entity.props,list:entity.list,navigation:entity.navigation,
          row:entity.row))
      else:
        if old.props!=entity.props or old.list!=entity.list or old.row!=entity.row or old.navigation!=entity.navigation:
          batch.ops.add(UpdateOp(kind:opUpdate,handle:handle,parent:entity.parent,index:entity.index,
            nodeId:entity.nodeId,nodeKind:entity.kind,props:entity.props,list:entity.list,navigation:entity.navigation,
            row:entity.row))
        if old.parent!=entity.parent or old.index!=entity.index:
          batch.ops.add(UpdateOp(kind:opMove,handle:handle,parent:entity.parent,index:entity.index,
            nodeId:entity.nodeId,nodeKind:entity.kind,props:entity.props,list:entity.list,navigation:entity.navigation,
            row:entity.row))
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
    # Candidate-only row gate on `entities + edits - removals`. A raw wire is not
    # trusted: the shared shape rules and per-list slots are applied to the whole
    # candidate child set, not only to the edited rows.
    var childOrder:Table[NodeHandle,seq[NodeHandle]]
    for order in pendingOrders:childOrder[order.parent]=order.children
    var acceptedChildren:Table[NodeHandle,seq[NodeHandle]]
    var acceptedChildrenBuilt=false
    proc acceptedChildrenOf(parent:NodeHandle):seq[NodeHandle]=
      if not acceptedChildrenBuilt:
        acceptedChildrenBuilt=true
        var indexed:Table[NodeHandle,seq[tuple[index:int,handle:NodeHandle]]]
        for handle,entity in entities.pairs:
          if handle in removed: continue
          indexed.mgetOrPut(entity.parent,@[]).add((entity.index,handle))
        for parentHandle,siblings in indexed.mpairs:
          siblings.sort(proc(a,b:tuple[index:int,handle:NodeHandle]):int=cmp(a.index,b.index))
          for item in siblings:acceptedChildren.mgetOrPut(parentHandle,@[]).add(item.handle)
      acceptedChildren.getOrDefault(parent)
    proc candidateEntity(handle:NodeHandle):MountedEntity=
      if handle==NoHandle or handle in removed:return
      if edits.hasKey(handle):edits.getOrDefault(handle) else:entities.getOrDefault(handle)
    proc candidateChildren(parent:NodeHandle):seq[NodeHandle]=
      if childOrder.hasKey(parent):return childOrder[parent]
      for handle in acceptedChildrenOf(parent):
        let current=candidateEntity(handle)
        if current.handle!=NoHandle and current.parent==parent:result.add(handle)
    var touched:HashSet[NodeHandle]
    for handle,entity in edits:
      if entity.kind==virtualList:touched.incl(handle)
      else:touched.incl(entity.parent)
      if entity.row.isSome:touched.incl(entity.row.get.listHandle)
      let accepted=entities.getOrDefault(handle)
      if accepted.row.isSome:touched.incl(accepted.row.get.listHandle)
    for parent in childOrder.keys:touched.incl(parent)
    var navigationTouched = touched
    for handle, entity in edits:
      navigationTouched.incl(handle)
      navigationTouched.incl(entity.parent)
      let old = entities.getOrDefault(handle)
      if old.handle != NoHandle: navigationTouched.incl(old.parent)
    for handle in removed:
      let old = entities.getOrDefault(handle)
      if old.handle != NoHandle: navigationTouched.incl(old.parent)
    for handle in navigationTouched:
      let entity = candidateEntity(handle)
      if entity.handle != NoHandle and entity.kind == NodeKind.navigation:
        let children = candidateChildren(handle)
        if children.len != 1:
          fail("navigation host requires exactly one active page")
        let child = candidateEntity(children[0])
        if children[0] == handle or child.handle == NoHandle or child.parent != handle:
          fail("navigation host active page has an invalid parent")
    # 1. Every edited binding against the candidate list.
    for handle,entity in edits:
      if entity.row.isNone: continue
      let binding=entity.row.get
      let listEntity=candidateEntity(binding.listHandle)
      if listEntity.handle==NoHandle or listEntity.kind!=virtualList:
        fail("native row binding has no virtual list")
      if listEntity.list.isNone: fail("native row binding list has no metadata")
      let reason=rowBindingReason(binding,listEntity.list.get,entity.parent,handle)
      if reason.len!=0: fail("native row binding rejected: " & reason)
      var member=false
      for child in candidateChildren(binding.listHandle):
        if child==handle: member=true;break
      if not member: fail("native row root is not in the list's final children")
    # 2. Whole candidate child set of every affected list.
    var slots:RowSlotTable
    for listHandle in touched:
      let listEntity=candidateEntity(listHandle)
      if listEntity.handle==NoHandle: continue
      if listEntity.kind!=virtualList: continue
      if listEntity.list.isNone: continue
      let meta=listEntity.list.get
      let children=candidateChildren(listHandle)
      var typedAfter=false
      for child in children:
        let childEntity=candidateEntity(child)
        if childEntity.handle!=NoHandle and childEntity.row.isSome: typedAfter=true;break
      for child in children:
        let childEntity=candidateEntity(child)
        if childEntity.handle==NoHandle: fail("native list has an unknown child")
        let childRow=childEntity.row
        if childRow.isNone:
          if typedAfter: fail("native changed list child has no row binding")
          continue
        let binding=childRow.get
        let reason=rowBindingReason(binding,meta,childEntity.parent,child)
        if reason.len!=0: fail("native row binding rejected: " & reason)
        let slotReason=reserveRowSlot(slots,binding)
        if slotReason.len!=0: fail("native row binding rejected: " & slotReason)
      if typedAfter: continue
      for child in acceptedChildrenOf(listHandle):
        let acceptedChild=entities.getOrDefault(child)
        if acceptedChild.handle==NoHandle or acceptedChild.row.isNone: continue
        for current in children:
          if current==child: fail("native typed list kept an unbound row")
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
