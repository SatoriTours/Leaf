## Next-turn protection receipt through real retained Session row delivery.
## No Android device, focus callback or real IME coverage is claimed.
import std/[unittest, tables, options, algorithm]
import ../fixture_app
import leaf/[backend, backend_session, mobile_host, native_layout]
import leaf/backends/headless
import leaf/backends/android/[list_geometry, list_layout, list_delivery,
  list_protection, protection_delivery]

type Fixture = ref object
  owner:MobileHost
  mount:MobileMount
  session:BackendSession
  lists:AndroidLists
  protection:AndroidRowProtection
  delivery:AndroidProtectionDelivery
  handle:NodeHandle
  source:uint64
  builds,renders,bulkBuilds,failAt:int

proc bindingOne(h:NodeHandle,b:uint64):bool = b==1
proc measure(e:MountedEntity,s:DipSize):DipSize = DipSize(width:s.width,height:24)
proc prepare(f:Fixture) =
  let entities=f.session.acceptedEntities
  let protected=f.protection.snapshotProtectedRows(f.session.mountGeneration,
    entities,bindingOne)
  discard f.lists.prepareListLayout(entities,DipSize(width:300,height:96),
    measure,1,1,protected)
  check f.lists.publishListLayout()

proc fixture(extraLists=0):Fixture =
  result=Fixture(failAt: -1,lists:newAndroidLists(),protection:newAndroidRowProtection(),
    delivery:newAndroidProtectionDelivery())
  let f=result
  var items:seq[string]
  for i in 0..<100:items.add($i)
  let list=virtualList("list",items,proc(index:int):Node =
    inc f.builds
    if index==f.failAt:fail("protected row build 1234")
    column(@[input($index,key="editor")],key="row"),rowHeight=24,overscan=0,
    styles=style({"height":"96"}))
  var children= @[list]
  for i in 0..<extraLists:
    children.add(virtualList("bulk-" & $i,@["only"],proc(index:int):Node =
      inc f.bulkBuilds
      text("row",key="text"),rowHeight=24,overscan=0))
  let root=if extraLists==0:list else:column(children,key="root")
  f.owner=newMobileHost(proc():Application = fixtureApplication(proc():Node =
    inc f.renders
    root))
  f.mount=f.owner.attach(newRecordingBackend(fullCapabilities()).backend,300,96,1)
  f.session=f.owner.backendSession(f.mount)
  f.handle=f.session.handleFor(f.owner.runtime.find("list").id)
  f.source=f.session.acceptedEntities[f.handle].list.get.sourceGeneration
  check f.owner.resume(f.mount)
  f.prepare()

proc queueProtection(f:Fixture):AndroidProtectionQueueResult =
  f.delivery.queueProtectionViewports(f.lists,f.protection,f.session,bindingOne)

proc indexes(f:Fixture):seq[int] =
  for row in f.owner.runtime.find("list").children:result.add(row.listIndex)
  result.sort()

proc editor(f:Fixture,index:int):NodeHandle =
  let entities=f.session.acceptedEntities
  for handle,e in entities:
    if e.kind==input:
      let row=entities.getOrDefault(e.parent)
      if row.row.isSome and row.row.get.itemIndex==index:return handle
  raise newException(AssertionDefect,"missing editor")

proc record(f:Fixture,handle:NodeHandle,sequence:uint64,
    reasons:set[AndroidProtectionReason]):bool =
  f.protection.recordProtection(AndroidProtectionFact(handle:handle,
    mount:f.session.mountGeneration,binding:1,sequence:sequence,reasons:reasons),
    f.session.mountGeneration,f.session.acceptedEntities,bindingOne)

