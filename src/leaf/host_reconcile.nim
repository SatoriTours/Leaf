## Backend-neutral host identity and candidate overlays. Snapshot planning is a
## compatibility path; delta planning never materializes the accepted tree.
import std/[tables, sets, options, unicode]
import ./[core, backend, host_protocol, commit_map, graphics]
export host_protocol

type
  HostRecord* = object
    handle*, parent*: NodeHandle
    nodeId*: string
    kind*: NodeKind
    props*: HostProps
    row*: Option[NativeRowBinding]
      ## Typed row sidecar for a list's direct row root (Nim-only).
    boundaryId*: uint64
  HostChildren* = object
    parent*: NodeHandle
    children*: seq[NodeHandle]
  HostChanges* = object
    upserts*: seq[HostRecord]
    removals*: seq[NodeHandle]
    children*: seq[HostChildren]
    boundaries*: seq[HostBoundary]
    window*: Option[HostWindow]
  StoredHost = ref object
    record: HostRecord
    children: seq[NodeHandle]
  HostCandidateStatus = enum
    hostCandidateStaging, hostCandidateSealed, hostCandidatePublished,
    hostCandidateDiscarded
  HostCandidate* = ref object
    wire: HostBatch
    edits: Table[NodeHandle, StoredHost]
    orders: Table[NodeHandle, seq[NodeHandle]]
    boundaries: seq[HostBoundary]
    owner, generation: uint64
    root: NodeHandle
    count, bytes: int
    measurements: UpdateStats
    recordPatch: PreparedMapPatch[NodeHandle, StoredHost]
    idPatch: PreparedMapPatch[string, NodeHandle]
    boundaryPatch: PreparedMapPatch[uint64, HostBoundary]
    status: HostCandidateStatus
  HostReconciler* = ref object
    sessionId, owner, generation, nextHandle, acceptedRevision: uint64
    records: CommitMap[NodeHandle, StoredHost]
    ids: CommitMap[string, NodeHandle]
    boundaries: CommitMap[uint64, HostBoundary]
    root: NodeHandle
    bytes: int
    window: Option[HostWindow]

when defined(leafProtocolProbes):
  var hostPublishAllocations*:int

proc probeAllocCount():int=
  when defined(nimAllocStats):
    let stats=getAllocStats()
    for name,value in fieldPairs(stats):
      when name=="allocCount":result=value
  else:0

proc sealDelta(r: HostReconciler,c: HostCandidate)
proc validateRowBindings(r: HostReconciler, c: HostCandidate)

var nextOwner: uint64
proc newHostReconciler*(sessionId: uint64): HostReconciler =
  if sessionId == 0: fail("host session id must be nonzero")
  inc nextOwner
  # Accepted maps start empty. Prepare sizes only the candidate's delta and
  # grows them at the documented threshold; publication only moves values.
  HostReconciler(sessionId:sessionId,owner:nextOwner,nextHandle:1,
    records:initCommitMap[NodeHandle,StoredHost](nextOwner),
    ids:initCommitMap[string,NodeHandle](nextOwner),
    boundaries:initCommitMap[uint64,HostBoundary](nextOwner))
proc revision*(r: HostReconciler): uint64 = r.acceptedRevision
proc batch*(c: HostCandidate): HostBatch = c.wire
proc stats*(c: HostCandidate): UpdateStats = c.measurements
proc record*(r: HostReconciler, handle: NodeHandle): Option[HostRecord] =
  let stored=r.records.getOrDefault(handle)
  if stored != nil: some(stored.record) else: none(HostRecord)
proc handleFor*(r: HostReconciler, id: string): NodeHandle = r.ids.getOrDefault(id,NoHandle)
proc children*(r: HostReconciler, handle: NodeHandle): seq[NodeHandle] =
  let stored=r.records.getOrDefault(handle)
  if stored != nil: stored.children else: @[]
