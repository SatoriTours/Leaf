## Managed component instances and affected overlays. The accepted maps are flat;
## successful publication replaces entries and never retains a candidate chain.
import std/[tables,sets,options,algorithm]
import ./[core,component_description,component_state,host_reconcile,backend]
export host_protocol.UpdateStats

type
  RowSlot=object
    id:uint64
    index:int
    used:uint64
  Instance=ref object
    id,parent,owner:uint64
    depth:int
    path:string
    description:UiDescription
    model:ComponentModel
    children:seq[uint64]
    handle,parentHost:NodeHandle
    bytes:int
    active:bool
    rowIndex:int
    rows:Table[string,RowSlot]
    rowClock:uint64
  ManagedStore=ref object
    owner:Runtime
    states:StateStore
    reconciler:HostReconciler
    rootDescription:UiDescription
    root,nextId:uint64
    instances:Table[uint64,Instance]
    index:Table[string,uint64]
    keys:Table[string,HashSet[uint64]]
    invalid:HashSet[uint64]
    count,componentCount,bytes:int
    policy:HostStylePolicy
    totals:UpdateStats
    snapshot:Snapshot
    snapshotValid,forceRoot:bool
  ManagedDriver=ref object of RuntimeDriver
    data:ManagedStore
    edits:Table[uint64,Instance]
    changes:HostChanges
    attempt:StateAttempt
    candidate:HostCandidate
    exported:Option[Snapshot]
    computed,dirty:HashSet[uint64]
    created:seq[uint64]
    root:uint64
    count,componentCount,bytes:int
    measurements:UpdateStats
    globalRefresh:bool
var nextManagedId:uint64
proc current(d:ManagedDriver,id:uint64):Instance=
  if d.edits.hasKey(id):d.edits.getOrDefault(id) else:d.data.instances.getOrDefault(id)
proc hostRoot(d:ManagedDriver,id:uint64):NodeHandle=
  let item=d.current(id)
  if item==nil:return NoHandle
  if item.description.kind==DescriptionKind.host:return item.handle
  if item.children.len>0:return d.hostRoot(item.children[0])
proc segment(desc:UiDescription,index:int):string=
  let key=desc.key
  if key.len==0:"i:" & $index else:"k:" & $key.len & ":" & key
proc descriptionBytes(desc:UiDescription,path:string):int=
  result=128+path.len+desc.key.len
  if desc.kind==DescriptionKind.host:
    let node=desc.hostNode
    result+=node.text.len+node.placeholder.len
    for styles in [node.styles,node.attributes]:
      for key,value in styles:result+=32+key.len+value.len
    if node.listSource!=nil:
      let source=node.listSource
      result+=source.len*16
      for i in 0..<source.len:result+=source.itemKey(i).len
proc copyInstance(item:Instance):Instance=
  result=Instance()
  result[]=item[]
proc materializeList(d:ManagedDriver,item:Instance,first,finish:int,protected:seq[int])
proc erase(d:ManagedDriver,id:uint64)=
  let old=d.current(id)
  if old==nil:return
  var children=old.children
  for slot in old.rows.values:
    if slot.id notin children:children.add(slot.id)
  for child in children:d.erase(child)
  d.edits[id]=nil
  dec d.count;d.bytes-=old.bytes
  if old.description.kind==DescriptionKind.component:dec d.componentCount
  if old.description.kind==DescriptionKind.host:
    if old.handle!=NoHandle:d.changes.removals.add(old.handle)
  elif old.active:d.changes.boundaries.add(HostBoundary(id:id))
proc allocate(d:ManagedDriver):uint64=
  if d.data.nextId==high(uint64):fail("component identity exhausted")
  result=d.data.nextId;inc d.data.nextId
  d.created.add(result)
