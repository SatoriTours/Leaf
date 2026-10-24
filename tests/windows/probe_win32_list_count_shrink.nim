## Probe-only input: a nonempty list source shrinks twice.
## A: 20 keys, every real row 48 DIP (estimate still 24); SB_BOTTOM reaches a
## far offset. B: 10 new keys, every real row 24 DIP, so total240 and the old
## offset exceeds the new reach120 -> the applied offset must clamp to exactly
## 120 with a fresh rowset. C: 3 new keys, still nonempty, total72 < viewport120
## -> offset must clamp to 0 with a live three-row nonempty rowset.
## This is NOT probe_win32_variable_shrink (one row 48->6) and NOT
## probe_win32_variable_source (same count20 reorder/empty/refill/placement).
## All expectations are hand-computed from the frozen fixture; the product
## HeightIndex, listFrameForTest offsets and listIntentForTest values are read
## only as the actual side of a comparison, never as the expected side.
## Optional coverage addition: `probe_win32_list_count_shrink failure` replays the
## same fixture with one injected business-commit failure (A20 -> B10), where the
## real SB_VERT projection is receipted before GetClientRect is refused once.
## A compile is not a Native RED: only a real run can accept or reject this.
when not defined(windows) or not defined(leafProtocolProbes):
  {.error: "Requires real Windows and leafProtocolProbes".}

import std/[tables, options, math, algorithm, strutils, os]
import leaf/[core, widgets, components, backend, backend_session, ui_thread,
  native_layout]
import leaf/component_description
import leaf/backends/win32/[api, calls, host, backend]

const
  ViewportDip = 120.0
  RowDip = 24.0
  TallDip = 48.0
  WidthDip = 300.0
  EstimateDip = 24.0
  OverscanRows = 0
  ReachB = 10.0 * RowDip - ViewportDip       # 120
  TotalC = 3.0 * RowDip                      # 72, below the viewport
  # Frozen scrollbar unit, then the phase-B projection derived from the frozen
  # geometry only: unit 32 -> units ceil(120/32)=4, page round(120/32)=4,
  # nMax units+max(0,page-1)=7, nPos round(120/32)=4.
  BarUnit = 32.0
  BarUnitsB = int(ceil(ReachB / BarUnit))
  BarPageB = uint32(int(round(ViewportDip / BarUnit)))
  BarMaxB = int32(BarUnitsB + max(0, int(BarPageB) - 1))
  BarPosB = int32(round(ReachB / BarUnit))

type
  ProbeBlocked = object of CatchableError
  ProbeFailed = object of CatchableError
  RowProps = tuple[index, phase: int, key: string]
  RowFact = object
    index: int
    key: string
    source: uint64
    window, parent: HWND
    rect: RECT                 # viewport-local actual edges in device px
    visible: bool

var
  pageState: State[int]
  failures = 0

proc blocked(message: string) {.noreturn.} =
  raise newException(ProbeBlocked, message)

proc require(condition: bool, message: string) =
  if not condition: raise newException(ProbeFailed, message)

proc checkValue(condition: bool, message: string) =
  if not condition:
    inc failures
    echo "check_failed ", message

proc near(a, b, tolerance: float64): bool = abs(a - b) <= tolerance

proc keysFor(phase: int): seq[string] =
  ## Distinct key text per phase so a stale source can never masquerade as new.
  let (prefix, count) =
    case phase
    of 0: ("a-", 20)
    of 1: ("b-", 10)
    else: ("c-", 3)
  for index in 0 ..< count: result.add(prefix & $index)

let RowDef = defineComponent[RowProps, int]("CountShrinkRow",
  proc(ctx: MountContext, props: RowProps): int = props.index,
  proc(ctx: ComponentContext, props: RowProps, model: int): UiDescription =
    # Plain numbers: styles.styleDimension parses the value and does not
    # understand the "$" token, so "$48" would fail the row build.
    let height = if props.phase == 0: "48" else: "24"
    host(row(@[text(props.key & ":" & $model, key = "label")], key = "row",
      styles = style({"height": height}))))

let PageDef = defineComponent[int, State[int]]("CountShrinkPage",
  proc(ctx: MountContext, value: int): State[int] =
    result = ctx.state(value)
    pageState = result,
  proc(ctx: ComponentContext, value: int, state: State[int]): UiDescription =
    let phase = ctx.value(state)
    let keys = keysFor(phase)
    componentList("list", keys,
      proc(index: int): UiDescription =
        component(RowDef, (index: index, phase: phase, key: keys[index])),
      rowHeight = 0.0, estimatedHeight = EstimateDip, overscan = OverscanRows,
      styles = style({"height": "120", "width": "300"})))

proc rectOf(window, port: HWND): RECT =
  require(GetWindowRect(window, addr result) != 0, "GetWindowRect sample")
  var points = [POINT(x: result.left, y: result.top),
    POINT(x: result.right, y: result.bottom)]
  setLastError(0)
  let mapped = MapWindowPoints(nil, port, addr points[0], 2)
  require(mapped != 0 or lastError() == 0, "MapWindowPoints sample")
  result = RECT(left: points[0].x, top: points[0].y,
    right: points[1].x, bottom: points[1].y)