suite "Android protected viewport receipt":
  test "unprotected initial geometry keeps the existing next-turn handoff":
    let f=fixture()
    defer:f.owner.close()
    check f.queueProtection.queued==0
    check f.session.pendingRowRequests==0 and f.builds==0
    check f.lists.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    f.prepare()
    check f.queueProtection.queued==0 and f.builds==4

  test "protection replaces an acknowledged old request and repeated facts do not requeue":
    let f=fixture()
    defer:f.owner.close()
    check f.lists.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    f.prepare()
    let control=f.editor(0)
    check f.lists.requestListOffset(f.handle,f.source,240)
    f.prepare()
    check f.lists.queueListViewports(f.session)==1
    check f.record(control,1,{rowFocused,rowComposing})
    let queued=f.queueProtection
    check queued.queued==1 and queued.refused==0
    check f.queueProtection.queued==0
    check f.lists.queueListViewports(f.session)==0
    check f.session.pendingRowRequests==1 and f.builds==4
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[0,10,11,12,13] and f.editor(0)==control
    f.prepare()
    check f.queueProtection.queued==0 and f.builds==8 and f.renders==1
    check f.record(control,2,{rowComposing})
    check f.queueProtection.queued==0 # Same protected row set.
    check f.record(control,3,{})
    check f.queueProtection.queued==1
    check f.queueProtection.queued==0
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[10,11,12,13]
    f.prepare()
    check f.queueProtection.queued==0 and f.builds==8 and f.renders==1

  test "a protection fact queued after prepare acknowledges that exact token":
    let f=fixture()
    defer:f.owner.close()
    check f.lists.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    f.prepare()
    check f.lists.requestListOffset(f.handle,f.source,240)
    f.prepare() # Geometry queued neither a new row range nor protection yet.
    check f.record(f.editor(0),1,{rowFocused})
    check f.queueProtection.queued==1
    check f.lists.queueListViewports(f.session)==0
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[0,10,11,12,13]

  test "protection remains recorded through pause without delivering business":
    let f=fixture()
    defer:f.owner.close()
    check f.lists.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    f.prepare()
    check f.record(f.editor(0),1,{rowFocused})
    check f.lists.requestListOffset(f.handle,f.source,240)
    f.prepare()
    check f.owner.pause(f.mount)
    check f.queueProtection.queued==1
    check not f.owner.safeTurn(f.mount)
    check f.builds==4 and f.session.pendingRowRequests==1
    check f.owner.resume(f.mount)
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[0,10,11,12,13] and f.builds==8

  test "full queue refusal stays retryable until another ordinary turn frees capacity":
    let f=fixture(extraLists=MaxPendingRowRequests)
    defer:f.owner.close()
    check f.lists.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    let control=f.editor(0)
    check f.record(control,1,{rowFocused})
    check f.lists.requestListOffset(f.handle,f.source,240)
    f.prepare()
    for i in 0..<MaxPendingRowRequests:
      let handle=f.session.handleFor(f.owner.runtime.find("bulk-" & $i).id)
      let source=f.session.acceptedEntities[handle].list.get.sourceGeneration
      check f.session.queueRows(RowViewportRequest(sessionId:f.session.sessionId,
        mountGeneration:f.session.mountGeneration,listHandle:handle,
        sourceGeneration:source,first:0,finish:1))
    check f.session.pendingRowRequests==MaxPendingRowRequests
    let refused=f.queueProtection
    check refused.queued==0 and refused.refused==1
    check f.queueProtection.refused==1
    check f.builds==4 and f.bulkBuilds==0
    check f.owner.safeTurn(f.mount)
    check f.bulkBuilds==MaxPendingRowRequests and f.builds==4
    check f.editor(0)==control and f.session.pendingRowRequests==0
    let retry=f.queueProtection
    check retry.queued==1 and retry.refused==0
    check f.queueProtection.queued==0
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[0,10,11,12,13] and f.editor(0)==control
    check f.builds==8 and f.renders==1

  test "a fact during prepare survives a later frame with the same bare range":
    let f=fixture()
    defer:f.owner.close()
    check f.lists.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    f.prepare()
    let control=f.editor(0)
    check f.lists.requestListOffset(f.handle,f.source,240)
    f.prepare()
    # Candidate captured the earlier empty protection set. A Native callback
    # may report focus while that candidate is being applied.
    discard f.lists.prepareListLayout(f.session.acceptedEntities,
      DipSize(width:300,height:96),measure,1,1)
    check f.record(control,1,{rowFocused})
    check f.queueProtection.queued==1
    check f.lists.publishListLayout()
    discard f.queueProtection
    check f.lists.queueListViewports(f.session)==0
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[0,10,11,12,13]
    check f.editor(0)==control

  test "a failed row receipt stays quiet while a new intent can retry the same range":
    let f=fixture()
    defer:f.owner.close()
    check f.lists.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    f.prepare()
    let control=f.editor(0)
    check f.record(control,1,{rowFocused})
    check f.lists.requestListOffset(f.handle,f.source,240)
    f.prepare()
    f.failAt=12
    check f.queueProtection.queued==1
    expect UiError:discard f.owner.safeTurn(f.mount)
    check f.indexes == @[0,1,2,3] and f.editor(0)==control
    let failedBuilds=f.builds
    f.failAt= -1
    check f.queueProtection.queued==0
    check f.lists.queueListViewports(f.session)==0
    check f.owner.safeTurn(f.mount)
    check f.builds==failedBuilds
    check f.lists.requestListOffset(f.handle,f.source,240)
    f.prepare()
    # The projection already carries the correct protection set. The normal
    # new-token receipt owns this explicit retry; it must remain unacknowledged.
    check f.queueProtection.queued==0
    check f.lists.queueListViewports(f.session)==1
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[0,10,11,12,13] and f.editor(0)==control
    check f.renders==1
