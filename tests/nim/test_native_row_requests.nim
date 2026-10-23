## S0: safe-turn row viewport requests. `queueRows` records accepted facts on
## the UI thread and never renders; `drainRowRequests` is the only place that
## materializes rows, and only on an ordinary safe turn. Requests queued during
## a commit/reentrant drain survive to the next turn, the latest request per
## list replaces the older viewport, the queue is bounded, and stale/faulted/
## closed identities never reach business state.
import std/[unittest, algorithm]
import ../fixture_app
import leaf/[core, widgets, backend, backend_session, host_protocol]
import leaf/backends/headless

proc app(render: proc(): Node): Application =
  fixtureApplication(render, "rows", 800, 600)

proc makeHost(sessionId = 51'u64, mountGeneration = 1'u64): HostContext =
  HostContext(sessionId: sessionId, mountGeneration: mountGeneration,
    contentWidth: 800, contentHeight: 600, scale: 1.0)

var items: seq[string]
var rowBuilds = 0
var failRowAt = -1
var showList = true
var counter = 0
var bulkLists = 0
var bulkBuilds = 0

# Reentrancy probe: a row builder asks for another viewport and tries to drain.
var rowSession: BackendSession
var armReentrant = false
var deferRequest: RowViewportRequest
var reentrantResult = -1

# A render that does not change list facts keeps the very same list node, so
# its source generation stays valid across unrelated commits.
var cachedList: Node

proc listNode(): Node =
  if cachedList == nil:
    cachedList = virtualList("list", items, proc(index: int): Node =
      inc rowBuilds
      if index == failRowAt: fail("row build failure")
      if armReentrant and index == 0 and rowSession != nil:
        if not rowSession.queueRows(deferRequest):
          reentrantResult = -2
        else:
          reentrantResult = rowSession.drainRowRequests()
      text(items[index], key = "row"), rowHeight = 10, overscan = 0)
  cachedList

proc renderRows(): Node =
  var children: seq[Node]
  children.add(text($counter, key = "counter"))
  children.add(button("go", key = "go", onClick = proc(e: Event) = inc counter))
  if showList:
    children.add(listNode())
  else:
    children.add(text("no list", key = "list"))
  column(children, key = "root")

proc renderBulk(): Node =
  var children: seq[Node]
  for index in 0 ..< bulkLists:
    children.add(virtualList("l" & $index, @["only"],
      proc(row: int): Node =
        inc bulkBuilds
        text("row", key = "row"), rowHeight = 10,
      overscan = 0))
  column(children, key = "root")

proc resetRows(count = 200): void =
  items = @[]
  for index in 0 ..< count: items.add($index)
  rowBuilds = 0
  failRowAt = -1
  showList = true
  counter = 0
  rowSession = nil
  armReentrant = false
  reentrantResult = -1
  cachedList = nil
  bulkBuilds = 0

proc request(session: BackendSession, listHandle: NodeHandle, source: ListSource,
             first, finish: int, protected: seq[int] = @[]): RowViewportRequest =
  RowViewportRequest(sessionId: session.sessionId,
    mountGeneration: session.mountGeneration, listHandle: listHandle,
    sourceGeneration: source.generation, first: first, finish: finish,
    protected: protected)

proc rowIndices(rt: Runtime, key = "list"): seq[int] =
  for child in rt.find(key).children: result.add(child.listIndex)
  result.sort()