proc reconcile(d:ManagedDriver,desc:UiDescription,oldId,parent,owner:uint64,
    parentHost:NodeHandle,path:string,depth:int):uint64=
  if desc==nil:fail("nil UI description")
  if path.len>MaxStringBytes:fail("managed node ID exceeds 1 MiB")
  if depth>MaxDepth:fail("managed description exceeds depth 64")
  var old=d.current(oldId)
  let same=old!=nil and old.description.kind==desc.kind and old.description.key==desc.key and
    (if desc.kind==DescriptionKind.component:old.description.erased.typeId==desc.erased.typeId
     else:old.description.hostNode.kind==desc.hostNode.kind)
  if not same:
    if old!=nil:d.erase(old.id)
    old=nil
  let oldRoot=if old==nil:NoHandle else:d.hostRoot(old.id)
  let id=if old==nil:d.allocate() else:old.id
  let item=Instance(id:id,parent:parent,owner:owner,depth:depth,path:path,description:desc,parentHost:parentHost,active:true,rowIndex: -1)
  if old==nil:
    inc d.count
    if desc.kind==DescriptionKind.component:inc d.componentCount
  else:
    d.bytes-=old.bytes
    item.rowIndex=old.rowIndex
  item.bytes=descriptionBytes(desc,path);d.bytes+=item.bytes
  if d.count-d.componentCount>MaxNodes or d.componentCount>MaxNodes or d.bytes>MaxTreeBytes:fail("managed description exceeds node/instance/byte budget")
  d.edits[id]=item
  if desc.kind==DescriptionKind.component:
    if old!=nil:item.model=old.model
    else:
      d.data.states.setPhase(StatePhase.initializing)
      try:item.model=desc.erased.instantiate(newMountContext(d.data.states,id))
      finally:d.data.states.setPhase(StatePhase.idle)
    if old!=nil and old.active and id notin d.dirty and desc.erased.equalProps(old.description.erased):
      item.children=old.children
      return id
    d.computed.incl(id)
    inc d.measurements.componentRenders
    d.data.states.setPhase(StatePhase.rendering)
    var output:UiDescription
    try:
      let data=d.data
      output=desc.erased.render(newComponentContext(data.states,d.attempt,id,
        proc(owner:uint64)=data.invalid.incl(owner)),item.model)
    finally:d.data.states.setPhase(StatePhase.idle)
    let previous=if old==nil or old.children.len==0:0'u64 else:old.children[0]
    item.children= @[d.reconcile(output,previous,id,id,parentHost,path & "/r/" & segment(output,0),depth+1)]
    let root=d.hostRoot(id)
    if old==nil or root!=oldRoot or d.globalRefresh:
      d.changes.boundaries.add(HostBoundary(id:id,root:root,parent:owner))
  else:
    item.handle=if old==nil or old.handle==NoHandle:d.data.reconciler.reserveHandle() else:old.handle
    let node=desc.hostNode
    item.description=desc.hostOnly()
    let props=normalizeHostProps(node,d.data.policy)
    inc d.measurements.normalizedHosts
    d.changes.upserts.add(HostRecord(handle:item.handle,parent:parentHost,nodeId:path,
      kind:node.kind,props:props,boundaryId:owner))
    if node.kind==NodeKind.virtualList:
      if node.listSource==nil:fail("virtual list has no source")
      if old!=nil and old.description.hostNode.listSource==node.listSource:
        item.rows=old.rows;item.children=old.children;item.rowClock=old.rowClock
      elif old!=nil:
        var restoreKeys:seq[string]
        for child in old.children:
          let previous=d.current(child)
          if previous!=nil and previous.rowIndex>=0:
            restoreKeys.add(old.description.hostNode.listSource.itemKey(previous.rowIndex))
        for slot in old.rows.values:d.erase(slot.id)
        var indices:seq[int]
        var lookup:Table[string,int]
        for i in 0..<node.listSource.len:lookup[node.listSource.itemKey(i)]=i
        for key in restoreKeys:
          if lookup.hasKey(key):indices.add(lookup.getOrDefault(key))
        d.materializeList(item,0,0,indices)
      return id
    var previous:Table[string,uint64]
    if old!=nil:
      for i,childId in old.children:
        let child=d.current(childId)
        if child!=nil:previous[segment(child.description,i)]=childId
    var seen:HashSet[string]
    var order:seq[NodeHandle]
    for i,child in desc.children:
      let part=segment(child,i)
      if part in seen:fail("duplicate sibling key")
      seen.incl(part)
      let childId=d.reconcile(child,previous.getOrDefault(part),id,owner,item.handle,path & "/" & part,depth+1)
      item.children.add(childId)
      order.add(d.hostRoot(childId))
    for part,childId in previous:
      if part notin seen:d.erase(childId)
    d.changes.children.add(HostChildren(parent:item.handle,children:order))
  id
