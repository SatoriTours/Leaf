## Managed component instances and affected overlays. The accepted maps are flat;
## successful publication replaces entries and never retains a candidate chain.
import ./task_worker
import std/[tables,sets,options,algorithm]
import ./[core,component_description,component_state,host_reconcile,backend,task_service,task_contracts]
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
    outlet:PageOutletSpec
    currentPage:string
    currentRetention:PageRetention
    retained:ref Table[string,uint64]
    registryBytes:int
    ownedBytes:int
    registration:OwnerRegistration
    siblingIndex:int
  ManagedStore=ref object
    owner:Runtime
    states:StateStore
    tasks:TaskService
    reconciler:HostReconciler
    rootDescription:UiDescription
    root,nextId,nextTypeId:uint64
    typeTokens:Table[string,uint64]
    instances:Table[uint64,Instance]
    index:Table[string,uint64]
    keys:Table[string,HashSet[uint64]]
    outlets:Table[uint64,uint64]
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
    preparedOutlets:Table[uint64,uint64]
    taskAttempt:TaskAttempt
    taskFrame:TaskIntentFrame
    metadataOnly:bool
var nextManagedId:uint64
proc current(d:ManagedDriver,id:uint64):Instance=
  if d.edits.hasKey(id):d.edits.getOrDefault(id) else:d.data.instances.getOrDefault(id)
proc hostRoot(d:ManagedDriver,id:uint64):NodeHandle=
  let item=d.current(id)
  if item==nil:return NoHandle
  case item.description.kind
  of DescriptionKind.host:return item.handle
  of DescriptionKind.component,DescriptionKind.pageOutlet:
    if item.children.len>0:return d.hostRoot(item.children[0])
proc segment(desc:UiDescription,index:int):string=
  let key=desc.key
  if key.len==0:"i:" & $index else:"k:" & $key.len & ":" & key
const OutletRegistrationBytes=64
when defined(leafProtocolProbes):
  var outletRegistryEdits*:uint64
proc newOutletRegistry():ref Table[string,uint64]=
  new(result)
  result[]=initTable[string,uint64]()
proc cloneOutletRegistry(source:ref Table[string,uint64]):ref Table[string,uint64]=
  result=newOutletRegistry()
  if source!=nil:result[]=source[]
proc outletRegistrationBytes(key:string):int=OutletRegistrationBytes+key.len
proc descriptionBytes(desc:UiDescription,path:string):int=
  result=128+path.len+desc.key.len
  case desc.kind
  of DescriptionKind.host:
    let node=desc.hostNode
    result+=node.text.len+node.placeholder.len
    for styles in [node.styles,node.attributes]:
      for key,value in styles:result+=32+key.len+value.len
    if node.listSource!=nil:
      let source=node.listSource
      result+=source.len*16
      for i in 0..<source.len:result+=source.itemKey(i).len
  of DescriptionKind.component:discard
  of DescriptionKind.pageOutlet:
    let spec=desc.outletSpec
    result+=32+spec.page.len+spec.view.len+spec.configurationBytes
proc copyInstance(item:Instance):Instance=
  result=Instance()
  result[]=item[]
proc materializeList(d:ManagedDriver,item:Instance,first,finish:int,protected:seq[int])
proc deactivate(d:ManagedDriver,id:uint64)
proc erase(d:ManagedDriver,id:uint64)=
  let old=d.current(id)
  if old==nil:return
  var children=old.children
  for slot in old.rows.values:
    if slot.id notin children:children.add(slot.id)
  if old.description.kind==DescriptionKind.pageOutlet and old.retained!=nil:
    for page,root in old.retained:
      if root!=0 and root notin children:children.add(root)
  for child in children:d.erase(child)
  d.edits[id]=nil
  dec d.count;d.bytes-=old.bytes
  case old.description.kind
  of DescriptionKind.component:
    dec d.componentCount
    if old.active:d.changes.boundaries.add(HostBoundary(id:id))
  of DescriptionKind.host:
    if old.handle!=NoHandle:d.changes.removals.add(old.handle)
  of DescriptionKind.pageOutlet:discard
