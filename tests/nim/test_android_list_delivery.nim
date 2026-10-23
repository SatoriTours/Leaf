## Real retained Runtime row delivery through Android's fact acknowledgement.
## This is a Linux host test, not an Android Views or device test.
import std/[unittest, tables, options, algorithm]
import ../fixture_app
import leaf/[backend, backend_session, mobile_host, native_layout]
import leaf/backends/headless
import leaf/backends/android/[list_layout, list_geometry, list_delivery]

type Fixture = ref object
  owner:MobileHost
  mount:MobileMount
  session:BackendSession
  lists:AndroidLists
  handle:NodeHandle
  builds,renders,failAt:int

proc measure(e:MountedEntity,s:DipSize):DipSize = DipSize(width:s.width,height:24)
proc prepare(f:Fixture) =
  discard f.lists.prepareListLayout(f.session.acceptedEntities,
    DipSize(width:300,height:96),measure,1,1)
  check f.lists.publishListLayout()
proc fixture(overscan=0):Fixture =
  result=Fixture(failAt: -1,lists:newAndroidLists())
  let f=result
  var items:seq[string]
  for i in 0..<100:items.add($i)
  let list=virtualList("list",items,proc(index:int):Node =
    inc f.builds
    if index==f.failAt:fail("row builder 1234")
    text($index,key="row"),rowHeight=24,overscan=overscan)
  f.owner=newMobileHost(proc():Application =
    fixtureApplication(proc():Node =
      inc f.renders
      list))
  f.mount=f.owner.attach(newRecordingBackend(fullCapabilities()).backend,300,96,1)
  f.session=f.owner.backendSession(f.mount)
  f.handle=f.session.handleFor(f.owner.runtime.find("list").id)
  f.prepare()
proc indices(f:Fixture):seq[int] =
  for child in f.owner.runtime.find("list").children:result.add(child.listIndex)
  result.sort()

suite "Android list viewport delivery":
  test "recording is business-free and safe turn adds overscan exactly once":
    let f=fixture(overscan=2)
    defer:f.owner.close()
    check f.builds==0 and f.renders==1
    check f.lists.queueListViewports(f.session)==1
    check f.builds==0 and f.session.pendingRowRequests==1
    check f.lists.queueListViewports(f.session)==0
    check f.owner.resume(f.mount)
    check f.owner.safeTurn(f.mount)
    check f.indices == @[0,1,2,3,4,5]
    check f.builds==6 and f.renders==1
    f.prepare()
    check f.lists.acceptedListLayout.projections[0].geometry.rowsReady
    check f.lists.queueListViewports(f.session)==0
    let source=f.owner.runtime.find("list").node.listSource.generation
    check f.lists.requestListOffset(f.handle,source,120)
    f.prepare()
    check f.lists.queueListViewports(f.session)==1
    check f.builds==6
    check f.owner.safeTurn(f.mount)
    check f.indices == @[3,4,5,6,7,8,9,10]
    check f.renders==1

  test "retained pause keeps the recorded request until the next ordinary turn":
    let f=fixture()
    defer:f.owner.close()
    check f.lists.queueListViewports(f.session)==1
    check not f.owner.safeTurn(f.mount)
    check f.builds==0 and f.session.pendingRowRequests==1
    check f.owner.resume(f.mount)
    check f.owner.safeTurn(f.mount)
    check f.indices == @[0,1,2,3]
    check f.session.pendingRowRequests==0

  test "a failed row fact is acknowledged once and only new intent permits retry":
    let f=fixture()
    defer:f.owner.close()
    check f.owner.resume(f.mount)
    f.failAt=2
    check f.lists.queueListViewports(f.session)==1
    expect UiError:discard f.owner.safeTurn(f.mount)
    check f.indices.len==0 and f.session.pendingRowRequests==0
    let builds=f.builds
    check f.lists.queueListViewports(f.session)==0
    check f.owner.safeTurn(f.mount)
    check f.builds==builds
    f.failAt= -1
    let source=f.owner.runtime.find("list").node.listSource.generation
    check f.lists.requestListOffset(f.handle,source,0)
    f.prepare()
    check f.lists.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    check f.indices == @[0,1,2,3] and f.renders==1

  test "refused obsolete metadata stays unacknowledged and never builds rows":
    let f=fixture()
    defer:f.owner.close()
    var entities=f.session.acceptedEntities
    var meta=entities[f.handle].list.get
    inc meta.sourceGeneration
    entities[f.handle].list=some(meta)
    discard f.lists.prepareListLayout(entities,DipSize(width:300,height:96),measure,1,1)
    check f.lists.publishListLayout()
    check f.lists.queueListViewports(f.session)==0
    check f.lists.pendingListViewports.len==1
    check f.builds==0 and f.session.pendingRowRequests==0
