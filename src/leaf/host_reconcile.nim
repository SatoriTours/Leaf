## Backend-neutral host identity and candidate overlays. Snapshot planning is a
## compatibility path; delta planning never materializes the accepted tree.
import std/[tables, sets, options]
import ./[core, backend, host_protocol]
export host_protocol

type
  HostRecord* = object
    handle*, parent*: NodeHandle
    nodeId*: string
    kind*: NodeKind
    props*: HostProps
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
  HostCandidate* = ref object
    wire: HostBatch
    edits: Table[NodeHandle, StoredHost]
    orders: Table[NodeHandle, seq[NodeHandle]]
    boundaries: seq[HostBoundary]
    owner, generation: uint64
    root: NodeHandle
    count, bytes: int
    measurements: UpdateStats
  HostReconciler* = ref object
    sessionId, owner, generation, nextHandle, acceptedRevision: uint64
    records: Table[NodeHandle, StoredHost]
    ids: Table[string, NodeHandle]
    boundaries: Table[uint64, HostBoundary]
    root: NodeHandle
    bytes: int
    window: Option[HostWindow]

var nextOwner: uint64
proc newHostReconciler*(sessionId: uint64): HostReconciler =
  if sessionId == 0: fail("host session id must be nonzero")
  inc nextOwner
  # The accepted maps reserve the validated maximum once. Publishing any
  # bounded candidate requires neither copying a map nor growing its buckets.
  HostReconciler(sessionId:sessionId,owner:nextOwner,nextHandle:1,
    records:initTable[NodeHandle,StoredHost](MaxNodes*2),
    ids:initTable[string,NodeHandle](MaxNodes*2),
    boundaries:initTable[uint64,HostBoundary](MaxNodes*2))
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
  sizeof(HostRecord)+record.nodeId.len+record.props.text.len+record.props.placeholder.len
proc validate*(r: HostReconciler,c: HostCandidate) =
  if c == nil or c.owner != r.owner: fail("foreign host candidate")
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
        nodeId:record.nodeId,nodeKind:record.kind,props:record.props))
    else:
      c.bytes+=record.bytes-old.record.bytes
      if record.parent != old.record.parent: touched.incl(record.handle)
      if old.record.parent == NoHandle: roots.excl(record.handle)
      if old.record != record:
        c.wire.ops.add(HostOp(kind:HostOpKind.update,handle:record.handle,parent:record.parent,
          nodeId:record.nodeId,nodeKind:record.kind,props:record.props))
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
  for id, stored in c.edits:
    if stored == nil: continue
    var ancestor=id
    var depth=0
    while ancestor != NoHandle:
      let current=r.lookup(c,ancestor)
      if current == nil: fail("unknown host ancestor")
      inc depth
      if depth > MaxDepth: fail("host cycle or depth exceeded")
      ancestor=current.record.parent
    # Moving an ancestor must not bypass depth budgets for unchanged children.
    let old=r.records.getOrDefault(id)
    if old != nil and old.record.parent != stored.record.parent:
      var pending = @[(id,depth)]
      while pending.len>0:
        let item=pending.pop()
        if item[1]>MaxDepth: fail("host depth exceeded")
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
proc publish*(r: HostReconciler,c: HostCandidate) {.raises: [].} =
  # Called only after validate and under the Runtime's reentry guard. Every map
  # was reserved for twice the maximum live node count at construction.
  for id,stored in c.edits:
    let old=r.records.getOrDefault(id)
    if old != nil: r.ids.del(old.record.nodeId)
  for id,stored in c.edits:
    if stored == nil: r.records.del(id)
    else: r.records[id]=stored;r.ids[stored.record.nodeId]=id
  for boundary in c.boundaries:
    if boundary.root==NoHandle:r.boundaries.del(boundary.id)
    else:r.boundaries[boundary.id]=boundary
  for op in c.wire.ops:
    if op.kind==HostOpKind.window:r.window=some(op.window)
  r.root=c.root;r.bytes=c.bytes;r.acceptedRevision=c.wire.nextRevision
  inc r.generation
proc accept*(r: HostReconciler,c: HostCandidate) =
  r.validate(c)
  r.publish(c)
proc `discard`*(r: HostReconciler,c: HostCandidate) =
  r.validate(c)
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
