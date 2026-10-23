## Private, typed row-protection facts. No Runtime, Views, JNI, layout or
## business callbacks run here. The caller supplies the current accepted tree
## and a read-only binding predicate, after its Session/lifecycle gate.
##
## The backend replaces pending row requests before business delivery; Native
## focus/composition collection belongs to the Views adapter.
import std/[tables, sets, options, algorithm]
import ../../[core, backend]

type
  AndroidProtectionReason* = enum
    rowFocused, rowComposing
  AndroidProtectionFact* = object
    handle*: NodeHandle
    mount*, binding*, sequence*: uint64
    reasons*: set[AndroidProtectionReason]
  AndroidProtectionBinding* =
    proc(handle:NodeHandle,binding:uint64):bool {.closure.}
  ProtectedAncestor = object
    root: NodeHandle
    binding: NativeRowBinding
  RecordedProtection = object
    fact: AndroidProtectionFact
    kind: NodeKind
    ancestors: seq[ProtectedAncestor]
  AndroidRowProtection* = ref object
    controls: Table[NodeHandle,RecordedProtection]

proc newAndroidRowProtection*():AndroidRowProtection = AndroidRowProtection()
proc protectionFactCount*(p:AndroidRowProtection):int =
  if p==nil:0 else:p.controls.len

proc rowAncestors(entities:Table[NodeHandle,MountedEntity],handle:NodeHandle,
    ancestors:var seq[ProtectedAncestor]):bool =
  var current=handle
  var depth=0
  while current!=NoHandle:
    inc depth
    if depth>MaxDepth or not entities.hasKey(current):return false
    let entity=entities.getOrDefault(current)
    if entity.handle!=current:return false
    if entity.kind==virtualList:
      if entity.list.isNone or entity.list.get.invalidReason(MaxListItems).len!=0:
        return false
    elif entity.list.isSome:return false
    if entity.parent!=NoHandle and not entities.hasKey(entity.parent):return false
    if entity.row.isSome:
      let row=entity.row.get
      if not entities.hasKey(row.listHandle):return false
      let list=entities.getOrDefault(row.listHandle)
      if list.kind!=virtualList or list.list.isNone or
          list.list.get.invalidReason(MaxListItems).len!=0 or
          row.rowBindingReason(list.list.get,entity.parent,current).len!=0:
        return false
      ancestors.add(ProtectedAncestor(root:current,binding:row))
    elif entity.parent!=NoHandle and
        entities.getOrDefault(entity.parent).kind==virtualList:
      return false # No untyped direct list children.
    current=entity.parent
  ancestors.len!=0

proc stillCurrent(entry:RecordedProtection,currentMount:uint64,
    entities:Table[NodeHandle,MountedEntity],valid:AndroidProtectionBinding):bool =
  let f=entry.fact
  if currentMount==0 or f.mount!=currentMount or valid==nil or
      not entities.hasKey(f.handle) or
      entities.getOrDefault(f.handle).kind!=entry.kind or
      not valid(f.handle,f.binding):return false
  var ancestors:seq[ProtectedAncestor]
  rowAncestors(entities,f.handle,ancestors) and ancestors==entry.ancestors

proc reconcileProtection*(p:AndroidRowProtection,currentMount:uint64,
    entities:Table[NodeHandle,MountedEntity],valid:AndroidProtectionBinding) =
  ## Remove obsolete controls outside publication. Released live controls keep
  ## their sequence fence, but removed handles leave no retained history.
  if p==nil or entities.len>MaxNodes:return
  var obsolete:seq[NodeHandle]
  for handle,entry in p.controls:
    if not entry.stillCurrent(currentMount,entities,valid):obsolete.add(handle)
  for handle in obsolete:p.controls.del(handle)

proc recordProtection*(p:AndroidRowProtection,fact:AndroidProtectionFact,
    currentMount:uint64,entities:Table[NodeHandle,MountedEntity],
    valid:AndroidProtectionBinding):bool =
  ## A complete reason mask replaces this control's previous mask. Even a
  ## release needs a valid current identity and a strictly newer sequence.
  ## Refused input does not consume its sequence or mutate stored facts.
  if p==nil or entities.len>MaxNodes or currentMount==0 or
      fact.mount!=currentMount or fact.handle==NoHandle or fact.binding==0 or
      fact.sequence==0 or valid==nil or not entities.hasKey(fact.handle) or
      not valid(fact.handle,fact.binding):return false
  let kind=entities.getOrDefault(fact.handle).kind
  if rowComposing in fact.reasons and kind!=input:return false
  var ancestors:seq[ProtectedAncestor]
  if not rowAncestors(entities,fact.handle,ancestors):return false
  let old=p.controls.getOrDefault(fact.handle)
  if p.controls.hasKey(fact.handle) and old.fact.mount==fact.mount and
      old.fact.binding==fact.binding and
      old.stillCurrent(currentMount,entities,valid) and
      fact.sequence<=old.fact.sequence:return false
  p.reconcileProtection(currentMount,entities,valid)
  p.controls[fact.handle]=RecordedProtection(fact:fact,kind:kind,ancestors:ancestors)
  true

proc snapshotProtectedRows*(p:AndroidRowProtection,currentMount:uint64,
    entities:Table[NodeHandle,MountedEntity],valid:AndroidProtectionBinding):
    Table[NodeHandle,seq[int]] =
  ## Independently owned, sorted and unique logical indexes. Capture all typed
  ## ancestor rows so keeping an inner editor also keeps its outer subtree.
  ## This read does not prune or acknowledge anything and may allocate.
  if p==nil or entities.len>MaxNodes:return
  var indexes:Table[NodeHandle,HashSet[int]]
  for entry in p.controls.values:
    if entry.fact.reasons=={} or not entry.stillCurrent(currentMount,entities,valid):
      continue
    for row in entry.ancestors:
      indexes.mgetOrPut(row.binding.listHandle,initHashSet[int]()).incl(
        row.binding.itemIndex)
  for handle,values in indexes:
    var ordered:seq[int]
    for value in values:ordered.add(value)
    ordered.sort()
    result[handle]=ordered