proc reserveHandle*(r: HostReconciler): NodeHandle =
  if r.nextHandle == high(uint64): fail("host handle space exhausted")
  result=NodeHandle(r.nextHandle)
  inc r.nextHandle
proc lookup(r: HostReconciler,c: HostCandidate,id: NodeHandle): StoredHost =
  if c.edits.hasKey(id): c.edits.getOrDefault(id) else: r.records.getOrDefault(id)
proc bytes(record: HostRecord): int =
  result=sizeof(HostRecord)+record.nodeId.len+record.props.text.len+
    record.props.placeholder.len
  if record.row.isSome:result+=record.row.get.itemKey.len
  if record.props.canvas.isSome:result+=record.props.canvas.get.ownedBytes
proc validate*(r: HostReconciler,c: HostCandidate) =
  if c == nil or c.owner != r.owner: fail("foreign host candidate")
  if c.status != hostCandidateSealed: fail("host candidate is not sealed")
  if c.generation != r.generation or c.wire.baseRevision != r.acceptedRevision:
    fail("stale host candidate")
proc planDelta*(r: HostReconciler, changes: HostChanges, nextRevision: uint64): HostCandidate =
  if nextRevision <= r.acceptedRevision: fail("host revision must advance")
  result=HostCandidate(owner:r.owner,generation:r.generation,
    wire:HostBatch(sessionId:r.sessionId,baseRevision:r.acceptedRevision,nextRevision:nextRevision),
    root:r.root,count:r.records.len,bytes:r.bytes,boundaries:changes.boundaries)
  let c=result
  var removed: HashSet[NodeHandle]
  var touched: HashSet[NodeHandle]
  var roots: HashSet[NodeHandle]
  if r.root != NoHandle: roots.incl(r.root)
  for id in changes.removals:
    let old=r.records.getOrDefault(id)
    if id in removed or old == nil: fail("remove of unknown host")
    removed.incl(id);c.edits[id]=nil;touched.incl(id)
    dec c.count;c.bytes-=old.record.bytes+old.children.len*sizeof(NodeHandle)
    if old.record.parent == NoHandle: roots.excl(id)
  var newIds: HashSet[string]
  for record in changes.upserts:
    if record.handle == NoHandle or record.handle in removed or c.edits.hasKey(record.handle):
      fail("duplicate host edit")
    let canvasReason = canvasMetadataReason(record.kind, record.props.canvas)
    if canvasReason.len != 0: fail(canvasReason)
    if (record.kind == NodeKind.navigation) != record.props.navigation.isSome:
      fail("navigation metadata must belong to a navigation host")
    if record.props.navigation.isSome:
      let reason = record.props.navigation.get.invalidReason(MaxNodes)
      if reason.len != 0: fail(reason)
    if record.kind != NodeKind.canvasHost and
        (record.props.eventMask and EventCanvasInputMask) != 0:
      fail("Canvas input handler requires a Canvas host")
    if record.kind != NodeKind.navigation and
        (record.props.eventMask and EventBackMask) != 0:
      fail("back handler requires a navigation host")
    if record.nodeId in newIds: fail("duplicate host node id")
    newIds.incl(record.nodeId)
    let old=r.records.getOrDefault(record.handle)
    if old != nil and old.record.kind != record.kind: fail("host kind cannot change in place")
    let stored=StoredHost(record:record,children:(if old == nil: @[] else:old.children))
    c.edits[record.handle]=stored
    inc c.measurements.visitedHosts
    if old == nil:
      inc c.count;c.bytes+=record.bytes
      touched.incl(record.handle)
      c.wire.ops.add(HostOp(kind:HostOpKind.create,handle:record.handle,parent:record.parent,
        nodeId:record.nodeId,nodeKind:record.kind,props:record.props,row:record.row))
    else:
      c.bytes+=record.bytes-old.record.bytes
      if record.parent != old.record.parent: touched.incl(record.handle)
      if old.record.parent == NoHandle: roots.excl(record.handle)
      if old.record != record:
        c.wire.ops.add(HostOp(kind:HostOpKind.update,handle:record.handle,parent:record.parent,
          nodeId:record.nodeId,nodeKind:record.kind,props:record.props,row:record.row))
    if record.parent == NoHandle: roots.incl(record.handle)
    inc c.measurements.indexEdits
  var memberships: Table[NodeHandle,HashSet[NodeHandle]]
  for order in changes.children:
    if c.orders.hasKey(order.parent): fail("duplicate final child order")
    let current=r.lookup(c,order.parent)
    if current == nil: fail("order for unknown parent")
    var members: HashSet[NodeHandle]
    for child in order.children:
      if child == NoHandle or child in members: fail("duplicate or zero child")
      members.incl(child)
    memberships[order.parent]=members
    c.orders[order.parent]=order.children
    if current.children != order.children:
      c.edits[order.parent]=StoredHost(record:current.record,children:order.children)
      c.bytes+=(order.children.len-current.children.len)*sizeof(NodeHandle)
      touched.incl(order.parent)
      c.wire.ops.add(HostOp(kind:HostOpKind.setChildren,handle:order.parent,children:order.children))
  var relations=touched
  for id in touched:
    let old=r.records.getOrDefault(id)
    if old != nil:
      for child in old.children: relations.incl(child)
    let current=r.lookup(c,id)
    if current != nil:
      for child in current.children: relations.incl(child)
  for id in relations:
    inc c.measurements.visitedHosts
    let current=r.lookup(c,id)
    let old=r.records.getOrDefault(id)
    if current == nil:
      if old != nil and old.record.parent != NoHandle and old.record.parent notin removed and
          not c.orders.hasKey(old.record.parent): fail("removed child remains attached")
      if old != nil:
        for child in old.children:
          let live=r.lookup(c,child)
          if live != nil and live.record.parent == id: fail("removed parent has surviving children")
    else:
      let parent=current.record.parent
      if old == nil or old.record.parent != parent:
        if old != nil and old.record.parent != NoHandle and old.record.parent notin removed and
            not c.orders.hasKey(old.record.parent): fail("old parent order missing")
        if parent != NoHandle and not c.orders.hasKey(parent): fail("new parent order missing")
      if parent != NoHandle:
        if r.lookup(c,parent) == nil: fail("unknown host parent")
        if memberships.hasKey(parent) and id notin memberships[parent]: fail("host absent from parent order")
      if id in touched:
        for child in current.children:
          let item=r.lookup(c,child)
          if item == nil or item.record.parent != id: fail("unknown child or multiple parents")
  var navigationTouched = touched
  for id, stored in c.edits:
    navigationTouched.incl(id)
    if stored != nil: navigationTouched.incl(stored.record.parent)
    let old = r.records.getOrDefault(id)
    if old != nil: navigationTouched.incl(old.record.parent)
  for id in navigationTouched:
    let current = r.lookup(c, id)
    if current != nil and current.record.kind == NodeKind.navigation and
        current.children.len != 1:
      fail("navigation host requires exactly one active page")
  for id, stored in c.edits:
    if stored == nil: continue
    var ancestor=id
    var depth=0
    while ancestor != NoHandle:
      let current=r.lookup(c,ancestor)
      if current == nil: fail("unknown host ancestor")
      inc depth
      if depth > MaxDepth+1: fail("host cycle or depth exceeded")
      ancestor=current.record.parent
    # Moving an ancestor must not bypass depth budgets for unchanged children.
    let old=r.records.getOrDefault(id)
    if old != nil and old.record.parent != stored.record.parent:
      var pending = @[(id,depth)]
      while pending.len>0:
        let item=pending.pop()
        if item[1]>MaxDepth+1: fail("host depth exceeded")
        for child in r.lookup(c,item[0]).children: pending.add((child,item[1]+1))
    let duplicate=r.ids.getOrDefault(stored.record.nodeId,NoHandle)
    if duplicate != NoHandle and duplicate != id:
      let existing=r.lookup(c,duplicate)
      if existing != nil and existing.record.nodeId == stored.record.nodeId:
        fail("duplicate accepted host node id")
  if c.count>MaxNodes or c.bytes>MaxTreeBytes or (c.count>0 and roots.len!=1) or (c.count==0 and roots.len!=0):
    fail("host description budget or root invalid")
  c.root=NoHandle
  for root in roots: c.root=root
  var boundaryEdits: Table[uint64,HostBoundary]
  for boundary in changes.boundaries:
    if boundary.id == 0 or boundaryEdits.hasKey(boundary.id): fail("duplicate or zero boundary id")
    boundaryEdits[boundary.id]=boundary
    if boundary.root != NoHandle and r.lookup(c,boundary.root) == nil: fail("dangling boundary root")
    c.wire.ops.add(HostOp(kind:HostOpKind.boundary,boundary:boundary))
  proc boundaryAt(id:uint64):HostBoundary =
    if boundaryEdits.hasKey(id):boundaryEdits.getOrDefault(id) else:r.boundaries.getOrDefault(id)
  for id,boundary in boundaryEdits:
    if boundary.root == NoHandle: continue
    var current=id
    var depth=0
    while current!=0:
      let value=boundaryAt(current)
      if value.id==0 or value.root==NoHandle:fail("unknown boundary parent")
      inc depth
      if depth>MaxDepth:fail("boundary cycle or depth exceeded")
      current=value.parent
  if removed.len>0 or boundaryEdits.len>0:
    for id,previous in r.boundaries:
      let boundary=boundaryAt(id)
      if boundary.root != NoHandle and (r.lookup(c,boundary.root)==nil or
          (boundary.parent!=0 and boundaryAt(boundary.parent).root==NoHandle)):
        fail("dangling accepted boundary")
  if changes.window.isSome and changes.window != r.window:
    c.wire.ops.add(HostOp(kind:HostOpKind.window,window:changes.window.get))
  for id in changes.removals: c.wire.ops.add(HostOp(kind:HostOpKind.remove,handle:id))
  c.measurements.ops=uint64(c.wire.ops.len)
  r.validateRowBindings(c)
  r.sealDelta(c)