proc rowsOf(win: Win32Backend, session: BackendSession,
            list: NodeHandle): seq[RowFact] =
  ## Typed row identity plus real HWND edges; sorted by index, never by
  ## enumeration or table order.
  for entity in session.acceptedEntities().values:
    if entity.row.isNone: continue
    let binding = entity.row.get
    if binding.listHandle != list: continue
    let window = win.rowWindowForTest(entity.handle)
    require(window != nil, "typed row has no live HWND")
    var fact = RowFact(index: binding.itemIndex, key: binding.itemKey,
      source: binding.sourceGeneration, window: window, parent: GetParent(window),
      visible: IsWindowVisible(window) != 0)
    require(fact.parent != nil, "row has no native parent")
    fact.rect = rectOf(window, fact.parent)
    result.add(fact)
  result.sort(proc(a, b: RowFact): int = cmp(a.index, b.index))

proc checkRowset(facts: seq[RowFact], phase, prefix: string, first, count: int,
                 offsetDip, heightDip: float64, port: HWND, source: uint64) =
  ## Expected rows/heights/tops are computed from the fixture constants only.
  let dpi = GetDpiForWindow(port)
  checkValue(dpi > 0, phase & " real dpi readable")
  let scale = if dpi == 0: 1.0 else: float64(dpi) / 96.0
  let tolerance = if dpi == 96: 0.0 else: 1.0
  var client: RECT
  checkValue(GetClientRect(port, addr client) != 0, phase & " viewport client readable")
  let viewportPx = int32(client.bottom - client.top)
  checkValue(facts.len == count, phase & " typed row count " & $facts.len &
    " must be " & $count)
  var seen: seq[HWND]
  for step in 0 ..< min(count, facts.len):
    let fact = facts[step]
    let expectedIndex = first + step
    let expectedTop = (float64(expectedIndex) * heightDip - offsetDip) * scale
    checkValue(fact.index == expectedIndex,
      phase & " row " & $step & " index " & $fact.index & " must be " & $expectedIndex)
    checkValue(fact.key == prefix & $expectedIndex,
      phase & " row " & $step & " key " & fact.key & " must be " &
        prefix & $expectedIndex)
    checkValue(fact.source == source, phase & " row " & $fact.index & " source")
    checkValue(fact.parent == port, phase & " row " & $fact.index & " parent is viewport")
    checkValue(fact.visible, phase & " row " & $fact.index & " visible")
    # Only rows the fixture geometry places inside the viewport are required to
    # overlap it: a still-present row whose measured top is already below the
    # client bottom is a trim question, not a count-shrink offset question.
    if expectedTop < float64(viewportPx):
      checkValue(fact.rect.top < viewportPx and fact.rect.bottom > 0,
        phase & " row " & $fact.index & " must overlap the " & $viewportPx &
          " px viewport (top " & $fact.rect.top & ", bottom " & $fact.rect.bottom & ")")
    checkValue(fact.rect.right > fact.rect.left, phase & " row " & $fact.index & " width")
    checkValue(abs(float64(fact.rect.top) - expectedTop) <= tolerance,
      phase & " row " & $fact.index & " top " & $fact.rect.top & " must be " &
        $expectedTop)
    checkValue(near(float64(fact.rect.bottom - fact.rect.top), heightDip * scale,
      tolerance), phase & " row " & $fact.index & " height must be " &
        $heightDip & " DIP")
    checkValue(fact.window notin seen, phase & " row " & $fact.index & " HWND unique")
    seen.add(fact.window)

proc barOf(port: HWND): tuple[ok: bool, info: SCROLLINFO, style: uint32,
                             error: DWORD] =
  result.info = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: SIF_ALL)
  setLastError(0)
  result.ok = int32(GetScrollInfo(port, SB_VERT, addr result.info)) != 0
  # Captured before GetWindowLongW can overwrite the thread error slot.
  result.error = lastError()
  result.style = uint32(GetWindowLongW(port, GWL_STYLE))

proc describeRows(facts: seq[RowFact]): string =
  for fact in facts:
    if result.len > 0: result.add(",")
    result.add($fact.index & ":" & fact.key & "@" & $fact.rect.top)

