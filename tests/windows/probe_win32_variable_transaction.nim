## T2 variable-row transaction probe: same-source row-local height update (A)
## and a real placement failure with rollback (B). Product code is not modified
## here; the probe only uses the frozen read-only hooks (frame/plan DTO, scalar
## gate, real row window) plus a single-shot Win32Calls.windowPos injection and a
## pure-scalar GDI measurement counter on the existing calls seam.
##
## Scope: offset 0, fixed width/font/DPI, same source. Fences follow the accepted
## method: three sentinels -1 per window, the real acceptedDelta callback is still
## invoked and forwards, and the scalars are read before any diagnostics/formatting.
## A fence that was not executed stays -1 and is never reinterpreted as 0.
when not defined(windows):
  {.error: "Variable transaction probe requires Windows".}

import std/[tables, algorithm, strutils, options]
import leaf/[core, widgets, components, backend, backend_session, ui_thread,
  native_layout, native_host_adapter, managed_runtime, host_reconcile]
import leaf/component_description
import leaf/backends/win32/[api, host, backend, calls]
import ../fixture_app

const
  ItemCount = 20
  EstimatedHeight = 24.0
  ParkedBudget = 8
  ViewportDip = 120.0
  ExpectedTopsFirst = [0.0, 24.0, 72.0, 96.0]
  ExpectedHeightsFirst = [24.0, 48.0, 24.0, 48.0]
  TolerancePx = 1.0

proc GetWindowRgnBox(hwnd: HWND, box: ptr RECT): int32 {.
  importc: "GetWindowRgnBox", dynlib: "user32.dll", stdcall.}
const
  RegionNull = 1         ## empty region (nothing visible)
  RegionSimple = 2
  RegionComplex = 3

var
  rowZeroState: State[int]
  parentRenders = 0
  nativeAcceptCalls = 0
  lastAcceptRevision = 0'u64
  failures = 0
  missingDeltaChannel = false
  lastWindowError: ref CatchableError = nil
  # pure-scalar GDI measurement observation (injection -> recovery end)
  gdiCounting = false
  gdiMeasureCalls = 0

# single-shot placement injection (B)
var injectArmed = false
var probeWin: Win32Backend = nil
var probeList = NoHandle
var injectSeq = 0
var injectRowWindow: HWND = nil
var injected = false
var injectedWindow: HWND = nil
var injectedCallSeq = 0
var injectedAcceptedRow0, injectedPreparedRow0: float64
var injectedPreparedMeasured: int32
var injectedX, injectedY, injectedW, injectedH: int32
var injectedFlags: uint32
var injectedReturn: int32 = -1
var injectedErr: uint32

let RowDef = defineComponent[int, State[int]]("VariableTxnRow",
  proc(ctx: MountContext, index: int): State[int] =
    result = ctx.state(0)
    if index == 0: rowZeroState = result,
  proc(ctx: ComponentContext, index: int, state: State[int]): UiDescription =
    let bump = ctx.value(state) * 24
    let base = if (index mod 2) == 0: 24 else: 48
    host(row(@[text("row " & $index & " h" & $(base + int(bump)), key = "label")],
      key = "row", styles = style({"height": $(base + int(bump))}))))

var pageKeys: seq[string]

let PageDef = defineComponent[int, int]("VariableTxnPage",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, model: int): UiDescription =
    inc parentRenders
    componentList("list", pageKeys,
      proc(index: int): UiDescription = component(RowDef, index),
      rowHeight = 0.0, estimatedHeight = EstimatedHeight, overscan = 0,
      styles = style({"height": "120"})))

var enumerated: seq[HWND]
proc collect(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  discard data
  enumerated.add(window)
  BOOL(1)

proc descendants(parent: HWND): seq[HWND] =
  enumerated.setLen(0)
  discard EnumChildWindows(parent, collect, 0)
  enumerated

proc styleOf(window: HWND): uint32 = uint32(GetWindowLongW(window, GWL_STYLE))

proc viewportOf(h: Win32Host): HWND =
  for window in descendants(h.windowHandle):
    if (styleOf(window) and WS_VSCROLL) != 0: return window

proc checkValue(condition: bool, label: string) =
  if not condition:
    echo "check_failed ", label
    inc failures

type Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession,
                     rt: Runtime]

proc countGdi() {.raises: [].} =
  ## Pure scalar observation on the existing calls seam: no allocation, no log
  ## buffer, no work inside an exception/unwind chain.
  if gdiCounting: inc gdiMeasureCalls