proc repairAncestors(d:ManagedDriver,id:uint64)=
  var child=id
  var item=d.current(id)
  var parent=if item==nil:0'u64 else:item.parent
  while parent!=0:
    let ancestor=d.current(parent)
    if ancestor==nil:return
    if ancestor.description.kind==DescriptionKind.host:
      var order:seq[NodeHandle]
      for child in ancestor.children:order.add(d.hostRoot(child))
      var replaced=false
      for existing in d.changes.children.mitems:
        if existing.parent==ancestor.handle:existing.children=order;replaced=true
      if not replaced:d.changes.children.add(HostChildren(parent:ancestor.handle,children:order))
      return
    d.changes.boundaries.add(HostBoundary(id:parent,root:d.hostRoot(child),parent:ancestor.owner))
    child=parent;parent=ancestor.parent
proc retainedDescription(d:ManagedDriver,id:uint64):UiDescription=
  let item=d.current(id)
  if item.description.kind==DescriptionKind.component:return item.description
  var children:seq[UiDescription]
  for child in item.children:children.add(d.retainedDescription(child))
  hostShell(item.description.hostNode,children)
proc deactivate(d:ManagedDriver,id:uint64)=
  let old=d.current(id)
  if old==nil or not old.active:return
  let item=old.copyInstance()
  item.active=false
  for child in item.children:d.deactivate(child)
  if item.description.kind==DescriptionKind.host:
    if item.handle!=NoHandle:d.changes.removals.add(item.handle)
    item.handle=NoHandle
  else:d.changes.boundaries.add(HostBoundary(id:id))
  d.edits[id]=item
proc materializeList(d:ManagedDriver,item:Instance,first,finish:int,protected:seq[int])=
  let source=item.description.hostNode.listSource
  if source==nil or first<0 or finish<first or finish>source.len:fail("invalid list viewport")
  var active:HashSet[int]
  for i in max(0,first-source.overscan)..<min(source.len,finish+source.overscan):active.incl(i)
  for i in protected:
    if i<0 or i>=source.len:fail("invalid protected row")
    active.incl(i)
  var indices:seq[int]
  for i in active:indices.add(i)
  indices.sort()
  inc item.rowClock
  var children:seq[uint64]
  var handles:seq[NodeHandle]
  for index in indices:
    let key=source.itemKey(index)
    var slot=item.rows.getOrDefault(key)
    let old=d.current(slot.id)
    if old==nil or not old.active:
      let description=if old==nil:item.description.buildDescriptionRow(index) else:d.retainedDescription(old.id)
      slot.id=d.reconcile(description,slot.id,item.id,item.owner,item.handle,
        item.path & "/item/k:" & $key.len & ":" & key,item.depth+1)
    let row=d.current(slot.id).copyInstance()
    row.rowIndex=index
    d.edits[slot.id]=row
    slot.index=index;slot.used=item.rowClock
    item.rows[key]=slot
    children.add(slot.id);handles.add(d.hostRoot(slot.id))
  for oldId in item.children:
    if oldId notin children:d.deactivate(oldId)
  item.children=children
  var warm:seq[(string,RowSlot)]
  for key,slot in item.rows:
    if slot.index notin active:warm.add((key,slot))
  warm.sort(proc(a,b:(string,RowSlot)):int=cmp(a[1].used,b[1].used))
  let limit=max(128,active.len)
  for i in 0..<max(0,item.rows.len-limit):
    let (key,slot)=warm[i]
    d.erase(slot.id);item.rows.del(key)
  d.edits[item.id]=item
  d.changes.children.add(HostChildren(parent:item.handle,children:handles))