proc allocate(d:ManagedDriver):uint64=
  if d.data.nextId==high(uint64):fail("component identity exhausted")
  result=d.data.nextId;inc d.data.nextId
  d.created.add(result)
proc typeSegment(data:ManagedStore,definition:ErasedComponent):string=
  let identity=definition.typeId
  var token=data.typeTokens.getOrDefault(identity)
  if token==0:
    if data.nextTypeId==high(uint64):fail("component type identity exhausted")
    inc data.nextTypeId
    token=data.nextTypeId;data.typeTokens[identity]=token
  "/t:" & $token
proc reconcile(d:ManagedDriver,desc:UiDescription,oldId,parent,owner:uint64,
    parentHost:NodeHandle,path:string,depth:int,siblingIndex=0):uint64=
  if desc==nil:fail("nil UI description")
  if path.len>MaxStringBytes:fail("managed node ID exceeds 1 MiB")
  if depth>MaxDepth:fail("managed description exceeds depth 64")
  var old=d.current(oldId)
  let same=old!=nil and old.description.kind==desc.kind and old.description.key==desc.key and
    (case desc.kind
     of DescriptionKind.component:old.description.erased.typeId==desc.erased.typeId
     of DescriptionKind.host:old.description.hostNode.kind==desc.hostNode.kind
     of DescriptionKind.pageOutlet:true)
  if not same:
    if old!=nil:d.erase(old.id)
    old=nil
  let oldRoot=if old==nil:NoHandle else:d.hostRoot(old.id)
  let id=if old==nil:d.allocate() else:old.id
  let item=Instance(id:id,parent:parent,owner:owner,depth:depth,path:path,description:desc,parentHost:parentHost,active:true,rowIndex: -1,siblingIndex:siblingIndex)
  if old==nil:
    inc d.count
    if desc.kind==DescriptionKind.component:inc d.componentCount
  else:
    d.bytes-=old.bytes
    item.rowIndex=old.rowIndex
  if desc.kind==DescriptionKind.pageOutlet:
    if old!=nil:
      item.outlet=old.outlet
      item.retained=old.retained
      item.currentPage=old.currentPage
      item.currentRetention=old.currentRetention
      item.children=old.children
      item.registryBytes=old.registryBytes
    else:
      item.retained=newOutletRegistry()
      item.currentPage=""
      item.currentRetention=PageRetention.retainState
      item.registryBytes=0
  item.bytes=descriptionBytes(desc,path)+item.registryBytes;d.bytes+=item.bytes
  if d.count-d.componentCount>MaxNodes or d.componentCount>MaxNodes or d.bytes>MaxTreeBytes:fail("managed description exceeds node/instance/byte budget")
  d.edits[id]=item
  case desc.kind
  of DescriptionKind.component:
    if old!=nil:
      item.model=old.model
      item.ownedBytes=old.ownedBytes
      item.registration=old.registration
    else:
      var mount:MountContext
      d.data.states.setPhase(StatePhase.initializing)
      try:
        item.registration=newOwnerRegistration(d.data.tasks,id)
        mount=newMountContext(d.data.states,id,item.registration)
        item.model=desc.erased.instantiate(mount)
      finally:
        # Close the accounting frame on both the success and the exception exit;
        # the readonly scalar is read once after the frame is closed.
        if mount!=nil:sealMountContext(mount)
        d.data.states.setPhase(StatePhase.idle)
      item.ownedBytes=ownedDescriptionBytes(mount)
    # Owned configuration/description bytes are charged once, before children.
    if item.ownedBytes!=0:
      if item.ownedBytes > MaxTreeBytes - d.bytes:
        fail("managed description exceeds node/instance/byte budget")
      d.bytes+=item.ownedBytes
      item.bytes+=item.ownedBytes
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
    item.children= @[d.reconcile(output,previous,id,id,parentHost,path & d.data.typeSegment(desc.erased) & "/r/" & segment(output,0),depth+1)]
    let root=d.hostRoot(id)
    if old==nil or root!=oldRoot or d.globalRefresh:
      d.changes.boundaries.add(HostBoundary(id:id,root:root,parent:owner))
  of DescriptionKind.host:
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
      let childId=d.reconcile(child,previous.getOrDefault(part),id,owner,item.handle,path & "/" & part,depth+1,i)
      item.children.add(childId)
      order.add(d.hostRoot(childId))
    for part,childId in previous:
      if part notin seen:d.erase(childId)
    d.changes.children.add(HostChildren(parent:item.handle,children:order))
  of DescriptionKind.pageOutlet:
    let spec=desc.outletSpec
    item.outlet=spec
    let built=spec.build()
    if built==nil:fail("page outlet build returned nil")
    let pagePath=path & "/p:" & $spec.page.len & ":" & spec.page
    var registryOwned=old==nil
    let registryStart=item.registryBytes
    template ownRegistry() =
      if not registryOwned:
        item.retained=cloneOutletRegistry(item.retained);registryOwned=true
    var childId:uint64
    if item.currentPage==spec.page and item.children.len>0:
      childId=d.reconcile(built,item.children[0],id,owner,parentHost,pagePath,depth+1)
    else:
      if item.currentPage.len>0 and item.children.len>0:
        let leaving=item.children[0]
        if item.currentRetention==PageRetention.disposeOnLeave:
          d.erase(leaving)
          if item.retained.getOrDefault(item.currentPage)!=0:
            ownRegistry()
            let removed=item.currentPage
            item.retained.del(removed)
            item.registryBytes-=outletRegistrationBytes(removed)
            when defined(leafProtocolProbes):inc outletRegistryEdits
        else:
          d.deactivate(leaving)
      let existing=item.retained.getOrDefault(spec.page)
      childId=d.reconcile(built,existing,id,owner,parentHost,pagePath,depth+1)
    # The registry keeps every visited page (active or inactive). An absent key
    # adds one entry charge; an existing page whose root id is replaced keeps
    # the same registry entry and only updates its value.
    let previous=item.retained.getOrDefault(spec.page)
    if previous!=childId:
      ownRegistry()
      item.retained[spec.page]=childId
      if previous==0:
        item.registryBytes+=outletRegistrationBytes(spec.page)
      when defined(leafProtocolProbes):inc outletRegistryEdits
    item.currentPage=spec.page
    item.currentRetention=spec.retention
    item.children= @[childId]
    # The registry byte charge is cached on the instance and adjusted only when
    # a registration is added or removed, so warm revisits scan no keys.
    let registryDelta=item.registryBytes-registryStart
    if registryDelta!=0:
      item.bytes+=registryDelta
      d.bytes+=registryDelta
      if d.bytes>MaxTreeBytes:fail("managed description exceeds node/instance/byte budget")
  id