var captionChildren: seq[HWND]
proc collectChild(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  discard data
  captionChildren.add(window)
  BOOL(1)

proc captions(window: HWND): seq[string] =
  ## Real child caption text, so a metadata-only "success" (typed binding updated
  ## while the native row still shows the old text) cannot pass.
  captionChildren.setLen(0)
  discard EnumChildWindows(window, collectChild, 0)
  for child in captionChildren:
    if GetParent(child) != window: continue
    let size = GetWindowTextLengthW(child) + 1
    if size <= 1: continue
    let value = newWideCString(int(size))
    discard GetWindowTextW(child, cast[WidePtr](unsafeAddr value[0]), size)
    result.add($value)

proc checkCaptions(facts: seq[RowFact], phase: string) =
  ## Exact equality: the fixture renders `key:index`, and a prefix test would let
  ## "a-1" also accept a stale "a-10", hiding exactly the stale-caption defect.
  for fact in facts:
    let expected = fact.key & ":" & $fact.index
    let actual = captions(fact.window)
    checkValue(expected in actual, phase & " row " & $fact.index & " real caption '" &
      actual.join("|") & "' must contain exactly '" & expected & "'")

proc checkIntent(win: Win32Backend, list: NodeHandle, expected: float64,
                 phase: string) =
  ## The getter is only the actual side: the expected number is `expected`.
  let intent = win.listIntentForTest(list)
  checkValue(intent.valid, phase & " typed intent readable")
  checkValue(intent.appliedOffset == expected,
    phase & " applied offset " & $intent.appliedOffset & " must be " & $expected)
  checkValue(intent.desiredOffset == expected,
    phase & " desired offset " & $intent.desiredOffset & " must be " & $expected)

proc checkFrame(win: Win32Backend, list: NodeHandle, expected: float64,
                first, finish: int, phase: string) =
  let frame = win.listFrameForTest(list)
  checkValue(frame.hasAccepted and frame.rowsetReady, phase & " accepted rowset ready")
  checkValue(frame.acceptedOffset == expected,
    phase & " accepted offset " & $frame.acceptedOffset & " must be " & $expected)
  checkValue(frame.acceptedFirst == first,
    phase & " accepted first " & $frame.acceptedFirst & " must be " & $first)
  checkValue(frame.acceptedFinish == finish,
    phase & " accepted finish " & $frame.acceptedFinish & " must be " & $finish)

proc main(): int =
  let failureMode = paramCount() > 0 and paramStr(1) == "failure"
  let activity = newUiScopeActivity()
  let rt = newRuntime(guardUiApplication(componentApplication(
    component(PageDef, 0), "count-shrink", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  var h: Win32Host
  var primary, secondary: ref CatchableError
  var classification = "FAIL-unset"
  var phase = "attach"
  var target = 120.0
  try:
    h = createHost("count-shrink", DipSize(width: 480, height: 320))
    h.setStartupScope(proc(): bool = activity.busy or rt.installingUpdate or rt.installingHook)
    # Fixed injection state: scalars only, no string receipt in the call wrappers.
    # The default run never arms, so both seams stay transparent system calls.
    var armed, injected, barReceipt = false
    var injectionCount = 0
    var watchedPort: HWND
    var partialBar = SCROLLINFO()
    let system = systemWin32Calls()
    var seam = system
    var seamToSystem = 0
    seam.setScrollInfo = proc(window: HWND, bar: int32, info: ptr SCROLLINFO,
                              redraw: BOOL): int32 =
      # The projection itself stays the untouched system call, so the default run
      # passes the thread error slot through exactly like the real backend.
      result = system.setScrollInfo(window, bar, info, redraw)
      if armed and not injected and window == watchedPort and bar == SB_VERT and
          info != nil and info.nMin == 0 and info.nMax == 7 and
          info.nPage == 4 and info.nPos == 4:
        # Only this extra receipting readback touches the TLS: save the slot the
        # native setter just left and restore it the moment the read returns. The
        # receipt is the struct the OS actually reports, not the request.
        let saved = lastError()
        seamToSystem = int(result)
        var real = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: SIF_ALL)
        if system.scrollInfo(window, SB_VERT, addr real) != 0 and
            real.nMin == 0 and real.nMax == 7 and real.nPage == 4 and
            real.nPos == 4:
          barReceipt = true
          partialBar = real
        setLastError(saved)
    seam.clientRect = proc(window: HWND, rect: ptr RECT): BOOL =
      if armed and barReceipt and not injected and window == watchedPort:
        injected = true
        inc injectionCount
        setLastError(1234)
        return 0
      system.clientRect(window, rect)
    let win = newWin32Backend(h, seam)
    let session = win.attachWin32Backend(rt)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)

    # Fixed schedule: four ordinary turns, never extended to force a result.
    for turn in 0 ..< 4: win.safeListTurn()

    var list: NodeHandle
    for entity in session.acceptedEntities().values:
      if entity.kind == NodeKind.virtualList: list = entity.handle
    if list == NoHandle: blocked("prime: no accepted virtualList")

    let primeFacts = rowsOf(win, session, list)
    if primeFacts.len == 0: blocked("prime: no typed row with a live HWND")
    var port = primeFacts[0].parent
    if port == nil: blocked("prime: row has no native parent")
    phase = "prime"
    let dpi = GetDpiForWindow(port)
    if dpi == 0: blocked("prime: GetDpiForWindow invalid sample")
    if dpi != 96:
      blocked("premise: this literal pixel oracle requires actual 96 DPI, got " & $dpi)
    var client: RECT
    if GetClientRect(port, addr client) == 0: blocked("prime: GetClientRect invalid sample")
    if client.right <= client.left: blocked("prime: viewport has no positive width")
    # A visible vertical scrollbar legitimately shrinks the client width, so the
    # declared 300 DIP width is only an upper bound here.
    if float64(client.right - client.left) > WidthDip + 1.0:
      blocked("premise: viewport client width exceeds the declared " & $WidthDip & " DIP")
    # Exact, not rounded: every phase-B/C expectation (clamp 120, row tops,
    # scrollbar unit/page) is only meaningful for the declared 120 DIP viewport,
    # and a 119/121 client height would legitimately clamp to a different offset.
    if int32(round(float64(client.bottom - client.top))) != int32(ViewportDip):
      blocked("premise: viewport client height " & $(client.bottom - client.top) &
        " px must be exactly " & $int32(ViewportDip) & " px at " & $dpi & " DPI")
    var sourceA: uint64
    for entity in session.acceptedEntities().values:
      if entity.handle == list and entity.list.isSome:
        sourceA = entity.list.get.sourceGeneration
    if sourceA == 0: blocked("prime: list source generation unreadable")
    let widthPx = int(client.right - client.left)
    let heightPx = int(client.bottom - client.top)
    echo "prime rows=", primeFacts.len, " port=", cast[uint64](port),
      " dpi=", dpi,
      " client_px=", widthPx, "x", heightPx, " source=", sourceA,
      " width_dip=", float64(widthPx)
    if primeFacts.len < 3 or primeFacts.len > 6:
      blocked("premise: prime typed row count " & $primeFacts.len &
        " outside the real 3..6 range for a 120 DIP viewport of 48 DIP rows")
    if primeFacts[0].index != 0: blocked("premise: prime rowset must start at index 0")
    for step, fact in primeFacts:
      if fact.index != step: blocked("premise: prime typed indices are not contiguous")
      if fact.parent != port: blocked("premise: prime row parent is not the viewport")
      if not near(float64(fact.rect.bottom - fact.rect.top), TallDip, 0.0):
        blocked("premise: prime row " & $fact.index & " real height is not " & $TallDip & " DIP")
      if fact.rect.top != int32(step) * 48:
        blocked("premise: prime row " & $fact.index & " top is not " & $(step * 48) & " px")
    checkRowset(primeFacts, "prime", "a-", 0, primeFacts.len, 0.0, TallDip, port, sourceA)
    checkCaptions(primeFacts, "prime")

    # Real SB_BOTTOM: the old offset only has to exceed the phase-B reach; no
    # phase-B expectation is derived from it or from the product HeightIndex.
    discard SendMessageW(port, WM_VSCROLL, WPARAM(SB_BOTTOM), 0)
    var previous = (applied: -1.0, desired: -1.0)
    var stableTurns = 0
    for turn in 0 ..< 4:
      win.safeListTurn()
      let intent = win.listIntentForTest(list)
      let frame = win.listFrameForTest(list)
      echo "  g1 turn=", turn, " applied=", intent.appliedOffset,
        " desired=", intent.desiredOffset, " accepted=", frame.acceptedOffset
      if intent.appliedOffset == previous.applied and
          intent.desiredOffset == previous.desired:
        inc stableTurns
      else:
        stableTurns = 0
      previous = (intent.appliedOffset, intent.desiredOffset)
    if stableTurns < 1:
      blocked("premise: SB_BOTTOM offset did not settle inside four ordinary turns")
    let oldIntent = win.listIntentForTest(list)
    let oldFrame = win.listFrameForTest(list)
    echo "g1 old_applied=", oldIntent.appliedOffset, " old_desired=",
      oldIntent.desiredOffset, " old_accepted=", oldFrame.acceptedOffset,
      " old_ready=", oldFrame.rowsetReady, " phaseB_reach=", ReachB
    if not oldIntent.valid: blocked("g1: typed intent unreadable after SB_BOTTOM")
    if oldIntent.appliedOffset != oldIntent.desiredOffset:
      blocked("premise: SB_BOTTOM did not settle applied==desired")
    if oldIntent.appliedOffset != oldFrame.acceptedOffset:
      blocked("premise: SB_BOTTOM intent and accepted offset disagree")
    if not (oldIntent.appliedOffset > ViewportDip):
      blocked("premise: old offset " & $oldIntent.appliedOffset &
        " must exceed the phase-B reach " & $ViewportDip)
    # The typed getters alone cannot show that the native rowset moved: assert the
    # real HWND facts of the accepted plan too. Every g1 row is expected from the
    # prime geometry only (48 DIP tall, contiguous), never from an offscreen
    # height estimate, and no turn is added to make this pass.
    let factsG1 = rowsOf(win, session, list)
    echo "g1 native_rows=", factsG1.len, " ", describeRows(factsG1),
      " ready=", oldFrame.rowsetReady
    checkValue(oldFrame.hasAccepted, "g1 accepted plan still present after SB_BOTTOM")
    checkValue(oldFrame.rowsetReady, "g1 accepted plan still rowset ready after SB_BOTTOM")
    if factsG1.len == 0:
      blocked("premise: SB_BOTTOM left no typed native row to inspect")
    var offFirstScreen = false
    var previousTop = 0'i32
    for step, fact in factsG1:
      checkValue(fact.source == sourceA, "g1 row " & $fact.index & " keeps the prime source")
      checkValue(fact.parent == port, "g1 row " & $fact.index & " is parented to the viewport")
      checkValue(fact.visible, "g1 row " & $fact.index & " visible")
      checkValue(near(float64(fact.rect.bottom - fact.rect.top), TallDip, 0.0),
        "g1 row " & $fact.index & " real height must be " & $TallDip & " DIP")
      if step > 0:
        checkValue(fact.rect.top - previousTop == 48,
          "g1 rows are contiguous, top delta " & $(fact.rect.top - previousTop) &
            " must be 48 px")
      previousTop = fact.rect.top
      if fact.index > primeFacts[^1].index and fact.rect.top < 120 and fact.rect.bottom > 0:
        offFirstScreen = true
    checkCaptions(factsG1, "g1")
    if not offFirstScreen:
      blocked("premise: no real row beyond prime last index " & $primeFacts[^1].index &
        " intersects the 0..120 px viewport; native departure from first screen unproved")

    # Optional coverage addition: one receipted business-commit refusal on the
    # very same A20 -> B10 step, then the real recovery of the accepted A plan.
    # Nothing here is a premise for the B/C oracle below: the failure run still
    # replays B and C from scratch afterwards, over the recovered viewport.
    if failureMode:
      phase = "failure"
      let frameA = win.listFrameForTest(list)
      let intentA = win.listIntentForTest(list)
      let revisionA = rt.acceptedRevision
      let stateA = pageState.read()
      let barA = barOf(port)
      echo "failure_premise a_source=", frameA.acceptedSource, " a_offset=",
        frameA.acceptedOffset, " a_range=", frameA.acceptedFirst, "..",
        frameA.acceptedFinish, " a_rows=", factsG1.len, " a_bar=",
        barA.info.nMin, "/", barA.info.nMax, "/", barA.info.nPage, "/",
        barA.info.nPos, " a_bar_ok=", barA.ok, " g1_target=",
        oldIntent.appliedOffset
      if not (frameA.hasAccepted and frameA.rowsetReady and intentA.valid):
        blocked("failure: phase-A accepted frame/intent unreadable before injection")
      if not barA.ok:
        blocked("failure: phase-A scrollbar unreadable (win32 error " &
          $barA.error & ")")
      checkValue(stateA == 0, "failure: page State must still be the prime value 0")
      # Arm only the phase-B business commit: the window is the accepted viewport
      # and the seam fires once, on the real 0/7/4/4 projection.
      let portA = port
      watchedPort = portA
      barReceipt = false
      let queued = pageState.set(1)
      if queued != StateWriteResult.queued:
        blocked("failure: page State write not queued")
      var refused: ref CatchableError
      armed = true
      try: discard rt.flush()
      except ProbeBlocked as error: raise error
      except CatchableError as error: refused = error
      finally: armed = false
      echo "failure_injection count=", injectionCount, " bar_receipt=",
        barReceipt, " set_scroll_info_return=", seamToSystem, " receipt_bar=",
        partialBar.nMin, "/", partialBar.nMax, "/", partialBar.nPage, "/",
        partialBar.nPos, " refused=", refused != nil
      if refused != nil:
        # The real caught text, so a passing run still shows the product message.
        echo "failure_caught_primary message=", refused.msg
      if injectionCount == 0 or not barReceipt:
        blocked("failure: the business commit never projected the real phase-B bar " &
          "(count " & $injectionCount & ", receipt " & $barReceipt &
          "), so no commit failure was injected")
      checkValue(injectionCount == 1,
        "failure: exactly one client-rect injection, got " & $injectionCount)
      checkValue(refused != nil,
        "failure: a refused client readback must fail the business commit")
      if refused == nil:
        raise newException(ProbeFailed,
          "failure: the commit survived a refused client readback")
      checkValue("GetClientRect list after scrollbar" in refused.msg,
        "failure: primary error must be the refused client readback, got '" &
          refused.msg & "'")
      checkValue("1234" in refused.msg,
        "failure: the original win32 error 1234 must survive the replay, got '" &
          refused.msg & "'")
      checkValue(refused.msg == "GetClientRect list after scrollbar failed: 1234",
        "failure: native delta adapter must preserve the exact primary error " &
          "without a secondary replay failure, got '" & refused.msg & "'")
      # State and plan restore: the rejected candidate publishes nothing, and the
      # restored accepted frame is the very same plan token/source/offset/range.
      checkValue(pageState.read() == 0,
        "failure: the rejected phase-B write must not publish")
      checkValue(rt.acceptedRevision == revisionA,
        "failure: the rejected commit must keep the accepted revision")
      let frameR = win.listFrameForTest(list)
      let intentR = win.listIntentForTest(list)
      checkValue(frameR.hasAccepted and frameR.rowsetReady,
        "failure: restored accepted rowset ready")
      checkValue(frameR.acceptedSource == frameA.acceptedSource,
        "failure: restored source " & $frameR.acceptedSource & " must be " &
          $frameA.acceptedSource)
      checkValue(frameR.acceptedToken == frameA.acceptedToken,
        "failure: restored plan token " & $frameR.acceptedToken &
          " must be the accepted " & $frameA.acceptedToken)
      checkValue(frameR.acceptedOffset == frameA.acceptedOffset and
        frameR.acceptedFirst == frameA.acceptedFirst and
        frameR.acceptedFinish == frameA.acceptedFinish,
        "failure: restored offset/range must equal the accepted plan")
      checkValue(frameR.acceptedRows.len == frameA.acceptedRows.len,
        "failure: restored row count " & $frameR.acceptedRows.len & " must be " &
          $frameA.acceptedRows.len)
      checkValue(intentR.valid and intentR.appliedOffset == intentA.appliedOffset and
        intentR.desiredOffset == intentA.desiredOffset,
        "failure: restored desired/applied offsets must equal the accepted intent")
      # The recovered host is new: re-find the viewport instead of assuming the
      # destroyed address, and require A's logical rowset on the new HWNDs.
      let factsR = rowsOf(win, session, list)
      # The injection did happen and A had real rows, so an empty or unparented
      # recovery is a violated restore contract, not an unproved premise.
      require(factsR.len > 0, "failure: restore contract violated: the recovered " &
        "viewport exposes no typed native row")
      let recoveredPort = factsR[0].parent
      require(recoveredPort != nil,
        "failure: restore contract violated: recovered row has no native parent")
      port = recoveredPort
      checkValue(factsR.len == factsG1.len, "failure: recovered row count " &
        $factsR.len & " must be " & $factsG1.len)
      var recoveredSeen: seq[HWND]
      for step in 0 ..< min(factsR.len, factsG1.len):
        let prior = factsG1[step]
        let current = factsR[step]
        checkValue(current.index == prior.index, "failure: recovered row " & $step &
          " index " & $current.index & " must be " & $prior.index)
        checkValue(current.key == prior.key, "failure: recovered row " &
          $current.index & " key " & current.key & " must be " & $prior.key)
        checkValue(current.source == prior.source and
          current.source == frameA.acceptedSource,
          "failure: recovered row " & $current.index & " source")
        checkValue(current.parent == recoveredPort, "failure: recovered row " &
          $current.index & " must be parented to the restored viewport")
        checkValue(current.window != nil and current.window notin recoveredSeen,
          "failure: recovered row " & $current.index &
            " HWND must be non-nil and unique")
        recoveredSeen.add(current.window)
        checkValue(current.visible, "failure: recovered row " & $current.index &
          " visible")
        checkValue(current.rect == prior.rect, "failure: recovered row " &
          $current.index & " rect must be unchanged")
        checkValue(current.rect.bottom - current.rect.top ==
          prior.rect.bottom - prior.rect.top, "failure: recovered row " &
            $current.index & " height must be unchanged")
      checkCaptions(factsR, "failureA")
      let barR = barOf(port)
      checkValue(barR.ok, "failure: recovered scrollbar readable (win32 error " &
        $barR.error & ")")
      checkValue(barR.info.nMin == barA.info.nMin and
        barR.info.nMax == barA.info.nMax and
        barR.info.nPage == barA.info.nPage and barR.info.nPos == barA.info.nPos,
        "failure: recovered bar " & $barR.info.nMin & "/" & $barR.info.nMax &
          "/" & $barR.info.nPage & "/" & $barR.info.nPos &
          " must equal the accepted " & $barA.info.nMin & "/" & $barA.info.nMax &
          "/" & $barA.info.nPage & "/" & $barA.info.nPos)
      checkValue((barR.style and WS_VSCROLL) == (barA.style and WS_VSCROLL),
        "failure: recovered viewport keeps the accepted WS_VSCROLL state")
      echo "failure_restore port_reused=", recoveredPort == portA, " rows=",
        factsR.len, " ", describeRows(factsR), " token=", frameR.acceptedToken,
        " source=", frameR.acceptedSource, " offset=", frameR.acceptedOffset,
        " range=", frameR.acceptedFirst, "..", frameR.acceptedFinish,
        " rows_meta=", frameR.acceptedRows.len, " intent=",
        intentR.appliedOffset, "/", intentR.desiredOffset, " bar=",
        barR.info.nMin, "/", barR.info.nMax, "/", barR.info.nPage, "/",
        barR.info.nPos, " state=", pageState.read(), " revision=",
        rt.acceptedRevision, " accepted token=", frameA.acceptedToken,
        " source=", frameA.acceptedSource, " offset=", frameA.acceptedOffset,
        " range=", frameA.acceptedFirst, "..", frameA.acceptedFinish,
        " rows_meta=", frameA.acceptedRows.len, " intent=",
        intentA.appliedOffset, "/", intentA.desiredOffset, " bar=",
        barA.info.nMin, "/", barA.info.nMax, "/", barA.info.nPage, "/",
        barA.info.nPos, " revision=", revisionA
      # Two ordinary turns: no hidden retry of the rejected business commit and no
      # drift inside the recovered HWND group.
      let quietA = rt.acceptedRevision
      for turn in 0 ..< 2: win.safeListTurn()
      let frameQ = win.listFrameForTest(list)
      let intentQ = win.listIntentForTest(list)
      let factsQ = rowsOf(win, session, list)
      let barQ = barOf(port)
      echo "failure_quiet revision_before=", quietA, " revision_after=",
        rt.acceptedRevision, " rows=", factsQ.len, " state=", pageState.read(),
        " token=", frameQ.acceptedToken, " source=", frameQ.acceptedSource,
        " offset=", frameQ.acceptedOffset, " range=", frameQ.acceptedFirst,
        "..", frameQ.acceptedFinish, " rows_meta=", frameQ.acceptedRows.len,
        " intent=", intentQ.appliedOffset, "/", intentQ.desiredOffset, " bar=",
        barQ.info.nMin, "/", barQ.info.nMax, "/", barQ.info.nPage, "/",
        barQ.info.nPos, " bar_ok=", barQ.ok, " vscroll_same=",
        (barQ.style and WS_VSCROLL) == (barA.style and WS_VSCROLL)
      checkValue(rt.acceptedRevision == quietA and pageState.read() == 0,
        "failure: quiet turns must not retry or publish the rejected phase-B commit")
      checkValue(frameQ.hasAccepted and frameQ.rowsetReady,
        "failure: quiet turns keep a ready accepted rowset")
      checkValue(frameQ.acceptedToken == frameA.acceptedToken and
        frameQ.acceptedSource == frameA.acceptedSource and
        frameQ.acceptedOffset == frameA.acceptedOffset and
        frameQ.acceptedFirst == frameA.acceptedFirst and
        frameQ.acceptedFinish == frameA.acceptedFinish and
        frameQ.acceptedRows.len == frameA.acceptedRows.len,
        "failure: quiet turns keep the restored accepted plan")
      checkValue(intentQ.valid and intentQ.appliedOffset == intentA.appliedOffset and
        intentQ.desiredOffset == intentA.desiredOffset,
        "failure: quiet turns keep the restored intent")
      checkValue(factsQ.len == factsR.len, "failure: quiet row count unchanged")
      for step in 0 ..< min(factsQ.len, factsR.len):
        checkValue(factsQ[step].index == factsR[step].index and
          factsQ[step].key == factsR[step].key and
          factsQ[step].source == factsR[step].source and
          factsQ[step].window == factsR[step].window and
          factsQ[step].parent == factsR[step].parent and
          factsQ[step].rect == factsR[step].rect and factsQ[step].visible,
          "failure: quiet row " & $factsQ[step].index & " must stay identical")
      checkCaptions(factsQ, "failureAquiet")
      checkValue(barQ.ok and barQ.info.nMin == barA.info.nMin and
        barQ.info.nMax == barA.info.nMax and
        barQ.info.nPage == barA.info.nPage and barQ.info.nPos == barA.info.nPos,
        "failure: quiet turns keep the accepted bar")
      checkValue((barQ.style and WS_VSCROLL) == (barA.style and WS_VSCROLL),
        "failure: quiet turns keep the accepted WS_VSCROLL state")
      if failures > 0:
        raise newException(ProbeFailed,
          "failure: accepted A recovery contract failed; the B/C retry is skipped")

    # Phase B: 10 new keys, every real row 24 DIP. Old far offset > new reach
    # 240-120=120, so the accepted offset must clamp to exactly 120.
    phase = "phaseB"
    target = 120.0
    if pageState.set(1) != StateWriteResult.queued:
      blocked("phaseB: page State write not queued")
    discard rt.flush()
    for turn in 0 ..< 4: win.safeListTurn()
    var sourceB = sourceA
    for entity in session.acceptedEntities().values:
      if entity.handle == list and entity.list.isSome:
        sourceB = entity.list.get.sourceGeneration
    checkValue(sourceB != sourceA,
      phase & " list source generation must change for the new key set (" &
        $sourceA & " -> " & $sourceB & ")")
    let factsB = rowsOf(win, session, list)
    echo "phaseB source=", sourceB, " rows=", factsB.len, " ", describeRows(factsB)
    checkIntent(win, list, ReachB, phase)
    checkFrame(win, list, ReachB, 5, 10, phase)
    checkRowset(factsB, phase, "b-", 5, 5, ReachB, RowDip, port, sourceB)
    checkCaptions(factsB, phase)
    let barB = barOf(port)
    checkValue(barB.ok, phase & " GetScrollInfo must succeed for the non-zero " &
      "phase-B range (win32 error " & $barB.error & ")")
    echo "phaseB bar nMin=", barB.info.nMin, " nMax=", barB.info.nMax,
      " nPage=", barB.info.nPage, " nPos=", barB.info.nPos,
      " style_vscroll=", (barB.style and WS_VSCROLL) != 0
    checkValue(barB.info.nMin == 0, phase & " bar nMin 0")
    checkValue(barB.info.nMax == BarMaxB,
      phase & " bar nMax " & $barB.info.nMax & " must be " & $BarMaxB)
    checkValue(barB.info.nPage == BarPageB,
      phase & " bar nPage " & $barB.info.nPage & " must be " & $BarPageB)
    checkValue(barB.info.nPos == BarPosB,
      phase & " bar nPos " & $barB.info.nPos & " must be " & $BarPosB)
    checkValue((barB.style and WS_VSCROLL) != 0, phase & " viewport keeps WS_VSCROLL")

    # Phase C: 3 new keys, still nonempty but total 72 < viewport 120, so the
    # range is max(72-120,0)=0 and the offset must clamp to exactly 0.
    phase = "phaseC"
    target = 0.0
    if pageState.set(2) != StateWriteResult.queued:
      blocked("phaseC: page State write not queued")
    discard rt.flush()
    for turn in 0 ..< 4: win.safeListTurn()
    var sourceC = sourceB
    for entity in session.acceptedEntities().values:
      if entity.handle == list and entity.list.isSome:
        sourceC = entity.list.get.sourceGeneration
    checkValue(sourceC != sourceB,
      phase & " list source generation must change for the new key set (" &
        $sourceB & " -> " & $sourceC & ")")
    let factsC = rowsOf(win, session, list)
    echo "phaseC source=", sourceC, " rows=", factsC.len, " ", describeRows(factsC),
      " total=", TotalC, " range=", max(TotalC - ViewportDip, 0.0)
    checkIntent(win, list, 0.0, phase)
    checkFrame(win, list, 0.0, 0, 3, phase)
    checkRowset(factsC, phase, "c-", 0, 3, 0.0, RowDip, port, sourceC)
    checkCaptions(factsC, phase)
    # The bar may legitimately be hidden when the whole source fits. Record what
    # the OS reports; do not turn a hidden bar into a fabricated projection.
    let barC = barOf(port)
    echo "phaseC bar_ok=", barC.ok, " error=", barC.error,
      " nMin=", barC.info.nMin, " nMax=", barC.info.nMax,
      " nPage=", barC.info.nPage, " nPos=", barC.info.nPos,
      " style_vscroll=", (barC.style and WS_VSCROLL) != 0
    checkValue(factsC.len == 3 and factsC[0].visible,
      phase & " nonempty three-row rowset with a visible first row")

    # Two quiet turns: settled offset, rowset, rects and accepted revision stay.
    phase = "quiet"
    let settledRevision = rt.acceptedRevision
    let settledRects = factsC
    for turn in 0 ..< 2: win.safeListTurn()
    let factsQuiet = rowsOf(win, session, list)
    let quietIntent = win.listIntentForTest(list)
    echo "quiet revision_before=", settledRevision, " revision_after=",
      rt.acceptedRevision, " rows=", factsQuiet.len
    checkValue(rt.acceptedRevision == settledRevision,
      phase & " quiet turns leave accepted revision unchanged")
    checkValue(quietIntent.valid, phase & " typed intent readable after quiet turns")
    checkValue(quietIntent.appliedOffset == 0.0 and quietIntent.desiredOffset == 0.0,
      phase & " quiet turns keep offset 0")
    checkValue(factsQuiet.len == settledRects.len, phase & " quiet row count unchanged")
    for step in 0 ..< min(factsQuiet.len, settledRects.len):
      checkValue(factsQuiet[step].index == settledRects[step].index,
        phase & " quiet row index unchanged")
      checkValue(factsQuiet[step].key == settledRects[step].key,
        phase & " quiet row " & $factsQuiet[step].index & " key unchanged")
      checkValue(factsQuiet[step].source == settledRects[step].source,
        phase & " quiet row " & $factsQuiet[step].index & " source unchanged")
      checkValue(factsQuiet[step].window == settledRects[step].window,
        phase & " quiet row " & $factsQuiet[step].index & " HWND unchanged")
      checkValue(factsQuiet[step].parent == settledRects[step].parent,
        phase & " quiet row " & $factsQuiet[step].index & " parent unchanged")
      checkValue(factsQuiet[step].visible, phase & " quiet row " &
        $factsQuiet[step].index & " still visible")
      checkValue(factsQuiet[step].rect == settledRects[step].rect,
        phase & " quiet row " & $factsQuiet[step].index & " rect unchanged")
    classification =
      if failures != 0: "FAIL-geometry"
      elif failureMode: "PASS-count-shrink-failure"
      else: "PASS-coverage-addition"
  except ProbeBlocked as error:
    primary = error
    classification = "NotRun-invalid-or-premise"
  except ProbeFailed as error:
    primary = error
    classification = "FAIL-contract"
    inc failures
  except CatchableError as error:
    primary = error
    classification = "FAIL-exception"
    inc failures

  # Exactly one bounded close per created-host outcome; no pump, no retry.
  if h != nil:
    try: h.destroyHost()
    except CatchableError as error: secondary = error
    if not h.resourcesReleasedInternal() and secondary == nil:
      secondary = newException(UiError, "host cleanup incomplete")
  if secondary == nil:
    try: rt.closeRuntime()
    except CatchableError as error: secondary = error
  if primary != nil:
    echo "actual_primary phase=", phase, " target=", target, " type=", primary.name,
      " msg=", primary.msg
  if secondary != nil:
    echo "actual_secondary type=", secondary.name, " msg=", secondary.msg
  echo "close_attempts=", (if h == nil: 0 else: 1), " failures=", failures
  if secondary != nil:
    echo "status=FAIL-close original_status=", classification
    return 1
  echo "probe_win32_list_count_shrink status=", classification
  if classification.startsWith("NotRun"): return 2
  if classification.startsWith("PASS"): return 0
  1

when isMainModule:
  quit(main())
