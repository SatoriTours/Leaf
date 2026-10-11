## Managed component instances and affected overlays. The accepted maps are flat;
## successful publication replaces entries and never retains a candidate chain.
import std/[tables,sets,options,algorithm]
import ./[core,component_description,component_state,host_reconcile,backend]
export host_protocol.UpdateStats

type
  Instance=ref object
    id,parent,owner:uint64
    depth:int
    path:string
    description:UiDescription
    model:ComponentModel
    children:seq[uint64]
    handle,parentHost:NodeHandle
    bytes:int
  ManagedStore=ref object
    owner:Runtime
    states:StateStore
    reconciler:HostReconciler
    rootDescription:UiDescription
    root,nextId:uint64
    instances:Table[uint64,Instance]
    index:Table[string,uint64]
    keys:Table[string,seq[uint64]]
    invalid:HashSet[uint64]
    count,bytes:int
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
    count,bytes:int
    measurements:UpdateStats
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
proc erase(d:ManagedDriver,id:uint64)=
  let old=d.current(id)
  if old==nil:return
  for child in old.children:d.erase(child)
  d.edits[id]=nil
  dec d.count;d.bytes-=old.bytes
  if old.description.kind==DescriptionKind.host:d.changes.removals.add(old.handle)
  else:d.changes.boundaries.add(HostBoundary(id:id))
proc allocate(d:ManagedDriver):uint64=
  if d.data.nextId==high(uint64):fail("component identity exhausted")
  result=d.data.nextId;inc d.data.nextId
  d.created.add(result)
proc reconcile(d:ManagedDriver,desc:UiDescription,oldId,parent,owner:uint64,
    parentHost:NodeHandle,path:string,depth:int):uint64=
  if desc==nil:fail("nil UI description")
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
  let item=Instance(id:id,parent:parent,owner:owner,depth:depth,path:path,description:desc,parentHost:parentHost)
  if old==nil:inc d.count
  else:d.bytes-=old.bytes
  item.bytes=descriptionBytes(desc,path);d.bytes+=item.bytes
  if d.count>MaxNodes or d.bytes>MaxTreeBytes:fail("managed description exceeds node/instance/byte budget")
  d.edits[id]=item
  if desc.kind==DescriptionKind.component:
    if old!=nil:item.model=old.model
    else:
      d.data.states.setPhase(StatePhase.initializing)
      try:item.model=desc.erased.instantiate(newMountContext(d.data.states,id))
      finally:d.data.states.setPhase(StatePhase.idle)
    if old!=nil and id notin d.dirty and desc.erased.equalProps(old.description.erased):
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
    item.children= @[d.reconcile(output,previous,id,id,parentHost,path & "/r",depth+1)]
    let root=d.hostRoot(id)
    if old==nil or root!=oldRoot:
      d.changes.boundaries.add(HostBoundary(id:id,root:root,parent:owner))
  else:
    item.handle=if old==nil:d.data.reconciler.reserveHandle() else:old.handle
    let node=desc.hostNode
    item.description=hostShell(node,@[])
    let props=normalizeHostProps(node,d.data.policy)
    inc d.measurements.normalizedHosts
    d.changes.upserts.add(HostRecord(handle:item.handle,parent:parentHost,nodeId:path,
      kind:node.kind,props:props,boundaryId:owner))
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
method stage*(base:ManagedDriver,forceRoot:bool):RuntimeDriver=
  let data=base.data
  let forceRoot=forceRoot or data.forceRoot
  data.forceRoot=false
  let queued=data.states.pendingOwners()
  if not forceRoot and queued.len==0 and data.invalid.len==0:return nil
  let d=ManagedDriver(data:data,count:data.count,bytes:data.bytes,root:data.root)
  try:
    d.attempt=data.states.beginAttempt()
    d.dirty=data.invalid
    data.invalid.clear()
    for owner in d.attempt.dirtyOwners:d.dirty.incl(owner)
    if forceRoot or data.root==0:
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
      if item==nil:continue
      let before=d.hostRoot(id)
      discard d.reconcile(item.description,id,item.parent,item.owner,item.parentHost,item.path,item.depth)
      if d.hostRoot(id)!=before:d.repairAncestors(id)
    if data.root==0:
      let config=data.owner.applicationConfig
      d.changes.window=some(HostWindow(title:config.title,width:config.width,height:config.height))
    d.candidate=data.reconciler.planDelta(d.changes,data.owner.acceptedRevision+1)
    data.reconciler.validate(d.candidate)
    data.states.validateAttempt(d.attempt)
    result=d
  except CatchableError:
    d.reject()
    raise
proc removeIndex(data:ManagedStore,item:Instance) {.raises:[].}=
  if item.description.kind!=DescriptionKind.host:return
  data.index.del(item.path)
  let key=item.description.key
  if key.len>0:
    var ids=data.keys.getOrDefault(key)
    for i in countdown(ids.high,0):
      if ids[i]==item.id:ids.delete(i)
    if ids.len==0:data.keys.del(key)
    else:data.keys[key]=ids
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
    if item!=nil and item.description.kind==DescriptionKind.host:
      data.index[item.path]=id
      let key=item.description.key
      if key.len>0:data.keys.mgetOrPut(key,@[]).add(id)
  data.reconciler.publish(d.candidate)
  data.states.publishAttempt(d.attempt)
  data.root=d.root;data.count=d.count;data.bytes=d.bytes
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
    let ids=data.keys.getOrDefault(key)
    if ids.len==0:fail("node key not found: " & key)
    if ids.len!=1:fail("ambiguous key: " & key & "; use full node ID")
    id=ids[0]
  data.instances.getOrDefault(id)
proc exportNode(d:ManagedDriver,id:uint64):MountedNode=
  let item=d.current(id)
  if item.description.kind==DescriptionKind.component:return d.exportNode(item.children[0])
  var children:seq[MountedNode]
  for child in item.children:children.add(d.exportNode(child))
  mountedDescription(item.description.hostNode,item.path,children)
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
      keys:initTable[string,seq[uint64]](MaxNodes*4))
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