suite "queued row viewports":
  test "enqueue records facts without rendering, drain materializes once":
    resetRows()
    let rt = newRuntime(app(renderRows))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let source = rt.find("list").node.listSource
    check rowBuilds == 0
    check session.queueRows(request(session, handle, source, 0, 5))
    check rowBuilds == 0
    check session.pendingRowRequests == 1
    check rt.find("list").children.len == 0
    check session.drainRowRequests() == 1
    check rowBuilds == 5
    check rt.find("list").children.len == 5
    check rowIndices(rt) == @[0, 1, 2, 3, 4]
    check session.pendingRowRequests == 0
    check session.drainRowRequests() == 0
    session.dispose()

  test "the latest request per list replaces the older viewport":
    resetRows()
    let rt = newRuntime(app(renderRows))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let source = rt.find("list").node.listSource
    check session.queueRows(request(session, handle, source, 0, 5))
    check session.queueRows(request(session, handle, source, 20, 25))
    check session.pendingRowRequests == 1
    check session.drainRowRequests() == 1
    check rowBuilds == 5
    check rowIndices(rt) == @[20, 21, 22, 23, 24]
    # Protected rows follow the latest request as well.
    check session.queueRows(request(session, handle, source, 30, 32, @[99]))
    check session.queueRows(request(session, handle, source, 40, 42, @[77]))
    check session.pendingRowRequests == 1
    check session.drainRowRequests() == 1
    check rowIndices(rt) == @[40, 41, 77]
    session.dispose()

  test "requests queued during apply survive the commit and drain later":
    resetRows()
    let rt = newRuntime(app(renderRows))
    let recording = newRecordingBackend(fullCapabilities())
    let baseApply = recording.backend.apply
    var armed: proc() {.closure.} = nil
    recording.backend.apply = proc(batch: UpdateBatch) =
      baseApply(batch)
      if armed != nil: armed()
    var observed: BackendSession
    let session = attachBackendObserved(rt, recording.backend, makeHost(),
      compatible, proc(s: BackendSession) = observed = s)
    let handle = session.handleFor(rt.find("list").id)
    let queued = request(session, handle, rt.find("list").node.listSource, 0, 4)
    var ranInside = false
    armed = proc() =
      ranInside = true
      check observed.queueRows(queued)
      # Commit in progress: the drain must not run and must keep the request.
      check observed.drainRowRequests() == 0
      check rowBuilds == 0
    check rt.dispatchRefresh("go", Event(kind: click))
    armed = nil
    check ranInside
    check rowBuilds == 0
    check session.pendingRowRequests == 1
    check session.drainRowRequests() == 1
    check rowBuilds == 4
    check session.pendingRowRequests == 0
    session.dispose()

  test "a reentrant drain defers to the next turn without spinning":
    resetRows()
    let rt = newRuntime(app(renderRows))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    rowSession = session
    let handle = session.handleFor(rt.find("list").id)
    let source = rt.find("list").node.listSource
    deferRequest = request(session, handle, source, 50, 52)
    check session.queueRows(request(session, handle, source, 0, 2))
    armReentrant = true
    check session.drainRowRequests() == 1
    armReentrant = false
    check reentrantResult == 0
    check rowBuilds == 2
    check rowIndices(rt) == @[0, 1]
    check session.pendingRowRequests == 1
    check session.drainRowRequests() == 1
    check rowIndices(rt) == @[50, 51]
    session.dispose()

