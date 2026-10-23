## Retained Android adapter/Runtime seam; scripted Views, no device IME claim.
import std/[unittest, tables, options, algorithm]
import ../fixture_app
import leaf/[backend, backend_session, mobile_host, native_layout]
import leaf/backends/android/backend as android_backend
import leaf/backends/android/[list_layout, list_geometry, list_protection]

type Fixture = ref object
  owner:MobileHost
  mount:MobileMount
  session:BackendSession
  adapter:AndroidAdapter
  staged:AndroidFrame
  visible:Table[NodeHandle,MountedEntity]
  duringApply:proc() {.closure.}
  list:NodeHandle
  source:uint64
  builds,renders,creates:int

proc fixture():Fixture =
  result=Fixture()
  let f=result
  var items:seq[string]
  for i in 0..<100:items.add($i)
  let list=virtualList("list",items,proc(index:int):Node =
    inc f.builds
    column(@[input($index,key="editor")],key="row"),rowHeight=24,overscan=0)
  f.owner=newMobileHost(proc():Application = fixtureApplication(proc():Node =
    inc f.renders
    list))
  var p:AndroidPlatform
  p.withLists=true
  p.measure=proc(e:MountedEntity,s:DipSize):DipSize = DipSize(width:s.width,height:24)
  p.stage=proc(frame:AndroidFrame) = f.staged=frame
  p.apply=proc() =
    for op in f.staged.ops:
      case op.kind
      of opCreate,opUpdate:
        if op.kind==opCreate:inc f.creates
        f.visible[op.handle]=MountedEntity(handle:op.handle,parent:op.parent,
          kind:op.nodeKind,index:op.index,nodeId:op.nodeId,
          props:op.props,list:op.list,row:op.row)
      of opMove:
        f.visible[op.handle].parent=op.parent
        f.visible[op.handle].index=op.index
        f.visible[op.handle].row=op.row
      of opRemove:f.visible.del(op.handle)
    if f.duringApply!=nil:f.duringApply()
  p.discardStage=proc() = discard
  p.restore=proc(frame:AndroidFrame) =
    f.visible.clear()
    for op in frame.ops:
      f.visible[op.handle]=MountedEntity(handle:op.handle,parent:op.parent,
        kind:op.nodeKind,index:op.index,nodeId:op.nodeId,
        props:op.props,list:op.list,row:op.row)
  p.restoreGeometry=proc(frame:AndroidFrame) = discard
  p.rebind=proc(s,m:uint64) = discard
  p.dispose=proc() = f.visible.clear()
  p.editEffects=proc(write:AndroidEditorWrite) = discard
  f.adapter=newAndroidAdapter(p,DipSize(width:300,height:96))
  f.mount=f.owner.attach(f.adapter.protocol,300,96,1)
  f.session=f.owner.backendSession(f.mount)
  check f.owner.resume(f.mount)
  f.list=f.session.handleFor(f.owner.runtime.find("list").id)
  f.source=f.session.acceptedEntities[f.list].list.get.sourceGeneration
  check f.adapter.queueListViewports(f.session)==1
  check f.owner.safeTurn(f.mount)

proc editor(f:Fixture,index:int):NodeHandle =
  let entities=f.session.acceptedEntities
  for handle,e in entities:
    if e.kind==input and entities.getOrDefault(e.parent).row.isSome and
        entities[e.parent].row.get.itemIndex==index:return handle
  raise newException(AssertionDefect,"missing editor")
proc indexes(f:Fixture):seq[int] =
  for row in f.owner.runtime.find("list").children:result.add(row.listIndex)
  result.sort()
proc record(f:Fixture,handle:NodeHandle,sequence:uint64,
    reasons:set[AndroidProtectionReason],binding=1'u64,mount=0'u64):bool =
  f.adapter.recordRowProtection(handle,
    (if mount==0:f.session.mountGeneration else:mount),sequence,binding,reasons)

suite "Android protected row backend":
  test "a fact replaces an old queued viewport before business delivery":
    let f=fixture()
    defer:f.owner.close()
    let input=f.editor(0)
    check f.adapter.requestListOffset(f.list,f.source,240)
    check f.adapter.flushListGeometry()
    check f.adapter.queueListViewports(f.session)==1
    check f.record(input,1,{rowFocused,rowComposing})
    check f.adapter.queueProtectionViewports(f.session).queued==1
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[0,10,11,12,13] and f.editor(0)==input
    check f.staged.listProjections[0].protected == @[0]
    check f.adapter.acceptedListLayout.projections[0].geometry.rowsReady
    check f.builds==8 and f.renders==1

  test "protection projection keeps a newer desired offset without business work":
    let f=fixture()
    defer:f.owner.close()
    let input=f.editor(0)
    let creates=f.creates
    let revision=f.owner.runtime.acceptedRevision
    check f.adapter.requestListOffset(f.list,f.source,240)
    check f.record(input,1,{rowFocused})
    check f.adapter.flushListGeometry()
    check f.staged.listProjections[0].geometry.offset==240
    check f.staged.listProjections[0].protected == @[0]
    check f.staged.ops.len==0 and f.staged.editorWrites.len==0
    check f.builds==4 and f.creates==creates and f.renders==1
    check f.owner.runtime.acceptedRevision==revision
    check not f.adapter.flushListGeometry()

  test "releasing one reason keeps the row until the full mask is empty":
    let f=fixture()
    defer:f.owner.close()
    let input=f.editor(0)
    check f.record(input,1,{rowFocused,rowComposing})
    check f.adapter.requestListOffset(f.list,f.source,240)
    check f.adapter.flushListGeometry()
    discard f.adapter.queueProtectionViewports(f.session)
    check f.owner.safeTurn(f.mount)
    check f.record(input,2,{rowComposing})
    check f.adapter.queueProtectionViewports(f.session).queued==0
    check not f.adapter.flushListGeometry()
    check f.record(input,3,{})
    check f.adapter.queueProtectionViewports(f.session).queued==1
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[10,11,12,13] and f.renders==1
    check f.staged.listProjections[0].protected.len==0

  test "late focus during geometry apply survives publication and is corrected once":
    let f=fixture()
    defer:f.owner.close()
    let input=f.editor(0)
    var fired=false
    f.duringApply=proc() =
      if not fired:
        fired=true
        check f.record(input,1,{rowFocused})
        discard f.adapter.queueProtectionViewports(f.session)
    check f.adapter.requestListOffset(f.list,f.source,240)
    check f.adapter.flushListGeometry()
    check f.staged.listProjections[0].protected.len==0
    check f.adapter.flushListGeometry()
    check f.staged.listProjections[0].geometry.offset==240
    check f.staged.listProjections[0].protected == @[0]
    check not f.adapter.flushListGeometry()
    discard f.adapter.queueProtectionViewports(f.session)
    discard f.adapter.queueListViewports(f.session)
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[0,10,11,12,13] and f.editor(0)==input

  test "identity and owning session refusal cannot consume a protection sequence":
    let f=fixture()
    let other=fixture()
    defer:f.owner.close();other.owner.close()
    let input=f.editor(0)
    check not f.record(input,100,{rowFocused},binding=2)
    check not f.record(input,100,{rowFocused},mount=f.session.mountGeneration+1)
    check not f.record(input,0,{rowFocused})
    check f.record(input,1,{rowFocused})
    check not f.record(input,1,{})
    check f.adapter.queueProtectionViewports(other.session).queued==0
    check other.session.pendingRowRequests==0
    check f.adapter.queueProtectionViewports(f.session).queued==1
