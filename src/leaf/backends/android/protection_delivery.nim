## Private handoff of protection changes before queued row facts are consumed.
## Call only with the adapter's owning Session after its lifecycle/identity
## gate. This records data; MobileHost.safeTurn still owns business execution.
## The ABI and Views collection are separate from this data-only module.
import std/[tables, options, sets, algorithm]
import ../../[backend, backend_session]
import ./[list_layout, list_geometry, list_protection]

type
  ProtectionReceipt = object
    first, finish: int
    protected: seq[int]
  ProtectionQueue = ref object
    source, mount: uint64
    queued: Option[ProtectionReceipt]
    queuedToken: uint64
  AndroidProtectionDelivery* = ref object
    lists: Table[NodeHandle,ProtectionQueue]
  AndroidProtectionQueueResult* = object
    queued*, refused*: int

proc newAndroidProtectionDelivery*():AndroidProtectionDelivery =
  AndroidProtectionDelivery()

proc sorted(values:seq[int]):seq[int] =
  result= @values
  result.sort()

proc queueProtectionViewports*(delivery:AndroidProtectionDelivery,
    lists:AndroidLists,protection:AndroidRowProtection,session:BackendSession,
    valid:AndroidProtectionBinding):AndroidProtectionQueueResult =
  ## Use the latest accepted bare range, even when its earlier unprotected row
  ## request was already acknowledged. Replacing that queued request before
  ## safeTurn prevents it from removing a newly focused editor.
  ##
  ## Receipts compare complete row facts rather than Native sequence numbers:
  ## duplicate facts and changing reasons within one row need no new delivery.
  ## A refused queue insertion keeps an unacknowledged entry for a later turn.
  if delivery==nil or lists==nil or session==nil:return
  let layout=lists.acceptedListLayout
  if layout==nil:
    delivery.lists.clear()
    return
  let entities=session.acceptedEntities
  let wanted=protection.snapshotProtectedRows(session.mountGeneration,entities,valid)
  var live=initHashSet[NodeHandle]()
  for projection in layout.projections:
    live.incl(projection.handle)
    var state=delivery.lists.getOrDefault(projection.handle)
    if state!=nil and (state.source!=projection.metadata.sourceGeneration or
        state.mount!=session.mountGeneration):
      delivery.lists.del(projection.handle)
      state=nil
    let protected=wanted.getOrDefault(projection.handle)
    if state==nil:
      # Ordinary initial/unprotected rows retain list_delivery's existing
      # next-turn path. Protection activates this receipt only when necessary.
      if protected.len==0 and projection.protected.len==0:continue
      state=ProtectionQueue(source:projection.metadata.sourceGeneration,
        mount:session.mountGeneration)
      delivery.lists[projection.handle]=state
    let fact=ProtectionReceipt(first:projection.geometry.first,
      finish:projection.geometry.finish,protected:protected.sorted)
    if state.queued.isSome and state.queued.get==fact:
      if state.queuedToken==projection.token or
          projection.protected.sorted==fact.protected:
        continue
      # A later candidate may have captured the older reason set before a
      # reentrant focus fact. Give that token its own protected receipt, or
      # ordinary list_delivery could overwrite our earlier queued protection.
    if session.queueRows(RowViewportRequest(sessionId:session.sessionId,
        mountGeneration:session.mountGeneration,listHandle:projection.handle,
        sourceGeneration:projection.metadata.sourceGeneration,
        first:fact.first,finish:fact.finish,protected:fact.protected)):
      state.queued=some(fact)
      state.queuedToken=projection.token
      # The ordinary geometry receipt must not subsequently overwrite this
      # fact with the protection set from an earlier prepared projection.
      discard lists.markListViewportQueued(projection.handle,projection.token)
      inc result.queued
    else:
      inc result.refused
  var obsolete:seq[NodeHandle]
  for handle in delivery.lists.keys:
    if handle notin live:obsolete.add(handle)
  for handle in obsolete:delivery.lists.del(handle)
