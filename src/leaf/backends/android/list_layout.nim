## Private Android list layout preparation. The shared LayoutScope lays out
## ordinary row subtrees; one immutable list geometry supplies their logical
## positions. No Views, business rendering or native callbacks run here.
import std/[tables, options, algorithm, sets, math]
import ../../[core, backend, native_layout]
import ./list_geometry

type
  ListEntry = ref object
    geometry: AndroidListGeometry
    queuedToken: uint64
    failedIntent: Option[uint64]
    scrollMount, scrollSequence: uint64
  AndroidListAttempt* = object
    owner: ListEntry
    intent: uint64
  AndroidRowSlot* = object
    root*: NodeHandle
    binding*: NativeRowBinding
  AndroidListProjection* = object
    handle*: NodeHandle
    metadata*: HostListProps
    geometry*: AndroidListFrame
    viewport*: DipRect
    rows*: seq[AndroidRowSlot]
    protected*: seq[int]
    token*: uint64
    owner: ListEntry
  AndroidListLayout* = ref object
    boxes*: seq[LayoutBox]
    projections*: seq[AndroidListProjection]
    owners: Table[NodeHandle, ListEntry]
  AndroidListViewport* = object
    handle*: NodeHandle
    sourceGeneration*, token*: uint64
    first*, finish*: int
    protected*: seq[int]
  AndroidLists* = ref object
    accepted, pending, retired: AndroidListLayout
    nextToken: uint64

proc newAndroidLists*():AndroidLists = AndroidLists()
proc acceptedListLayout*(lists:AndroidLists):AndroidListLayout = lists.accepted

proc clippedViewport(a,b:DipRect):DipRect =
  let x=max(a.x,b.x)
  let y=max(a.y,b.y)
  DipRect(x:x,y:y,width:max(0.0,min(a.x+a.width,b.x+b.width)-x),
    height:max(0.0,min(a.y+a.height,b.y+b.height)-y))

proc validateRows(entities:Table[NodeHandle,MountedEntity]):
    Table[NodeHandle,seq[AndroidRowSlot]] =
  if entities.len>MaxNodes:fail("Android list layout node budget exceeded")
  var slots:RowSlotTable
  for handle,e in entities:
    if handle==NoHandle or handle!=e.handle:
      fail("Android list layout handle is invalid")
    if e.parent!=NoHandle and not entities.hasKey(e.parent):
      fail("Android list layout parent is missing")
    if e.kind==virtualList:
      if e.list.isNone:fail("Android list metadata is missing")
      let reason=e.list.get.invalidReason(MaxListItems)
      if reason.len!=0:fail(reason)
    elif e.list.isSome:fail("Android list metadata belongs to a non-list")
    if e.row.isSome:
      let binding=e.row.get
      let parent=entities.getOrDefault(binding.listHandle)
      if parent.kind!=virtualList or parent.list.isNone:
        fail("Android row binding has no typed list")
      let reason=binding.rowBindingReason(parent.list.get,e.parent,handle)
      if reason.len!=0:fail(reason)
      let reserved=slots.reserveRowSlot(binding)
      if reserved.len!=0:fail(reserved)
      result.mgetOrPut(binding.listHandle,@[]).add(
        AndroidRowSlot(root:handle,binding:binding))
    elif e.parent!=NoHandle and entities.getOrDefault(e.parent).kind==virtualList:
      fail("Android direct list child has no typed row binding")
  # Parent walks also reject cycles hidden behind a layout leaf, before layout
  # can recurse. The shared engine handles the actual sizing and arrangement.
  for e in entities.values:
    var parent=e.parent
    var depth=0
    while parent!=NoHandle:
      inc depth
      if depth>MaxDepth:fail("Android list layout tree exceeds depth budget")
      parent=entities.getOrDefault(parent).parent
  for _,rows in result.mpairs:
    rows.sort(proc(a,b:AndroidRowSlot):int=cmp(a.binding.itemIndex,b.binding.itemIndex))

proc discardListLayout*(lists:AndroidLists) =
  if lists.pending!=nil:
    for projection in lists.pending.projections:
      projection.owner.geometry.discardListGeometry()
    lists.pending=nil