proc prepareHost(d:ManagedDriver)=
  var changes=HostChanges(window:d.changes.window)
  var upserts:Table[NodeHandle,HostRecord]
  var orders:Table[NodeHandle,HostChildren]
  var boundaries:Table[uint64,HostBoundary]
  var removed:HashSet[NodeHandle]
  for record in d.changes.upserts:upserts[record.handle]=record
  for order in d.changes.children:orders[order.parent]=order
  for boundary in d.changes.boundaries:boundaries[boundary.id]=boundary
  for handle in d.changes.removals:
    removed.incl(handle);upserts.del(handle);orders.del(handle)
  for record in upserts.values:changes.upserts.add(record)
  for order in orders.values:changes.children.add(order)
  for boundary in boundaries.values:changes.boundaries.add(boundary)
  for handle in removed:
    if d.data.reconciler.record(handle).isSome:changes.removals.add(handle)
  d.candidate=d.data.reconciler.planDelta(changes,d.data.owner.acceptedRevision+1)
  d.data.reconciler.validate(d.candidate)
  d.data.states.validateAttempt(d.attempt)
  d.exported=none(Snapshot)
method stage*(base:ManagedDriver,forceRoot:bool):RuntimeDriver=
  let data=base.data
  let forceRoot=forceRoot or data.forceRoot
  data.forceRoot=false
  let queued=data.states.pendingOwners()
  if not forceRoot and queued.len==0 and data.invalid.len==0:return nil
  let d=ManagedDriver(data:data,count:data.count,componentCount:data.componentCount,bytes:data.bytes,root:data.root,globalRefresh:forceRoot)
  try:
    d.attempt=data.states.beginAttempt()
    d.dirty=data.invalid
    data.invalid.clear()
    for owner in d.attempt.dirtyOwners:d.dirty.incl(owner)
    if forceRoot or data.root==0:
      d.dirty.incl(data.root)
      d.root=d.reconcile(data.rootDescription,data.root,0,0,NoHandle,"root",0)
    var dirty:seq[uint64]
    for id in d.dirty:dirty.add(id)
    dirty.sort(proc(a,b:uint64):int=
      let first=data.instances.getOrDefault(a)
      let second=data.instances.getOrDefault(b)
      cmp(if first==nil:0 else:first.depth,if second==nil:0 else:second.depth))
    for id in dirty:
      if id in d.computed:continue
      let item=d.current(id)
      if item==nil or not item.active:continue
      let before=d.hostRoot(id)
      discard d.reconcile(item.description,id,item.parent,item.owner,item.parentHost,item.path,item.depth)
      if d.hostRoot(id)!=before:d.repairAncestors(id)
    if data.root==0:
      let config=data.owner.applicationConfig
      d.changes.window=some(HostWindow(title:config.title,width:config.width,height:config.height))
    d.prepareHost()
    result=d
  except CatchableError:
    d.reject()
    raise
method stageViewport*(base:ManagedDriver,key:string,first,finish:int,protected:seq[int]):RuntimeDriver=
  var d=base
  if d.candidate==nil:
    let staged=base.stage(false)
    if staged!=nil:d=ManagedDriver(staged)
    else:
      d=ManagedDriver(data:base.data,count:base.data.count,componentCount:base.data.componentCount,bytes:base.data.bytes,root:base.data.root)
      d.attempt=d.data.states.beginAttempt()
  try:
    var target:Instance
    for item in d.edits.values:
      if item!=nil and item.description.kind==DescriptionKind.host and (item.path==key or item.description.key==key):target=item
    if target==nil:
      var id=d.data.index.getOrDefault(key)
      if id==0:
        if not d.data.keys.hasKey(key) or d.data.keys[key].len!=1:fail("unknown or ambiguous list")
        for found in d.data.keys[key]:id=found
      target=d.current(id)
    if target==nil or target.description.hostNode.kind!=NodeKind.virtualList:fail("not a virtual list")
    target=target.copyInstance()
    d.materializeList(target,first,finish,protected)
    d.prepareHost()
    result=d
  except CatchableError:
    d.reject()
    raise
