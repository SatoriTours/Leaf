## T2 local candidate: native virtualList / compound-row publish+accept
## allocation probe. It is NOT part of the normal test_* runner.
##
## Real managed Runtime (componentApplication + State) + real Win32 backend +
## real Host. A 10000-item list is materialized only inside the bounded viewport
## (120 DIP / 24 DIP rows), with compound rows: text + EDIT + button + checkbox.
##
## r2 measurement correction (probe only, no product change): the native accept
## count is witnessed by a thin wrapper around the real `backend.acceptedDelta`
## callback (scalar counters only, `raises: []`, no output/allocation inside the
## fence), because `rt.acceptedRevision` only counts Runtime publishes. The
## initial attach is measured as a bootstrap *native metadata accept* window:
## its managed/host publish fences are only applicable when that route actually
## published (`stagingChanged`), so a legitimate confirm-only attach is not a
## failure.
##
## Every measured window resets the three protocol fences to -1 right before the
## commit and reads them right after it; -1 = the fence did not run in this
## window and is never a PASS. Row phases additionally require exactly one
## native accept and exactly one Runtime publish, so a window that resolved two
## commits cannot hide a non-zero first one behind a final 0.
##
## r3 criterion correction (probe only, after the first Native run): phase 3 is a
## source-generation replacement (a parent State re-render builds a new
## virtualList -> new ListSource generation), so the row bindings are replaced and
## the native frame is rebuilt from idle parked groups plus the created shortfall.
## It is therefore asserted with a per-row window bound, not with a same-binding
## zero-create claim; same-source row-local churn is not covered here.
##
## Compile (acceptance controller): -d:release --mm:orc -d:nimAllocStats
## -d:leafProtocolProbes. Missing flags exit 2 (NotRun); non-Windows is a
## compile-time error.
when not defined(windows):
  {.error: "Win32 list allocation probe requires Windows".}

import leaf/[core, widgets, components, backend, backend_session,
  ui_thread, native_layout, native_host_adapter, managed_runtime,
  host_reconcile]
import leaf/component_description
import leaf/backends/win32/[api, host, backend]

const
  ItemCount = 10_000        ## off-screen source size: only a bounded frame lands
  RowHeight = 24.0
  ViewportHeight = 120.0
  RowsPerFrame = 5          ## 120 DIP / 24 DIP
  WindowsPerRow = 5         ## row root + text + EDIT + button + checkbox
  FrameWindows = WindowsPerRow * RowsPerFrame
  ParkedBudget = 8          ## RowPool.MaxParkedRows, proven by the frozen suite
  HostWidth = 480.0
  HostHeight = 320.0

var nativeAcceptCalls = 0     ## witness: real acceptedDelta invocations
var lastAcceptRevision = 0'u64 ## scalar only; never formatted inside the fence

var pageState: State[int]
var hotTick = 0
var keyCount = ItemCount

proc rowBuilder(index: int): UiDescription =
  ## Compound row. No business Node is read here and no index is parsed out of a
  ## node id: the row content depends only on the item index and the accepted
  ## hot value.
  let label = if index == 0: "hot-" & $hotTick else: "item " & $index
  host(row(@[
    text(label, key = "label"),
    input("", key = "edit", placeholder = "hint"),
    button("act", key = "button"),
    checkbox("chk", false, key = "check")], key = "row"))

