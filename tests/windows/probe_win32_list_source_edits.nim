## Insert/delete around a non-zero in-row offset must keep the numeric offset
## while the typed row generation changes and the old row State owner retires.
## A: 20 keys a-0..a-19, every real row a uniform 24 DIP, viewport 130 -> six
##    real rows; one SB_PAGEDOWN moves the numeric offset to exactly 106, first
##    row index 4 at top -10 (130 - 24 = 106, an already measured number).
## B: two keys inserted in FRONT (22 keys, old tail order untouched) -> the
##    numeric offset must stay 106, so the same logical key a-4 moves from index
##    4 at top -10 to index 6 at top 38. It is NOT chased to 144 and the old
##    first key is not turned into an anchor.
## C: the two inserted keys are deleted again (20 keys) -> 106 once more, and
##    the phase-B key a-2 is no longer in the visible rowset (a-2 exists in A,
##    B and C alike; only in B is it inside the 130 px window).
## The fixture is uniform-height, so no unknown measurement distribution is
## inferred here. Every expected number is a frozen literal: this probe only
## observes the product's actual side and never derives its own oracle from it.
## Optional mode `create-failure` (argv[1]): exactly one direct row root of the
## real A->B prepare is refused by CreateWindowExW. The accepted phase-A plan,
## its six native rows and its live row State must survive untouched, with no
## hidden retry; the ordinary B/C replay then runs unchanged.
when not defined(windows) or not defined(leafProtocolProbes):
  {.error: "Requires real Windows and leafProtocolProbes".}

import std/[tables, options, strutils, algorithm, sequtils, os]
import leaf/[core, widgets, components, backend, backend_session, ui_thread,
  native_layout]
import leaf/component_description
import leaf/backends/win32/[api, calls, host, backend]

const
  ViewportDip = 130.0                      # frozen list viewport, 96 DPI
  RowDip = 24.0                            # every real row in every phase
  EstimateDip = 24.0                       # equals the real height: uniform rows,
                                           # no unknown measurement spread
  PrimeRows = 6                            # floor(130 / 24) + the clipped edge
  OffsetA = 106                            # max(RowDip, 130 - 24) after PageDown
  FirstA = 4                               # row whose top is -10 at offset 106
  FinishA = 10                             # exclusive end of the 130 px window
  BarMaxA = 14                             # ceil(350/32)=11 units + page-1
  BarPageA = 4                             # round(130/32)
  BarPosA = 3                              # round(106/32)
  BarMaxB = 16                             # ceil(398/32)=13 units + page-1
  BarPosB = 3                              # the same numeric offset, same unit

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
  rowStates: Table[string, State[int]]
  failures = 0

proc blocked(message: string) {.noreturn.} =
  raise newException(ProbeBlocked, message)

proc require(condition: bool, message: string) =
  if not condition: raise newException(ProbeFailed, message)

proc checkValue(condition: bool, message: string) =
  if not condition:
    inc failures
    echo "check_failed ", message

proc guardContract(phase, what: string) =
  ## Stop the optional failure section at the first broken step: continuing into
  ## quiet turns, the explicit State write or the B/C replay would only report the
  ## same broken recovery again.
  if failures != 0:
    raise newException(ProbeFailed, phase & ": " & what &
      " failed; the accepted-plan recovery contract is broken, the later " &
      "phases are skipped")

proc keysFor(phase: int): seq[string] =
  ## Phase B prepends two keys and keeps the old tail exactly as it was; phase C
  ## is phase A's key set again, so only a real delete/insert pair is covered.
  case phase
  of 0, 2:
    for index in 0 ..< 20: result.add("a-" & $index)
  else:
    result.add("insert-0")
    result.add("insert-1")
    for index in 0 ..< 20: result.add("a-" & $index)

let RowDef = defineComponent[RowProps, State[int]]("EditRow",
  proc(ctx: MountContext, props: RowProps): State[int] =
    # Row-local State with its own 0: the fixture needs a per-row owner that a
    # new source generation has to retire, not a page-wide value.
    result = ctx.state(0)
    rowStates[props.key] = result,
  proc(ctx: ComponentContext, props: RowProps, state: State[int]): UiDescription =
    host(row(@[text(props.key & ":" & $ctx.value(state), key = "label")],
      key = "row", styles = style({"height": "24"}))))

