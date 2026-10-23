## Android platform seam with a real retained Runtime; no Android device claim.
import std/[unittest, tables, options]
import ../fixture_app
import leaf/[backend, backend_session, mobile_host, native_layout]
import leaf/backends/android/backend as android_backend
import leaf/backends/android/[list_geometry, list_layout]

type Native = ref object
  staged,replayed:AndroidFrame
  boxes:seq[LayoutBox]
  visible:Table[NodeHandle,MountedEntity]
  calls,creates,restores,geometryRestores:int
  geometryReplay:AndroidFrame
  failGeometry,failGeometryReplay:bool
  duringApply:proc() {.closure.}
  failApply:bool
proc native():tuple[platform:AndroidPlatform,state:Native] =
  let n=Native()
  var p:AndroidPlatform
  p.withLists=true
  p.measure=proc(e:MountedEntity,s:DipSize):DipSize =
    inc n.calls
    DipSize(width:s.width,height:24)
  p.stage=proc(f:AndroidFrame) =
    inc n.calls
    n.staged=f
  p.apply=proc() =
    inc n.calls
    for op in n.staged.ops:
      case op.kind
      of opCreate:
        n.visible[op.handle]=MountedEntity(handle:op.handle,parent:op.parent,
          kind:op.nodeKind,index:op.index,nodeId:op.nodeId,props:op.props,list:op.list,row:op.row)
        inc n.creates
      of opUpdate:
        n.visible[op.handle].props=op.props
        n.visible[op.handle].list=op.list
        n.visible[op.handle].row=op.row
      of opMove:
        n.visible[op.handle].parent=op.parent
        n.visible[op.handle].index=op.index
        n.visible[op.handle].row=op.row
      of opRemove:n.visible.del(op.handle)
      if n.failApply:fail("list apply 1234")
    n.boxes=n.staged.boxes
    if n.duringApply!=nil:n.duringApply()
    if n.failGeometry:fail("geometry apply 4321")
  p.discardStage=proc() = inc n.calls
  p.restore=proc(f:AndroidFrame) =
    inc n.calls;inc n.restores
    n.replayed=f;n.boxes=f.boxes;n.visible.clear()
    for op in f.ops:
      n.visible[op.handle]=MountedEntity(handle:op.handle,parent:op.parent,
        kind:op.nodeKind,index:op.index,nodeId:op.nodeId,props:op.props,list:op.list,row:op.row)
  p.restoreGeometry=proc(f:AndroidFrame) =
    inc n.calls;inc n.geometryRestores
    if n.failGeometryReplay:fail("geometry replay 8765")
    n.geometryReplay=f;n.boxes=f.boxes
  p.rebind=proc(s,m:uint64) = inc n.calls
  p.dispose=proc() = n.visible.clear()
  (p,n)
type Fixture = ref object
  owner:MobileHost
  mount:MobileMount
  session:BackendSession
  adapter:AndroidAdapter
  n:Native
  list:Node
  builds,renders:int
proc makeList(f:Fixture,count=100):Node =
  var items:seq[string]
  for i in 0..<count:items.add($i)
  virtualList("list",items,proc(index:int):Node =
    inc f.builds
    column(@[text($index,key="text")],key="row"),rowHeight=24,overscan=0)
proc fixture():Fixture =
  result=Fixture()
  let f=result
  f.list=f.makeList()
  f.owner=newMobileHost(proc():Application = fixtureApplication(proc():Node =
    inc f.renders
    f.list))
  let (p,n)=native();f.n=n
  f.adapter=newAndroidAdapter(p,DipSize(width:300,height:96))
  f.mount=f.owner.attach(f.adapter.protocol,300,96,1)
  f.session=f.owner.backendSession(f.mount)
  check f.owner.resume(f.mount)
proc listHandle(f:Fixture):NodeHandle=f.session.handleFor(f.owner.runtime.find("list").id)

