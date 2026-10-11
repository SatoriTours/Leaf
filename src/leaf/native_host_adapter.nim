## HostBatch -> native delta adapter. Final sibling indices are assigned once;
## accepted entities remain in one persistent map. Full metadata is an explicit
## compatibility cost only for backends without acceptedDelta.
import std/[tables,sets,algorithm]
import ./[core,backend,host_session]
var nextNativeConsumer:uint64=1000
proc nativeHostConsumer*(backend:Backend,sessionId=0'u64,
    onAccepted:proc(delta:HostAcceptedDelta) {.closure,raises:[].}=nil,
    onRecover:proc() {.closure.}=nil,
    onFault:proc(reason:string) {.closure,raises:[].}=nil,
    mode=compatible):HostConsumer=
  if backend==nil or backend.prepare==nil or backend.apply==nil:fail("incomplete native consumer")
  var id=sessionId
  if id==0:inc nextNativeConsumer;id=nextNativeConsumer
  var entities=initTable[NodeHandle,MountedEntity](MaxNodes*4)
  var edits:Table[NodeHandle,MountedEntity]
  var removed:seq[NodeHandle]
  var orders:seq[HostChildOrder]
  var pendingIssues:seq[CapabilityIssue]
  var batch:UpdateBatch
  var applied=false
  var faulted=false
  result=HostConsumer(sessionId:id)
  result.prepare=proc(wire:HostBatch)=
    if faulted:fail("native consumer is faulted")
    edits.clear();removed.setLen(0);orders.setLen(0);pendingIssues.setLen(0);applied=false
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
      of HostOpKind.setChildren:orders.add(HostChildOrder(parent:op.handle,children:op.children))
      of HostOpKind.remove:removed.add(op.handle)
      else:discard
    for order in orders:
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
    batch.finalOrders=orders
    backend.prepare(batch)
  result.apply=proc()=
    try:
      backend.apply(batch);applied=true
    except CatchableError as primary:
      try:
        backend.restore(entities)
        if onRecover!=nil:onRecover()
      except CatchableError as secondary:
        faulted=true
        if onFault!=nil:onFault(secondary.msg)
        primary.msg.add("; restore failed: " & secondary.msg)
      raise primary
  result.accept=proc(revision:uint64) {.raises:[].}=
    var delta=HostAcceptedDelta(revision:revision,removals:removed,orders:orders,issues:move(pendingIssues))
    for handle in removed:entities.del(handle)
    for handle,entity in edits:entities[handle]=entity;delta.upserts.add(entity)
    if backend.acceptedDelta!=nil:backend.acceptedDelta(delta)
    elif backend.accepted!=nil:backend.accepted(entities,revision)
    if onAccepted!=nil:onAccepted(delta)
    applied=false;edits.clear();removed.setLen(0);orders.setLen(0);pendingIssues.setLen(0)
  result.discardPrepared=proc() {.raises:[].}=
    try:
      if applied:
        backend.restore(entities)
        if onRecover!=nil:onRecover()
      if backend.discardPrepared!=nil:backend.discardPrepared()
    except Exception as error:
      faulted=true
      if onFault!=nil:onFault(error.msg)
    applied=false;edits.clear();removed.setLen(0);orders.setLen(0);pendingIssues.setLen(0)
  result.faultPrepared=proc() {.raises:[].}=
    faulted=true
    if onFault!=nil:onFault("native installation rollback scope refused entry")
