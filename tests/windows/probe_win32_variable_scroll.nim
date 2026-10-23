## Probe-only input: variable list, unchanged typed materialized rowset, real
## SB_LINEDOWN. Exact schedule: attach, 2 prime turns, one message, 2 scroll turns.
## No pump, fake viewport requests, product repair, source/State changes or warmup.
## A compiled probe is not a Native RED. Valid Native geometry failures establish
## RED; all-PASS is a coverage addition. Invalid OS sampling is NotRun.
when not defined(windows):
  {.error: "Variable scroll probe requires real Windows".}
when not defined(leafProtocolProbes):
  {.error: "Variable scroll probe requires leafProtocolProbes".}

import std/[tables, options, algorithm, math]
import leaf/[core, widgets, components, backend, backend_session, ui_thread,
  native_layout]
import leaf/component_description
import leaf/backends/win32/[api, calls, host, backend]

proc GetWindowRgnBox(window: HWND, rect: ptr RECT): int32 {.
  importc: "GetWindowRgnBox", dynlib: "user32.dll", stdcall.}

const
  ItemCount = 20
  ViewportDip = 120.0
  StepDip = 24.0
  TolerancePx = 1.0
  RegionNull = 1'i32
  RegionSimple = 2'i32
  RegionComplex = 3'i32
  BeforeTops = [0.0, 24.0, 72.0, 96.0, 144.0]
  AfterTops = [-24.0, 0.0, 48.0, 72.0, 120.0]
  RowHeights = [24.0, 48.0, 24.0, 48.0, 24.0]

var
  pageKeys: seq[string]
  parentRenders = 0
  nativeAcceptCalls = 0
  lastAcceptRevision = 0'u64
  failures = 0

type
  ProbeBlocked = object of CatchableError
  ProbeFailed = object of CatchableError
  IntentFacts = tuple[valid: bool, desiredOffset, appliedOffset: float64,
    intentGeneration: uint64]
  RowFact = object
    list, root: NodeHandle
    source: uint64
    index: int
    key: string
    window, parent: HWND
    rect: RECT                    # viewport-local actual window edges in px
    region: RECT                  # window-local actual region box
    rectOk, mapReturn, regionKind: int32
    rectError, mapError, regionError: uint32
  Sample = object
    revision, source: uint64
    parentRenders, creates: uint64
    nativeCalls, nativeTotal: int
    lastAcceptRevision: uint64
    intent: IntentFacts
    frame: ListFrameFacts
    rows: seq[RowFact]
    bar: SCROLLINFO
    barOk: int32
    barError: uint32
    client: RECT
    dpi: uint32

proc blocked(message: string) {.noreturn.} =
  raise newException(ProbeBlocked, message)
proc require(condition: bool, message: string) =
  if not condition: raise newException(ProbeFailed, message)
proc checkValue(condition: bool, message: string) =
  if not condition:
    inc failures
    echo "check_failed ", message
proc near(a, b: float64): bool = abs(a - b) <= TolerancePx
proc hwndValue(window: HWND): uint64 = uint64(cast[uint](window))

let RowDef = defineComponent[int, int]("VariableScrollProbeRow",
  proc(ctx: MountContext, index: int): int = index,
  proc(ctx: ComponentContext, index, model: int): UiDescription =
    host(row(@[text("row " & $index, key = "label")], key = "row",
      styles = style({"height": (if index mod 2 == 0: "24" else: "48")}))))

let PageDef = defineComponent[int, int]("VariableScrollProbePage",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p, model: int): UiDescription =
    inc parentRenders
    componentList("list", pageKeys,
      proc(index: int): UiDescription = component(RowDef, index),
      rowHeight = 0.0, estimatedHeight = 24.0, overscan = 1,
      styles = style({"height": "120"})))