proc validateRowBindings(r: HostReconciler, c: HostCandidate) =
  ## Candidate-only typed-row consistency over the *whole* candidate view, not
  ## just `c.edits`: every affected list is checked through its final children,
  ## so an edit cannot collide with an accepted, unedited peer and a typed list
  ## cannot silently degrade. Runs before the candidate is sealed, while the
  ## accepted maps are untouched and no backend has seen the batch.
  if c == nil: return
  var touched: HashSet[NodeHandle]
  for id, stored in c.edits:
    # Check the accepted binding before any `continue`: a pure Some->None edit
    # (or a removal) leaves the list record, its metadata and its membership
    # untouched, so only the accepted side names the list that must be re-gated.
    let accepted = r.record(id)
    if accepted.isSome and accepted.get.row.isSome:
      touched.incl(accepted.get.row.get.listHandle)
    if stored == nil: continue
    if stored.record.kind == virtualList: touched.incl(id)
    if stored.record.row.isSome: touched.incl(stored.record.row.get.listHandle)
  for parent in c.orders.keys: touched.incl(parent)
  # 1. Scalar consistency for every edited binding, including membership.
  for id, stored in c.edits:
    if stored == nil: continue
    let record = stored.record
    if record.row.isNone: continue
    let binding = record.row.get
    let listStored = r.lookup(c, binding.listHandle)
    if listStored == nil: fail("row binding references an unknown list")
    if listStored.record.kind != virtualList:
      fail("row binding parent is not a virtual list")
    let listProps = listStored.record.props.list
    if listProps.isNone: fail("row binding list has no list metadata")
    let reason = rowBindingReason(binding, listProps.get, record.parent, id)
    if reason.len != 0: fail(reason)
    var member = false
    for child in listStored.children:
      if child == id: member = true; break
    if not member: fail("row root is not in the list's final children")
  # 2. Full candidate children of every affected list: uniqueness and no mixed
  #    bound/unbound rows; a typed list may only lose its rows by membership
  #    removal, reparenting or removal of the list itself.
  var slots: RowSlotTable
  for listHandle in touched:
    let listStored = r.lookup(c, listHandle)
    if listStored == nil: continue
    if listStored.record.kind != virtualList: continue
    let listProps = listStored.record.props.list
    if listProps.isNone: continue
    let meta = listProps.get
    var typedAfter = false
    for child in listStored.children:
      let childStored = r.lookup(c, child)
      if childStored != nil and childStored.record.row.isSome:
        typedAfter = true
        break
    for child in listStored.children:
      let childStored = r.lookup(c, child)
      if childStored == nil: fail("changed list has an unknown child")
      let childRow = childStored.record.row
      if childRow.isNone:
        if typedAfter: fail("changed list child has no row binding")
        continue
      let binding = childRow.get
      let reason = rowBindingReason(binding, meta, childStored.record.parent, child)
      if reason.len != 0: fail(reason)
      let slotReason = reserveRowSlot(slots, binding)
      if slotReason.len != 0: fail(slotReason)
    if typedAfter: continue
    for child in r.children(listHandle):
      let acceptedChild = r.record(child)
      if acceptedChild.isNone or acceptedChild.get.row.isNone: continue
      for current in listStored.children:
        if current == child:
          fail("typed list kept an unbound row " & $child)

