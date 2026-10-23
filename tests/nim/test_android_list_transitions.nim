## Real retained Runtime + Android adapter; measurement/native objects are a
## scripted platform seam. This does not attest Android Views or IME behavior.
import std/[unittest, tables, options, algorithm]
import ../fixture_app
import leaf/[backend, backend_session, mobile_host, native_layout]
import leaf/backends/android/backend as android_backend
import leaf/backends/android/[list_layout, list_geometry]

type Fixture = ref object
  owner:MobileHost
  mount:MobileMount
  adapter:AndroidAdapter
  session:BackendSession
  staged:AndroidFrame
  visible:Table[NodeHandle,MountedEntity]
  node:Node
  builds,renders,restores:int
  failApply:bool

proc makeList(f:Fixture,keys:seq[string],variable=false):Node =
  virtualList("list",keys,proc(i:int):Node =
    inc f.builds
    column(@[text(keys[i],key="value")],key="row",
      styles=style({"height":(if variable and i mod 2==1:"48" else:"24")})),
    rowHeight=(if variable:0.0 else:24.0),estimatedHeight=24,overscan=0)

proc keys(count:int):seq[string] =
  for i in 0..<count:result.add("key-" & $i)

proc fixture(variable=false):Fixture =
  result=Fixture()
  let f=result
  f.node=f.makeList(keys(20),variable)
  f.owner=newMobileHost(proc():Application = fixtureApplication(proc():Node =
    inc f.renders
    f.node))
  var p:AndroidPlatform
  p.withLists=true
  p.measure=proc(e:MountedEntity,s:DipSize):DipSize = DipSize(width:30,height:24)
  p.stage=proc(frame:AndroidFrame) = f.staged=frame
  p.apply=proc() =
    for op in f.staged.ops:
      case op.kind
      of opCreate,opUpdate:
        f.visible[op.handle]=MountedEntity(handle:op.handle,parent:op.parent,
          kind:op.nodeKind,index:op.index,nodeId:op.nodeId,props:op.props,
          list:op.list,row:op.row)
      of opMove:
        f.visible[op.handle].parent=op.parent
        f.visible[op.handle].index=op.index
        f.visible[op.handle].row=op.row
      of opRemove:f.visible.del(op.handle)
      if f.failApply:fail("transitions-1234")
  p.restore=proc(frame:AndroidFrame) =
    inc f.restores
    f.visible.clear()
    for op in frame.ops:
      f.visible[op.handle]=MountedEntity(handle:op.handle,parent:op.parent,
        kind:op.nodeKind,index:op.index,nodeId:op.nodeId,props:op.props,
        list:op.list,row:op.row)
  p.restoreGeometry=proc(frame:AndroidFrame) = discard
  p.discardStage=proc() = discard
  p.rebind=proc(session,mount:uint64) = discard
  p.dispose=proc() = f.visible.clear()
  f.adapter=newAndroidAdapter(p,DipSize(width:300,height:96))
  f.mount=f.owner.attach(f.adapter.protocol,300,96,1)
  f.session=f.owner.backendSession(f.mount)
  check f.owner.resume(f.mount)

proc projection(f:Fixture):AndroidListProjection =
  f.adapter.acceptedListLayout.projections[0]
proc settle(f:Fixture):int =
  ## A finite observation cap, not a production retry loop.
  for turn in 0..<6:
    if f.adapter.queueListViewports(f.session)==0:return turn
    check f.owner.safeTurn(f.mount)
  raise newException(AssertionDefect,"rowset did not converge within six turns")
proc rowIndexes(f:Fixture):seq[int] =
  for child in f.owner.runtime.find("list").children:result.add(child.listIndex)
  result.sort()
proc scroll(f:Fixture,offset:float64) =
  let p=f.projection
  check f.adapter.requestListOffset(p.handle,p.metadata.sourceGeneration,offset)
  check f.adapter.flushListGeometry()
  discard f.settle()