proc prepareListLayout*(lists:AndroidLists,
    entities:Table[NodeHandle,MountedEntity],size:DipSize,measure:MeasureProc,
    scale:float64,fontEpoch:uint64,
    protectedRows:Table[NodeHandle,seq[int]]=initTable[NodeHandle,seq[int]]()):
    AndroidListLayout =
  if lists.pending!=nil:fail("Android list layout is already prepared")
  if measure==nil:fail("Android list layout requires measurement")
  let rowGroups=validateRows(entities)
  if lists.nextToken==high(uint64):fail("Android list layout token exhausted")
  inc lists.nextToken # Failed candidates never reuse an acknowledgement token.
  lists.retired=nil # Destruction stays outside publication.
  let candidate=AndroidListLayout()
  let leafMeasure:MeasureProc=proc(e:MountedEntity,available:DipSize):DipSize =
    if e.kind==virtualList:DipSize(width:available.width,height:0)
    else:measure(e,available)
  candidate.boxes=layoutTree(entities,size,leafMeasure)
  var scope=initLayoutScope(entities,leafMeasure)
  var prepared:seq[ListEntry]
  var complete=false
  defer:
    if not complete:
      for owner in prepared:owner.geometry.discardListGeometry()
  var visited=initHashSet[NodeHandle]()
  var cursor=0
  while cursor<candidate.boxes.len:
    let box=candidate.boxes[cursor]
    inc cursor
    if box.handle in visited:fail("Android list layout visits a handle twice")
    visited.incl(box.handle)
    let entity=entities.getOrDefault(box.handle)
    if entity.kind!=virtualList:continue
    let meta=entity.list.get
    let owner=if lists.accepted!=nil and lists.accepted.owners.hasKey(box.handle):
      lists.accepted.owners.getOrDefault(box.handle)
      else:ListEntry(geometry:newAndroidListGeometry(box.handle))
    let rows=rowGroups.getOrDefault(box.handle)
    var bindings:seq[NativeRowBinding]
    var samples:seq[RowHeightSample]
    for row in rows:
      bindings.add(row.binding)
      if meta.heightMode==HostHeightMode.variable:
        # A variable row has intrinsic height, independent of viewport height.
        # A finite shared protocol limit bounds the measurement constraint.
        let measured=scope.measureSubtree(row.root,
          DipSize(width:box.rect.width,height:MaxListDimension))
        samples.add(RowHeightSample(index:row.binding.itemIndex,height:measured.height))
    var pinned:seq[int]
    for index in protectedRows.getOrDefault(box.handle):pinned.add(index)
    let frame=owner.geometry.prepareListGeometry(meta,box.rect.width,box.rect.height,
      scale,fontEpoch,bindings,samples,pinned)
    prepared.add(owner)
    candidate.owners[box.handle]=owner
    candidate.projections.add(AndroidListProjection(handle:box.handle,
      metadata:meta,geometry:frame,viewport:box.rect,rows:rows,protected:pinned,
      token:lists.nextToken,owner:owner))
    let clip=clippedViewport(box.clip,box.rect)
    for row in rows:
      let index=row.binding.itemIndex
      let rect=DipRect(x:box.rect.x,y:box.rect.y+frame.prefix(index)-frame.offset,
        width:box.rect.width,height:frame.prefix(index+1)-frame.prefix(index))
      candidate.boxes.add(scope.layoutSubtree(row.root,rect,clip))
  if visited.len!=entities.len:fail("Android list layout has unreachable entities")
  lists.pending=candidate
  complete=true
  candidate

proc publishListLayout*(lists:AndroidLists):bool {.raises:[].} =
  if lists.pending==nil:return false
  for projection in lists.pending.projections:
    discard projection.owner.geometry.publishListGeometry()
  swap(lists.retired,lists.accepted)
  swap(lists.accepted,lists.pending)
  true

proc requestListOffset*(lists:AndroidLists,handle:NodeHandle,
    sourceGeneration:uint64,offset:float64):bool =
  if lists.accepted==nil or classify(offset) in {fcNan,fcInf,fcNegInf}:return false
  for projection in lists.accepted.projections:
    if projection.handle==handle and projection.metadata.sourceGeneration==sourceGeneration:
      projection.owner.geometry.requestOffset(offset)
      return true

proc recordListOffset*(lists:AndroidLists,handle:NodeHandle,
    sourceGeneration,mount,sequence:uint64,offset:float64):bool =
  ## The ABI validates the live Session/mount first. Sequence belongs to this
  ## accepted list owner, not to a retained history of removed list handles.
  if lists.accepted==nil or sequence==0 or mount==0 or
      classify(offset) in {fcNan,fcInf,fcNegInf}:return false
  for projection in lists.accepted.projections:
    if projection.handle==handle and projection.metadata.sourceGeneration==sourceGeneration:
      let owner=projection.owner
      if owner.scrollMount==mount and sequence<=owner.scrollSequence:return false
      owner.geometry.requestOffset(offset)
      owner.scrollMount=mount
      owner.scrollSequence=sequence
      return true

proc requestProtectionProjection*(lists:AndroidLists,handle:NodeHandle):bool =
  ## Re-project the current desired position after a protection-set change.
  ## An unapplied scroll intent must keep its desired offset.
  if lists.accepted!=nil:
    for projection in lists.accepted.projections:
      if projection.handle==handle:
        let geometry=projection.owner.geometry
        geometry.requestOffset(geometry.desiredOffset)
        return true

proc listProjectionNeeded*(lists:AndroidLists):bool =
  if lists.accepted!=nil:
    for projection in lists.accepted.projections:
      let owner=projection.owner
      if owner.geometry.hasUnprojectedIntent and
          (owner.failedIntent.isNone or owner.failedIntent.get!=owner.geometry.intentGeneration):
        return true

proc captureListAttempt*(lists:AndroidLists):seq[AndroidListAttempt] =
  if lists.accepted!=nil:
    for projection in lists.accepted.projections:
      result.add(AndroidListAttempt(owner:projection.owner,
        intent:projection.owner.geometry.intentGeneration))

proc blockListAttempt*(attempt:seq[AndroidListAttempt]) =
  # Suppress only the intent captured before this attempt, never one recorded
  # by a measurement or native callback while that attempt was running.
  for entry in attempt:entry.owner.failedIntent=some(entry.intent)

proc pendingListViewports*(lists:AndroidLists):seq[AndroidListViewport] =
  if lists.accepted!=nil:
    for projection in lists.accepted.projections:
      if not projection.geometry.rowsReady and projection.owner.queuedToken!=projection.token:
        result.add(AndroidListViewport(handle:projection.handle,
          sourceGeneration:projection.metadata.sourceGeneration,token:projection.token,
          first:projection.geometry.first,finish:projection.geometry.finish,
          protected:projection.protected))

proc markListViewportQueued*(lists:AndroidLists,handle:NodeHandle,token:uint64):bool =
  if lists.accepted!=nil:
    for projection in lists.accepted.projections:
      if projection.handle==handle and projection.token==token and
          not projection.geometry.rowsReady:
        projection.owner.queuedToken=token
        return true