proc sealDelta(r: HostReconciler,c: HostCandidate) =
  ## Prepare the accepted-map delta. Every allocation, including the possible
  ## O(N) capacity rebuild, happens here; publication only moves values.
  var recordRemovals: seq[NodeHandle]
  var recordUpserts: seq[(NodeHandle,StoredHost)]
  var idRemovals: seq[string]
  var idUpserts: seq[(string,NodeHandle)]
  for id,stored in c.edits:
    let old=r.records.getOrDefault(id)
    if stored==nil:
      recordRemovals.add(id)
      if old!=nil: idRemovals.add(old.record.nodeId)
    else:
      recordUpserts.add((id,stored))
      if old==nil:
        idUpserts.add((stored.record.nodeId,id))
      elif old.record.nodeId!=stored.record.nodeId:
        idRemovals.add(old.record.nodeId)
        idUpserts.add((stored.record.nodeId,id))
  var boundaryRemovals: seq[uint64]
  var boundaryUpserts: seq[(uint64,HostBoundary)]
  for boundary in c.boundaries:
    if boundary.root==NoHandle:boundaryRemovals.add(boundary.id)
    else:boundaryUpserts.add((boundary.id,boundary))
  c.recordPatch=r.records.preparePatch(recordRemovals,recordUpserts,MaxNodes)
  c.idPatch=r.ids.preparePatch(idRemovals,idUpserts,MaxNodes)
  c.boundaryPatch=r.boundaries.preparePatch(boundaryRemovals,boundaryUpserts,MaxNodes)
  c.status=hostCandidateSealed