var enumerated: seq[HWND]
proc collect(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  discard data
  enumerated.add(window)
  BOOL(1)

proc viewportOf(h: Win32Host): HWND =
  enumerated.setLen(0)
  setLastError(0)
  let enumReturn = EnumChildWindows(h.windowHandle, collect, 0)
  let enumError = lastError()
  echo "enumerate return=", enumReturn, " err=", enumError
  if enumReturn == 0 and enumError != 0: blocked("EnumChildWindows invalid sample")
  var ports: seq[HWND]
  for window in enumerated:
    setLastError(0)
    let style = GetWindowLongW(window, GWL_STYLE)
    let error = lastError()
    if style == 0 and error != 0: blocked("GetWindowLongW invalid sample")
    if (uint32(style) and WS_VSCROLL) != 0: ports.add(window)
  echo "viewports=", ports.len
  require(ports.len == 1, "expected one actual WS_VSCROLL viewport")
  ports[0]

proc listHandleOf(session: BackendSession): NodeHandle =
  let entities = session.acceptedEntities()
  var count = 0
  for entity in entities.values:
    if entity.kind == NodeKind.virtualList:
      inc count
      result = entity.handle
      require(entity.list.isSome, "accepted list metadata missing")
      require(entity.list.get.itemCount == ItemCount, "accepted count differs")
      require(entity.list.get.overscan == 1, "new probe overscan must be 1")
  require(count == 1, "expected exactly one typed list")

proc sample(win: Win32Backend, session: BackendSession, rt: Runtime,
            port: HWND, listHandle: NodeHandle, callsInWindow: int): Sample =
  # This is outside all allocation fences; materialized DTOs/logs are observations.
  result.nativeCalls = callsInWindow
  result.nativeTotal = nativeAcceptCalls
  result.lastAcceptRevision = lastAcceptRevision
  result.revision = rt.acceptedRevision
  result.parentRenders = uint64(parentRenders)
  result.creates = win.diagnostics.creates
  result.intent = win.listIntentForTest(listHandle)
  result.frame = win.listFrameForTest(listHandle)
  setLastError(0)
  let clientOk = GetClientRect(port, addr result.client)
  let clientError = lastError()
  result.dpi = GetDpiForWindow(port)
  echo "client_sample ok=", clientOk, " err=", clientError, " dpi=", result.dpi
  if clientOk == 0 or result.dpi == 0: blocked("viewport API sample invalid")
  let scale = float64(result.dpi) / 96.0
  require(result.client.right > result.client.left and
    near(float64(result.client.bottom - result.client.top), ViewportDip * scale),
    "actual client must be positive width and 120 DIP height")
  result.bar = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: SIF_ALL)
  setLastError(0)
  result.barOk = int32(GetScrollInfo(port, SB_VERT, addr result.bar))
  result.barError = lastError()
  if result.barOk == 0: blocked("GetScrollInfo invalid sample")
  let entities = session.acceptedEntities()
  require(entities.hasKey(listHandle), "typed list disappeared")
  require(entities[listHandle].list.isSome, "typed list has no source metadata")
  result.source = entities[listHandle].list.get.sourceGeneration
  for entity in entities.values:
    if entity.row.isNone: continue
    let binding = entity.row.get
    if binding.listHandle != listHandle: continue
    var fact = RowFact(list: binding.listHandle, root: entity.handle,
      source: binding.sourceGeneration, index: binding.itemIndex, key: binding.itemKey)
    fact.window = win.rowWindowForTest(entity.handle)
    require(fact.window != nil, "accepted typed row has no live typed HWND")
    setLastError(0)
    fact.parent = GetParent(fact.window)
    let parentError = lastError()
    if fact.parent == nil and parentError != 0: blocked("GetParent invalid sample")
    var rect: RECT
    setLastError(0)
    fact.rectOk = int32(GetWindowRect(fact.window, addr rect))
    fact.rectError = lastError()
    if fact.rectOk == 0: blocked("GetWindowRect invalid sample")
    var corners = [POINT(x: rect.left, y: rect.top),
      POINT(x: rect.right, y: rect.bottom)]
    setLastError(0)
    fact.mapReturn = MapWindowPoints(nil, port, addr corners[0], 2)
    fact.mapError = lastError()
    if fact.mapReturn == 0 and fact.mapError != 0:
      blocked("MapWindowPoints invalid sample")
    fact.rect = RECT(left: corners[0].x, top: corners[0].y,
      right: corners[1].x, bottom: corners[1].y)
    setLastError(0)
    fact.regionKind = GetWindowRgnBox(fact.window, addr fact.region)
    fact.regionError = lastError()
    # Native plans install custom regions. An unreadable necessary region is
    # insufficient sampling, not evidence of a geometry product RED.
    if fact.regionKind notin [RegionNull, RegionSimple, RegionComplex]:
      blocked("GetWindowRgnBox missing/invalid necessary sample")
    result.rows.add(fact)
  result.rows.sort(proc(a, b: RowFact): int = cmp(a.index, b.index))