proc removeIndex(data:ManagedStore,item:Instance) {.raises:[].}=
  if item.description.kind!=DescriptionKind.host or not item.active:return
  data.index.del(item.path)
  let key=item.description.key
  if key.len>0:
    if data.keys.hasKey(key):
      data.keys.mgetOrPut(key,default(HashSet[uint64])).excl(item.id)
      if data.keys.mgetOrPut(key,default(HashSet[uint64])).len==0:data.keys.del(key)
method publish*(d:ManagedDriver) {.raises:[].}=
  if d.candidate==nil:return
  let data=d.data
  for id,item in d.edits:
    let old=data.instances.getOrDefault(id)
    if old!=nil:data.removeIndex(old)
    if item==nil:
      data.instances.del(id);data.states.disposeOwner(id)
    else:data.instances[id]=item
  for id,item in d.edits:
    if item!=nil and item.active and item.description.kind==DescriptionKind.host:
      data.index[item.path]=id
      let key=item.description.key
      if key.len>0:data.keys.mgetOrPut(key,default(HashSet[uint64])).incl(id)
  data.reconciler.publish(d.candidate)
  data.states.publishAttempt(d.attempt)
  data.root=d.root;data.count=d.count;data.componentCount=d.componentCount;data.bytes=d.bytes
  data.snapshotValid=d.exported.isSome
  if d.exported.isSome:data.snapshot=d.exported.get
  let h=d.candidate.stats
  data.totals.componentRenders+=d.measurements.componentRenders
  data.totals.normalizedHosts+=d.measurements.normalizedHosts
  data.totals.visitedHosts+=h.visitedHosts
  data.totals.indexEdits+=h.indexEdits
  data.totals.ops+=h.ops
  d.edits.clear();d.changes=default(HostChanges);d.candidate=nil;d.attempt=nil
  d.created.setLen(0);d.computed.clear();d.dirty.clear()
method reject*(d:ManagedDriver) {.raises:[].}=
  if d.attempt!=nil:d.data.states.rejectAttempt(d.attempt)
  d.data.states.clearQueued()
  d.data.invalid.clear()
  for owner in d.created:d.data.states.disposeOwner(owner)
  d.edits.clear();d.candidate=nil;d.attempt=nil;d.created.setLen(0)
proc lookup(data:ManagedStore,key:string):Instance=
  var id=data.index.getOrDefault(key)
  if id==0:
    if not data.keys.hasKey(key):fail("node key not found: " & key)
    if data.keys[key].len!=1:fail("ambiguous key: " & key & "; use full node ID")
    for found in data.keys[key]:id=found
  data.instances.getOrDefault(id)
proc exportNode(d:ManagedDriver,id:uint64,rowIndex= -1):MountedNode=
  let item=d.current(id)
  let index=if rowIndex>=0:rowIndex else:item.rowIndex
  if item.description.kind==DescriptionKind.component:return d.exportNode(item.children[0],index)
  var children:seq[MountedNode]
  for child in item.children:children.add(d.exportNode(child))
  mountedDescription(item.description.hostNode,item.path,children,itemIndex=index)
method exportSnapshot*(d:ManagedDriver):Snapshot=
  if d.candidate!=nil:
    let config=d.data.owner.applicationConfig
    if d.exported.isNone:
      inc d.data.totals.snapshotExports
      d.exported=some(Snapshot(title:config.title,width:config.width,height:config.height,root:d.exportNode(d.root)))
    return d.exported.get
  if not d.data.snapshotValid:
    inc d.data.totals.snapshotExports
    let config=d.data.owner.applicationConfig
    d.data.snapshot=Snapshot(title:config.title,width:config.width,height:config.height,root:d.exportNode(d.data.root))
    d.data.snapshotValid=true
  d.data.snapshot