proc publish*(r: HostReconciler,c: HostCandidate) {.raises: [].} =
  # Called only after validate and under the Runtime's reentry guard. Moves
  # prepared values into pre-sized accepted storage; replaced values are
  # retired until `finishPublish`, so publication runs no user destructor.
  if c==nil or c.status!=hostCandidateSealed:return
  when defined(leafProtocolProbes) and defined(nimAllocStats):
    let before=probeAllocCount()
  r.records.publishValidated(c.recordPatch)
  r.ids.publishValidated(c.idPatch)
  r.boundaries.publishValidated(c.boundaryPatch)
  for op in c.wire.ops:
    if op.kind==HostOpKind.window:r.window=some(op.window)
  r.root=c.root;r.bytes=c.bytes;r.acceptedRevision=c.wire.nextRevision
  inc r.generation
  c.status=hostCandidatePublished
  when defined(leafProtocolProbes) and defined(nimAllocStats):
    hostPublishAllocations=probeAllocCount()-before
proc finishPublish*(r: HostReconciler,c: HostCandidate) {.raises: [].} =
  ## The whole Runtime commit is accepted; release retired accepted values.
  if c==nil:return
  finishPublished(c.recordPatch)
  finishPublished(c.idPatch)
  finishPublished(c.boundaryPatch)