proc replace(f:Fixture,items:seq[string]) =
  f.node=f.makeList(items)
  discard f.owner.runtime.refresh()
  discard f.settle()

suite "Android list source and variable transitions":
  test "reordered source rejects queued old facts and rebuilds typed indexes":
    let f=fixture()
    defer:f.owner.close()
    discard f.settle()
    f.scroll(48)
    let old=f.projection
    check f.session.queueRows(RowViewportRequest(sessionId:f.session.sessionId,
      mountGeneration:f.session.mountGeneration,listHandle:old.handle,
      sourceGeneration:old.metadata.sourceGeneration,first:15,finish:19))
    f.replace(@["key-5","key-4","key-3","key-2","key-1","key-0"])
    let next=f.projection
    check next.handle==old.handle
    check next.metadata.sourceGeneration!=old.metadata.sourceGeneration
    check not f.adapter.requestListOffset(old.handle,old.metadata.sourceGeneration,0)
    check next.geometry.offset==48 and f.rowIndexes == @[2,3,4,5]
    for row in next.rows:
      check row.binding.itemKey == @["key-5","key-4","key-3","key-2","key-1","key-0"][row.binding.itemIndex]
    check f.session.pendingRowRequests==0

  test "shrink empty and restore clamp reach without retaining removed source rows":
    let f=fixture()
    defer:f.owner.close()
    discard f.settle()
    f.scroll(384)
    check f.rowIndexes == @[16,17,18,19]
    f.replace(keys(3))
    check f.projection.geometry.offset==0 and f.projection.geometry.total==72
    check f.rowIndexes == @[0,1,2]
    f.replace(@[])
    check f.projection.geometry.total==0 and f.projection.geometry.offset==0
    check f.rowIndexes.len==0 and f.projection.geometry.rowsReady
    f.replace(keys(20))
    check f.rowIndexes == @[0,1,2,3]
    check f.projection.geometry.offset==0 and f.projection.geometry.rowsReady

  test "paused queued viewport builds no rows and resumes only latest intent":
    let f=fixture()
    defer:f.owner.close()
    discard f.settle()
    let before=f.builds
    check f.owner.pause(f.mount)
    let p=f.projection
    check f.adapter.requestListOffset(p.handle,p.metadata.sourceGeneration,240)
    check f.adapter.flushListGeometry()
    check f.adapter.queueListViewports(f.session)==1
    check not f.owner.safeTurn(f.mount)
    check f.builds==before
    check f.owner.resume(f.mount)
    check f.owner.safeTurn(f.mount)
    discard f.settle()
    check f.rowIndexes == @[10,11,12,13] and f.renders==1

  test "partial source update failure restores old typed source and geometry":
    let f=fixture()
    defer:f.owner.close()
    discard f.settle()
    f.scroll(48)
    let old=f.projection
    f.node=f.makeList(keys(2))
    f.failApply=true
    expect UiError:discard f.owner.runtime.refresh()
    check f.restores==1 and f.projection.geometry==old.geometry
    check f.visible[old.handle].list.get.sourceGeneration==old.metadata.sourceGeneration
    check f.rowIndexes == @[2,3,4,5]
    f.failApply=false
    discard f.owner.runtime.refresh()
    discard f.settle()
    check f.projection.geometry.offset==0 and f.rowIndexes == @[0,1]

  test "variable row subtree heights determine accepted positions and bounded rowset":
    let f=fixture(variable=true)
    defer:f.owner.close()
    let turns=f.settle()
    check turns in 1..2
    let p=f.projection
    check p.geometry.prefix(1)==24 and p.geometry.prefix(2)==72
    check p.geometry.prefix(3)==96
    check p.geometry.first==0 and p.geometry.finish==3
    check f.rowIndexes == @[0,1,2] and p.geometry.rowsReady
    f.scroll(82)
    check f.projection.geometry.first==2
    check f.projection.geometry.prefix(2)-f.projection.geometry.offset == -10
    check f.renders==1