proc repairAncestors(d:ManagedDriver,id:uint64)=
  var child=id
  var item=d.current(id)
  var parent=if item==nil:0'u64 else:item.parent
  while parent!=0:
    let ancestor=d.current(parent)
    if ancestor==nil:return
    case ancestor.description.kind
    of DescriptionKind.host:
      var order:seq[NodeHandle]
      for child in ancestor.children:order.add(d.hostRoot(child))
      var replaced=false
      for existing in d.changes.children.mitems:
        if existing.parent==ancestor.handle:existing.children=order;replaced=true
      if not replaced:d.changes.children.add(HostChildren(parent:ancestor.handle,children:order))
      return
    of DescriptionKind.component:
      d.changes.boundaries.add(HostBoundary(id:parent,root:d.hostRoot(child),parent:ancestor.owner))
    of DescriptionKind.pageOutlet:discard
    child=parent;parent=ancestor.parent
proc retainedDescription(d:ManagedDriver,id:uint64):UiDescription=
  let item=d.current(id)
  case item.description.kind
  of DescriptionKind.component:return item.description
  of DescriptionKind.pageOutlet:
    if item.children.len==0:fail("page outlet has no active page")
    let active=d.retainedDescription(item.children[0])
    var spec=item.description.outletSpec
    spec.build=proc():UiDescription=active
    return pageOutlet(spec,item.description.key)
  of DescriptionKind.host:
    var children:seq[UiDescription]
    for child in item.children:children.add(d.retainedDescription(child))
    hostShell(item.description.hostNode,children)