suite "Android list backend preparation":
  test "only an explicit list platform gains list capability":
    check virtualList notin androidCapabilities(true,true).kinds
    check virtualList in androidCapabilities(true,true,true).kinds

  test "full typed metadata survives initial and materialized frames without parent render":
    let f=fixture()
    defer:f.owner.close()
    let h=f.listHandle
    check f.n.visible[h].list.get.itemCount==100
    check f.n.staged.withLists and f.n.staged.listProjections.len==1
    check f.builds==0 and f.renders==1
    check f.adapter.queueListViewports(f.session)==1
    check f.builds==0
    check f.owner.safeTurn(f.mount)
    check f.builds==4 and f.renders==1
    check f.n.visible.len==9 and f.n.boxes.len==9
    let projection=f.n.staged.listProjections[0]
    check projection.geometry.rowsReady and projection.geometry.total==2400
    check projection.rows.len==4
    for row in projection.rows:
      let entity=f.n.visible[row.root]
      check entity.row.get.itemIndex==row.binding.itemIndex
      check entity.row.get.listHandle==h
    check f.adapter.queueListViewports(f.session)==0

  test "metadata-only source and count change reaches stage and accepted replay":
    let f=fixture()
    defer:f.owner.close()
    let h=f.listHandle
    let old=f.n.visible[h].list.get.sourceGeneration
    f.list=f.makeList(5)
    discard f.owner.runtime.refresh()
    check f.n.visible[h].list.get.itemCount==5
    check f.n.visible[h].list.get.sourceGeneration!=old
    check f.n.staged.listProjections[0].metadata.itemCount==5
    check f.adapter.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    check f.n.staged.listProjections[0].geometry.rowsReady

  test "partial native row apply failure restores accepted metadata and exact geometry":
    let f=fixture()
    defer:f.owner.close()
    check f.adapter.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    let h=f.listHandle
    let generation=f.n.visible[h].list.get.sourceGeneration
    let old=f.adapter.acceptedListLayout
    let eventMount=f.session.mountGeneration
    f.n.failApply=true
    expect UiError:discard f.session.requestRows(h,generation,10,14)
    check f.n.restores==1 and f.session.mountGeneration>eventMount
    check f.adapter.acceptedListLayout==old
    check f.n.replayed.listProjections[0].geometry==old.projections[0].geometry
    check f.n.visible[h].list.get.sourceGeneration==generation
    check f.n.visible.len==9
    f.n.failApply=false
    discard f.session.requestRows(h,generation,10,14)
    check f.n.visible.len==9 and f.renders==1

  test "a foreign session cannot acknowledge or receive this adapter's viewports":
    let f=fixture()
    let other=fixture()
    defer:f.owner.close();other.owner.close()
    check f.adapter.queueListViewports(other.session)==0
    check other.session.pendingRowRequests==0 and f.builds==0
    check f.adapter.queueListViewports(f.session)==1

  test "geometry-only scroll preserves revision creates and parent renders":
    let f=fixture()
    defer:f.owner.close()
    check f.adapter.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    let h=f.listHandle
    let generation=f.n.visible[h].list.get.sourceGeneration
    let revision=f.owner.runtime.acceptedRevision
    let creates=f.n.creates
    check f.adapter.requestListOffset(h,generation,24)
    check f.adapter.flushListGeometry()
    check f.n.staged.ops.len==0 and f.n.staged.editorWrites.len==0
    check f.n.staged.listProjections[0].geometry.offset==24
    check f.owner.runtime.acceptedRevision==revision and f.renders==1
    check f.n.creates==creates
    check not f.adapter.flushListGeometry()
    check f.adapter.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    check f.owner.runtime.find("list").children.len==4 and f.renders==1
    check f.n.staged.listProjections[0].geometry.rowsReady

  test "geometry failure replays existing views and does not repeat the same failed intent":
    let f=fixture()
    defer:f.owner.close()
    let h=f.listHandle
    let generation=f.n.visible[h].list.get.sourceGeneration
    let old=f.adapter.acceptedListLayout
    check f.adapter.requestListOffset(h,generation,24)
    f.n.failGeometry=true
    expect AndroidListGeometryError:discard f.adapter.flushListGeometry()
    check f.adapter.acceptedListLayout==old
    check f.n.geometryRestores==1 and f.n.restores==0
    check f.n.geometryReplay.listProjections[0].geometry.offset==0
    let calls=f.n.calls
    check not f.adapter.flushListGeometry()
    check f.n.calls==calls
    f.n.failGeometry=false
    check f.adapter.requestListOffset(h,generation,24)
    check f.adapter.flushListGeometry()
    check f.adapter.acceptedListLayout.projections[0].geometry.offset==24

  test "new intent arriving during failed geometry is not suppressed by the old failure":
    let f=fixture()
    defer:f.owner.close()
    let h=f.listHandle
    let generation=f.n.visible[h].list.get.sourceGeneration
    check f.adapter.requestListOffset(h,generation,24)
    f.n.duringApply=proc() = check f.adapter.requestListOffset(h,generation,120)
    f.n.failGeometry=true
    expect AndroidListGeometryError:discard f.adapter.flushListGeometry()
    f.n.duringApply=nil;f.n.failGeometry=false
    check f.adapter.flushListGeometry()
    check f.adapter.acceptedListLayout.projections[0].geometry.offset==120

  test "failed geometry replay reports unrecovered state and blocks further geometry":
    let f=fixture()
    defer:f.owner.close()
    let h=f.listHandle
    check f.adapter.requestListOffset(h,f.n.visible[h].list.get.sourceGeneration,24)
    f.n.failGeometry=true;f.n.failGeometryReplay=true
    try:
      discard f.adapter.flushListGeometry()
      check false
    except AndroidListGeometryError as error:
      check error.recoveryFailed
    check not f.adapter.requestListOffset(h,f.n.visible[h].list.get.sourceGeneration,48)

  test "native contract defects retain cleanup ownership and block later geometry":
    let f=fixture()
    defer:f.owner.close()
    let h=f.listHandle
    let source=f.n.visible[h].list.get.sourceGeneration
    let accepted=f.adapter.acceptedListLayout
    check f.adapter.requestListOffset(h,source,24)
    f.n.duringApply=proc() = raise newException(AssertionDefect,"native contract 9876")
    expect AssertionDefect:discard f.adapter.flushListGeometry()
    check f.adapter.acceptedListLayout==accepted
    check not f.adapter.requestListOffset(h,source,48)
    check not f.adapter.flushListGeometry()
    check f.adapter.queueListViewports(f.session)==0
