## Private candidate geometry for Android virtual rows. No Views, Runtime,
## materialization or native callbacks live here. The accepted frame and its
## HeightIndex stay immutable; the native adapter will project this exact frame.
import std/[math, sets, unicode]
import ../../[core, backend, native_list_layout, height_index]

type
  RowHeightSample* = object
    index*: int
    height*: float64
  AndroidListFrame* = ref object
    props: HostListProps
    heights: HeightIndex
    rows: seq[NativeRowBinding]
    width, viewport, scale: float64
    fontEpoch, intent: uint64
    position: float64
    visible: VisibleRange
    ready: bool
  AndroidListGeometry* = ref object
    handle: NodeHandle
    accepted, pending, retired: AndroidListFrame
    desired: float64
    intent: uint64

proc finite(value:float64):bool = classify(value) notin {fcNan,fcInf,fcNegInf}
proc newAndroidListGeometry*(handle:NodeHandle):AndroidListGeometry =
  if handle==NoHandle: fail("Android list requires a handle")
  AndroidListGeometry(handle:handle)
proc acceptedFrame*(g:AndroidListGeometry):AndroidListFrame = g.accepted
proc desiredOffset*(g:AndroidListGeometry):float64 = g.desired
proc intentGeneration*(g:AndroidListGeometry):uint64 = g.intent
proc hasUnprojectedIntent*(g:AndroidListGeometry):bool =
  g.accepted!=nil and g.intent!=g.accepted.intent
proc offset*(f:AndroidListFrame):float64 = f.position
proc rowsReady*(f:AndroidListFrame):bool = f.ready
proc total*(f:AndroidListFrame):float64 = f.heights.total
proc first*(f:AndroidListFrame):int = f.visible.first
proc finish*(f:AndroidListFrame):int = f.visible.finish
proc prefix*(f:AndroidListFrame,index:int):float64 = f.heights.prefix(index)

proc requestOffset*(g:AndroidListGeometry,value:float64) =
  if not value.finite: fail("Android list intent is not finite")
  if g.intent==high(uint64): fail("Android list intent generation exhausted")
  inc g.intent
  g.desired=value

proc sameHeightContext(f:AndroidListFrame,p:HostListProps,width,scale:float64,
                       fontEpoch:uint64):bool =
  f!=nil and f.props.sourceGeneration==p.sourceGeneration and
    f.props.itemCount==p.itemCount and f.props.heightMode==p.heightMode and
    f.props.rowHeight==p.rowHeight and f.props.estimate==p.estimate and
    f.width==width and f.scale==scale and f.fontEpoch==fontEpoch

proc prepareListGeometry*(g:AndroidListGeometry,p:HostListProps,width,viewport,
    scale:float64,fontEpoch:uint64,rows:seq[NativeRowBinding],
    measured:seq[RowHeightSample],protected:seq[int] = @[]):AndroidListFrame =
  if g.pending!=nil: fail("Android list already has a geometry candidate")
  let reason=p.invalidReason(MaxListItems)
  if reason.len!=0: fail(reason)
  # A collapsed layout may have zero width; it is still a finite context and
  # must invalidate measured heights again when its width is restored.
  if not width.finite or width<0 or not viewport.finite or viewport<0 or
      not scale.finite or scale<=0:
    fail("Android list measurement context is invalid")
  if rows.len>MaxNodes or measured.len>rows.len or protected.len>MaxNodes:
    fail("Android list row geometry budget exceeded")
  var indexes=initHashSet[int]()
  var keys=initHashSet[string]()
  for row in rows:
    if row.listHandle!=g.handle or row.sourceGeneration!=p.sourceGeneration or
        row.itemIndex<0 or row.itemIndex>=p.itemCount or
        row.itemKey.len>MaxStringBytes or row.itemKey.validateUtf8() != -1:
      fail("Android list row identity is invalid")
    if row.itemIndex in indexes or row.itemKey in keys:
      fail("Android list has duplicate row identity")
    indexes.incl(row.itemIndex);keys.incl(row.itemKey)
  var pinned=initHashSet[int]()
  for index in protected:
    if index<0 or index>=p.itemCount: fail("Android protected row is out of range")
    pinned.incl(index)
  let old=g.accepted
  g.retired=nil # Destruction is outside the publication window.
  let candidate=AndroidListFrame(props:p,width:width,viewport:viewport,scale:scale,
    fontEpoch:fontEpoch,intent:g.intent)
  if old.sameHeightContext(p,width,scale,fontEpoch):
    candidate.heights=cloneHeightIndex(old.heights)
  else:
    let estimate=if p.heightMode==HostHeightMode.uniform:p.rowHeight else:p.estimate
    candidate.heights=initHeightIndex(p.itemCount,estimate)
  for row in rows: candidate.rows.add(row) # Own the row vector, never alias caller storage.
  var sampled=initHashSet[int]()
  for sample in measured:
    if sample.index notin indexes or sample.index in sampled:
      fail("Android list measurement is not a unique materialized row")
    if p.heightMode==HostHeightMode.uniform and sample.height!=p.rowHeight:
      fail("Android uniform row measurement differs from its declared height")
    candidate.heights.measure(sample.index,sample.height)
    sampled.incl(sample.index)
  var wanted=g.desired
  # An explicit intent, including one received after the previous prepare,
  # outranks anchoring. Only a known stable key from the same source can anchor.
  if old!=nil and old.props.sourceGeneration==p.sourceGeneration and
      old.intent==g.intent and old.first<old.finish:
    for anchor in old.rows:
      if anchor.itemIndex!=old.first: continue
      for row in candidate.rows:
        if row.itemKey==anchor.itemKey:
          let delta=max(0.0,old.position-old.heights.prefix(anchor.itemIndex))
          wanted=candidate.heights.prefix(row.itemIndex)+
            min(delta,candidate.heights.height(row.itemIndex))
          break
      break
  candidate.position=clampListOffset(candidate.heights.total,viewport,wanted)
  candidate.visible=listVisible(candidate.heights,candidate.position,viewport)
  # Match the Runtime's expansion exactly, including its empty-range behavior.
  # Never pass these expanded endpoints back as a visible fact.
  let neededFirst=max(0,candidate.first-p.overscan)
  let neededFinish=min(p.itemCount,candidate.finish+p.overscan)
  var expected=neededFinish-neededFirst
  for index in pinned:
    if index<neededFirst or index>=neededFinish: inc expected
  candidate.ready=indexes.len==expected
  for index in indexes:
    if (index<neededFirst or index>=neededFinish) and index notin pinned:
      candidate.ready=false
  g.pending=candidate # Failed validation/measurement never installs partial state.
  candidate

proc discardListGeometry*(g:AndroidListGeometry) = g.pending=nil
proc publishListGeometry*(g:AndroidListGeometry):bool {.raises:[].} =
  if g.pending==nil: return false
  swap(g.retired,g.accepted)
  swap(g.accepted,g.pending)
  if g.intent==g.accepted.intent: g.desired=g.accepted.position
  true