let PageDef = defineComponent[int, State[int]]("EditPage",
  proc(ctx: MountContext, value: int): State[int] =
    result = ctx.state(0)
    pageState = result,
  proc(ctx: ComponentContext, value: int, state: State[int]): UiDescription =
    let phase = ctx.value(state)
    let keys = keysFor(phase)
    componentList("list", keys,
      proc(index: int): UiDescription =
        component(RowDef, (index: index, phase: phase, key: keys[index])),
      rowHeight = 0.0, estimatedHeight = EstimateDip, overscan = 0,
      styles = style({"height": "130", "width": "300"})))

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
  ## Real child caption text: a typed binding that says 0 while the native row
  ## still renders 7 would otherwise pass a metadata-only check.
  captionChildren.setLen(0)
  discard EnumChildWindows(window, collectChild, 0)
  for child in captionChildren:
    if GetParent(child) != window: continue
    let size = GetWindowTextLengthW(child) + 1
    if size <= 1: continue
    let value = newWideCString(int(size))
    discard GetWindowTextW(child, cast[WidePtr](unsafeAddr value[0]), size)
    result.add($value)

proc checkCaptions(facts: seq[RowFact], phase: string, values: seq[int]) =
  ## Exact per-row text `key:value`, so both the live key and the live row State
  ## value are the real native caption, not a typed echo of the request.
  for step in 0 ..< min(facts.len, values.len):
    let fact = facts[step]
    let expected = fact.key & ":" & $values[step]
    let actual = captions(fact.window)
    checkValue(expected in actual, phase & " row " & $fact.index &
      " real caption '" & actual.join("|") & "' must contain exactly '" &
      expected & "'")

proc checkRowset(facts: seq[RowFact], phase: string, expected: seq[string],
                 first, offset: int, port: HWND, source: uint64) =
  ## Tops come from the frozen 24 DIP row height and the numeric offset only.
  checkValue(facts.len == expected.len, phase & " typed row count " &
    $facts.len & " must be " & $expected.len)
  var seen: seq[HWND]
  for step in 0 ..< min(facts.len, expected.len):
    let fact = facts[step]
    let index = first + step
    let top = int32(index * 24 - offset)
    checkValue(fact.index == index, phase & " row " & $step & " index " &
      $fact.index & " must be " & $index)
    checkValue(fact.key == expected[step], phase & " row " & $index & " key '" &
      fact.key & "' must be '" & expected[step] & "'")
    checkValue(fact.source == source, phase & " row " & $index & " source " &
      $fact.source & " must be " & $source)
    checkValue(fact.parent == port, phase & " row " & $index & " parent is viewport")
    checkValue(fact.visible, phase & " row " & $index & " visible")
    checkValue(fact.rect.top == top, phase & " row " & $index & " top " &
      $fact.rect.top & " must be " & $top)
    checkValue(fact.rect.bottom - fact.rect.top == 24, phase & " row " & $index &
      " height " & $(fact.rect.bottom - fact.rect.top) & " must be 24")
    checkValue(fact.rect.right > fact.rect.left, phase & " row " & $index & " width")
    checkValue(fact.window notin seen, phase & " row " & $index & " HWND unique")
    seen.add(fact.window)

proc checkBar(bar: tuple[ok: bool, info: SCROLLINFO, style: uint32, error: DWORD],
              phase: string, nMax, nPos: int32) =
  echo phase, " bar_ok=", bar.ok, " error=", bar.error, " nMin=", bar.info.nMin,
    " nMax=", bar.info.nMax, " nPage=", bar.info.nPage, " nPos=",
    bar.info.nPos, " style_vscroll=", (bar.style and WS_VSCROLL) != 0
  checkValue(bar.ok, phase & " real GetScrollInfo must succeed (win32 error " &
    $bar.error & ")")
  checkValue(bar.info.nMin == 0, phase & " bar nMin 0")
  checkValue(bar.info.nMax == nMax, phase & " bar nMax " & $bar.info.nMax &
    " must be " & $nMax)
  checkValue(bar.info.nPage == uint32(BarPageA), phase & " bar nPage " &
    $bar.info.nPage & " must be " & $BarPageA)
  checkValue(bar.info.nPos == nPos, phase & " bar nPos " & $bar.info.nPos &
    " must be " & $nPos)
  checkValue((bar.style and WS_VSCROLL) != 0, phase & " viewport keeps WS_VSCROLL")

proc keys(first, count: int, prefix = "a-"): seq[string] =
  for index in first ..< first + count: result.add(prefix & $index)