proc wrapCalls(calls: Win32Calls): Win32Calls =
  ## Transparent except for one injected failure at the candidate placement of the
  ## known row window and a count of real GDI measurement calls; every other call
  ## and every original return/TLS is forwarded unchanged.
  result = calls
  let windowPos = calls.windowPos
  let getDC = calls.getDC
  let releaseDC = calls.releaseDC
  let selectObject = calls.selectObject
  let textExtent = calls.textExtent
  let drawText = calls.drawText
  let textMetrics = calls.textMetrics
  let createFont = calls.createFont
  let themePartSize = calls.themePartSize
  let themeMargins = calls.themeMargins
  let systemMetric = calls.systemMetric
  let adjustRect = calls.adjustRect
  result.getDC = proc(window: HWND): HDC {.closure, raises: [CatchableError].} =
    countGdi()
    getDC(window)
  result.releaseDC = proc(window: HWND, dc: HDC): int32 {.closure, raises: [CatchableError].} =
    countGdi()
    releaseDC(window, dc)
  result.selectObject = proc(dc: HDC, obj: HGDIOBJ): HGDIOBJ {.closure, raises: [CatchableError].} =
    countGdi()
    selectObject(dc, obj)
  result.textExtent = proc(dc: HDC, text: WidePtr, count: int32,
      size: ptr SIZE): BOOL {.closure, raises: [CatchableError].} =
    countGdi()
    textExtent(dc, text, count, size)
  result.drawText = proc(dc: HDC, text: WidePtr, count: int32, rect: ptr RECT,
      flags: UINT): int32 {.closure, raises: [CatchableError].} =
    countGdi()
    drawText(dc, text, count, rect, flags)
  result.textMetrics = proc(dc: HDC, metric: ptr TEXTMETRICW): BOOL {.closure, raises: [CatchableError].} =
    countGdi()
    textMetrics(dc, metric)
  result.createFont = proc(font: ptr LOGFONTW): HFONT {.closure, raises: [CatchableError].} =
    countGdi()
    createFont(font)
  result.themePartSize = proc(theme: HTHEME, dc: HDC, part, state: int32,
      rect: ptr RECT, mode: int32, size: ptr SIZE): int32 {.closure, raises: [CatchableError].} =
    countGdi()
    themePartSize(theme, dc, part, state, rect, mode, size)
  result.themeMargins = proc(theme: HTHEME, dc: HDC, part, state, property: int32,
      rect: ptr RECT, margins: ptr MARGINS): int32 {.closure, raises: [CatchableError].} =
    countGdi()
    themeMargins(theme, dc, part, state, property, rect, margins)
  result.systemMetric = proc(index: int32, dpi: UINT): int32 {.closure, raises: [CatchableError].} =
    countGdi()
    systemMetric(index, dpi)
  result.adjustRect = proc(rect: ptr RECT, style: DWORD, menu: BOOL, exStyle: DWORD,
      dpi: UINT): BOOL {.closure, raises: [CatchableError].} =
    countGdi()
    adjustRect(rect, style, menu, exStyle, dpi)
  result.windowPos = proc(window, after: HWND, x, y, width, height: int32,
      flags: UINT): BOOL {.closure, raises: [CatchableError].} =
    inc injectSeq
    var gate = false
    var gateAcceptedRow0 = 0.0
    var gatePreparedRow0 = 0.0
    var gateMeasured = 0'i32
    if injectArmed and not injected and window != nil and
        window == injectRowWindow and (flags and 0x0001'u32) == 0'u32 and
        probeWin != nil and probeList != NoHandle:
      # Allocation-free scalar observation: only inject while the *prepared*
      # candidate for this list was already measured with row0 = 48 while the
      # accepted frame still has row0 = 24, i.e. during candidate placement.
      let scalars = probeWin.frameScalarsForTest(probeList)
      gateAcceptedRow0 = scalars.acceptedRow0
      gatePreparedRow0 = scalars.preparedRow0
      gateMeasured = scalars.preparedMeasured
      gate = scalars.acceptedValid and scalars.preparedValid and
        scalars.preparedMeasured > 0 and
        abs(scalars.preparedRow0 - 48.0) <= 0.001 and
        abs(scalars.acceptedRow0 - 24.0) <= 0.001
    if gate:
      injected = true
      gdiCounting = true           # observation window: injection -> recovery end
      injectedWindow = window
      injectedX = x
      injectedY = y
      injectedW = width
      injectedH = height
      injectedFlags = uint32(flags)
      injectedCallSeq = injectSeq
      injectedAcceptedRow0 = gateAcceptedRow0
      injectedPreparedRow0 = gatePreparedRow0
      injectedPreparedMeasured = gateMeasured
      injectedReturn = 0
      injectedErr = 1234'u32
      setLastError(injectedErr)
      return BOOL(0)
    windowPos(window, after, x, y, width, height, flags)

var
  lastCaughtError: ref CatchableError = nil
  winManaged = -1
  winHost = -1
  winNative = -1
  winCalls = 0
  winPublishes = 0

template window(rt: Runtime, label: string, body: untyped) =
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
      phaseError = error
    winManaged = managedPublishAllocations
    winHost = hostPublishAllocations
    winNative = nativeAcceptAllocations
    winCalls = nativeAcceptCalls - callsBefore
    winPublishes = int(rt.acceptedRevision - publishBefore)
    echo label, " native_calls=", winCalls, " publishes=", winPublishes,
      " managed=", winManaged, " host=", winHost, " native=", winNative,
      " revision=", rt.acceptedRevision
    if phaseError != nil:
      echo label, " error=", phaseError.msg
      inc failures
    lastWindowError = phaseError

template windowExpectedError(rt: Runtime, label: string, body: untyped) =
  ## Window whose single expected failure is the observation itself: the real ref
  ## is kept and the counters are read first, but the expected error is not counted
  ## as a probe failure (a missing error still fails).
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
      phaseError = error
    winManaged = managedPublishAllocations
    winHost = hostPublishAllocations
    winNative = nativeAcceptAllocations
    winCalls = nativeAcceptCalls - callsBefore
    winPublishes = int(rt.acceptedRevision - publishBefore)
    echo label, " expected_error=", (phaseError != nil), " native_calls=",
      winCalls, " publishes=", winPublishes, " managed=", winManaged, " host=",
      winHost, " native=", winNative, " revision=", rt.acceptedRevision
    if phaseError == nil:
      checkValue(false, label & " expected a raised error")
    else:
      echo label, " error type=", phaseError.name, " msg=", phaseError.msg
    lastCaughtError = phaseError

type RowFact = object
  found: bool
  index: int
  key: string
  root, window: uint64
  parent: uint64
  top, height: float64
  rectOk, mapRet: int32
  rectErr, mapErr: uint32
  sampled: bool
  rgnReturn: int32
  rgnLeft, rgnTop, rgnRight, rgnBottom: int32

proc rowFacts(win: Win32Backend, session: BackendSession, port: HWND,
              scale: float64): seq[RowFact] =
  let entities = session.acceptedEntities()
  var listHandle = NoHandle
  for entity in entities.values:
    if entity.kind == NodeKind.virtualList: listHandle = entity.handle
  if listHandle == NoHandle: return
  for entity in entities.values:
    if entity.row.isNone: continue
    let binding = entity.row.get
    if binding.listHandle != listHandle: continue
    var fact = RowFact(found: true, index: binding.itemIndex, key: binding.itemKey,
      root: uint64(entity.handle))
    let window = win.rowWindowForTest(entity.handle)
    fact.window = uint64(cast[uint](window))
    if window != nil:
      fact.parent = uint64(cast[uint](GetParent(window)))
      var rect: RECT
      setLastError(0)
      fact.rectOk = int32(GetWindowRect(window, addr rect))
      fact.rectErr = lastError()
      var mapped = false
      var corners = [POINT(), POINT()]
      if fact.rectOk != 0:
        corners = [POINT(x: rect.left, y: rect.top),
          POINT(x: rect.right, y: rect.bottom)]
        setLastError(0)
        fact.mapRet = int32(MapWindowPoints(nil, port, addr corners[0], 2))
        fact.mapErr = lastError()
        mapped = fact.mapRet != 0 or fact.mapErr == 0'u32
      if fact.rectOk != 0 and mapped:
        fact.sampled = true
        fact.top = float64(corners[0].y) / scale
        fact.height = float64(corners[1].y - corners[0].y) / scale
      var box: RECT
      fact.rgnReturn = GetWindowRgnBox(window, addr box)
      fact.rgnLeft = box.left
      fact.rgnTop = box.top
      fact.rgnRight = box.right
      fact.rgnBottom = box.bottom
    result.add(fact)
  result.sort(proc(a, b: RowFact): int = cmp(a.index, b.index))

proc describe(rows: seq[RowFact]): string =
  for row in rows:
    result.add("[" & $row.index & " key=" & row.key & " root=" & $row.root &
      " hwnd=" & $row.window & " parent=" & $row.parent & " top=" & $row.top &
      " h=" & $row.height & " rect_ok=" & $row.rectOk & " rect_err=" &
      $row.rectErr & " map_ret=" & $row.mapRet & " map_err=" & $row.mapErr &
      " sampled=" & $row.sampled & " rgn=" & $row.rgnReturn & " box=" &
      $row.rgnLeft & "," & $row.rgnTop & "," & $row.rgnRight & "," &
      $row.rgnBottom & "]")

proc describeFacts(facts: ListFrameFacts): string =
  result.add("accepted=" & $facts.hasAccepted & " src=" & $facts.acceptedSource &
    " offset=" & $facts.acceptedOffset & " range=" & $facts.acceptedFirst &
    ".." & $facts.acceptedFinish & " measured=" & $facts.acceptedMeasured &
    " frame=" & $facts.acceptedFrameId & " token=" & $facts.acceptedToken &
    " ready=" & $facts.rowsetReady & " rows_pending=" & $facts.rowsPending &
    " trim_pending=" & $facts.trimPending & " needed=" & $facts.neededFirst &
    ".." & $facts.neededFinish & " rows=")
  for row in facts.acceptedRows:
    result.add("(" & $row.index & "," & row.key & ",h" & $row.height &
      ",p" & $row.prefix & ")")
  if facts.hasPrepared:
    result.add(" prepared_frame=" & $facts.preparedFrameId & " token=" &
      $facts.preparedToken & " prepared_measured=" & $facts.preparedMeasured)
  if facts.hasFailed:
    result.add(" failed_frame=" & $facts.failedFrameId & " phase=" &
      facts.failedPhase & " heights=")
    for height in facts.failedHeights:
      result.add("(" & $height.index & ",h" & $height.height & ")")

type BarFact = object
  ret: int32
  err: uint32
  low, high, page, pos: int32

proc barFor(window: HWND): BarFact =
  ## Real readback through the existing Win32Calls.scrollInfo seam (no GDI object
  ## is created). `ret` 0 stays an honest readback result, not a failure by itself.
  var info = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)),
    fMask: SIF_RANGE or SIF_PAGE or SIF_POS)
  let calls = systemWin32Calls()
  setLastError(0)
  result.ret = int32(calls.scrollInfo(window, SB_VERT, addr info))
  result.err = lastError()
  result.low = info.nMin
  result.high = info.nMax
  result.page = int32(info.nPage)
  result.pos = info.nPos