proc printSample(label: string, value: Sample) =
  echo label, " revision=", value.revision, " source=", value.source,
    " parent_renders=", value.parentRenders, " creates=", value.creates,
    " native_calls=", value.nativeCalls, " native_total=", value.nativeTotal,
    " last_accept_revision=", value.lastAcceptRevision,
    " allocation_fences=not_collected/no_allocation_claim"
  echo label, " intent_valid=", value.intent.valid,
    " desired=", value.intent.desiredOffset, " applied=", value.intent.appliedOffset,
    " intent_generation=", value.intent.intentGeneration,
    " frame_valid=", value.frame.hasAccepted,
    " frame_source=", value.frame.acceptedSource,
    " frame_id=", value.frame.acceptedFrameId,
    " frame_token=", value.frame.acceptedToken,
    " frame_offset=", value.frame.acceptedOffset,
    " frame_range=", value.frame.acceptedFirst, "..", value.frame.acceptedFinish,
    " rowset_ready=", value.frame.rowsetReady,
    " rows_pending=", value.frame.rowsPending, " trim_pending=", value.frame.trimPending,
    " dpi=", value.dpi, " client=", value.client.right - value.client.left,
    "x", value.client.bottom - value.client.top
  echo label, " bar_ok=", value.barOk, " bar_err=", value.barError,
    " bar_min=", value.bar.nMin, " bar_max=", value.bar.nMax,
    " page=", value.bar.nPage, " pos=", value.bar.nPos,
    " track=", value.bar.nTrackPos
  for row in value.rows:
    echo label, " row list=", uint64(row.list), " root=", uint64(row.root),
      " key=", row.key, " index=", row.index, " source=", row.source,
      " hwnd=", hwndValue(row.window), " parent=", hwndValue(row.parent),
      " rect=", row.rect.left, ",", row.rect.top, ",", row.rect.right, ",", row.rect.bottom,
      " rect_ok=", row.rectOk, " rect_err=", row.rectError,
      " map_ret=", row.mapReturn, " map_err=", row.mapError,
      " region_kind=", row.regionKind, " region_err=", row.regionError,
      " region=", row.region.left, ",", row.region.top, ",",
      row.region.right, ",", row.region.bottom
  for row in value.frame.acceptedRows:
    echo label, " measured index=", row.index, " key=", row.key,
      " height=", row.height, " prefix=", row.prefix

proc sameBinding(a, b: RowFact): bool =
  a.list == b.list and a.root == b.root and a.source == b.source and
    a.index == b.index and a.key == b.key and a.window == b.window and a.parent == b.parent

proc sameRect(a, b: RECT): bool =
  a.left == b.left and a.top == b.top and a.right == b.right and a.bottom == b.bottom