proc deactivate(d:ManagedDriver,id:uint64)=
  let old=d.current(id)
  if old==nil or not old.active:return
  let item=old.copyInstance()
  item.active=false
  for child in item.children:d.deactivate(child)
  case item.description.kind
  of DescriptionKind.host:
    if item.handle!=NoHandle:d.changes.removals.add(item.handle)
    item.handle=NoHandle
  of DescriptionKind.component:
    d.changes.boundaries.add(HostBoundary(id:id))
  of DescriptionKind.pageOutlet:discard
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
        item.path & "/item/k:" & $key.len & ":" & key,item.depth+1,index)
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
when defined(leafProtocolProbes):
  var outletIndexLookups*:uint64
  var outletIndexEdits*:uint64
proc prepareOutlets(d:ManagedDriver)=
  ## Incremental router-identity overlay. Only tokens touched by this candidate
  ## are checked, and only their final owner (or a removal encoded as 0) enters
  ## the delta; an unrelated local update scans or copies no index entries.
  d.preparedOutlets.clear()
  var touched:HashSet[uint64]
  var candidateOwners:Table[uint64,uint64]
  for id,item in d.edits:
    let accepted=d.data.instances.getOrDefault(id)
    if accepted!=nil and accepted.description.kind==DescriptionKind.pageOutlet:
      touched.incl(accepted.outlet.routerId)
    if item!=nil and item.description.kind==DescriptionKind.pageOutlet:
      let token=item.outlet.routerId
      touched.incl(token)
      if candidateOwners.hasKey(token) and candidateOwners[token]!=id:
        fail("duplicate page outlet route identity")
      candidateOwners[token]=id
  if touched.len==0:return
  for token in touched:
    var owner=0'u64
    if candidateOwners.hasKey(token):owner=candidateOwners[token]
    when defined(leafProtocolProbes):inc outletIndexLookups
    let acceptedOwner=d.data.outlets.getOrDefault(token)
    if acceptedOwner!=0:
      let survivor=d.current(acceptedOwner)
      if survivor!=nil and survivor.description.kind==DescriptionKind.pageOutlet and survivor.outlet.routerId==token:
        if owner!=0 and owner!=acceptedOwner:fail("duplicate page outlet route identity")
        if owner==0:owner=acceptedOwner
    d.preparedOutlets[token]=owner
    when defined(leafProtocolProbes):inc outletIndexEdits