proc describeBar(bar: BarFact): string =
  "ret=" & $bar.ret & " err=" & $bar.err & " range=" & $bar.low & ".." &
    $bar.high & " page=" & $bar.page & " pos=" & $bar.pos

proc rowsSampled(rows: seq[RowFact], label: string): string =
  ## Empty means usable. A method/query failure is NotRun for this case, never a
  ## product verdict.
  for row in rows:
    if row.window == 0'u64: return label & " row " & $row.index & " has no window"
    if not row.sampled:
      return label & " rect query failed row " & $row.index & " rect_ok=" &
        $row.rectOk & " rect_err=" & $row.rectErr & " map_ret=" & $row.mapRet &
        " map_err=" & $row.mapErr
  ""

proc closeHost(h: Win32Host, label: string): bool =
  ## The one bounded close per case: a failure is recorded, never re-raised.
  result = true
  try: h.destroyHost()
  except CatchableError as error:
    echo label, " close error type=", error.name, " msg=", error.msg
    checkValue(false, label & " close raised")
    result = false

proc openFixture(calls: Win32Calls, label: string): Fixture =
  let activity = newUiScopeActivity()
  let rt = newRuntime(guardUiApplication(
    componentApplication(component(PageDef, 0), "variable-txn", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("variable-txn", DipSize(width: 480, height: 320))
  h.setStartupScope(proc(): bool =
    activity.busy or rt.installingUpdate or rt.installingHook)
  let win = newWin32Backend(h, calls)
  let realAccepted = win.asBackend.acceptedDelta
  if realAccepted == nil:
    # NotRun before any accept is counted: no fake callback, no attach.
    missingDeltaChannel = true
    return (h, win, nil, rt)
  win.asBackend.acceptedDelta = proc(delta: HostAcceptedDelta) {.raises: [].} =
    inc nativeAcceptCalls
    lastAcceptRevision = delta.revision
    realAccepted(delta)
  var session: BackendSession = nil
  window(rt, label & " attach"):
    session = win.attachWin32Backend(rt)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
  # attach: the install confirm accepts natively exactly once without a Runtime
  # publication; the managed/host fences do not run on that path (-1 = not run).
  checkValue(winCalls == 1, label & " attach native accept 1")
  checkValue(winPublishes == 0, label & " attach publishes 0")
  checkValue(winNative == 0, label & " attach native accept alloc 0")
  checkValue(winManaged == -1 and winHost == -1,
    label & " attach managed/host not executed")
  if lastWindowError != nil: return (h, win, nil, rt)
  (h, win, session, rt)

var
  casePhase = "setup"
  activeHost: Win32Host = nil

proc runCases(): int

proc main(): int =
  when not (defined(release) and defined(gcOrc) and defined(nimAllocStats)):
    echo "probe_win32_variable_transaction status=requires-release-orc-alloc-stats"
    return 2
  var primary: ref CatchableError = nil
  try:
    return runCases()
  except CatchableError as error:
    primary = error
  var secondary: ref CatchableError = nil
  if activeHost != nil:
    try: activeHost.destroyHost()
    except CatchableError as error: secondary = error
  echo "primary error phase=", casePhase, " type=", primary.name, " msg=",
    primary.msg
  if secondary != nil:
    echo "close secondary type=", secondary.name, " msg=", secondary.msg
  echo "probe_win32_variable_transaction status=diagnostic_incomplete reason=raised"
  3

proc runCases(): int =
  pageKeys = @[]
  for index in 0 ..< ItemCount: pageKeys.add($index)
  let baseCalls = wrapCalls(systemWin32Calls())

  # ---- case A: same-source row-local height update, success path ----
  casePhase = "caseA"
  var f = openFixture(baseCalls, "A")
  activeHost = f.h
  if f.s == nil:
    discard closeHost(f.h, "A")
    if missingDeltaChannel:
      echo "probe_win32_variable_transaction status=not_run reason=no_accepted_delta_channel"
      return 2
    echo "probe_win32_variable_transaction status=variable_transaction_red failures=",
      failures
    return 1
  probeWin = f.win
  var port = viewportOf(f.h)
  if port == nil:
    echo "probe_win32_variable_transaction status=not_run reason=no_viewport"
    discard closeHost(f.h, "A")
    return 2
  var dpi = GetDpiForWindow(port)
  if dpi == 0:
    echo "probe_win32_variable_transaction status=not_run reason=no_viewport_dpi"
    discard closeHost(f.h, "A")
    return 2
  var scale = float64(dpi) / 96.0
  # Turn 1 materializes the estimated range, turn 2 trims it to the measured one.
  window(f.rt, "A turn1_materialize"):
    f.win.safeListTurn()
  checkValue(winCalls == 1 and winPublishes == 1, "A turn1 one accept/publish")
  checkValue(winManaged == 0 and winHost == 0 and winNative == 0,
    "A turn1 fences zero")
  window(f.rt, "A turn2_trim"):
    f.win.safeListTurn()
  checkValue(winCalls == 1 and winPublishes == 1, "A turn2 one accept/publish")
  checkValue(winManaged == 0 and winHost == 0 and winNative == 0,
    "A turn2 fences zero")
  let listHandle = f.s.handleFor(f.rt.find("list").id)
  probeList = listHandle
  let sourceBefore = f.rt.find("list").node.listSource.generation
  var facts = f.win.listFrameForTest(listHandle)
  echo "A initial frame ", facts.describeFacts
  echo "A initial rows ", rowFacts(f.win, f.s, port, scale).describe
  checkValue(facts.hasAccepted, "A accepted frame")
  checkValue(facts.rowsetReady, "A accepted rowset ready")
  checkValue(facts.acceptedSource == sourceBefore, "A source")
  checkValue(facts.acceptedOffset == 0.0, "A offset 0")
  checkValue(facts.acceptedRows.len == 4, "A four accepted rows")
  for position, row in facts.acceptedRows:
    if position < 4:
      checkValue(row.index == position, "A row index " & $position)
      checkValue(abs(row.height - ExpectedHeightsFirst[position]) <= 0.001,
        "A row height " & $position)
      checkValue(abs(row.prefix - ExpectedTopsFirst[position]) <= 0.001,
        "A row prefix " & $position)
  var initialRows = rowFacts(f.win, f.s, port, scale)
  checkValue(initialRows.len == 4, "A four real initial rows")
  var methodBlocked = if initialRows.len == 4: ""
                     else: "A initial typed rowset count " & $initialRows.len
  if methodBlocked.len == 0: methodBlocked = rowsSampled(initialRows, "A initial")
  if methodBlocked.len == 0:
    for position, row in initialRows:
      checkValue(abs(row.top - ExpectedTopsFirst[position]) <= TolerancePx,
        "A real row top " & $position)
      checkValue(abs(row.height - ExpectedHeightsFirst[position]) <= TolerancePx,
        "A real row height " & $position)
  var initialRoots: seq[uint64]
  for row in initialRows: initialRoots.add(row.root)
  if methodBlocked.len != 0:
    # A method failure is NotRun for this case: never continue from a wrong start.
    echo "probe_win32_variable_transaction status=not_run reason=", methodBlocked
    discard closeHost(f.h, "A")
    return 2

  let rendersBefore = parentRenders
  let write = rowZeroState.set(1)                 # row 0 root height 24 -> 48
  checkValue(write == StateWriteResult.queued, "A state write queued")
  window(f.rt, "A row_hot_update"):
    discard f.rt.flush()
  checkValue(winCalls == 1 and winPublishes == 1, "A single accept/publish")
  checkValue(winManaged == 0 and winHost == 0 and winNative == 0,
    "A fences zero")
  # The measured candidate exposes fewer rows than the accepted rowset, so the
  # trim fact is still pending: turn 1 must execute it, turn 2 must be empty.
  window(f.rt, "A trim_turn1"):
    f.win.safeListTurn()
  checkValue(winCalls == 1 and winPublishes == 1, "A trim turn1 accept/publish")
  checkValue(winManaged == 0 and winHost == 0 and winNative == 0,
    "A trim turn1 fences zero")
  window(f.rt, "A trim_turn2_empty"):
    f.win.safeListTurn()
  checkValue(winCalls == 0 and winPublishes == 0, "A trim turn2 no accept")
  checkValue(winManaged == -1 and winHost == -1 and winNative == -1,
    "A trim turn2 fences not executed")
  facts = f.win.listFrameForTest(listHandle)
  let updatedRows = rowFacts(f.win, f.s, port, scale)
  echo "A updated frame ", facts.describeFacts, " rows ", updatedRows.describe
  checkValue(facts.hasAccepted, "A accepted frame after update")
  checkValue(facts.rowsetReady, "A updated rowset ready")
  checkValue(facts.acceptedSource == sourceBefore, "A same source after update")
  checkValue(facts.acceptedOffset == 0.0, "A offset still 0")
  checkValue(parentRenders == rendersBefore, "A parent did not re-render")
  checkValue(facts.acceptedRows.len == 3, "A three accepted rows after update")
  for position, row in facts.acceptedRows:
    if position < 3:
      checkValue(row.index == position, "A updated index " & $position)
      let wanted = if position == 0: 48.0 else: ExpectedHeightsFirst[position]
      checkValue(abs(row.height - wanted) <= 0.001, "A updated height " & $position)
  checkValue(updatedRows.len == 3, "A real rowset trimmed to 3")
  if methodBlocked.len == 0:
    methodBlocked = rowsSampled(updatedRows, "A updated")
  if methodBlocked.len == 0:
    for position, row in updatedRows:
      if position < 3:
        # row 0 grew by 24 DIP, so every following row shifts down by 24 DIP.
        let wantedTop = if position == 0: 0.0
                       else: ExpectedTopsFirst[position] + 24.0
        checkValue(abs(row.top - wantedTop) <= TolerancePx,
          "A updated real top " & $position)
        let wantedHeight = if position == 0: 48.0
                           else: ExpectedHeightsFirst[position]
        checkValue(abs(row.height - wantedHeight) <= TolerancePx,
          "A updated real height " & $position)
  # other rows keep their typed binding roots (no unrelated replacement)
  for position in 1 ..< min(min(updatedRows.len, 3), initialRoots.len):
    checkValue(updatedRows[position].root == initialRoots[position],
      "A other row " & $position & " binding unchanged")
  checkValue(f.win.diagnostics.liveRows == 3, "A live rows 3")
  discard closeHost(f.h, "A")
  checkValue(f.h.resourcesReleasedInternal(), "A close complete")
  activeHost = nil

  # ---- case B: accepted frame first, then a placement failure and rollback ----
  injectArmed = false
  injected = false
  gdiCounting = false
  gdiMeasureCalls = 0
  casePhase = "caseB"
  var fb = openFixture(baseCalls, "B")
  activeHost = fb.h
  if fb.s == nil:
    discard closeHost(fb.h, "B")
    if missingDeltaChannel:
      echo "probe_win32_variable_transaction status=not_run reason=no_accepted_delta_channel_b"
      return 2
    echo "probe_win32_variable_transaction status=variable_transaction_red failures=",
      failures
    return 1
  probeWin = fb.win
  port = viewportOf(fb.h)
  if port == nil:
    echo "probe_win32_variable_transaction status=not_run reason=no_viewport_b"
    discard closeHost(fb.h, "B")
    return 2
  dpi = GetDpiForWindow(port)
  if dpi == 0:
    echo "probe_win32_variable_transaction status=not_run reason=no_viewport_dpi_b"
    discard closeHost(fb.h, "B")
    return 2
  scale = float64(dpi) / 96.0
  window(fb.rt, "B turn1_materialize"):
    fb.win.safeListTurn()
  checkValue(winCalls == 1 and winPublishes == 1, "B turn1 one accept/publish")
  checkValue(winManaged == 0 and winHost == 0 and winNative == 0,
    "B turn1 fences zero")
  window(fb.rt, "B turn2_trim"):
    fb.win.safeListTurn()
  checkValue(winCalls == 1 and winPublishes == 1, "B turn2 one accept/publish")
  checkValue(winManaged == 0 and winHost == 0 and winNative == 0,
    "B turn2 fences zero")
  let listB = fb.s.handleFor(fb.rt.find("list").id)
  probeList = listB
  let sourceB = fb.rt.find("list").node.listSource.generation
  let beforeB = fb.win.listFrameForTest(listB)
  echo "B initial frame ", beforeB.describeFacts
  checkValue(beforeB.hasAccepted and beforeB.acceptedRows.len == 4,
    "B initial accepted four rows")
  checkValue(beforeB.rowsetReady, "B initial rowset ready")
  checkValue(not beforeB.hasPrepared, "B no prepared candidate before the write")
  let rowsBefore = rowFacts(fb.win, fb.s, port, scale)
  echo "B initial rows ", rowsBefore.describe
  checkValue(rowsBefore.len == 4, "B four real initial rows")
  let barBefore = barFor(port)
  echo "B initial bar ", barBefore.describeBar
  var bBlocked = rowsSampled(rowsBefore, "B initial")
  if rowsBefore.len != 4 and bBlocked.len == 0:
    bBlocked = "B initial typed rowset count " & $rowsBefore.len
  # A failed scrollbar readback is a method failure, never a 0 default.
  if barBefore.ret == 0 and bBlocked.len == 0:
    bBlocked = "B initial scrollbar readback failed err=" & $barBefore.err
  var rootsBefore: seq[uint64]
  var rowZeroWindow: HWND = nil
  for row in rowsBefore:
    rootsBefore.add(row.root)
    if row.index == 0: rowZeroWindow = cast[HWND](row.window)
  if rowZeroWindow == nil and bBlocked.len == 0: bBlocked = "B row0 window unknown"
  if bBlocked.len != 0:
    # A wrong starting point can never prove a recovery: stop before injecting.
    echo "probe_win32_variable_transaction status=not_run reason=", bBlocked
    discard closeHost(fb.h, "B")
    return 2
  let revisionBefore = fb.rt.acceptedRevision
  let stateBefore = rowZeroState.read()

  injectRowWindow = rowZeroWindow
  injectArmed = true
  let writeB = rowZeroState.set(1)
  checkValue(writeB == StateWriteResult.queued, "B state write queued")
  windowExpectedError(fb.rt, "B placement_failure"):
    discard fb.rt.flush()
  let caught = lastCaughtError
  injectArmed = false
  gdiCounting = false
  let gdiObserved = gdiMeasureCalls
  echo "B injection injected=", injected, " window=",
    $uint64(cast[uint](injectedWindow)), " x=", injectedX, " y=", injectedY,
    " w=", injectedW, " h=", injectedH, " flags=", injectedFlags,
    " ret=", injectedReturn, " err=", injectedErr, " call_seq=", injectedCallSeq,
    " window_pos_calls=", injectSeq
  checkValue(injected, "B injection happened")
  checkValue(injectedReturn == 0 and injectedErr == 1234'u32,
    "B injected original BOOL/error kept")
  checkValue(caught != nil, "B commit raised the captured error")
  checkValue(winCalls == 0, "B failed window never accepted natively")
  checkValue(winPublishes == 0, "B no publish on the failed candidate")
  checkValue(winManaged == -1 and winHost == -1 and winNative == -1,
    "B failed window fences not executed")
  if caught != nil:
    checkValue(caught.name == "UiError", "B raised type is UiError")
    checkValue("SetWindowPos row subtree" in caught.msg,
      "B primary is the injected placement failure")
    checkValue("1234" in caught.msg, "B primary keeps the original error")
    checkValue("restore failed" notin caught.msg,
      "B recovery did not fault (no secondary restore failure)")
    checkValue("accepted-plan replay failed" notin caught.msg,
      "B replay itself succeeded")
  checkValue(fb.rt.acceptedRevision == revisionBefore, "B revision unchanged")
  checkValue(rowZeroState.read() == stateBefore, "B accepted state unchanged")
  let afterB = fb.win.listFrameForTest(listB)
  echo "B recovered frame ", afterB.describeFacts
  checkValue(afterB.hasAccepted, "B accepted frame survives")
  checkValue(afterB.acceptedToken == beforeB.acceptedToken,
    "B replayed the very accepted plan (token)")
  checkValue(afterB.acceptedSource == sourceB, "B same source after recovery")
  checkValue(afterB.acceptedOffset == 0.0, "B offset preserved")
  checkValue(afterB.acceptedRows.len == 4, "B accepted rowset preserved")
  checkValue(not afterB.hasPrepared, "B no prepared candidate leaked")
  for position, row in afterB.acceptedRows:
    if position < 4:
      checkValue(row.index == position, "B recovered index " & $position)
      checkValue(abs(row.height - ExpectedHeightsFirst[position]) <= 0.001,
        "B recovered height " & $position & " (failed candidate never leaks)")
      checkValue(abs(row.prefix - ExpectedTopsFirst[position]) <= 0.001,
        "B recovered prefix " & $position)
  checkValue(afterB.hasFailed, "B failed candidate recorded")
  checkValue(afterB.failedPhase == "placement", "B failure phase " &
    afterB.failedPhase)
  if afterB.hasFailed:
    var failedRowZero = -1.0
    for height in afterB.failedHeights:
      if height.index == 0: failedRowZero = height.height
    echo "B failed candidate row0 height=", failedRowZero
    checkValue(abs(failedRowZero - 48.0) <= 0.001,
      "B failure happened after measuring the candidate")
  # Recovery re-reads the *current* typed rowset, the current viewport HWND, DPI
  # and client size: the old viewport was destroyed by the teardown.
  let portAfter = viewportOf(fb.h)
  checkValue(portAfter != nil, "B current viewport after recovery")
  var scaleAfter = scale
  var clientPxAfter = 0'i32
  if portAfter != nil:
    let dpiAfter = GetDpiForWindow(portAfter)
    checkValue(dpiAfter > 0, "B current viewport dpi")
    var client: RECT
    if GetClientRect(portAfter, addr client) != 0:
      clientPxAfter = client.bottom - client.top
    if dpiAfter > 0:
      scaleAfter = float64(dpiAfter) / 96.0
    echo "B recovered viewport hwnd=", $uint64(cast[uint](portAfter)), " dpi=",
      dpiAfter, " client_px=", clientPxAfter, " scale=", scaleAfter
  let rowsAfter = rowFacts(fb.win, fb.s, portAfter, scaleAfter)
  echo "B recovered rows ", rowsAfter.describe
  checkValue(rowsAfter.len == 4, "B typed rowset preserved")
  for position in 0 ..< min(rowsAfter.len, rootsBefore.len):
    checkValue(rowsAfter[position].root == rootsBefore[position],
      "B typed binding root preserved " & $position)
  var afterBlocked = rowsSampled(rowsAfter, "B recovered")
  if afterBlocked.len == 0:
    for position, row in rowsAfter:
      if position < 4:
        checkValue(row.parent == uint64(cast[uint](portAfter)),
          "B recovered row parent is the current viewport " & $position)
        checkValue(abs(row.top - ExpectedTopsFirst[position]) <= TolerancePx,
          "B recovered real top " & $position)
        checkValue(abs(row.height - ExpectedHeightsFirst[position]) <= TolerancePx,
          "B recovered real height " & $position)
        if position == 3:
          # Fourth row is partially visible: the real clip must cut it at 24 DIP.
          let hasRegion = row.rgnReturn == RegionSimple or
            row.rgnReturn == RegionComplex
          checkValue(hasRegion, "B recovered fourth row clip region present rgn=" &
            $row.rgnReturn)
          if hasRegion:
            # The region box is window-local: the real clip cuts the 48-DIP row at
            # the remaining 24 DIP of the 120-DIP viewport.
            let clipDips = float64(row.rgnBottom - row.rgnTop) / scaleAfter
            checkValue(abs(clipDips - 24.0) <= TolerancePx,
              "B recovered fourth row clip height " & $clipDips & " DIP")
          checkValue(row.rgnReturn != RegionNull,
            "B recovered fourth row is not clipped away")
  let barAfter = barFor(portAfter)
  echo "B recovered bar ", barAfter.describeBar, " (before ",
    barBefore.describeBar, ")"
  if barAfter.ret == 0 and afterBlocked.len == 0:
    afterBlocked = "B recovered scrollbar readback failed err=" & $barAfter.err
  checkValue(barAfter.low == barBefore.low and barAfter.high == barBefore.high and
    barAfter.page == barBefore.page and barAfter.pos == barBefore.pos,
    "B scrollbar range/page/pos replayed")
  checkValue(fb.win.diagnostics.liveRows == 4, "B live rows 4")
  checkValue(fb.win.diagnostics.parkedRows <= ParkedBudget, "B parked budget")
  let receipts = fb.win.restoreReceiptsForTest()
  echo "B restore receipts replayed=", receipts.replayed, " applied=",
    receipts.applied, " measured=", receipts.measured, " cache_hits=",
    receipts.cacheHits, " gdi_measure_calls=", gdiObserved
  checkValue(receipts.replayed == 1, "B recovery selected the pinned plan once")
  checkValue(receipts.applied == 1, "B recovery applied one whole plan")
  checkValue(receipts.measured == 0, "B recovery re-measured no row")
  checkValue(gdiObserved == 0, "B recovery made no real GDI measurement call")
  discard closeHost(fb.h, "B")
  checkValue(fb.h.resourcesReleasedInternal(), "B close complete")
  activeHost = nil
  if afterBlocked.len != 0:
    echo "probe_win32_variable_transaction status=not_run reason=", afterBlocked
    return 2

  if failures == 0:
    echo "probe_win32_variable_transaction status=variable_transaction_passed"
    return 0
  echo "probe_win32_variable_transaction status=variable_transaction_red failures=",
    failures
  1

when isMainModule:
  quit(main())