proc main(): int =
  let createFailureMode = paramCount() > 0 and paramStr(1) == "create-failure"
  let activity = newUiScopeActivity()
  let rt = newRuntime(guardUiApplication(componentApplication(
    component(PageDef, 0), "source-edits", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  var h: Win32Host
  var primary, secondary: ref CatchableError
  var classification = "FAIL-unset"
  var phase = "attach"
  try:
    h = createHost("source-edits", DipSize(width: 480, height: 320))
    h.setStartupScope(proc(): bool = activity.busy or rt.installingUpdate or rt.installingHook)
    # Fixed injection state: scalars only, no string receipt in the call wrappers.
    # The default run never arms, so both seams stay transparent system calls and
    # the thread error slot passes through exactly like the real backend.
    var armed = false
    var watchingDestroy = false
    var matchedCreates = 0
    var injectionCount = 0
    var firstRoot: HWND
    var watchedPort: HWND
    var destroyCount = 0
    var destroyReceipt = -1
    let system = systemWin32Calls()
    var seam = system
    seam.createWindow = proc(exStyle: DWORD, className, title: WidePtr,
                             style: DWORD, x, y, width, height: int32,
                             parent: HWND, menu: HMENU, instance: HINSTANCE,
                             param: pointer): HWND =
      # Identity is the real creation callback of a direct row root of the one
      # watched viewport, not a row index or a logical key: only the first such
      # creation is really performed, the second is refused once.
      if armed and parent == watchedPort:
        inc matchedCreates
        if matchedCreates == 1:
          result = system.createWindow(exStyle, className, title, style, x, y,
            width, height, parent, menu, instance, param)
          if result != nil: firstRoot = result
          return
        if matchedCreates == 2:
          # Disarm immediately: every later creation in the same flush is a real
          # system call. Only the destroy observer stays armed for the cleanup.
          armed = false
          inc injectionCount
          setLastError(1234)
          return nil
      result = system.createWindow(exStyle, className, title, style, x, y, width,
        height, parent, menu, instance, param)
    seam.destroyWindow = proc(window: HWND): BOOL =
      # Real release observer for the one row root created above. Every call
      # forwards and returns the untouched OS result. The observation window is
      # the single business flush, so every real destroy of that exact root is
      # counted there (the count is exact, not a first-only sample); after the
      # window closes a recycled HWND can no longer add receipts.
      result = system.destroyWindow(window)
      if watchingDestroy and firstRoot != nil and window == firstRoot:
        inc destroyCount
        destroyReceipt = int(result)
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
    let port = primeFacts[0].parent
    if port == nil: blocked("prime: row has no native parent")
    # Premise only: the frozen literal oracle is 96 DPI with a 130 px viewport
    # and six measurable rows. No pixel tolerance is invented to hide a miss.
    let dpi = GetDpiForWindow(port)
    if dpi != 96: blocked("prime: this literal pixel oracle requires actual 96 DPI, got " & $dpi)
    var client: RECT
    if GetClientRect(port, addr client) == 0:
      blocked("prime: viewport client rect unreadable")
    let clientHeight = client.bottom - client.top
    let clientWidth = client.right - client.left
    if clientHeight != 130:
      blocked("prime: fixture premise wants a 130 px viewport, got " & $clientHeight)
    if clientWidth <= 0 or clientWidth > 300:
      blocked("prime: viewport width must be positive and <= 300 px, got " & $clientWidth)
    if primeFacts.len != PrimeRows or primeFacts[0].index != 0:
      blocked("prime: fixture premise wants six rows starting at index 0, got " &
        $primeFacts.len & " from " & $primeFacts[0].index)
    let frameA0 = win.listFrameForTest(list)
    if not (frameA0.hasAccepted and frameA0.rowsetReady):
      blocked("prime: no accepted rowset for the phase-A fixture")
    let sourceA = frameA0.acceptedSource
    phase = "prime"
    echo "prime dpi=", dpi, " client=", clientWidth, "x", clientHeight, " source=",
      sourceA, " offset=", frameA0.acceptedOffset, " range=", frameA0.acceptedFirst,
      "..", frameA0.acceptedFinish, " rows=", primeFacts.len, " ",
      describeRows(primeFacts)
    checkRowset(primeFacts, phase, keys(0, PrimeRows), 0, 0, port, sourceA)
    checkCaptions(primeFacts, phase, @[0, 0, 0, 0, 0, 0])

    # Real PageDown: 130 - 24 = 106, an already measured number in the fixture.
    discard SendMessageW(port, WM_VSCROLL, WPARAM(SB_PAGEDOWN), 0)
    for turn in 0 ..< 4: win.safeListTurn()
    phase = "phaseA"
    let frameA = win.listFrameForTest(list)
    let intentA = win.listIntentForTest(list)
    let factsA = rowsOf(win, session, list)
    echo "phaseA source=", frameA.acceptedSource, " offset=", frameA.acceptedOffset,
      " desired=", intentA.desiredOffset, " applied=", intentA.appliedOffset,
      " range=", frameA.acceptedFirst, "..", frameA.acceptedFinish, " rows=",
      factsA.len, " ", describeRows(factsA)
    checkValue(intentA.valid, phase & " typed intent readable")
    checkValue(intentA.desiredOffset == OffsetA and intentA.appliedOffset == OffsetA,
      phase & " desired/applied offset must be 106, got " &
        $intentA.desiredOffset & "/" & $intentA.appliedOffset)
    checkValue(frameA.hasAccepted and frameA.rowsetReady, phase & " rowset ready")
    checkValue(frameA.acceptedOffset == OffsetA, phase & " accepted offset " &
      $frameA.acceptedOffset & " must be 106")
    checkValue(frameA.acceptedFirst == FirstA and frameA.acceptedFinish == FinishA,
      phase & " range must be 4..10, got " & $frameA.acceptedFirst & ".." &
        $frameA.acceptedFinish)
    checkValue(frameA.acceptedSource == sourceA, phase & " same source as prime")
    checkRowset(factsA, phase, keys(FirstA, PrimeRows), FirstA, OffsetA, port, sourceA)
    checkCaptions(factsA, phase, @[0, 0, 0, 0, 0, 0])

    # Witness State: a row-local write inside source A must stay inside A.
    require("a-4" in rowStates, "phaseA: fixture row a-4 State was never registered")
    let oldAState = rowStates["a-4"]
    # The active State store and the prime are already valid here, so a refused
    # write is a contract failure, not an unproved premise.
    require(oldAState.set(7) == StateWriteResult.queued,
      "phaseA: row-local State write for a-4 must be queued")
    discard rt.flush()
    for turn in 0 ..< 2: win.safeListTurn()
    let frameA1 = win.listFrameForTest(list)
    let intentA1 = win.listIntentForTest(list)
    let factsA1 = rowsOf(win, session, list)
    # A hot row-local State write still owes native rows; an empty rowset must
    # produce its own contract report instead of an IndexDefect below.
    require(factsA1.len > 0,
      "phaseA: the accepted row-state turn must keep native rows, got none")
    echo "phaseA_state a-4=", rowStates["a-4"].read(), " source=",
      frameA1.acceptedSource, " offset=", frameA1.acceptedOffset, " caption=",
      captions(factsA1[0].window).join("|")
    checkValue(rowStates["a-4"].read() == 7, phase &
      " row State a-4 must be 7 after an ordinary accepted turn")
    checkValue(frameA1.hasAccepted and frameA1.rowsetReady,
      phase & " row-state turn keeps an accepted ready rowset")
    checkValue(frameA1.acceptedSource == sourceA and
      frameA1.acceptedOffset == OffsetA and frameA1.acceptedFirst == FirstA and
      frameA1.acceptedFinish == FinishA, phase &
        " row-local State write must not change source or numeric offset")
    checkValue(intentA1.valid and intentA1.desiredOffset == OffsetA and
      intentA1.appliedOffset == OffsetA, phase &
        " row-local State write must not change the scroll intent, got " &
        $intentA1.desiredOffset & "/" & $intentA1.appliedOffset)
    checkRowset(factsA1, phase & "_after_state", keys(FirstA, PrimeRows), FirstA,
      OffsetA, port, sourceA)
    checkCaptions(factsA1.filterIt(it.key == "a-4"), phase & "_state", @[7])
    checkBar(barOf(port), phase, BarMaxA, BarPosA)

    # Optional coverage addition: one receipted prepare-time creation failure on
    # the real A -> B step, then the accepted phase-A plan must still be whole.
    # Nothing here relaxes the B/C oracle below: the ordinary replay still runs
    # afterwards, over the recovered viewport.
    if createFailureMode:
      phase = "createFailure"
      # Never inject on top of an already broken ordinary run: the earlier checks
      # own that evidence and a rejection could not be attributed to this mode.
      require(failures == 0, "createFailure: the ordinary A checks must pass " &
        "before a creation failure is injected, got " & $failures & " failure(s)")
      let frameA2 = win.listFrameForTest(list)
      let intentA2 = win.listIntentForTest(list)
      let revisionA = rt.acceptedRevision
      let barA = barOf(port)
      echo "failure_premise a_source=", frameA2.acceptedSource, " a_offset=",
        frameA2.acceptedOffset, " a_range=", frameA2.acceptedFirst, "..",
        frameA2.acceptedFinish, " a_rows=", factsA1.len, " a_state=",
        oldAState.read(), " a_bar=", barA.info.nMin, "/", barA.info.nMax, "/",
        barA.info.nPage, "/", barA.info.nPos, " a_bar_ok=", barA.ok
      if not (frameA2.hasAccepted and frameA2.rowsetReady and intentA2.valid):
        blocked("createFailure: phase-A accepted frame/intent unreadable")
      if not barA.ok:
        blocked("createFailure: phase-A scrollbar unreadable (win32 error " &
          $barA.error & ")")
      # Arm only the one phase-B business commit: the viewport is the accepted A
      # viewport, and the seam refuses exactly one second direct row root there.
      let portA = port
      watchedPort = portA
      matchedCreates = 0
      # The premise above is already validated, so a refused page State write is a
      # contract failure, not an unproved premise.
      require(pageState.set(1) == StateWriteResult.queued,
        "createFailure: phase-B page State write must be queued after a valid A")
      var refused: ref CatchableError
      armed = true
      watchingDestroy = true
      try: discard rt.flush()
      except ProbeBlocked as error: raise error
      except CatchableError as error: refused = error
      finally:
        armed = false
        watchingDestroy = false
      echo "failure_injection matched_creates=", matchedCreates, " count=",
        injectionCount, " first_root=", cast[uint64](firstRoot), " destroyed=",
        destroyCount, " destroy_receipt=", destroyReceipt, " refused=",
        refused != nil
      if refused != nil:
        # The real caught text, so a passing run still shows the product message.
        echo "failure_caught_primary message=", refused.msg
      if injectionCount == 0:
        blocked("createFailure: the phase-B prepare never created a second direct " &
          "row root in the watched viewport (matched " & $matchedCreates &
          "), so no creation failure was injected")
      checkValue(injectionCount == 1,
        "createFailure: exactly one refused row-root creation, got " &
          $injectionCount)
      checkValue(matchedCreates == 2, "createFailure: the watched prepare creates " &
        "one real row root and then the refused one, got " & $matchedCreates)
      checkValue(refused != nil,
        "createFailure: a refused CreateWindowExW must fail the business commit")
      if refused == nil:
        raise newException(ProbeFailed,
          "createFailure: the commit survived a refused row-root creation")
      checkValue(refused.msg == "CreateWindowExW control failed: 1234",
        "createFailure: the refused creation must surface the exact native " &
          "primary error without a replay wrapper, got '" & refused.msg & "'")
      checkValue(firstRoot != nil,
        "createFailure: the first matched creation must really have produced a " &
          "native row root")
      # The orphaned first root really went away through the real DestroyWindow,
      # while the accepted viewport itself is still live. The destroy observer was
      # open for the whole business flush, so this is the exact call count.
      checkValue(destroyCount == 1 and destroyReceipt != 0,
        "createFailure: the created candidate root must be released exactly once " &
          "through the real DestroyWindow during the flush, got count " &
          $destroyCount & " receipt " & $destroyReceipt)
      checkValue(IsWindow(firstRoot) == 0,
        "createFailure: the released candidate root must not still be a window")
      checkValue(IsWindow(port) != 0,
        "createFailure: the accepted A viewport must survive the refusal")
      # A recovery is asserted from real identities only: the accepted plan, its
      # page State, the captured row State owner and the native rows.
      checkValue(pageState.read() == 0,
        "createFailure: the refused phase-B write must not publish, page State " &
          $pageState.read() & " must stay 0")
      checkValue(rt.acceptedRevision == revisionA,
        "createFailure: the refused commit must keep the accepted revision")
      checkValue(oldAState.read() == 7, "createFailure: the accepted source-A row " &
        "State owner must still read 7, got " & $oldAState.read())
      let frameR = win.listFrameForTest(list)
      let intentR = win.listIntentForTest(list)
      checkValue(frameR.hasAccepted and frameR.rowsetReady,
        "createFailure: the accepted rowset must stay ready")
      checkValue(frameR.acceptedToken == frameA2.acceptedToken and
        frameR.acceptedSource == frameA2.acceptedSource and
        frameR.acceptedOffset == OffsetA and frameR.acceptedFirst == FirstA and
        frameR.acceptedFinish == FinishA and
        frameR.acceptedRows == frameA2.acceptedRows, "createFailure: the " &
          "accepted plan must be identical after the refusal (token " &
          $frameR.acceptedToken & " vs " & $frameA2.acceptedToken & ")")
      checkValue(intentR.valid and intentR.desiredOffset == OffsetA and
        intentR.appliedOffset == OffsetA,
        "createFailure: the accepted intent must stay 106, got " &
          $intentR.desiredOffset & "/" & $intentR.appliedOffset)
      let factsR = rowsOf(win, session, list)
      require(factsR.len > 0, "createFailure: recovery contract violated: the " &
        "accepted viewport exposes no typed native row")
      # Full identity equality with the accepted phase-A rowset: not only the
      # viewport address but every row HWND, key, source generation, parent,
      # device rect and visibility must be the same real windows. A rejection that
      # silently rebuilt the accepted rows cannot pass this.
      checkValue(factsR == factsA1, "createFailure: the accepted six rows must be " &
        "the identical native rowset after the refusal, got " &
        describeRows(factsR) & " vs " & describeRows(factsA1))
      checkRowset(factsR, phase, keys(FirstA, PrimeRows), FirstA, OffsetA, port,
        sourceA)
      checkCaptions(factsR, phase, @[7, 0, 0, 0, 0, 0])
      let barR = barOf(port)
      checkBar(barR, phase, BarMaxA, BarPosA)
      echo "failure_restore port_same=", factsR[0].parent == portA, " rows=",
        factsR.len, " ", describeRows(factsR), " token=", frameR.acceptedToken,
        " source=", frameR.acceptedSource, " offset=", frameR.acceptedOffset,
        " range=", frameR.acceptedFirst, "..", frameR.acceptedFinish,
        " intent=", intentR.appliedOffset, "/", intentR.desiredOffset, " bar=",
        barR.info.nMin, "/", barR.info.nMax, "/", barR.info.nPage, "/",
        barR.info.nPos, " page_state=", pageState.read(), " row_state=",
        oldAState.read(), " revision=", rt.acceptedRevision
      guardContract(phase, "rejection and accepted-plan recovery")
      # Two quiet turns: no hidden retry of the refused phase-B commit.
      let quietA = rt.acceptedRevision
      for turn in 0 ..< 2: win.safeListTurn()
      let frameQ = win.listFrameForTest(list)
      let intentQ = win.listIntentForTest(list)
      let factsQ = rowsOf(win, session, list)
      let barQ = barOf(port)
      echo "failure_quiet revision_before=", quietA, " revision_after=",
        rt.acceptedRevision, " page_state=", pageState.read(), " row_state=",
        oldAState.read(), " rows=", factsQ.len, " token=", frameQ.acceptedToken,
        " source=", frameQ.acceptedSource, " offset=", frameQ.acceptedOffset
      checkValue(rt.acceptedRevision == quietA and pageState.read() == 0 and
        oldAState.read() == 7, "createFailure: quiet turns must not retry or " &
          "publish the refused phase-B commit")
      checkValue(frameQ.hasAccepted and frameQ.rowsetReady,
        "createFailure: quiet turns must keep a ready accepted rowset")
      checkValue(frameQ.acceptedToken == frameA2.acceptedToken and
        frameQ.acceptedSource == frameA2.acceptedSource and
        frameQ.acceptedOffset == OffsetA and frameQ.acceptedFirst == FirstA and
        frameQ.acceptedFinish == FinishA and
        frameQ.acceptedRows == frameA2.acceptedRows,
        "createFailure: quiet turns must keep " &
          "the accepted plan identity")
      checkValue(intentQ.valid and intentQ.desiredOffset == OffsetA and
        intentQ.appliedOffset == OffsetA,
        "createFailure: quiet turns must keep the accepted intent 106")
      # Whole-row equality plus the real native captions: quiet metadata identity
      # alone would not prove the rendered text stayed the accepted text.
      checkValue(factsQ == factsR, "createFailure: quiet turns must keep the " &
        "identical native rowset, got " & describeRows(factsQ))
      checkCaptions(factsQ, phase & "_quiet", @[7, 0, 0, 0, 0, 0])
      checkBar(barQ, phase & "_quiet", BarMaxA, BarPosA)
      guardContract(phase & "_quiet", "two quiet turns without a hidden retry")
      # Only one explicit write proves the accepted row owner is still alive: the
      # capture above already showed 7, so a live owner must accept 9.
      if oldAState.set(9) != StateWriteResult.queued:
        raise newException(ProbeFailed,
          "createFailure: a live accepted row State must accept the write 9")
      discard rt.flush()
      for turn in 0 ..< 2: win.safeListTurn()
      let factsL = rowsOf(win, session, list)
      let frameL = win.listFrameForTest(list)
      let intentL = win.listIntentForTest(list)
      require(factsL.len > 0, "createFailure: the accepted row-state turn must " &
        "keep native rows, got none")
      echo "failure_state_alive row_state=", oldAState.read(), " rows=",
        factsL.len, " ", describeRows(factsL), " source=", frameL.acceptedSource,
        " offset=", frameL.acceptedOffset, " range=", frameL.acceptedFirst, "..",
        frameL.acceptedFinish, " token=", frameL.acceptedToken, " revision=",
        rt.acceptedRevision
      checkValue(oldAState.read() == 9, "createFailure: the accepted row State " &
        "owner must still be writable after the refusal, got " & $oldAState.read())
      # This is a new, successfully committed business write, so the backend may
      # publish a new accepted frame/token here. Only the numeric plan, the typed
      # rows and the rendered State value are contractual; the token is printed
      # above and deliberately not pinned.
      checkValue(frameL.hasAccepted and frameL.rowsetReady,
        "createFailure: the live row-State turn must keep a ready accepted rowset")
      checkValue(frameL.acceptedSource == sourceA and
        frameL.acceptedOffset == OffsetA and frameL.acceptedFirst == FirstA and
        frameL.acceptedFinish == FinishA, "createFailure: the live " &
          "row-State turn must keep the accepted plan (source " &
          $frameL.acceptedSource & ")")
      checkValue(intentL.valid and intentL.desiredOffset == OffsetA and
        intentL.appliedOffset == OffsetA,
        "createFailure: the live row-State turn must keep the numeric intent 106")
      checkValue(pageState.read() == 0,
        "createFailure: the live row-State turn must not publish phase B")
      checkValue(factsL == factsA1, "createFailure: the live row-State turn must " &
        "keep the identical native rowset, got " & describeRows(factsL))
      checkRowset(factsL, phase & "_alive", keys(FirstA, PrimeRows), FirstA,
        OffsetA, port, sourceA)
      checkCaptions(factsL, phase & "_alive", @[9, 0, 0, 0, 0, 0])
      checkBar(barOf(port), phase & "_alive", BarMaxA, BarPosA)
      if failures != 0:
        # Preserve the failure evidence and do not continue into B/C to force a
        # green run: a broken recovery makes the later phases meaningless.
        raise newException(ProbeFailed,
          "createFailure: the recovery contract failed, phase B/C not run")

    # Phase B: two keys inserted in front. The numeric offset is retained, so the
    # rows keep their geometry and slide by key only.
    phase = "phaseB"
    if pageState.set(1) != StateWriteResult.queued:
      raise newException(ProbeFailed, "phaseB: page State write must be queued")
    discard rt.flush()
    for turn in 0 ..< 4: win.safeListTurn()
    let frameB = win.listFrameForTest(list)
    let intentB = win.listIntentForTest(list)
    let factsB = rowsOf(win, session, list)
    let sourceB = frameB.acceptedSource
    echo "phaseB source=", sourceB, " offset=", frameB.acceptedOffset, " desired=",
      intentB.desiredOffset, " applied=", intentB.appliedOffset, " range=",
      frameB.acceptedFirst, "..", frameB.acceptedFinish, " rows=", factsB.len, " ",
      describeRows(factsB)
    checkValue(sourceB != sourceA, phase & " source generation must change for the " &
      "new key set (" & $sourceA & " -> " & $sourceB & ")")
    checkValue(intentB.valid and intentB.desiredOffset == OffsetA and
      intentB.appliedOffset == OffsetA, phase &
        " insert must retain the numeric offset 106, got " & $intentB.desiredOffset &
        "/" & $intentB.appliedOffset)
    checkValue(frameB.hasAccepted and frameB.rowsetReady, phase & " rowset ready")
    checkValue(frameB.acceptedOffset == OffsetA, phase & " accepted offset " &
      $frameB.acceptedOffset & " must be 106")
    checkValue(frameB.acceptedFirst == FirstA and frameB.acceptedFinish == FinishA,
      phase & " range must stay 4..10, got " & $frameB.acceptedFirst & ".." &
        $frameB.acceptedFinish)
    checkRowset(factsB, phase, keys(2, PrimeRows), FirstA, OffsetA, port, sourceB)
    checkCaptions(factsB, phase, @[0, 0, 0, 0, 0, 0])
    # The same logical row moved: old index 4 top -10, new index 6 top 38. It was
    # not anchored to 144 and the old first key a-4 is not chased either.
    var movedA4: RowFact
    var foundA4 = false
    for fact in factsB:
      if fact.key == "a-4":
        movedA4 = fact
        foundA4 = true
    checkValue(foundA4, phase & " native rowset must still contain a-4")
    if foundA4:
      checkValue(movedA4.index == 6 and movedA4.rect.top == 38, phase &
        " a-4 must move from index 4 @ -10 to index 6 @ 38, got index " &
        $movedA4.index & " @ " & $movedA4.rect.top)
      checkValue(movedA4.index * 24 - OffsetA == 38, phase & " literal oracle a-4")
    checkBar(barOf(port), phase, BarMaxB, BarPosB)
    # The old source's row State owners must be retired, not rebound.
    require("a-4" in rowStates,
      "phaseB: the new source-B row a-4 State was never registered")
    let oldDisposition = oldAState.set(8)
    checkValue(oldDisposition == StateWriteResult.disposed, phase &
      " the accepted source-A row State must be disposed, not queued, got " &
      $oldDisposition)
    checkValue(rowStates["a-4"].read() == 0, phase &
      " the fresh source-B row State for a-4 must start at 0, got " &
      $rowStates["a-4"].read())
    echo "phaseB_state old_disposition=", oldDisposition, " old_queued=",
      oldDisposition == StateWriteResult.queued, " fresh=",
      rowStates["a-4"].read()

    # Phase C: the two inserted keys are deleted again. The numeric offset stays.
    phase = "phaseC"
    if pageState.set(2) != StateWriteResult.queued:
      raise newException(ProbeFailed, "phaseC: page State write must be queued")
    discard rt.flush()
    for turn in 0 ..< 4: win.safeListTurn()
    let frameC = win.listFrameForTest(list)
    let intentC = win.listIntentForTest(list)
    let factsC = rowsOf(win, session, list)
    let sourceC = frameC.acceptedSource
    echo "phaseC source=", sourceC, " offset=", frameC.acceptedOffset, " desired=",
      intentC.desiredOffset, " applied=", intentC.appliedOffset, " range=",
      frameC.acceptedFirst, "..", frameC.acceptedFinish, " rows=", factsC.len, " ",
      describeRows(factsC)
    checkValue(sourceC != sourceB, phase & " source generation must change again (" &
      $sourceB & " -> " & $sourceC & ")")
    checkValue(intentC.valid and intentC.desiredOffset == OffsetA and
      intentC.appliedOffset == OffsetA, phase &
        " delete must retain the numeric offset 106, got " & $intentC.desiredOffset &
        "/" & $intentC.appliedOffset)
    checkValue(frameC.hasAccepted and frameC.rowsetReady, phase & " rowset ready")
    checkValue(frameC.acceptedOffset == OffsetA and frameC.acceptedFirst == FirstA and
      frameC.acceptedFinish == FinishA, phase &
        " accepted offset/range must be 106 and 4..10, got " &
        $frameC.acceptedOffset & " and " & $frameC.acceptedFirst & ".." &
        $frameC.acceptedFinish)
    checkRowset(factsC, phase, keys(FirstA, PrimeRows), FirstA, OffsetA, port, sourceC)
    checkCaptions(factsC, phase, @[0, 0, 0, 0, 0, 0])
    var staleB = false
    for fact in factsC:
      if fact.key == "a-2": staleB = true
    checkValue(not staleB, phase & " the key a-2 must leave the phase-C " &
      "visible rowset instead of being anchored (it is inside the B window only)")
    checkBar(barOf(port), phase, BarMaxA, BarPosA)

    # Two quiet turns: nothing retries, nothing drifts.
    phase = "quiet"
    let settledRevision = rt.acceptedRevision
    let factsSettled = factsC
    for turn in 0 ..< 2: win.safeListTurn()
    let factsQuiet = rowsOf(win, session, list)
    let quietIntent = win.listIntentForTest(list)
    let quietFrame = win.listFrameForTest(list)
    let quietBar = barOf(port)
    echo "quiet revision_before=", settledRevision, " revision_after=",
      rt.acceptedRevision, " state=", pageState.read(), " offset=",
      quietFrame.acceptedOffset, " rows=", factsQuiet.len
    checkValue(pageState.read() == 2, phase & " page State must stay at 2")
    checkValue(rt.acceptedRevision == settledRevision, phase &
      " quiet turns must not publish another accepted revision")
    checkValue(quietIntent.valid and quietIntent.desiredOffset == OffsetA and
      quietIntent.appliedOffset == OffsetA, phase & " quiet intent stays 106")
    checkValue(quietFrame.hasAccepted and quietFrame.rowsetReady and
      quietFrame.acceptedToken == frameC.acceptedToken and
      quietFrame.acceptedRows.len == frameC.acceptedRows.len and
      quietFrame.acceptedSource == sourceC and
      quietFrame.acceptedOffset == OffsetA and quietFrame.acceptedFirst == FirstA and
      quietFrame.acceptedFinish == FinishA, phase &
        " quiet turns must keep the accepted phase-C frame identity (token " &
        $quietFrame.acceptedToken & " vs " & $frameC.acceptedToken & ", rows " &
        $quietFrame.acceptedRows.len & " vs " & $frameC.acceptedRows.len & ")")
    checkValue(factsQuiet.len == factsSettled.len, phase & " quiet row count unchanged")
    for step in 0 ..< min(factsQuiet.len, factsSettled.len):
      checkValue(factsQuiet[step].index == factsSettled[step].index and
        factsQuiet[step].key == factsSettled[step].key and
        factsQuiet[step].source == factsSettled[step].source and
        factsQuiet[step].window == factsSettled[step].window and
        factsQuiet[step].parent == factsSettled[step].parent and
        factsQuiet[step].rect == factsSettled[step].rect and
        factsQuiet[step].visible, phase & " quiet row " &
          $factsQuiet[step].index & " must stay identical")
    checkCaptions(factsQuiet, phase, @[0, 0, 0, 0, 0, 0])
    checkBar(quietBar, phase, BarMaxA, BarPosA)

    let passMarker = if createFailureMode: "PASS-source-edits-create-failure"
                     else: "PASS-source-edits-coverage"
    classification = if failures == 0: passMarker else: "FAIL-geometry"
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
    echo "actual_primary phase=", phase, " type=", primary.name,
      " msg=", primary.msg
  if secondary != nil:
    echo "actual_secondary type=", secondary.name, " msg=", secondary.msg
  echo "close_attempts=", (if h == nil: 0 else: 1), " failures=", failures
  if secondary != nil:
    echo "status=FAIL-close original_status=", classification
    return 1
  echo "probe_win32_list_source_edits status=", classification
  if classification.startsWith("NotRun"): return 2
  if classification.startsWith("PASS"): return 0
  1

when isMainModule:
  quit(main())