proc verifyRows(value: Sample, port: HWND, moved: bool, label: string) =
  checkValue(value.rows.len == 5, label & " five typed materialized roots")
  let scale = float64(value.dpi) / 96.0
  for position, row in value.rows:
    checkValue(row.parent == port, label & " actual parent")
    checkValue(row.source == value.source, label & " row source")
    if position >= 5:
      checkValue(false, label & " extra accepted root")
      continue
    checkValue(row.index == position and row.key == $position,
      label & " typed index/key")
    let top = if moved: AfterTops[position] else: BeforeTops[position]
    let bottom = top + RowHeights[position]
    # Independently specified shared edges, not the product's rowRect helper.
    let expectedTop = round(top * scale)
    let expectedBottom = round(bottom * scale)
    checkValue(near(float64(row.rect.top), expectedTop), label & " actual top index " & $position)
    checkValue(near(float64(row.rect.bottom), expectedBottom), label & " actual bottom index " & $position)
    checkValue(near(float64(row.rect.left), 0.0) and
      near(float64(row.rect.right), float64(value.client.right - value.client.left)),
      label & " actual width index " & $position)
    let visibleTop = max(0.0, expectedTop)
    let visibleBottom = min(float64(value.client.bottom - value.client.top), expectedBottom)
    if visibleBottom > visibleTop:
      checkValue(row.regionKind in [RegionSimple, RegionComplex], label & " visible row nonempty region")
      if row.regionKind in [RegionSimple, RegionComplex]:
        checkValue(near(float64(row.region.top), visibleTop - expectedTop) and
          near(float64(row.region.bottom), visibleBottom - expectedTop),
          label & " actual region vertical intersection index " & $position)
        checkValue(near(float64(row.region.left), 0.0) and
          near(float64(row.region.right), float64(value.client.right - value.client.left)),
          label & " actual region horizontal intersection")
    # Fully offscreen overscan roots can legally have NULLREGION.
  for position in 1 ..< value.rows.len:
    checkValue(value.rows[position].rect.top >= value.rows[position - 1].rect.bottom,
      label & " no overlap")

proc verifyStable(before, after: Sample, label: string) =
  checkValue(after.source == before.source, label & " source stable")
  checkValue(after.parentRenders == before.parentRenders, label & " parent render stable")
  checkValue(after.creates == before.creates, label & " no unrelated native create")
  checkValue(after.dpi == before.dpi and sameRect(after.client, before.client), label & " fixed client/DPI")
  checkValue(after.rows.len == before.rows.len, label & " rowset count stable")
  for index in 0 ..< min(after.rows.len, before.rows.len):
    checkValue(sameBinding(before.rows[index], after.rows[index]), label & " full typed binding/HWND stable")

