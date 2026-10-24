## T2 keyboard gate: a list viewport must take native keyboard scrolling, and a
## focused in-row EDIT must keep its own key semantics.
##
## Standalone suite: the frozen lists/navigation suites are NOT imported (they
## would run their own cases). The fixture/query helpers below are copied
## minimally from those files, and every observation is either a real HWND fact
## (style, focus, client rect, row window rects, scroll info, EDIT selection) or
## a scalar from the existing test-only probes (`listIntentForTest` /
## `listFrameForTest`). No product API is added and no second scroll authority is
## introduced: the expected mapping is the documented `list_host.handleScrollCode`
## semantics (line = row height, page = viewport - row height, HOME = 0,
## END = clamped maximum offset).
##
## All three cases use the real managed Runtime, a real Win32Host/BackendSession
## and the production `safeListTurn`, never a direct `handleScrollCode` call.
## Cases 1/2 send `WM_KEYDOWN` directly to check intent and EDIT isolation.
##
## Case 3 posts keys through the real thread queue and `host.pump`, retaining the
## real `IsDialogMessageW` result; it checks six scroll keys and forward Tab from
## a preceding button into the viewport and out to the following button.
## Physical input, Shift+Tab, full tab order, IME and visuals remain unverified.
when not defined(windows):
  {.error: "Win32 list keyboard suite requires Windows".}
# The intent scalars (`desiredOffset`/`appliedOffset`/`intentGeneration`) exist
# only under `-d:leafProtocolProbes`. The canonical runner
# (`scripts/test_win32.nim`) does not define it, so this suite must still
# compile and run there: without probes it asserts every real HWND fact
# (style/focus/DLGCODE/client+row rects/scrollbar/EDIT selection) and reports the
# intent scalars as unavailable instead of inventing them. The authorized Native
# RED build passes `-d:leafProtocolProbes` and gets the full intent evidence.

import std/[unittest, strutils, algorithm, widestrs, math, tables, sequtils]
import ../fixture_app
import leaf/[core, widgets, backend, backend_session, native_layout, ui_thread]
import leaf/backends/win32/[api, host, backend, calls]
# `MinScrollUnit` / `MaxScrollUnits` are the frozen public scrollbar grain this
# suite mirrors independently (the same constants the old navigation suite used).
import leaf/backends/win32/list_host

const
  ItemCount = 10_000
  RowHeight = 24.0
  ViewportDip = 120.0
  PoolBudgetRows = 8                  ## RowPool.MaxParkedRows
  TolerancePx = 1.5                   ## row-edge rounding at non-96 DPI
  ## Keyboard facts (local constants: this suite must not widen `api.nim` first).
  VkUp = 0x26'u32
  VkDown = 0x28'u32
  VkHome = 0x24'u32
  VkEnd = 0x23'u32
  VkPrior = 0x21'u32                 ## VK_PRIOR = Page Up
  VkNext = 0x22'u32                  ## VK_NEXT = Page Down
  VkLeft = 0x25'u32
  VkRight = 0x27'u32
  VkReturn = 0x0D'u32
  DlgcWantArrows = 1'i64
  DlgcWantAllKeys = 4'i64
  EmGetSel = EM_GETSEL             ## 0x00B0, already exported
  EmSetSel = EM_SETSEL             ## 0x00B1, already exported

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

proc nativeText(window: HWND): string =
  let size = GetWindowTextLengthW(window) + 1
  let value = newWideCString(int(size))
  discard GetWindowTextW(window, cast[WidePtr](unsafeAddr value[0]), size)
  $value

proc nativeClass(window: HWND): string =
  ## Raw class name as Windows reports it. Win32 registers the edit control as
  ## "Edit", not "EDIT"; callers must not assume one casing.
  let value = newWideCString(64)
  discard GetClassNameW(window, cast[WidePtr](unsafeAddr value[0]), 64)
  $value

proc isEditClass(window: HWND): bool =
  ## Case-insensitive: Win32 reports "Edit", the Win32 headers use "EDIT", and
  ## neither is more correct than the other. Comparing exact strings made the
  ## in-row editor look absent on a real run - a fixture bug, not a product gap.
  cmpIgnoreCase(nativeClass(window), "EDIT") == 0

type Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession,
                     runtime: Runtime, activity: UiScopeActivity]

proc openHost(): Win32Host =
  createHost("T2 keyboard", DipSize(width: 480, height: 320))