proc prepareLifecycle(d:ManagedDriver)=
  type OrderedTransition=object
    registration:OwnerRegistration
    kind:LifecyclePhase
    depth:int
    ranks:seq[int]
    path:string
    active:bool
  var ordered:seq[OrderedTransition]
  var registrations:seq[OwnerRegistration]
  for id,item in d.edits:
    let old=d.data.instances.getOrDefault(id)
    if item!=nil and item.description.kind==DescriptionKind.component and old==nil:
      registrations.add(item.registration)
    var source:Instance
    var kind:LifecyclePhase
    var entering=false
    if old!=nil and old.description.kind==DescriptionKind.component:
      if item==nil:source=old;kind=LifecyclePhase.dispose
      elif old.active and not item.active:source=old;kind=LifecyclePhase.deactivate
      elif not old.active and item.active:source=item;kind=LifecyclePhase.activate;entering=true
    elif old==nil and item!=nil and item.description.kind==DescriptionKind.component:
      source=item;kind=LifecyclePhase.mount;entering=true
    # Newly created and erased in this overlay has no accepted owner and no
    # final instance: neither its registration nor a cleanup event escapes.
    if source==nil:continue
    var ranks:seq[int]
    var ancestor=source
    while ancestor!=nil:
      ranks.add(ancestor.siblingIndex)
      if ancestor.parent==0:break
      ancestor=if entering:d.current(ancestor.parent) else:d.data.instances.getOrDefault(ancestor.parent)
    ranks.reverse()
    ordered.add(OrderedTransition(registration:source.registration,kind:kind,
      depth:source.depth,ranks:move(ranks),path:source.path,active:item!=nil and item.active))
  ordered.sort(proc(a,b:OrderedTransition):int=
    let aEnter=a.kind in {LifecyclePhase.mount,LifecyclePhase.activate}
    let bEnter=b.kind in {LifecyclePhase.mount,LifecyclePhase.activate}
    result=cmp(aEnter,bEnter)
    if result==0:result=(if aEnter:cmp(a.depth,b.depth) else:cmp(b.depth,a.depth))
    if result==0:
      for i in 0..<min(a.ranks.len,b.ranks.len):
        result=cmp(a.ranks[i],b.ranks[i])
        if result!=0:break
    if result==0:result=cmp(a.ranks.len,b.ranks.len)
    # Retained pages share a child slot but have distinct stable page paths.
    if result==0:result=cmp(a.path,b.path))
  var transitions:seq[OwnerTransition]
  for i,transition in ordered:
    transitions.add(ownerTransitionInternal(transition.registration,transition.kind,transition.depth,uint64(i),transition.active))
  if d.taskAttempt!=nil:d.data.tasks.rejectTasks(d.taskAttempt)
  d.taskAttempt=d.data.tasks.prepareTasks(d.data.owner.acceptedRevision+1,transitions,registrations,d.taskFrame)
  if d.taskAttempt.preparedTaskBytesInternal > MaxTreeBytes-d.bytes:
    fail("managed description and pending lifecycle events exceed 16 MiB")

proc prepareHost(d:ManagedDriver)=
  d.prepareOutlets()
  d.prepareLifecycle()
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
  if not forceRoot and queued.len==0 and data.invalid.len==0 and not data.tasks.hasTaskIntents:return nil
  let d=ManagedDriver(data:data,count:data.count,componentCount:data.componentCount,bytes:data.bytes,root:data.root,globalRefresh:forceRoot)
  try:
    d.taskFrame=data.tasks.sealTaskIntentsInternal()
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
      discard d.reconcile(item.description,id,item.parent,item.owner,item.parentHost,item.path,item.depth,item.siblingIndex)
      if d.hostRoot(id)!=before:d.repairAncestors(id)
    if data.root==0:
      let config=data.owner.applicationConfig
      d.changes.window=some(HostWindow(title:config.title,width:config.width,height:config.height))
    d.metadataOnly=d.edits.len==0 and d.changes.upserts.len==0 and d.changes.removals.len==0
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
      d.taskFrame=d.data.tasks.sealTaskIntentsInternal()
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
    d.metadataOnly=false
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
  data.tasks.publishTasks(d.taskAttempt)
  # Apply only the prepared token delta; unrelated registrations are untouched.
  for token,owner in d.preparedOutlets:
    if owner==0:data.outlets.del(token)
    else:data.outlets[token]=owner
  data.root=d.root;data.count=d.count;data.componentCount=d.componentCount;data.bytes=d.bytes
  if not d.metadataOnly:
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
  d.taskAttempt=nil
  d.taskFrame=nil
method reject*(d:ManagedDriver) {.raises:[].}=
  d.data.tasks.rejectTaskIntentsInternal(d.taskFrame)
  d.taskFrame=nil
  d.data.tasks.rejectTasks(d.taskAttempt)
  d.taskAttempt=nil
  if d.attempt!=nil:d.data.states.rejectAttempt(d.attempt)
  d.data.states.clearQueued()
  d.data.invalid.clear()
  for owner in d.created:d.data.states.disposeOwner(owner)
  d.edits.clear();d.candidate=nil;d.attempt=nil;d.created.setLen(0)
  d.preparedOutlets.clear()
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
  case item.description.kind
  of DescriptionKind.component:return d.exportNode(item.children[0],index)
  of DescriptionKind.pageOutlet:
    if item.children.len==0:fail("page outlet has no active page")
    return d.exportNode(item.children[0],index)
  of DescriptionKind.host:
    var children:seq[MountedNode]
    for child in item.children:children.add(d.exportNode(child))
    mountedDescription(item.description.hostNode,item.path,children,itemIndex=index)