proc ListPage(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
  hotTick = ctx.value(s)
  var keys = newSeqOfCap[string](keyCount)
  for index in 0 ..< keyCount: keys.add($index)
  componentList("list", keys, rowBuilder, rowHeight = RowHeight, overscan = 0,
    styles = style({"height": "120"}))

let ListPageDef = defineComponent[int, State[int]]("ListAllocPage",
  proc(ctx: MountContext, p: int): State[int] =
    result = ctx.state(0)
    pageState = result,
  ListPage)

proc main(): int =
  when not (defined(leafProtocolProbes) and defined(nimAllocStats) and
      defined(release) and defined(gcOrc)):
    echo "probe_win32_list_alloc status=requires-release-orc-alloc-probes"
    return 2
  let activity = newUiScopeActivity()
  let rt = newRuntime(guardUiApplication(
    componentApplication(component(ListPageDef, 0), "list-alloc",
      width = int(HostWidth), height = int(HostHeight)),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("list-alloc", DipSize(width: HostWidth, height: HostHeight))
  h.setStartupScope(proc(): bool = activity.busy or rt.installingUpdate)
  let win = newWin32Backend(h)
  var failures = 0
  # Witness channel: the real typed accepted-delta callback stays in place, the
  # wrapper only counts the call and its revision (no allocation, no output).
  let realAcceptedDelta = win.asBackend.acceptedDelta
  if realAcceptedDelta == nil:
    echo "probe_win32_list_alloc status=requires-accepted-delta-channel"
    h.destroyHost()
    return 2
  win.asBackend.acceptedDelta = proc(delta: HostAcceptedDelta) {.raises: [].} =
    inc nativeAcceptCalls
    lastAcceptRevision = delta.revision
    realAcceptedDelta(delta)

  var windowCalls = 0
  var windowPublishes = 0
  var windowManaged = -1
  var windowHost = -1
  var windowNative = -1
  var windowLastRevision = 0'u64

  template window(label: string, body: untyped) =
    block:
      managedPublishAllocations = -1
      hostPublishAllocations = -1
      nativeAcceptAllocations = -1
      let callsBefore = nativeAcceptCalls
      let publishBefore = rt.acceptedRevision
      var phaseError: ref CatchableError = nil
      try:
        body
      except CatchableError as error:
        phaseError = error # keep the original ref; format it after the reads
      windowManaged = managedPublishAllocations
      windowHost = hostPublishAllocations
      windowNative = nativeAcceptAllocations
      windowCalls = nativeAcceptCalls - callsBefore
      windowPublishes = int(rt.acceptedRevision - publishBefore)
      windowLastRevision = lastAcceptRevision
      let diag = win.diagnostics # only after the counter reads above
      echo label, " native_calls=", windowCalls, " publishes=",
        windowPublishes, " managed=", windowManaged, " host=", windowHost,
        " native=", windowNative, " last_accept_revision=", windowLastRevision,
        " revision=", rt.acceptedRevision, " creates=", diag.creates,
        " set_texts=", diag.setTexts, " live_rows=", diag.liveRows,
        " parked=", diag.parkedRows, " reused=", diag.reusedRows,
        " live_windows=", diag.liveWindows
      if phaseError != nil:
        let message = phaseError.msg
        echo label, " error=", message
        inc failures
      if windowCalls != 1:
        echo label, " native_accept_window expected=1 actual=", windowCalls
        inc failures

  template rowFences(label: string) =
    if windowManaged < 0 or windowHost < 0 or windowNative < 0:
      echo label, " not_triggered managed=", windowManaged, " host=",
        windowHost, " native=", windowNative
      inc failures
    elif windowManaged != 0 or windowHost != 0 or windowNative != 0:
      echo label, " allocations_nonzero managed=", windowManaged, " host=",
        windowHost, " native=", windowNative
      inc failures
    if windowPublishes != 1:
      echo label, " runtime_publish_window expected=1 actual=", windowPublishes
      inc failures

  # phase 0: initial attach. This route may only confirm an already accepted
  # managed description, so it is measured as the bootstrap native metadata
  # accept fence: exactly one native accept, native accept fence zero, and the
  # managed/host publish fences only when this route really published.
  var session: BackendSession
  window("phase0-attach"):
    session = win.attachWin32Backend(rt)
  if windowNative < 0:
    echo "phase0-attach native_accept_fence not_triggered"
    inc failures
  elif windowNative != 0:
    echo "phase0-attach native_accept_allocations_nonzero actual=", windowNative
    inc failures
  if windowPublishes == 0:
    # Confirm-only attach: no Runtime publish happened, so the managed/host
    # publish fences are not applicable and must not be reported as zero.
    echo "phase0-attach publish=not_applicable managed=", windowManaged,
      " host=", windowHost
    if windowManaged != -1 or windowHost != -1:
      echo "phase0-attach publish_fence_without_publish managed=",
        windowManaged, " host=", windowHost
      inc failures
  elif windowPublishes == 1:
    if windowManaged != 0 or windowHost != 0:
      echo "phase0-attach publish_fence managed=", windowManaged, " host=",
        windowHost
      inc failures
  else:
    echo "phase0-attach publish_window expected 0..1 actual=", windowPublishes
    inc failures
  if session == nil:
    echo "probe_win32_list_alloc no_session"
    h.destroyHost()
    return 1
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  let listNode = rt.find("list")
  let listHandle = session.handleFor(listNode.id)
  if listHandle == NoHandle:
    echo "probe_win32_list_alloc no_list_handle"
    h.destroyHost()
    return 1

  proc request(first, finish: int): RowViewportRequest =
    RowViewportRequest(sessionId: session.sessionId,
      mountGeneration: session.mountGeneration, listHandle: listHandle,
      sourceGeneration: rt.find("list").node.listSource.generation,
      first: first, finish: finish, protected: @[])

  # phase 1: initial bounded row frame (create).
  let createsBefore1 = win.diagnostics.creates
  let source1 = request(0, RowsPerFrame).sourceGeneration
  var queued = session.queueRows(request(0, RowsPerFrame))
  if not queued:
    echo "phase1-initial-rows queue_refused source=", source1
    inc failures
  var drained = 0
  window("phase1-initial-rows"):
    drained = session.drainRowRequests()
  rowFences("phase1-initial-rows")
  let diag1 = win.diagnostics
  echo "phase1 request first=0 finish=", RowsPerFrame, " source=", source1
  if drained != 1:
    echo "phase1-initial-rows drain=", drained
    inc failures
  if diag1.liveRows != RowsPerFrame:
    echo "phase1-initial-rows live_rows=", diag1.liveRows
    inc failures
  if diag1.creates <= createsBefore1:
    echo "phase1-initial-rows no_native_creates"
    inc failures

  # phase 2a: move the viewport by three rows (create + remove in one commit).
  let moveBefore = win.diagnostics
  let source2 = request(3, 3 + RowsPerFrame).sourceGeneration
  queued = session.queueRows(request(3, 3 + RowsPerFrame))
  if not queued:
    echo "phase2-move-rows queue_refused source=", source2
    inc failures
  drained = 0
  window("phase2-move-rows"):
    drained = session.drainRowRequests()
  rowFences("phase2-move-rows")
  let diag2 = win.diagnostics
  echo "phase2 request first=3 finish=", 3 + RowsPerFrame, " source=", source2
  if drained != 1:
    echo "phase2-move-rows drain=", drained
    inc failures
  if diag2.creates <= moveBefore.creates:
    echo "phase2-move-rows no_native_creates"
    inc failures
  if diag2.parkedRows <= moveBefore.parkedRows:
    echo "phase2-move-rows rows_not_parked parked=", diag2.parkedRows
    inc failures
  if diag2.liveRows > RowsPerFrame + ParkedBudget:
    echo "phase2-move-rows live_rows=", diag2.liveRows
    inc failures

  # phase 2b: return to the first frame; the parked slots must hand over HWNDs.
  let reuseBefore = win.diagnostics
  queued = session.queueRows(request(0, RowsPerFrame))
  if not queued:
    echo "phase2-reuse-rows queue_refused"
    inc failures
  drained = 0
  window("phase2-reuse-rows"):
    drained = session.drainRowRequests()
  rowFences("phase2-reuse-rows")
  let diag3 = win.diagnostics
  echo "phase2-reuse creates_delta=", int(diag3.creates - reuseBefore.creates),
    " reused_delta=", diag3.reusedRows - reuseBefore.reusedRows
  if drained != 1:
    echo "phase2-reuse-rows drain=", drained
    inc failures
  if diag3.reusedRows <= reuseBefore.reusedRows:
    echo "phase2-reuse-rows no_warm_reuse"
    inc failures

  # phase 3: source-generation update. A parent State re-render builds a new
  # virtualList, hence a new ListSource generation; managed_runtime then erases
  # the old row instances and re-materializes rows by key, and row bindings of a
  # stale generation are rejected, so the native frame is rebuilt: idle parked
  # groups are borrowed by owner+signature and the shortfall is created. That is
  # the contracted path, so the criterion is the per-row window bound, not a
  # same-binding zero-create (same-source row-local churn stays uncovered).
  let updateBefore = win.diagnostics
  let sourceBefore = request(0, RowsPerFrame).sourceGeneration
  echo "phase3 source_before=", sourceBefore
  pageState.set(pageState.read() + 1)
  window("phase3-source-generation-update"):
    discard rt.flush()
  rowFences("phase3-source-generation-update")
  let diag4 = win.diagnostics
  let sourceAfter = rt.find("list").node.listSource.generation
  echo "phase3 source_after=", sourceAfter,
    " creates_delta=", int(diag4.creates - updateBefore.creates),
    " reused_delta=", diag4.reusedRows - updateBefore.reusedRows
  if sourceAfter == sourceBefore:
    echo "phase3-source-generation-update same_source before=", sourceBefore,
      " after=", sourceAfter
    inc failures
  if diag4.setTexts <= updateBefore.setTexts:
    echo "phase3-source-generation-update no_accepted_text_delta"
    inc failures
  if diag4.liveRows != RowsPerFrame:
    echo "phase3-source-generation-update live_rows=", diag4.liveRows
    inc failures
  if diag4.parkedRows > ParkedBudget:
    echo "phase3-source-generation-update parked=", diag4.parkedRows
    inc failures
  if int(diag4.creates - updateBefore.creates) > FrameWindows:
    echo "phase3-source-generation-update creates_delta=",
      int(diag4.creates - updateBefore.creates), " bound=", FrameWindows
    inc failures

  # phase 4: shrink the source below the materialized frame; the rows that are
  # out of range must leave inside the same accepted commit.
  let shrinkBefore = win.diagnostics
  keyCount = 3
  pageState.set(pageState.read() + 1)
  window("phase4-shrink"):
    discard rt.flush()
  rowFences("phase4-shrink")
  let diag5 = win.diagnostics
  echo "phase4 source_after=", rt.find("list").node.listSource.generation
  if diag5.liveRows >= shrinkBefore.liveRows:
    echo "phase4-shrink live_rows_not_reduced before=", shrinkBefore.liveRows,
      " after=", diag5.liveRows
    inc failures
  if diag5.liveRows > keyCount:
    echo "phase4-shrink live_rows=", diag5.liveRows, " keys=", keyCount
    inc failures

  h.destroyHost()
  if failures == 0:
    echo "probe_win32_list_alloc status=passed"
    return 0
  echo "probe_win32_list_alloc status=failed failures=", failures
  1

when isMainModule:
  quit(main())