method find*(d:ManagedDriver,key:string):MountedNode=
  var item:Instance
  try:item=d.current(d.data.lookup(key).id)
  except UiError:
    for edited in d.edits.values:
      if edited!=nil and edited.description.kind==DescriptionKind.host and (edited.path==key or edited.description.key==key):
        if item!=nil:fail("ambiguous key: " & key)
        item=edited
  if item==nil:fail("node key not found: " & key)
  d.exportNode(item.id)
method invokeAccepted*(d:ManagedDriver,key:string,event:Event):bool=
  let node=d.data.lookup(key).description.hostNode
  if node.disabled:return false
  let handler=node.handler(event.kind)
  if handler==nil:fail("node has no handler: " & key)
  handler(event)
  true
method stats*(d:ManagedDriver):PerformanceStats=
  PerformanceStats(renders:d.data.totals.componentRenders,builtNodes:d.data.totals.normalizedHosts,
    mountedNodes:d.data.count,treeBytes:d.data.bytes)
proc componentApplication*(root:UiDescription,title:string,width=640,height=480,
    executionScope:ExecutionScope=nil):Application=
  if root==nil:fail("component application needs a root")
  newDriverApplication(title,width,height,proc(owner:Runtime):RuntimeDriver=
    inc nextManagedId
    let data=ManagedStore(owner:owner,states:newStateStore(nextManagedId),
      reconciler:newHostReconciler(nextManagedId),rootDescription:root,nextId:1,
      instances:initTable[uint64,Instance](MaxNodes*4),index:initTable[string,uint64](MaxNodes*4),
      keys:initTable[string,HashSet[uint64]](MaxNodes*4))
    ManagedDriver(data:data),executionScope)
proc managed*(runtime:Runtime):bool=runtime.runtimeDriver of ManagedDriver
proc managedReconciler*(runtime:Runtime):HostReconciler=
  if not runtime.managed:fail("runtime is not managed")
  ManagedDriver(runtime.runtimeDriver).data.reconciler
proc hostCandidate*(runtime:Runtime):HostCandidate=
  if runtime.managed:ManagedDriver(runtime.runtimeDriver).candidate else:nil
proc updateStats*(runtime:Runtime):UpdateStats=
  if runtime.managed:ManagedDriver(runtime.runtimeDriver).data.totals else:default(UpdateStats)
proc invalidateRoot*(runtime:Runtime)=
  if not runtime.managed:fail("invalidateRoot requires managed runtime")
  ManagedDriver(runtime.runtimeDriver).data.forceRoot=true

proc useNativePolicy*(runtime:Runtime,capabilities:BackendCapabilities,mode=compatible):seq[CapabilityIssue]=
  let data=ManagedDriver(runtime.runtimeDriver).data
  for item in data.instances.values:
    if item.description.kind==DescriptionKind.host:
      let node=item.description.hostNode
      let props=normalizeHostProps(node,nativeStrict)
      result.add(checkTypedCapabilities(item.path,node.kind,props.normalized,capabilities,mode))
  data.policy=nativeStrict

proc listStats*(runtime:Runtime,key:string):tuple[activeRows,warmRows,instances,activeInstances,eventBindings:int]=
  let d=ManagedDriver(runtime.runtimeDriver)
  let item=d.data.lookup(key)
  result.activeRows=item.children.len
  result.warmRows=item.rows.len-item.children.len
  result.instances=d.data.instances.len
  for instance in d.data.instances.values:
    if instance.active:
      inc result.activeInstances
      if instance.description.kind==DescriptionKind.host:
        let node=instance.description.hostNode
        for kind in EventKind:
          if node.handler(kind)!=nil:inc result.eventBindings

proc recordFfiBytes*(runtime:Runtime,bytes:uint64) {.raises:[].}=
  if runtime.managed:ManagedDriver(runtime.runtimeDriver).data.totals.ffiBytes+=bytes