proc discardCandidate*(r: HostReconciler,c: HostCandidate) {.raises: [].} =
  ## Rejected candidate: accepted maps were never touched and the generation
  ## does not advance. Candidate-owned values are released.
  if c==nil or c.status!=hostCandidateSealed:return
  discardPrepared(c.recordPatch)
  discardPrepared(c.idPatch)
  discardPrepared(c.boundaryPatch)
  c.status=hostCandidateDiscarded
proc accept*(r: HostReconciler,c: HostCandidate) =
  r.validate(c)
  r.publish(c)
proc `discard`*(r: HostReconciler,c: HostCandidate) =
  r.validate(c)
  discardPrepared(c.recordPatch)
  discardPrepared(c.idPatch)
  discardPrepared(c.boundaryPatch)
  c.status=hostCandidateDiscarded
  inc r.generation
proc planSnapshot*(r:HostReconciler,snapshot:Snapshot,nextRevision:uint64,
                   policy:HostStylePolicy):HostCandidate =
  var changes=HostChanges(window:some(HostWindow(title:snapshot.title,width:snapshot.width,height:snapshot.height)))
  var seen:HashSet[NodeHandle]
  var normalized=0'u64
  proc visit(mounted:MountedNode,parent:NodeHandle,parentReused:bool):NodeHandle =
    let existing=r.ids.getOrDefault(mounted.id,NoHandle)
    let old=r.records.getOrDefault(existing)
    let reused=parentReused and old != nil and old.record.kind==mounted.node.kind
    result=if reused:existing else:r.reserveHandle()
    seen.incl(result)
    let props=normalizeHostProps(mounted.node,policy)
    inc normalized
    changes.upserts.add(HostRecord(handle:result,parent:parent,nodeId:mounted.id,
      kind:mounted.node.kind,props:props))
    var children:seq[NodeHandle]
    for child in mounted.children:children.add(visit(child,result,reused))
    changes.children.add(HostChildren(parent:result,children:children))
  if snapshot.root!=nil:discard visit(snapshot.root,NoHandle,true)
  for id in r.records.keys:
    if id notin seen:changes.removals.add(id)
  result=r.planDelta(changes,nextRevision)
  result.measurements.normalizedHosts=normalized
proc fullBatch*(r:HostReconciler,sessionId:uint64):HostBatch=
  ## Initial synchronization only. Ordinary managed commits use their delta.
  result=HostBatch(sessionId:sessionId,baseRevision:0,nextRevision:r.acceptedRevision)
  for id,stored in r.records:
    let record=stored.record
    result.ops.add(HostOp(kind:HostOpKind.create,handle:id,parent:record.parent,
      nodeId:record.nodeId,nodeKind:record.kind,props:record.props,row:record.row))
  for id,stored in r.records:
    result.ops.add(HostOp(kind:HostOpKind.setChildren,handle:id,children:stored.children))
  for boundary in r.boundaries.values:result.ops.add(HostOp(kind:HostOpKind.boundary,boundary:boundary))
  if r.window.isSome:result.ops.add(HostOp(kind:HostOpKind.window,window:r.window.get))