proc main(): int =
  when not (defined(release) and defined(gcOrc) and defined(nimAllocStats)):
    echo "status=NotRun reason=requires-release-orc-alloc-stats close_complete=N.A.-no-host"
    return 2
  pageKeys = @[]
  for index in 0 ..< ItemCount: pageKeys.add($index)
  var rt: Runtime
  var h: Win32Host
  var win: Win32Backend
  var session: BackendSession
  var primary, secondary: ref CatchableError
  var phase = "create"
  var classification = "FAIL"
  var closeComplete = false
  try:
    let activity = newUiScopeActivity()
    rt = newRuntime(guardUiApplication(
      componentApplication(component(PageDef, 0), "variable-scroll", 480, 320),
      proc(): uint64 = uint64(GetCurrentThreadId()), activity))
    h = createHost("variable-scroll", DipSize(width: 480, height: 320))
    h.setStartupScope(proc(): bool = activity.busy or rt.installingUpdate or rt.installingHook)
    win = newWin32Backend(h)
    let realAccepted = win.asBackend.acceptedDelta
    if realAccepted == nil: blocked("missing actual acceptedDelta channel")
    win.asBackend.acceptedDelta = proc(delta: HostAcceptedDelta) {.raises: [].} =
      inc nativeAcceptCalls
      lastAcceptRevision = delta.revision
      realAccepted(delta)
    phase = "attach"
    let attachCalls = nativeAcceptCalls
    session = win.attachWin32Backend(rt)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    echo "attach native_calls=", nativeAcceptCalls - attachCalls,
      " revision=", rt.acceptedRevision,
      " allocation_fences=not_collected/no_allocation_claim"
    let port = viewportOf(h)
    let listHandle = listHandleOf(session)
    for turn in 1 .. 2:
      phase = "prime" & $turn
      let beforeCalls = nativeAcceptCalls
      win.safeListTurn()
      let actualCalls = nativeAcceptCalls - beforeCalls  # read before DTO/log allocation
      let value = sample(win, session, rt, port, listHandle, actualCalls)
      printSample(phase, value)
    phase = "prime-preconditions"
    let before = sample(win, session, rt, port, listHandle, 0)
    printSample("before", before)
    let primeFailures = failures
    verifyRows(before, port, false, "prime")
    checkValue(before.intent.valid and before.intent.desiredOffset == 0.0 and
      before.intent.appliedOffset == 0.0, "prime valid offset-zero intent")
    checkValue(before.frame.hasAccepted and before.frame.rowsetReady and
      before.frame.acceptedOffset == 0.0 and before.frame.acceptedSource == before.source,
      "prime accepted frame")
    checkValue(before.frame.acceptedFirst == 0 and before.frame.acceptedFinish == 4,
      "prime visible range 0..4")
    checkValue(before.source != 0 and before.parentRenders == 1, "prime one stable source construction")
    checkValue(before.bar.nMin == 0 and before.bar.nPos == 0 and before.bar.nPage > 0,
      "prime actual scrollbar usable")
    require(failures == primeFailures, "valid prime contract FAIL; scroll case stopped")

    phase = "message"
    let callsBeforeMessage = nativeAcceptCalls
    let wp = WPARAM(SB_LINEDOWN)
    let lp = LPARAM(0)
    setLastError(0)
    let messageReturn = SendMessageW(port, WM_VSCROLL, wp, lp)
    let messageError = lastError()
    let messageCalls = nativeAcceptCalls - callsBeforeMessage
    echo "message hwnd=", hwndValue(port), " msg=", WM_VSCROLL,
      " wparam=", wp, " lparam=", lp, " return=", messageReturn,
      " tls_observation=", messageError, " return_zero_is_legal=true"
    let immediate = sample(win, session, rt, port, listHandle, messageCalls)
    printSample("immediate", immediate)
    verifyStable(before, immediate, "immediate")
    checkValue(immediate.intent.valid and immediate.intent.desiredOffset == StepDip and
      immediate.intent.appliedOffset == 0.0 and
      immediate.intent.intentGeneration == before.intent.intentGeneration + 1,
      "actual message records one desired24/applied0 intent")
    checkValue(immediate.nativeCalls == 0 and immediate.revision == before.revision,
      "message does not dispatch/commit")
    checkValue(immediate.frame.acceptedOffset == before.frame.acceptedOffset and
      immediate.frame.acceptedFrameId == before.frame.acceptedFrameId and
      immediate.frame.acceptedToken == before.frame.acceptedToken,
      "message leaves accepted frame unchanged")
    for index in 0 ..< min(before.rows.len, immediate.rows.len):
      checkValue(sameRect(before.rows[index].rect, immediate.rows[index].rect),
        "message does not immediately move actual window rect")
      checkValue(before.rows[index].regionKind == immediate.rows[index].regionKind,
        "message leaves region kind unchanged")
      if before.rows[index].regionKind in [RegionSimple, RegionComplex] and
          immediate.rows[index].regionKind in [RegionSimple, RegionComplex]:
        checkValue(sameRect(before.rows[index].region, immediate.rows[index].region),
          "message leaves nonempty region bbox unchanged")
      # NULLREGION bbox has no necessary geometry meaning; do not compare it.
    checkValue(immediate.bar.nMin == before.bar.nMin and immediate.bar.nMax == before.bar.nMax and
      immediate.bar.nPage == before.bar.nPage and immediate.bar.nPos == before.bar.nPos,
      "message leaves actual bar unchanged")

    var final: Sample
    for turn in 1 .. 2:
      phase = "scroll" & $turn
      let callsBeforeTurn = nativeAcceptCalls
      let revisionBeforeTurn = rt.acceptedRevision
      win.safeListTurn()
      let actualCalls = nativeAcceptCalls - callsBeforeTurn
      let revisionAfterTurn = rt.acceptedRevision
      let publishDelta = int64(revisionAfterTurn) - int64(revisionBeforeTurn)
      final = sample(win, session, rt, port, listHandle, actualCalls)
      printSample(phase, final)
      echo phase, " revision_before=", revisionBeforeTurn,
        " revision_after=", revisionAfterTurn, " pubdelta=", publishDelta
      verifyStable(before, final, phase)
    phase = "final-oracle"
    verifyRows(final, port, true, "final")
    checkValue(final.intent.valid and final.intent.desiredOffset == StepDip and
      final.intent.appliedOffset == StepDip and
      final.intent.intentGeneration == immediate.intent.intentGeneration,
      "two scroll turns apply exactly offset24")
    checkValue(final.frame.hasAccepted and final.frame.acceptedOffset == StepDip and
      final.frame.acceptedFirst == 1 and final.frame.acceptedFinish == 4 and
      final.frame.acceptedSource == before.source and final.frame.rowsetReady,
      "accepted geometry offset24 range1..4")
    checkValue(final.frame.acceptedRows == before.frame.acceptedRows,
      "same measured active prefixes/heights/keys")
    # 20 rows are each <=48 DIP; even if initial overscan measured a sixth row,
    # total<=960 so MinScrollUnit32 dominates the projection. Actual range/page
    # must remain identical; do not hard-code nMax from the old overscan0 probe.
    let unit = 32.0
    let expectedPage = uint32(max(1.0, round(ViewportDip / unit)))
    let effectiveUnits = max(0'i64, int64(before.bar.nMax) -
      max(0'i64, int64(before.bar.nPage) - 1) - int64(before.bar.nMin))
    let expectedPos = int32(clamp(round(StepDip / unit), 0.0, float64(effectiveUnits)))
    echo "bar_oracle unit=", unit, " total_upper_bound=960 actual_effective_units=",
      effectiveUnits, " expected_page=", expectedPage, " expected_pos=", expectedPos
    checkValue(effectiveUnits > 0 and before.bar.nPage == expectedPage,
      "real before bar projection usable")
    checkValue(final.bar.nMin == before.bar.nMin and final.bar.nMax == before.bar.nMax and
      final.bar.nPage == before.bar.nPage and final.bar.nPos == expectedPos,
      "real bar range/page stable and position projected from24")
    # This gate requires pure geometry on the unchanged typed rowset. Revision
    # is checked independently of the actual per-operation callback counts.
    checkValue(final.revision == before.revision,
      "pure geometry leaves Runtime accepted revision unchanged")
    classification = if failures == 0: "PASS-coverage-addition" else: "FAIL-geometry"
  except ProbeBlocked as error:
    primary = error
    classification = "NotRun-invalid-sample"
  except ProbeFailed as error:
    primary = error
    classification = "FAIL-contract"
    inc failures
  except CatchableError as error:
    primary = error
    classification = "FAIL-exception"
    inc failures

  # Exactly one bounded host close on every created-host outcome, no pump/retry.
  # Runtime disposal only follows the host's complete native release.
  if h != nil:
    try: h.destroyHost()
    except CatchableError as error: secondary = error
    closeComplete = h.resourcesReleasedInternal()
    if closeComplete and rt != nil:
      try: rt.closeRuntime()
      except CatchableError as error:
        if secondary == nil: secondary = error
        else: echo "additional_runtime_cleanup type=", error.name, " msg=", error.msg
  else:
    echo "close_no_host=true"
    if rt != nil:
      try: rt.closeRuntime()
      except CatchableError as error: secondary = error
  if primary != nil:
    echo "actual_primary phase=", phase, " type=", primary.name, " msg=", primary.msg
  if secondary != nil:
    echo "actual_secondary type=", secondary.name, " msg=", secondary.msg
  echo "close_attempts=", (if h == nil: 0 else: 1), " close_complete=", closeComplete,
    " failures=", failures, " native_total=", nativeAcceptCalls,
    " parent_renders=", parentRenders
  if secondary != nil or (h != nil and not closeComplete):
    echo "status=FAIL-close original_status=", classification
    return 1
  echo "probe_win32_variable_scroll status=", classification
  if classification == "NotRun-invalid-sample": return 2
  if classification == "PASS-coverage-addition": return 0
  1

when isMainModule:
  quit(main())