suite "rejected queued row viewports":
  test "invalid identity, range, source or list is refused":
    resetRows()
    let rt = newRuntime(app(renderRows))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let source = rt.find("list").node.listSource
    let buttonHandle = session.handleFor(rt.find("go").id)
    check not session.queueRows(RowViewportRequest(sessionId: session.sessionId + 1,
      mountGeneration: session.mountGeneration, listHandle: handle,
      sourceGeneration: source.generation, first: 0, finish: 2))
    check not session.queueRows(RowViewportRequest(sessionId: session.sessionId,
      mountGeneration: session.mountGeneration + 1, listHandle: handle,
      sourceGeneration: source.generation, first: 0, finish: 2))
    check not session.queueRows(RowViewportRequest(sessionId: session.sessionId,
      mountGeneration: session.mountGeneration, listHandle: NoHandle,
      sourceGeneration: source.generation, first: 0, finish: 2))
    check not session.queueRows(request(session, buttonHandle, source, 0, 2))
    check not session.queueRows(request(session, handle, source, 0, source.len + 1))
    check not session.queueRows(request(session, handle, source, -1, 2))
    check not session.queueRows(request(session, handle, source, 5, 2))
    check not session.queueRows(RowViewportRequest(sessionId: session.sessionId,
      mountGeneration: session.mountGeneration, listHandle: handle,
      sourceGeneration: source.generation - 1, first: 0, finish: 2))
    check not session.queueRows(request(session, handle, source, 0, 2, @[source.len]))
    check session.pendingRowRequests == 0
    check rowBuilds == 0
    session.dispose()

  test "cross-runtime and cross-session requests never reach business":
    resetRows()
    let rt = newRuntime(app(renderRows))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost(51'u64))
    let other = newRuntime(app(renderRows))
    let otherRecording = newRecordingBackend(fullCapabilities())
    let otherSession = attachBackend(other, otherRecording.backend, makeHost(52'u64))
    let handle = session.handleFor(rt.find("list").id)
    let foreign = request(session, handle, rt.find("list").node.listSource, 0, 3)
    check not otherSession.queueRows(foreign)
    check otherSession.pendingRowRequests == 0
    check otherSession.drainRowRequests() == 0
    check rowBuilds == 0
    check other.find("list").children.len == 0
    session.dispose()
    otherSession.dispose()

  test "a source replaced after enqueue is not executed":
    resetRows()
    let rt = newRuntime(app(renderRows))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let oldGeneration = rt.find("list").node.listSource.generation
    check session.queueRows(request(session, handle, rt.find("list").node.listSource, 0, 5))
    items = @["a", "b", "c"]
    cachedList = nil
    check rt.dispatchRefresh("go", Event(kind: click))
    check rt.find("list").node.listSource.generation != oldGeneration
    check session.drainRowRequests() == 0
    check rowBuilds == 0
    check rt.find("list").children.len == 0
    check session.pendingRowRequests == 0
    # The same viewport against the new source is accepted and runs.
    check session.queueRows(request(session, handle, rt.find("list").node.listSource, 0, 2))
    check session.drainRowRequests() == 1
    check rowBuilds == 2
    session.dispose()

  test "unmounted lists drop their queued viewports":
    resetRows()
    let rt = newRuntime(app(renderRows))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    check session.queueRows(request(session, handle, rt.find("list").node.listSource, 0, 3))
    showList = false
    check rt.dispatchRefresh("go", Event(kind: click))
    check session.drainRowRequests() == 0
    check rowBuilds == 0
    check session.pendingRowRequests == 0
    session.dispose()

  test "close, fault and dispose invalidate queued viewports":
    resetRows()
    let rt = newRuntime(app(renderRows))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let source = rt.find("list").node.listSource
    check session.queueRows(request(session, handle, source, 0, 3))
    requestClose(session)
    check session.pendingRowRequests == 0
    check not session.queueRows(request(session, handle, source, 0, 3))
    check session.drainRowRequests() == 0
    check rowBuilds == 0

    # A faulted session refuses new viewports and never replays old ones.
    let faultedRt = newRuntime(app(renderRows))
    let faultedRecording = newRecordingBackend(fullCapabilities())
    let faultedSession = attachBackend(faultedRt, faultedRecording.backend,
      makeHost(53'u64))
    let faultedHandle = faultedSession.handleFor(faultedRt.find("list").id)
    let faultedSource = faultedRt.find("list").node.listSource
    check faultedSession.queueRows(request(faultedSession, faultedHandle,
      faultedSource, 0, 3))
    faultedRecording.failApply = true
    faultedRecording.failRestore = true
    expect UiError:
      discard faultedRt.dispatchRefresh("go", Event(kind: click))
    check faultedSession.faulted
    check faultedSession.pendingRowRequests == 0
    check not faultedSession.queueRows(request(faultedSession, faultedHandle,
      faultedSource, 0, 3))
    check faultedSession.drainRowRequests() == 0
    check rowBuilds == 0

    let disposedRt = newRuntime(app(renderRows))
    let disposedRecording = newRecordingBackend(fullCapabilities())
    let disposedSession = attachBackend(disposedRt, disposedRecording.backend,
      makeHost(54'u64))
    let disposedHandle = disposedSession.handleFor(disposedRt.find("list").id)
    let disposedSource = disposedRt.find("list").node.listSource
    check disposedSession.queueRows(request(disposedSession, disposedHandle,
      disposedSource, 0, 3))
    disposedSession.dispose()
    check disposedSession.pendingRowRequests == 0
    check not disposedSession.queueRows(request(disposedSession, disposedHandle,
      disposedSource, 0, 3))
    check disposedSession.drainRowRequests() == 0
    check rowBuilds == 0

suite "bounded queued row viewports":
  test "the queue is bounded and its oldest facts stay intact":
    resetRows()
    bulkLists = MaxPendingRowRequests + 3
    let rt = newRuntime(app(renderBulk))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    var accepted = 0
    for index in 0 ..< bulkLists:
      let handle = session.handleFor(rt.find("l" & $index).id)
      let source = rt.find("l" & $index).node.listSource
      if session.queueRows(request(session, handle, source, 0, 1)):
        inc accepted
    check accepted == MaxPendingRowRequests
    check session.pendingRowRequests == MaxPendingRowRequests
    check bulkBuilds == 0
    check session.drainRowRequests() == MaxPendingRowRequests
    check bulkBuilds == MaxPendingRowRequests
    check session.pendingRowRequests == 0
    bulkLists = 0
    session.dispose()

suite "failed queued row viewports":
  test "a rejected row build keeps the accepted viewport and does not spin":
    resetRows()
    let rt = newRuntime(app(renderRows))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let source = rt.find("list").node.listSource
    let revision = rt.acceptedRevision
    failRowAt = 3
    check session.queueRows(request(session, handle, source, 0, 5))
    expect UiError:
      discard session.drainRowRequests()
    check rt.acceptedRevision == revision
    check rt.find("list").children.len == 0
    check not session.faulted
    check session.pendingRowRequests == 0
    check session.drainRowRequests() == 0
    failRowAt = -1
    check session.queueRows(request(session, handle, source, 0, 5))
    check session.drainRowRequests() == 1
    check rowIndices(rt) == @[0, 1, 2, 3, 4]
    session.dispose()

  test "the explicit synchronous requestRows contract is unchanged":
    resetRows()
    let rt = newRuntime(app(renderRows))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let rows = session.requestRows(handle, rt.find("list").node.listSource.generation, 10, 13)
    check rows.len == 3
    check rowBuilds == 3
    check rowIndices(rt) == @[10, 11, 12]
    check session.pendingRowRequests == 0
    check session.drainRowRequests() == 0
    session.dispose()

## r1: drain failure capacity. A fact that `queueRows` accepted must never
## disappear silently: it either executes, is replaced by a newer fact for the
## same list, or is refused with an observable `false` that the caller can
## re-queue on a later turn. The 256 bound covers the total live recorded facts,
## including the ones still in flight inside an active drain.
var reorderLists = 0
var reorderFail = false
var reorderDefect = false
var reorderBuilds = 0
var reorderDuring: seq[RowViewportRequest] = @[]
var reorderDuringResults: seq[bool] = @[]
var reorderDuringDone = false
var reorderArmDuring = false
var reorderSession: BackendSession

proc renderReorder(): Node =
  ## One builder per list. The closure is assigned to a `var` inside a branch so
  ## each list keeps its own captured index (an inline closure argument would
  ## share one hoisted capture location across the loop).
  var children: seq[Node]
  for index in 0 ..< reorderLists:
    let which = index
    var builder: RowBuilder
    if which == 0:
      builder = proc(row: int): Node =
        if reorderArmDuring and not reorderDuringDone:
          reorderDuringDone = true
          for request in reorderDuring:
            reorderDuringResults.add(reorderSession.queueRows(request))
        inc reorderBuilds
        text("row" & $row, key = "row")
    elif which == 1:
      builder = proc(row: int): Node =
        if reorderDefect: raise newException(IndexDefect, "row builder defect")
        if reorderFail: fail("row build failure (reorder)")
        inc reorderBuilds
        text("row" & $row, key = "row")
    else:
      builder = proc(row: int): Node =
        inc reorderBuilds
        text("row" & $row, key = "row")
    children.add(virtualList("r" & $which, @["a", "b"], builder,
      rowHeight = 10, overscan = 0))
  column(children, key = "root")

proc resetReorder(): void =
  reorderLists = 0
  reorderFail = true
  reorderDefect = false
  reorderBuilds = 0
  reorderDuring = @[]
  reorderDuringResults = @[]
  reorderDuringDone = false
  reorderArmDuring = false
  reorderSession = nil

proc reorderRequest(session: BackendSession, rt: Runtime, listIndex, first,
                    finish: int): RowViewportRequest =
  let handle = session.handleFor(rt.find("r" & $listIndex).id)
  let source = rt.find("r" & $listIndex).node.listSource
  request(session, handle, source, first, finish)

suite "drain failure capacity":
  test "facts accepted during a failing drain are never silently lost":
    resetReorder()
    reorderLists = 260
    let rt = newRuntime(app(renderReorder))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost(61'u64))
    reorderSession = session
    var queued = 0
    for index in 0 ..< MaxPendingRowRequests:
      if session.queueRows(reorderRequest(session, rt, index, 0, 1)): inc queued
    check queued == MaxPendingRowRequests
    # Four new lists asked for while the drain is inside l0's row build. The
    # cap is already reserved by the in-flight facts, so these are refused with
    # an observable `false` instead of being accepted and later dropped.
    reorderDuring = @[reorderRequest(session, rt, 256, 0, 1),
      reorderRequest(session, rt, 257, 0, 1),
      reorderRequest(session, rt, 258, 0, 1),
      reorderRequest(session, rt, 259, 0, 1)]
    reorderArmDuring = true
    expect UiError:
      discard session.drainRowRequests()
    reorderArmDuring = false
    check reorderDuringResults == @[false, false, false, false]
    # l0 executed one row, l1 failed and is dropped, l2..l255 stay queued.
    check reorderBuilds == 1
    check session.pendingRowRequests == MaxPendingRowRequests - 2
    check rt.find("r1").children.len == 0
    for index in 256 .. 259:
      check rt.find("r" & $index).children.len == 0
    check session.drainRowRequests() == MaxPendingRowRequests - 2
    check session.pendingRowRequests == 0
    check rt.find("r1").children.len == 0
    for index in 2 ..< MaxPendingRowRequests:
      check rt.find("r" & $index).children.len == 1
    # Everything refused above is re-queueable on a later turn and then runs.
    reorderFail = false
    var retried = 0
    if session.queueRows(reorderRequest(session, rt, 1, 0, 1)): inc retried
    for index in 256 .. 259:
      if session.queueRows(reorderRequest(session, rt, index, 0, 1)): inc retried
    check retried == 5
    check session.drainRowRequests() == 5
    check rt.find("r1").children.len == 1
    for index in 256 .. 259:
      check rt.find("r" & $index).children.len == 1
    session.dispose()

  test "a newer fact replaces an in-flight fact for the same list within the bound":
    resetReorder()
    reorderLists = 256
    let rt = newRuntime(app(renderReorder))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost(62'u64))
    reorderSession = session
    var queued = 0
    for index in 0 ..< MaxPendingRowRequests:
      if session.queueRows(reorderRequest(session, rt, index, 0, 1)): inc queued
    check queued == MaxPendingRowRequests
    # The in-flight r2 fact asked for rows 0..1; the newer fact asks for 1..2.
    # It takes over the in-flight slot's capacity, so it needs no extra room.
    reorderDuring = @[reorderRequest(session, rt, 2, 1, 2)]
    reorderArmDuring = true
    expect UiError:
      discard session.drainRowRequests()
    reorderArmDuring = false
    check reorderDuringResults == @[true]
    # 253 unattempted facts (r3..r255) plus the newer r2 fact.
    check session.pendingRowRequests == 254
    check session.drainRowRequests() == 254
    check session.pendingRowRequests == 0
    check rowIndices(rt, "r2") == @[1]
    check rowIndices(rt, "r3") == @[0]
    check rt.find("r1").children.len == 0
    session.dispose()

  test "a row-build Defect faults the session and never strands or crashes":
    resetReorder()
    reorderLists = 258
    let rt = newRuntime(app(renderReorder))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost(63'u64))
    reorderSession = session
    var queued = 0
    for index in 0 ..< MaxPendingRowRequests:
      if session.queueRows(reorderRequest(session, rt, index, 0, 1)): inc queued
    check queued == MaxPendingRowRequests
    # A Defect is not a recoverable UiError: it leaves the Runtime attempt scope
    # unusable, so no recorded fact could ever run again. The session is declared
    # faulted and its facts are dropped instead of being kept as dead
    # reservations. This boundary is allocation-free; growing the queue while a
    # Defect unwinds crashed the Windows debug build (D-W1, 0xC0000005).
    reorderDefect = true
    expect IndexDefect:
      discard session.drainRowRequests()
    check session.faulted
    check session.pendingRowRequests == 0
    check not session.queueRows(reorderRequest(session, rt, 256, 0, 1))
    check session.drainRowRequests() == 0
    # Dropping the facts is not a business effect: nothing ran for the failure.
    check rt.find("r1").children.len == 0
    # The unrecoverable boundary is observable rather than silent: explicit
    # synchronous requests now fail loudly instead of touching the dead scope.
    expect UiError:
      discard session.requestRows(session.handleFor(rt.find("r2").id),
        rt.find("r2").node.listSource.generation, 0, 1)
    requestClose(session)
    check session.pendingRowRequests == 0