method exportSnapshot*(d:ManagedDriver):Snapshot=
  if d.metadataOnly and d.data.snapshotValid:return d.data.snapshot
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
    mountedNodes:d.data.count,treeBytes:d.data.bytes+d.data.tasks.pendingTaskBytesInternal)
method configureTaskPumpDriverInternal*(d:ManagedDriver,supported:bool)=
  d.data.tasks.configureTaskServiceInternal(supported)
method retireTaskPoolDriverInternal*(d:ManagedDriver)=
  d.data.tasks.retireTaskPoolServiceInternal()
method finalizeTaskPoolDriverInternal*(d:ManagedDriver)=
  d.data.tasks.finalizeTaskPoolServiceInternal()
method requireCloseAccessInternal*(d:ManagedDriver)=
  d.data.tasks.requireCloseTaskAccessInternal()
method prepareCloseDeferredInternal*(d:ManagedDriver)=
  var owners:seq[Instance]
  for item in d.data.instances.values:
    if item.description.kind==DescriptionKind.component:owners.add(item)
  proc ranks(item:Instance):seq[int]=
    var ancestor=item
    while ancestor!=nil:
      result.add(ancestor.siblingIndex)
      ancestor=d.data.instances.getOrDefault(ancestor.parent)
    result.reverse()
  owners.sort(proc(a,b:Instance):int=
    result=cmp(b.depth,a.depth)
    if result==0:
      let left=ranks(a);let right=ranks(b)
      for i in 0..<min(left.len,right.len):
        result=cmp(left[i],right[i])
        if result!=0:break
      if result==0:result=cmp(left.len,right.len)
    if result==0:result=cmp(a.path,b.path))
  var ordered:seq[OwnerRegistration]
  for item in owners:ordered.add(item.registration)
  d.data.tasks.prepareCloseTaskServiceInternal(ordered)
method invalidateCloseStateInternal*(d:ManagedDriver)=
  d.data.tasks.invalidateTaskStateInternal()
  d.data.states.clearQueued()
  d.data.invalid.clear()
method retireDeferred*(d:ManagedDriver) {.raises:[].}=
  d.data.tasks.retireTaskService()
method closeDeferred*(d:ManagedDriver)=
  d.data.tasks.closeTaskService()
method deferredRetiredInternal*(d:ManagedDriver):bool=
  d.data.tasks.taskRetiredInternal()
method taskPumpPendingDriverInternal*(d:ManagedDriver):bool=
  let tasks=d.data.tasks
  not tasks.taskRetiredInternal and (tasks.pendingTaskBytesInternal>0 or tasks.taskWorkerStatsInternal.reservedTasks>0)
method pumpDeferred*(d:ManagedDriver):TaskPumpReport=
  d.data.tasks.pumpTaskService()
proc componentApplication*(root:UiDescription,title:string,width=640,height=480,
    executionScope:ExecutionScope=nil):Application=
  if root==nil:fail("component application needs a root")
  newDriverApplication(title,width,height,proc(owner:Runtime):RuntimeDriver=
    inc nextManagedId
    let data=ManagedStore(owner:owner,states:newStateStore(owner.runtimeIdentity),
      reconciler:newHostReconciler(nextManagedId),rootDescription:root,nextId:1,
      instances:initTable[uint64,Instance](MaxNodes*4),index:initTable[string,uint64](MaxNodes*4),
      keys:initTable[string,HashSet[uint64]](MaxNodes*4),outlets:initTable[uint64,uint64](MaxNodes*2))
    data.tasks=newTaskService(owner,data.states)
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

proc taskServiceInternal*(runtime:Runtime):TaskService=
  if not runtime.managed:fail("Runtime is not managed")
  ManagedDriver(runtime.runtimeDriver).data.tasks