proc mounted(render: proc(): Node): Fixture =
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(
    fixtureApplication(render, "T2 keyboard", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = openHost()
  h.setStartupScope(proc(): bool =
    activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win = newWin32Backend(h)
  let session = win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime, activity)

proc mountedWith(render: proc(): Node, calls: Win32Calls): Fixture =
  ## Same real Runtime/host/backend wiring as `mounted`, but with an injected
  ## `Win32Calls` so case3 can count real `IsDialogMessageW` invocations. The
  ## cases 1/2 fixture is untouched.
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(
    fixtureApplication(render, "T2 keyboard", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("T2 keyboard", DipSize(width: 480, height: 320), calls)
  h.setStartupScope(proc(): bool =
    activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win = newWin32Backend(h, calls)
  let session = win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime, activity)

proc settle(f: Fixture) = f.win.safeListTurn()

proc runTurn(f: Fixture, body: proc()) =
  ## One production safe turn inside a real pump, then a normal close.
  f.h.setSafeTick(proc() =
    body()
    f.h.requestClose())
  check f.h.pump() == 0

proc compoundRow(index: int): Node =
  row(@[
    text("item " & $index, key = "label"),
    input("", key = "edit"),
    button("act " & $index, key = "button")], key = "row")

proc listRender(): Node =
  var keys: seq[string] = @[]
  for index in 0 ..< ItemCount: keys.add($index)
  column(@[virtualList("list", keys, proc(index: int): Node = compoundRow(index),
    rowHeight = RowHeight, overscan = 0,
    styles = style({"height": $int(ViewportDip)}))], key = "root")

proc keyedRender(): Node =
  ## case3 fixture: three tab-stop siblings around the frozen 120-DIP list, so a
  ## real forward Tab traversal has a place to start and a place to leave to. The
  ## list keeps the original `compoundRow` children.
  var keys: seq[string] = @[]
  for index in 0 ..< ItemCount: keys.add($index)
  column(@[
    button("before", key = "before"),
    virtualList("list", keys, proc(index: int): Node = compoundRow(index),
      rowHeight = RowHeight, overscan = 0,
      styles = style({"height": $int(ViewportDip)})),
    button("after", key = "after")], key = "root")

proc viewports(h: Win32Host): seq[HWND] =
  for window in descendants(h.windowHandle):
    if (styleOf(window) and WS_VSCROLL) != 0: result.add(window)

proc rowRoots(viewport: HWND): seq[HWND] =
  for window in descendants(viewport):
    if GetParent(window) == viewport: result.add(window)

proc clippedRows(viewport: HWND): seq[tuple[y: int32, text: string]] =
  ## Row roots actually intersecting the viewport client area, with their first
  ## own child text; a fully off-screen row is never reported as visible.
  var client: RECT
  if GetClientRect(viewport, addr client) == 0: return
  if client.right <= 0 or client.bottom <= 0: return
  for rowWindow in rowRoots(viewport):
    if IsWindowVisible(rowWindow) == 0: continue
    var rect: RECT
    if GetWindowRect(rowWindow, addr rect) == 0: continue
    var corners = [POINT(x: rect.left, y: rect.top),
      POINT(x: rect.right, y: rect.bottom)]
    discard MapWindowPoints(nil, viewport, addr corners[0], 2)
    if corners[1].y <= 0 or corners[0].y >= client.bottom: continue
    var label = ""
    for child in descendants(rowWindow):
      if GetParent(child) != rowWindow: continue
      let value = nativeText(child)
      if value.len > 0: label = value; break
    result.add((corners[0].y, label))
  result.sort(proc(a, b: tuple[y: int32, text: string]): int = cmp(a.y, b.y))

proc orderedRowTexts(viewport: HWND): seq[string] =
  for item in clippedRows(viewport): result.add(item.text)

proc rowLine(viewport: HWND): string =
  ## `(y,text)` list, kept raw in the log so a Native RED shows actual placement.
  for item in clippedRows(viewport): result.add("(" & $item.y & "," & item.text & ")")

proc editorIn(rowWindow: HWND): HWND =
  for child in descendants(rowWindow):
    if isEditClass(child): return child

proc barOf(viewport: HWND): SCROLLINFO =
  result = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)),
    fMask: SIF_RANGE or SIF_PAGE or SIF_POS)
  if GetScrollInfo(viewport, SB_VERT, addr result) == 0: result.cbSize = 0

proc viewportDip(port: HWND): float64 =
  var client: RECT
  if GetClientRect(port, addr client) == 0: return 0.0
  let dpi = GetDpiForWindow(port)
  if dpi == 0: return 0.0
  let scale = float64(dpi) / 96.0
  float64(client.bottom - client.top) / scale

proc listHandleOf(f: Fixture): NodeHandle =
  var count = 0
  for entity in f.s.acceptedEntities().values:
    if entity.kind == NodeKind.virtualList:
      inc count
      result = entity.handle
  check count == 1

type Snapshot = object
  hasIntent: bool                    ## listIntentForTest.valid
  hasFrame: bool                     ## listFrameForTest.hasAccepted (variable rows)
  desired, applied: float64
  intent: uint64
  revision: uint64
  acceptedFirst, acceptedFinish: int
  rows: seq[string]
  line: string
  bar: SCROLLINFO
  barOk: bool

proc snap(f: Fixture, port: HWND, list: NodeHandle): Snapshot =
  ## Intent and variable-frame facts are INDEPENDENT observations.
  ##
  ## This fixture uses uniform rows (`rowHeight`), so the backend takes the legacy
  ## uniform projection (`backend.nim`, "Uniform rows keep the legacy projection")
  ## and never creates a variable `acceptedFrame`: `hasAccepted` is *expected* to
  ## be false here and is NOT a product gap. Requiring it would have been a fixture
  ## bug that masks the real intent scalars. The intent probe is therefore kept
  ## whenever it is valid, with the accepted-range checks only applied when a
  ## variable frame actually exists.
  when defined(leafProtocolProbes):
    let intent = f.win.listIntentForTest(list)
    result.hasIntent = intent.valid
    if intent.valid:
      result.desired = intent.desiredOffset
      result.applied = intent.appliedOffset
      result.intent = intent.intentGeneration
    let frame = f.win.listFrameForTest(list)
    result.hasFrame = frame.hasAccepted
    if frame.hasAccepted:
      result.acceptedFirst = frame.acceptedFirst
      result.acceptedFinish = frame.acceptedFinish
  result.revision = f.runtime.acceptedRevision
  result.rows = orderedRowTexts(port)
  result.line = rowLine(port)
  result.bar = barOf(port)
  result.barOk = result.bar.cbSize != 0

proc describe(s: Snapshot): string =
  let scalars =
    if not s.hasIntent:
      "desired/applied/intent=unavailable(no leafProtocolProbes)"
    elif s.hasFrame:
      "desired=" & $s.desired & " applied=" & $s.applied &
        " intent=" & $s.intent & " accepted=[" & $s.acceptedFirst & "," &
        $s.acceptedFinish & ")"
    else:
      "desired=" & $s.desired & " applied=" & $s.applied &
        " intent=" & $s.intent & " accepted=n/a(uniform rows: no variable frame)"
  scalars & " rev=" & $s.revision & " rows=" & s.rows.join("|")

const IntentNote = when defined(leafProtocolProbes): "" else:
  " [intent scalars unavailable: rebuild with -d:leafProtocolProbes]"

proc checkFrameStable(pre, post: Snapshot) =
  ## The *applied* frame must not move: a message handler records intent only and
  ## never lays out or commits. `desired`/`intentGeneration` are deliberately NOT
  ## compared here - in case1 that is exactly what the key is supposed to change.
  ## The variable-frame range is only comparable when such a frame exists.
  if pre.hasIntent and post.hasIntent:
    check post.applied == pre.applied
  if pre.hasFrame and post.hasFrame:
    check post.acceptedFirst == pre.acceptedFirst
    check post.acceptedFinish == pre.acceptedFinish

proc checkNoIntent(pre, post: Snapshot) =
  ## Nothing at all moved: no scroll intent was even recorded. This is the case2
  ## contract (a focused EDIT's ordinary keys never reach the list) and the
  ## Enter-submit contract. Not usable for case1, where the key must move intent.
  if pre.hasIntent and post.hasIntent:
    check post.desired == pre.desired
    check post.applied == pre.applied
    check post.intent == pre.intent
  if pre.hasFrame and post.hasFrame:
    check post.acceptedFirst == pre.acceptedFirst
    check post.acceptedFinish == pre.acceptedFinish

proc checkDesired(s: Snapshot, expected: float64) =
  if not s.hasIntent: return
  check abs(s.desired - expected) <= TolerancePx

proc keyDown(port: HWND, vk: uint32): LRESULT =
  ## Real viewport message path: exactly the WM_KEYDOWN a focused control gets.
  ## The dialog-manager *declaration* is asserted separately via WM_GETDLGCODE.
  ## pump's IsDialogMessageW routing is not covered by this suite.
  SendMessageW(port, WM_KEYDOWN, WPARAM(vk), 0)

proc firstRowAt(offsetDip, viewport, total: float64): int =
  ## The row whose top edge is at/above the clamped offset: the only row index a
  ## correct frame can start at. Boundary-adjacent offsets are snapped, since the
  ## product rounds row edges to physical pixels.
  let reach = max(0.0, total - viewport)
  let start = clamp(offsetDip, 0.0, reach)
  let ratio = start / RowHeight
  let nearest = round(ratio)
  let index = if abs(ratio - nearest) < 1e-4: int(nearest) else: int(floor(ratio))
  clamp(index, 0, ItemCount - 1)

proc frameRowCount(offsetDip, viewport, total: float64): int =
  ## Exact number of rows the viewport shows for this offset.
  ##
  ## The scrolled offset need not be a row multiple (`SB_LINEUP`/`PAGE` move by
  ## offsets, not rows), so the first visible row is partially clipped at the top
  ## and the viewport still holds `ceil((offset %% 24 + viewport) / 24)` rows -
  ## whole rows plus whatever it takes to reach the bottom edge. Computing it from
  ## the offset keeps an edge row counted when it genuinely exists and refuses to
  ## invent one when it does not; it never hard-codes the viewport size, so a
  ## different DPI or client height stays correct.
  let reach = max(0.0, total - viewport)
  let start = clamp(offsetDip, 0.0, reach)
  let remainder = start - floor(start / RowHeight) * RowHeight
  let visible = ceil((remainder + viewport) / RowHeight)
  clamp(int(visible), 1, ItemCount)

type BarModel = object
  ## Independent projection of the frozen public scrollbar maths
  ## (`list_host.scrollUnit` / `scrollUnits` / `scrollPage` / `scrollPosForOffset`
  ## / `syncScrollbar`), recomputed here from known geometry only. Nothing is read
  ## back from the real `nMax`, so a product change cannot move the expectation.
  unit: float64
  units: int32                       ## ceil(reach / unit): the inclusive range body
  page: int32                        ## round(viewport / unit), at least 1
  nMax: int32                        ## units + (page - 1)
  posAtReach: int32                  ## clamp(round(reach / unit), 0, units)
  effectiveMax: int32                ## nMax - (page - 1): the largest legal nPos

proc barModel(viewport, total: float64): BarModel =
  let reach = max(0.0, total - viewport)
  # `scrollUnit` scales with the larger of reach/viewport so the unit count stays
  # under MaxScrollUnits; MinScrollUnit is the floor for small content.
  let unit = max(MinScrollUnit,
    max(reach, viewport) / float64(MaxScrollUnits))
  result.unit = unit
  result.units =
    if reach <= 0.0: 0'i32
    else: int32(min(float64(MaxScrollUnits), ceil(reach / unit)))
  result.page =
    if viewport <= 0.0: 0'i32
    else: int32(max(1.0, round(viewport / unit)))
  result.nMax = int32(clamp(int64(result.units) +
    max(0'i64, int64(result.page) - 1), 0'i64, int64(high(int32))))
  result.posAtReach = int32(clamp(round(reach / unit), 0.0,
    float64(result.units)))
  result.effectiveMax = int32(clamp(int64(result.nMax) -
    max(0'i64, int64(result.page) - 1), 0'i64, int64(high(int32))))

proc describeBar(m: BarModel): string =
  "unit=" & $m.unit & " units=" & $m.units & " page=" & $m.page &
    " nMax=" & $m.nMax & " posAtReach=" & $m.posAtReach &
    " effectiveMax=" & $m.effectiveMax

proc checkBarAtReach(info: SCROLLINFO, m: BarModel) =
  ## The end-of-list scrollbar must match the independent model exactly, with the
  ## one documented exception this suite has to state out loud:
  ##
  ## `scrollUnits` uses `ceil` so the range still covers the whole reach, while
  ## `scrollPosForOffset` uses `round`, so for a reach that is not a whole number
  ## of units (239880/32 = 7496.25) the two differ by exactly one unit. The frozen
  ## `test_win32_list_navigation.nim` accepts the same one-unit delta
  ## ("tolerance=1 unit"). Accepting it here is therefore NOT a free +/-1: it is
  ## only allowed when the round model lands exactly on `units - 1`, and the range
  ## and page must still be exact.
  check info.nMin == 0
  check info.nMax == m.nMax
  check int32(info.nPage) == m.page
  check info.nPos == m.posAtReach
  let delta = abs(int64(info.nPos) - int64(m.posAtReach))
  echo "case1 at_end bar ", describeBar(m), " actual(nMax=", info.nMax,
    ",nPage=", info.nPage, ",nPos=", info.nPos, ")",
    " nPos_delta=", delta
  if delta != 0:
    # Only the ceil-vs-round grain: the rounded position sits one unit below the
    # ceil'd range body, so no DIP is left unreachable and nothing overruns.
    check m.posAtReach == m.units - 1
    check delta == 1
  # Whatever the grain, the readable position may never exceed the effective max.
  check info.nPos <= m.effectiveMax
  check info.nPos >= 0

proc rowLabels(first, count: int): seq[string] =
  for step in 0 ..< count:
    let row = first + step
    if row < ItemCount: result.add("item " & $row)

proc checkRows(rows: seq[string], first, count: int) =
  ## The frame must be exactly these consecutive rows. The expected count is
  ## derived from the real offset/viewport, so a missing edge row (real gap at the
  ## bottom) fails just as a phantom extra row or a wrong start does.
  let want = rowLabels(first, count)
  if rows != want:
    echo "  frame mismatch first=", first, " count=", count,
      " got=", rows.join("|"), " want=", want.join("|")
  check rows == want

# --- case3: real message-queue routing ----------------------------------------
#
# Cases 1/2 prove the `WM_GETDLGCODE` declaration and the key -> scroll mapping
# once a key reaches the viewport via `SendMessageW`. They say nothing about
# `host.pump`: whether a key posted into the thread queue is actually routed by
# the real `IsDialogMessageW`. That is case3, and it must be driven only through
# the real queue - no direct `IsDialogMessageW`, no `DispatchMessage`, no
# synthetic MSG.

const
  VkTab = 0x09'u32                    ## VK_TAB (absent from api.nim: local only)
  GwlexStyle = -20'i32                ## GWL_EXSTYLE (absent from api.nim: local only)
  WsExControlParent = 0x00010000'i32  ## WS_EX_CONTROLPARENT (local only)
  QueueStages = 32                    ## hard bound on queue phases
  PumpDeadlineMs = 10_000             ## leaves the outer 30s Native limit room

proc quitDeadline(window: HWND, message: UINT, timer: UINT_PTR,
                  time: DWORD) {.stdcall, raises: [].} =
  ## Bounded escape for a blocking `host.pump` (`test_component_tasks.nim`
  ## precedent): a real timer posts WM_QUIT so pump returns instead of hanging.
  discard KillTimer(nil, timer)
  PostQuitMessage(97)

proc boundedPump(h: Win32Host): int =
  let timer = SetTimer(nil, 0, PumpDeadlineMs, quitDeadline)
  if timer == 0: return -1
  try: result = h.pump()
  finally: discard KillTimer(nil, timer)

type KeyReceipt = object
  ## One real `WM_KEYDOWN` as seen by the wrapper, recorded AFTER the original
  ## `IsDialogMessageW` returned so the real routing result is part of the
  ## evidence. `seq` is a monotonic ordinal, never reused.
  seq: int
  window: HWND
  vk: uint32
  consumed: bool                      ## original IsDialogMessageW returned != 0

type DialogRoute = ref object
  ## Counting wrapper around the *real* `IsDialogMessageW` binding. It never
  ## fabricates or alters the result: it records the call, defers to the original
  ## function, and only then stores the receipt, so `host.dispatch`'s branching is
  ## untouched.
  inner: proc(window: HWND, message: ptr MSG): BOOL {.closure, raises: [CatchableError].}
  calls: int
  receipts: seq[KeyReceipt]

proc countingCalls(inner: Win32Calls, route: DialogRoute): Win32Calls =
  result = inner
  let original = inner.dialogMessage
  route.inner = original
  route.receipts.setLen(0)
  result.dialogMessage = proc(window: HWND, message: ptr MSG): BOOL {.closure,
      raises: [CatchableError].} =
    inc route.calls
    # Snapshot the raw values BEFORE delegating: a delegate that mutates the MSG
    # must not be able to mis-bind the receipt to another window or key.
    var isKey = false
    var rawWindow: HWND = nil
    var rawVk = 0'u32
    if message != nil:
      isKey = message[].message == WM_KEYDOWN
      rawWindow = message[].hwnd
      rawVk = uint32(message[].wParam)
    let result0 = original(window, message)      # real routing result
    if isKey:
      let receipt = KeyReceipt(seq: route.receipts.len, window: rawWindow,
        vk: rawVk, consumed: result0 != 0)
      route.receipts.add(receipt)
      echo "case3 receipt seq=", receipt.seq, " target=",
        nativeClass(receipt.window) & "/" & nativeText(receipt.window),
        " vk=0x", toHex(int64(receipt.vk), 2),
        " consumed=", receipt.consumed
    result0

proc findReceipt(route: DialogRoute, window: HWND, vk: uint32,
                 floor = 0): KeyReceipt =
  ## Exact match on (target window, virtual key) at or after `floor`. `floor` is
  ## the receipt count recorded when the key was posted, so re-posting the same
  ## (window, key) can never be satisfied by an earlier receipt.
  ## Returns `seq: -1` when the key has not been routed yet.
  result.seq = -1
  for index in max(0, floor) ..< route.receipts.len:
    let receipt = route.receipts[index]
    if receipt.window == window and receipt.vk == vk:
      return receipt

proc hasReceipt(route: DialogRoute, window: HWND, vk: uint32,
                floor = 0): bool =
  findReceipt(route, window, vk, floor).seq >= 0

proc controlByText(parent: HWND, className, text: string): HWND =
  ## Unique (class, text) lookup anywhere under `parent`. Enumeration order is not
  ## used: the fixture's BUTTONs live under the root row's own HWND, not directly
  ## under the host window, so a direct-children scan finds none.
  var found: seq[HWND] = @[]
  for window in descendants(parent):
    if cmpIgnoreCase(nativeClass(window), className) != 0: continue
    if nativeText(window) == text: found.add(window)
  if found.len == 1: result = found[0]

suite "T2 list keyboard: viewport focus and arrow/page/home/end intent":
  test "viewport is focusable, claims arrow keys and maps keys to scroll intent only":
    let f = mounted(listRender)
    defer: f.h.destroyHost()
    var hostWindow: HWND = nil
    runTurn(f, proc() =
      f.settle()
      let ports = viewports(f.h)
      check ports.len == 1
      if ports.len != 1: return
      let port = ports[0]
      let list = f.listHandleOf
      let dip = viewportDip(port)
      echo "case1 viewport client_dip=", dip, " dpi=", GetDpiForWindow(port)
      check dip > 0.0
      if dip <= 0.0: return
      let total = float64(ItemCount) * RowHeight
      let reach = max(0.0, total - dip)
      let vis = frameRowCount(0.0, dip, total)
      echo "case1 whole_rows=", vis, " viewport_dip=", dip
      let top = firstRowAt(0.0, dip, total)
      # Effective page/line for this real viewport: line = measured row height,
      # page = viewport - row height (same as handleScrollCode).
      let page = max(RowHeight, dip - RowHeight)

      # --- premise facts (recorded, and each missing fact keeps the case going) --
      let tabStop = (styleOf(port) and WS_TABSTOP) != 0
      echo "case1 premise WS_TABSTOP=", tabStop, " style=0x",
        toHex(styleOf(port), 8)
      check tabStop
      let dlgCode = int64(SendMessageW(port, WM_GETDLGCODE, 0, 0))
      echo "case1 premise WM_GETDLGCODE=0x", toHex(dlgCode, 8),
        " wants_arrows=", (dlgCode and DlgcWantArrows) != 0,
        " wants_allkeys=", (dlgCode and DlgcWantAllKeys) != 0
      check (dlgCode and DlgcWantArrows) != 0
      discard SetFocus(port)
      let focused = GetFocus() == port
      echo "case1 premise SetFocus/GetFocus=", focused
      check focused

      let initial = f.snap(port, list)
      echo "case1 initial ", initial.describe, " line=", initial.line,
        " bar(nMin=", initial.bar.nMin, ",nMax=", initial.bar.nMax,
        ",nPage=", initial.bar.nPage, ",nPos=", initial.bar.nPos, ")"
      check initial.barOk
      checkRows(initial.rows, top, vis)
      check initial.rows.len > 0
      if initial.rows.len > 0: check initial.rows[0] == "item 0"
      if initial.hasIntent:
        check initial.desired == 0.0 and initial.applied == 0.0
      if initial.hasFrame:
        check initial.acceptedFirst == top
        check initial.acceptedFinish == top + initial.rows.len
      check initial.bar.nPos == 0
      # Range and page are pure geometry: exact at every offset, top included.
      let model = barModel(dip, total)
      check initial.bar.nMin == 0
      check initial.bar.nMax == model.nMax
      check int32(initial.bar.nPage) == model.page
      check f.win.diagnostics.liveRows == initial.rows.len

      # One keyboard step: real WM_KEYDOWN to the focused viewport -> the applied
      # frame must not move, then one production safeListTurn -> the applied frame
      # must land on the offset this test expects. pump's IsDialogMessageW routing
      # is out of scope here (only the WM_GETDLGCODE declaration is checked).
      proc step(vk: uint32, label: string, wantDesired: float64): float64 =
        ## `wantDesired` is this test's own independent expectation of where the
        ## key must land; probe scalars only confirm it, never define it. The
        ## return value is that clamped model, so chained steps stay independent
        ## of probe availability.
        let expected = clamp(wantDesired, 0.0, reach)
        let pre = f.snap(port, list)
        let delivered = keyDown(port, vk)
        let afterMessage = f.snap(port, list)
        echo "case1 ", label, " vk=0x", toHex(int64(vk), 2),
          " lresult=", delivered, " -> intent_only ", afterMessage.describe
        # intent-only: no accepted frame, no business revision, no native move
        check afterMessage.revision == pre.revision
        checkFrameStable(pre, afterMessage)
        check afterMessage.rows == pre.rows
        check afterMessage.line == pre.line
        # desired is the clamped request; only desired/intent may have moved
        echo "case1 ", label, " expected_desired=", expected, IntentNote,
          " actual_desired=", afterMessage.desired
        checkDesired(afterMessage, expected)
        # Generation follows the confirmed `requestViewport` guard
        # (`if next != list.desiredOffset:` inc) : a key that really moves the
        # offset must advance the generation exactly once, and a repeated key at a
        # clamped boundary must not advance it at all. Comparing against `expected`
        # rather than `afterMessage.desired` keeps this valid with or without probes.
        if afterMessage.hasIntent and pre.hasIntent:
          if abs(expected - pre.desired) > TolerancePx:
            check afterMessage.intent == pre.intent + 1
          else:
            check afterMessage.intent == pre.intent
        f.settle()
        let settled = f.snap(port, list)
        let first = firstRowAt(expected, dip, total)
        let count = frameRowCount(expected, dip, total)
        let want = rowLabels(first, count)
        echo "case1 ", label, " applied ", settled.describe,
          " line=", settled.line, " want=", want.join("|"),
          " bar(nMax=", settled.bar.nMax, ",nPage=", settled.bar.nPage,
          ",nPos=", settled.bar.nPos, ")"
        if settled.hasIntent:
          check abs(settled.applied - expected) <= TolerancePx
        # Range/page never depend on the offset, so they stay exact each time.
        check settled.bar.nMin == 0
        check settled.bar.nMax == model.nMax
        check int32(settled.bar.nPage) == model.page
        # nPos tracks this sample's offset under the same round model.
        let wantPos = int32(clamp(round(expected / model.unit), 0.0,
          float64(model.units)))
        check settled.bar.nPos == wantPos
        checkRows(settled.rows, first, count)
        check rowRoots(port).len <= vis + 1 + PoolBudgetRows
        check f.win.diagnostics.liveRows == settled.rows.len
        check settled.barOk
        expected

      # --- arrows: one row per key ------------------------------------------
      var current = step(VkDown, "down line", RowHeight)
      check current > 0.0
      current = step(VkDown, "down line 2", current + RowHeight)
      current = step(VkUp, "up line", current - RowHeight)
      # --- page: viewport - one row ----------------------------------------
      current = step(VkNext, "page down", current + page)
      current = step(VkPrior, "page up", current - page)
      # --- home / end -------------------------------------------------------
      current = step(VkHome, "home", 0.0)
      check current == 0.0
      current = step(VkEnd, "end", reach)
      check abs(current - reach) <= TolerancePx
      let atEnd = f.snap(port, list)
      echo "case1 at_end rows=", atEnd.rows.join("|"), " desired=",
        atEnd.desired, " applied=", atEnd.applied
      checkRows(atEnd.rows, firstRowAt(reach, dip, total),
        frameRowCount(reach, dip, total))
      check atEnd.rows.len > 0
      if atEnd.rows.len > 0:
        check atEnd.rows[^1] == "item " & $(ItemCount - 1)
      # The native scrollbar must expose this same reach. The expectation comes
      # from the independent `barModel` (geometry in, no read-back of nMax), not
      # from the width of the real range: see `checkBarAtReach` for the single
      # documented one-unit grain between `ceil` units and `round` positions.
      check atEnd.barOk
      checkBarAtReach(atEnd.bar, barModel(dip, total))
      # --- repeated key at the end must clamp, not overrun -------------------
      let endBefore = f.snap(port, list)
      current = step(VkEnd, "end repeat", reach)
      check abs(current - reach) <= TolerancePx
      let endAfter = f.snap(port, list)
      echo "case1 end_repeat rows=", endAfter.rows.join("|")
      check endAfter.rows == endBefore.rows
      check endAfter.bar.nPos == endBefore.bar.nPos
      current = step(VkDown, "down at end", reach)
      check abs(current - reach) <= TolerancePx
      check f.snap(port, list).rows == endBefore.rows
      # --- back to the top, and the start clamps too -----------------------
      current = step(VkHome, "home from end", 0.0)
      check current == 0.0
      check f.snap(port, list).rows == initial.rows
      current = step(VkHome, "home repeat", 0.0)
      check current == 0.0
      current = step(VkUp, "up at top", 0.0)
      check current == 0.0
      check f.snap(port, list).rows == initial.rows
      hostWindow = f.h.windowHandle)
    f.h.destroyHost()
    check f.h.resourcesReleasedInternal()
    check hostWindow != nil
    check IsWindow(hostWindow) == 0

  test "real pump routes posted Tab and arrow keys through IsDialogMessageW":
    # case3, first-round fixture correction. Everything comes from the real thread
    # queue: `PostMessageW` queues the key, the real `host.pump` consumes it, and
    # the real `IsDialogMessageW` binding routes it. No direct
    # `IsDialogMessageW`/`DispatchMessage`/`SendMessage`, no synthetic MSG.
    #
    # Anti-false-negative: the tick installed below is production-identical
    # (`safeListTurn` first, then observe), and a stage only advances after the
    # *matching* receipt (target window + virtual key) actually appeared. A stale
    # `WM_HOST_TICK` that wins the race just observes "not yet" and returns.
    let route = DialogRoute()
    let calls = countingCalls(systemWin32Calls(), route)
    let f = mountedWith(keyedRender, calls)
    var hostWindow: HWND = nil
    var before, after: HWND
    var port: HWND
    var list: NodeHandle
    var stages = 0
    var phase = "mount"
    var expectedWindow: HWND          # target of the key we are waiting for
    var expectedVk: uint32
    var expectedFrom = 0              # receipt floor recorded when the key was posted
    var phaseObserved = false

    proc label(window: HWND): string =
      nativeClass(window) & "/" & nativeText(window)

    proc failStage(reason: string) =
      echo "case3 FAIL phase=", phase, " stages=", stages, " reason=", reason,
        " expected_target=", label(expectedWindow), " expected_vk=0x",
        toHex(int64(expectedVk), 2), " focus=", label(GetFocus()),
        " receipts=", route.receipts.len, " calls=", route.calls,
        " viewport=", label(port)
      f.h.requestClose()
      check false

    proc postKey(target: HWND, vk: uint32, why: string) =
      ## Queue one real key, then exactly one FIFO sampling marker for it.
      ## Same thread, same queue: the key is queued before its marker, so the
      ## genuine key receipt always precedes the marker-driven observation. That
      ## makes the sample deterministic even for keys the list does NOT wake on
      ## (Tab is swallowed by `IsDialogMessageW` and never sets needsTick).
      if GetFocus() != target:
        failStage("focus is not the post target for " & why)
        return
      expectedWindow = target
      expectedVk = vk
      expectedFrom = route.receipts.len   # only receipts after this count count
      phaseObserved = false
      echo "case3 post key=", why, " target=", label(target), " vk=0x",
        toHex(int64(vk), 2), " focus=", label(GetFocus()),
        " floor=", expectedFrom
      if PostMessageW(target, WM_KEYDOWN, WPARAM(vk), 0) == 0:
        failStage("PostMessageW(WM_KEYDOWN) failed for " & why)
        return
      # The single marker for this key: the framework's own tick message, so the
      # ordinary `safeTick` observes the state left by this exact key.
      if PostMessageW(f.h.windowHandle, WM_HOST_TICK, 0, 0) == 0:
        failStage("PostMessageW(WM_HOST_TICK) marker failed for " & why)

    proc checkKeyRows(snap: Snapshot, wantOffset: float64) =
      ## Real row set + intent for one queued key, using the same independent
      ## geometry model as case1 (`firstRowAt`/`frameRowCount`).
      let dip = viewportDip(port)
      let total = float64(ItemCount) * RowHeight
      let reach = max(0.0, total - dip)
      let want = clamp(wantOffset, 0.0, reach)
      checkRows(snap.rows, firstRowAt(want, dip, total),
        frameRowCount(want, dip, total))
      check snap.rows.len > 0
      if snap.hasIntent:
        check abs(snap.desired - want) <= TolerancePx
        check abs(snap.applied - want) <= TolerancePx
      let model = barModel(dip, total)
      check snap.bar.nMin == 0
      check snap.bar.nMax == model.nMax
      check int32(snap.bar.nPage) == model.page
      check snap.bar.nPos == int32(clamp(round(want / model.unit), 0.0,
        float64(model.units)))

    proc observe() =
      ## Runs after the real `safeListTurn` in the same tick (production shape).
      if phase == "done" or phase == "mount": return
      if not hasReceipt(route, expectedWindow, expectedVk, expectedFrom): return
      if phaseObserved: return
      phaseObserved = true
      case phase
      of "tab_in":
        check GetFocus() == port
        echo "case3 tab_in focus=", label(GetFocus()), " receipt(hwnd=",
          label(expectedWindow), " vk=0x", toHex(int64(expectedVk), 2), ") consumed=",
          findReceipt(route, expectedWindow, expectedVk, expectedFrom).consumed
        postKey(port, VkDown, "down")
        phase = "down"
      of "down":
        let snap = f.snap(port, list)
        echo "case3 down ", snap.describe, " rows=", snap.rows.join("|")
        checkKeyRows(snap, RowHeight)
        postKey(port, VkUp, "up")
        phase = "up"
      of "up":
        let snap = f.snap(port, list)
        echo "case3 up ", snap.describe, " rows=", snap.rows.join("|")
        checkKeyRows(snap, 0.0)
        postKey(port, VkNext, "pagedown")
        phase = "pagedown"
      of "pagedown":
        let dip = viewportDip(port)
        let page = max(RowHeight, dip - RowHeight)
        let snap = f.snap(port, list)
        echo "case3 pagedown ", snap.describe, " rows=", snap.rows.join("|")
        checkKeyRows(snap, page)
        postKey(port, VkPrior, "pageup")
        phase = "pageup"
      of "pageup":
        let snap = f.snap(port, list)
        echo "case3 pageup ", snap.describe, " rows=", snap.rows.join("|")
        checkKeyRows(snap, 0.0)
        postKey(port, VkEnd, "end")
        phase = "end"
      of "end":
        let dip = viewportDip(port)
        let total = float64(ItemCount) * RowHeight
        let reach = max(0.0, total - dip)
        let snap = f.snap(port, list)
        echo "case3 end ", snap.describe, " rows=", snap.rows.join("|")
        checkKeyRows(snap, reach)
        postKey(port, VkHome, "home")
        phase = "home"
      of "home":
        let snap = f.snap(port, list)
        echo "case3 home ", snap.describe, " rows=", snap.rows.join("|")
        checkKeyRows(snap, 0.0)
        postKey(port, VkTab, "tab_out")
        phase = "tab_out"
      of "tab_out":
        echo "case3 tab_out focus=", label(GetFocus()), " after=", label(after),
          " viewport=", label(port)
        check GetFocus() != port
        check GetFocus() == after
        phase = "done"
        f.h.requestClose()
      else: discard

    var mountedOnce = false
    var ended = false
    var seenTabIn = false

    proc body() =
      inc stages
      if stages > QueueStages:
        failStage("stage budget exhausted")
        return
      case phase
      of "mount":
        if mountedOnce: return
        mountedOnce = true
        let ports = viewports(f.h)
        check ports.len == 1
        if ports.len != 1: failStage("expected one viewport"); return
        port = ports[0]
        list = f.listHandleOf
        # Locate the buttons by unique (class, text), never by enumeration order:
        # they are children of the root row's own HWND, not of the host window.
        before = controlByText(f.h.windowHandle, "BUTTON", "before")
        after = controlByText(f.h.windowHandle, "BUTTON", "after")
        check before != nil
        check after != nil
        if before == nil or after == nil:
          failStage("before/after button not found by class+text"); return
        # They must be real siblings of the viewport under one control parent.
        check GetParent(before) == GetParent(port)
        check GetParent(after) == GetParent(port)
        let parent = GetParent(port)
        check parent != nil
        check (GetWindowLongW(parent, GwlexStyle) and WsExControlParent) != 0
        let dip = viewportDip(port)
        let total = float64(ItemCount) * RowHeight
        echo "case3 mount viewport=", label(port), " dip=", dip,
          " rows=", frameRowCount(0.0, dip, total),
          " before=", label(before), " after=", label(after),
          " shared_parent=", label(parent)
        check abs(dip - ViewportDip) <= TolerancePx
        check frameRowCount(0.0, dip, total) == 5
        check (styleOf(port) and WS_TABSTOP) != 0
        discard SetFocus(before)
        check GetFocus() == before
        echo "case3 mount initial focus=", label(GetFocus())
        # The Tab must be posted to the *actual* focus owner, so the MSG.hwnd
        # records the window that really received it.
        check GetFocus() == before
        postKey(before, VkTab, "tab_in")
        phase = "tab_in"
      of "tab_in": seenTabIn = true
      else: discard
      hostWindow = f.h.windowHandle

    # Production-identical hookup: the real native turn first, then observation.
    # `observe` never calls settle/drain/pump itself.
    #
    # No re-arming here at all. Every key carries exactly one FIFO marker posted
    # by `postKey`, so a stale tick that arrives before the key is routed simply
    # observes "no matching receipt yet" and returns. Nothing guesses, nothing
    # self-posts, and there is no timer-driven busy wait.
    proc tick() =
      f.win.safeListTurn()          # production order: native turn first
      if ended: return
      body()
      observe()
      if phase == "done":
        ended = true
      elif stages >= QueueStages:
        failStage("stage budget exhausted")

    f.h.setSafeTick(tick)

    check boundedPump(f.h) == 0
    check ended
    check phase == "done"
    check seenTabIn
    # Eight queued keys, each with its own exact receipt, not just a total count.
    check route.receipts.len == 8
    check hasReceipt(route, before, VkTab)
    check hasReceipt(route, port, VkDown)
    check hasReceipt(route, port, VkUp)
    check hasReceipt(route, port, VkNext)
    check hasReceipt(route, port, VkPrior)
    check hasReceipt(route, port, VkEnd)
    check hasReceipt(route, port, VkHome)
    check hasReceipt(route, port, VkTab)      # tab-out target is the viewport
    for index in 0 ..< route.receipts.len:
      check route.receipts[index].seq == index     # monotonic, none reused
    f.h.destroyHost()
    check f.h.resourcesReleasedInternal()
    check hostWindow != nil
    check IsWindow(hostWindow) == 0

  test "focused in-row EDIT keeps insert-caret key semantics and never scrolls":
    var submits = 0
    var changes = 0
    let f = mounted(proc(): Node =
      var keys: seq[string] = @[]
      for index in 0 ..< ItemCount: keys.add($index)
      column(@[virtualList("list", keys, proc(index: int): Node =
        if index == 0:
          row(@[
            text("item 0", key = "label"),
            input("abcd", key = "edit",
              onChange = (proc(e: Event) = inc changes),
              onSubmit = (proc(e: Event) = inc submits))], key = "row")
        else: compoundRow(index),
        rowHeight = RowHeight, overscan = 0,
        styles = style({"height": $int(ViewportDip)}))], key = "root"))
    defer: f.h.destroyHost()
    var hostWindow: HWND = nil
    runTurn(f, proc() =
      f.settle()
      let ports = viewports(f.h)
      check ports.len == 1
      if ports.len != 1: return
      let port = ports[0]
      let list = f.listHandleOf
      let dip = viewportDip(port)
      check dip > 0.0
      if dip <= 0.0: return
      let total = float64(ItemCount) * RowHeight
      let initial = f.snap(port, list)
      let changesBase = changes
      echo "case2 initial ", initial.describe, " line=", initial.line,
        " viewport_dip=", dip, " changes_base=", changesBase
      check initial.rows.len > 0
      if initial.rows.len > 0: check initial.rows[0] == "item 0"
      checkRows(initial.rows, 0, frameRowCount(0.0, dip, total))
      # Every row has an EDIT (compoundRow), so "first root owning an EDIT" is
      # arbitrary - it would just be whichever row the pool happened to place
      # first. Select the row whose own label actually reads "item 0", then take
      # the EDIT inside *that* row.
      proc ownLabel(rowWindow: HWND): string =
        for child in descendants(rowWindow):
          if GetParent(child) != rowWindow: continue
          if isEditClass(child): continue
          let value = nativeText(child)
          if value.len > 0: return value
      # Raw child classes of the item-0 row, so a real class-casing difference is
      # visible in the log instead of being reported as "the editor is missing".
      proc outline(rowWindow: HWND): string =
        for child in descendants(rowWindow):
          if GetParent(child) != rowWindow: continue
          result.add("[" & nativeClass(child) & ":'" & nativeText(child) & "']")
      var firstRow: HWND = nil
      for candidate in rowRoots(port):
        if ownLabel(candidate) == "item 0": firstRow = candidate; break
      if firstRow == nil:
        echo "case2 no row root owns label 'item 0'; row_roots=",
          rowRoots(port).len, " labels=",
          rowRoots(port).mapIt(nativeText(it)).join("|")
      check firstRow != nil
      if firstRow == nil: return
      let edit = editorIn(firstRow)
      let labelText = ownLabel(firstRow)
      echo "case2 selected row label=", labelText, " outline=", outline(firstRow),
        " editor=", (edit != nil),
        " class=", (if edit == nil: "" else: nativeClass(edit)),
        " text=", (if edit == nil: "" else: nativeText(edit))
      check labelText == "item 0"
      check edit != nil
      if edit == nil: return
      discard SetFocus(edit)
      check GetFocus() == edit
      discard SendMessageW(edit, EmSetSel, WPARAM(1), LPARAM(2))
      let selBefore = SendMessageW(edit, EmGetSel, 0, 0)
      echo "case2 selection before=0x", toHex(selBefore, 8),
        " (start=", (selBefore and 0xFFFF), ", end=",
        ((selBefore shr 16) and 0xFFFF), ")"
      check (selBefore and 0xFFFF) == 1
      check ((selBefore shr 16) and 0xFFFF) == 2

      proc editKey(vk: uint32, label: string): Snapshot =
        let pre = f.snap(port, list)
        let selPre = SendMessageW(edit, EmGetSel, 0, 0)
        discard SendMessageW(edit, WM_KEYDOWN, WPARAM(vk), 0)
        let post = f.snap(port, list)
        let selPost = SendMessageW(edit, EmGetSel, 0, 0)
        echo "case2 ", label, " vk=0x", toHex(int64(vk), 2),
          " sel ", (selPre and 0xFFFF), "..", ((selPre shr 16) and 0xFFFF),
          " -> ", (selPost and 0xFFFF), "..", ((selPost shr 16) and 0xFFFF),
          " desired ", pre.desired, " -> ", post.desired,
          " applied ", pre.applied, " -> ", post.applied,
          " rev ", pre.revision, " -> ", post.revision
        # The list must not observe a scroll: no intent, no frame, no revision.
        check post.revision == pre.revision
        checkNoIntent(pre, post)
        check post.rows == pre.rows
        check post.line == pre.line
        post

      # Selected 1..2; caret keys are EDIT's own insert-caret semantics.
      # HOME/END keep the standard EDIT behaviour (line start/line end) instead
      # of scrolling the list, whatever an unfocused viewport would do.
      proc caret(): tuple[start, lift: int] =
        let value = SendMessageW(edit, EmGetSel, 0, 0)
        (int(value and 0xFFFF), int((value shr 16) and 0xFFFF))
      discard editKey(VkLeft, "left")
      echo "case2 caret after left=", caret()
      check caret() == (1, 1)          # selection collapsed to its start
      discard editKey(VkRight, "right")
      echo "case2 caret after right=", caret()
      check caret() == (2, 2)          # selection collapsed to its end
      discard editKey(VkHome, "home in editor")
      echo "case2 caret after home=", caret(), " text_len=", nativeText(edit).len
      check caret() == (0, 0)          # standard single-line HOME: line start
      discard editKey(VkEnd, "end in editor")
      echo "case2 caret after end=", caret(), " text_len=", nativeText(edit).len
      check caret() == (4, 4)          # standard single-line END: line end
      # Up/Down are still EDIT's own keys: the list must not steal them either.
      discard editKey(VkUp, "up in editor")
      discard editKey(VkDown, "down in editor")
      let settledText = nativeText(edit)
      echo "case2 editor text after keys=", settledText, " changes=", changes
      check settledText == "abcd"
      check changes == changesBase
      # Existing submit path stays intact: Enter is not turned into a scroll.
      let preEnter = f.snap(port, list)
      discard SendMessageW(edit, WM_KEYDOWN, WPARAM(VkReturn), 0)
      f.s.drainEvents()
      let postEnter = f.snap(port, list)
      echo "case2 enter submits=", submits, " desired=", postEnter.desired,
        " rev=", postEnter.revision
      check submits == 1
      checkNoIntent(preEnter, postEnter)
      check postEnter.rows == preEnter.rows
      # The viewport itself still scrolls once focus returns to it (the editor
      # path above was not a global disable).
      discard SetFocus(port)
      check GetFocus() == port
      discard keyDown(port, VkDown)
      f.settle()
      let afterFocus = f.snap(port, list)
      echo "case2 viewport refocus down ", afterFocus.describe
      check afterFocus.rows.len > 0
      if afterFocus.rows.len > 0: check afterFocus.rows[0] == "item 1"
      hostWindow = f.h.windowHandle)
    f.h.destroyHost()
    check f.h.resourcesReleasedInternal()
    check hostWindow != nil
    check IsWindow(hostWindow) == 0
