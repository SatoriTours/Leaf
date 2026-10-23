## Real retained Runtime/Session seam. Native focus and IME are not connected.
import std/[unittest, tables, options, algorithm]
import ../fixture_app
import leaf/[backend, backend_session, mobile_host]
import leaf/backends/headless
import leaf/backends/android/list_protection

type Fixture = ref object
  owner:MobileHost
  mount:MobileMount
  session:BackendSession
  protection:AndroidRowProtection
  listHandle:NodeHandle
  source:uint64
  builds,renders:int

proc fixture():Fixture =
  result=Fixture(protection:newAndroidRowProtection())
  let f=result
  var items:seq[string]
  for index in 0..<100:items.add($index)
  let list=virtualList("list",items,proc(index:int):Node =
    inc f.builds
    column(@[input("value-" & $index,key="editor")],key="row"),
    rowHeight=24,overscan=0)
  f.owner=newMobileHost(proc():Application = fixtureApplication(proc():Node =
    inc f.renders
    list))
  f.mount=f.owner.attach(newRecordingBackend(fullCapabilities()).backend,300,96,1)
  f.session=f.owner.backendSession(f.mount)
  check f.owner.resume(f.mount)
  f.listHandle=f.session.handleFor(f.owner.runtime.find("list").id)
  f.source=f.session.acceptedEntities[f.listHandle].list.get.sourceGeneration

proc queue(f:Fixture,first,finish:int,protected:seq[int] = @[]):bool =
  f.session.queueRows(RowViewportRequest(sessionId:f.session.sessionId,
    mountGeneration:f.session.mountGeneration,listHandle:f.listHandle,
    sourceGeneration:f.source,first:first,finish:finish,protected:protected))

proc indexes(f:Fixture):seq[int] =
  for row in f.owner.runtime.find("list").children:result.add(row.listIndex)
  result.sort()

proc editor(f:Fixture,index:int):NodeHandle =
  let entities=f.session.acceptedEntities
  for handle,entity in entities:
    if entity.kind==input:
      let row=entities.getOrDefault(entity.parent)
      if row.row.isSome and row.row.get.itemIndex==index:return handle
  raise newException(AssertionDefect,"editor row is not materialized")

proc bindingOne(handle:NodeHandle,binding:uint64):bool = binding==1
proc record(f:Fixture,handle:NodeHandle,sequence:uint64,
    reasons:set[AndroidProtectionReason]):bool =
  f.protection.recordProtection(AndroidProtectionFact(handle:handle,
    mount:f.session.mountGeneration,binding:1,sequence:sequence,reasons:reasons),
    f.session.mountGeneration,f.session.acceptedEntities,bindingOne)

proc protected(f:Fixture):seq[int] =
  f.protection.snapshotProtectedRows(f.session.mountGeneration,
    f.session.acceptedEntities,bindingOne).getOrDefault(f.listHandle)

suite "Android protection before retained row delivery":
  test "new protection replaces a queued viewport before it can evict the input":
    let f=fixture()
    defer:f.owner.close()
    check f.queue(0,4)
    check f.owner.safeTurn(f.mount)
    let input=f.editor(0)
    check f.indexes == @[0,1,2,3] and f.builds==4 and f.renders==1
    check f.queue(10,14) # Earlier scroll projection has already queued this.
    check f.record(input,1,{rowFocused,rowComposing})
    check f.queue(10,14,f.protected)
    check f.session.pendingRowRequests==1
    check f.builds==4 and f.indexes == @[0,1,2,3]
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[0,10,11,12,13]
    check f.editor(0)==input and f.builds==8 and f.renders==1
    check f.record(input,2,{rowComposing})
    check f.queue(10,14,f.protected)
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[0,10,11,12,13] and f.editor(0)==input
    check f.record(input,3,{})
    check f.queue(10,14,f.protected)
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[10,11,12,13] and f.builds==8 and f.renders==1
    f.protection.reconcileProtection(f.session.mountGeneration,
      f.session.acceptedEntities,bindingOne)
    check f.protection.protectionFactCount==0

  test "paused facts stay data-only and protection survives until resumed delivery":
    let f=fixture()
    defer:f.owner.close()
    check f.queue(0,4)
    check f.owner.safeTurn(f.mount)
    let input=f.editor(0)
    check f.record(input,1,{rowFocused})
    check f.queue(10,14,f.protected)
    check f.owner.pause(f.mount)
    check not f.owner.safeTurn(f.mount)
    check f.session.pendingRowRequests==1 and f.builds==4
    check f.owner.resume(f.mount)
    check f.owner.safeTurn(f.mount)
    check f.indexes == @[0,10,11,12,13] and f.editor(0)==input
    check f.builds==8 and f.renders==1

  test "a late protection lookup cannot resurrect a row already consumed away":
    let f=fixture()
    defer:f.owner.close()
    check f.queue(0,4)
    check f.owner.safeTurn(f.mount)
    let input=f.editor(0)
    check f.queue(10,14)
    check f.owner.safeTurn(f.mount)
    check not f.record(input,1,{rowFocused})
    check f.protected.len==0 and f.protection.protectionFactCount==0
    check f.indexes == @[10,11,12,13]
