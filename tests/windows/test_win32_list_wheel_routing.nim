## T2 wheel routing: sibling-list wheel remainders in real native delivery.
##
## The only synthesised thing is the `WM_MOUSEWHEEL`, sent through the real
## `SendMessageW` to a real in-row child HWND (an `EDIT` in one list, a `BUTTON` in
## the other). The path under test is production `backend.captureControl`, which
## walks the real `GetParent` chain to the nearest list viewport and gives the
## delta to that list only. No queue state machine, no hover or physical-mouse
## claim. The expected movement comes from the read-only system policy
## (`SPI_GETWHEELSCROLLLINES`) plus known geometry, never from the product's own
## `systemWheelLines`/`handleWheel`; a "0 lines" policy is an environment block
## (stated, skipped), never a pass, and the user's setting is never changed.
##
## Every expectation is hand-computed from the frozen fixture: 120 items x 24 DIP,
## 120 DIP viewport => reach 2760, unit 32, units ceil(2760/32) = 87,
## page round(120/32) = 4, nMax 87+3 = 90, effective max 87, and
## nPos = round(offset/32). Range/page/position are *exact* per stage: they are
## different fields with their own definitions, not one field's error bar.
## Intent scalars need `-d:leafProtocolProbes`; without it every real HWND fact is
## still asserted and the scalar checks say they are unavailable.
## `listFrameForTest` is not consulted: uniform rows mean the backend legitimately
## keeps the legacy projection and never builds a variable `acceptedFrame`.
## Standalone: frozen suites are not imported. Physical input, hover-enter,
## trackpad precision and RTL remain unverified.
when not defined(windows):
  {.error: "Win32 list wheel routing suite requires Windows".}
import std/[unittest, strutils, algorithm, widestrs, math, tables]
import ../fixture_app
import leaf/[core, widgets, backend, backend_session, native_layout, ui_thread]
import leaf/backends/win32/[api, host, backend, calls]

const
  ItemCount = 120                     ## > 100: a real scroll range either way
  RowHeight = 24.0
  ViewportDip = 120.0                 ## 120 / 24 = 5 visible rows
  ToleranceDip = 1.5                  ## client height scaling at non-96 DPI
  # Frozen scrollbar projection for this fixture (see the header derivation).
  # 87/4/90 hold for any client height in [118,122] DIP, so the tolerance above
  # cannot turn the constants into a false expectation.
  BarUnit = 32.0
  BarUnits = 87'i32
  BarPage = 4'i32
  BarMax = 90'i32

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
  ## Win32 reports "Edit"/"Static"/"Button", the headers use upper case: compare
  ## case-insensitively.
  let value = newWideCString(64)
  discard GetClassNameW(window, cast[WidePtr](unsafeAddr value[0]), 64)
  $value

type Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession,
                     runtime: Runtime, activity: UiScopeActivity]

proc mounted(render: proc(): Node): Fixture =
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(
    fixtureApplication(render, "T2 wheel", 520, 400),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("T2 wheel", DipSize(width: 520, height: 400))
  h.setStartupScope(proc(): bool =
    activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win = newWin32Backend(h)
  let session = win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime, activity)

proc settle(f: Fixture) = f.win.safeListTurn()

proc runTurn(f: Fixture, body: proc()) =
  f.h.setSafeTick(proc() =
    body()
    f.h.requestClose())
  check f.h.pump() == 0

proc compoundRow(index: int): Node =
  ## One compound row with two different wheel targets in the same list.
  row(@[
    text("item " & $index, key = "label"),
    input("", key = "edit"),
    button("act " & $index, key = "button")], key = "row")

proc listsRender(): Node =
  ## Two sibling vertical lists, each with an explicit 120 DIP / 300 DIP box.
  var keys: seq[string] = @[]
  for index in 0 ..< ItemCount: keys.add($index)
  column(@[
    virtualList("listA", keys, proc(index: int): Node = compoundRow(index),
      rowHeight = RowHeight, overscan = 0,
      styles = style({"height": "120", "width": "300"})),
    virtualList("listB", keys, proc(index: int): Node = compoundRow(index),
      rowHeight = RowHeight, overscan = 0,
      styles = style({"height": "120", "width": "300"}))], key = "root")

proc orderedViewports(h: Win32Host): seq[HWND] =
  ## Top-to-bottom by real screen rect. `EnumChildWindows` order is NOT used: the
  ## two lists are identified by where they actually are.
  for window in descendants(h.windowHandle):
    if (styleOf(window) and WS_VSCROLL) != 0: result.add(window)
  result.sort(proc(a, b: HWND): int =
    var ra, rb: RECT
    if GetWindowRect(a, addr ra) == 0 or GetWindowRect(b, addr rb) == 0: return 0
    cmp(ra.top, rb.top))

proc ownLabel(rowRoot: HWND): string =
  ## The row's label comes from its own `Static` child whose text starts with
  ## "item". Enumeration order is never used to pick it: the same row also owns an
  ## `Edit` and a `Button`, and taking "the first non-empty own child" would just
  ## return whichever class the pool happened to order first. Only a unique match
  ## yields a label.
  var found: seq[string] = @[]
  for child in descendants(rowRoot):
    if GetParent(child) != rowRoot: continue
    if cmpIgnoreCase(nativeClass(child), "Static") != 0: continue
    let value = nativeText(child)
    if value.startsWith("item"): found.add(value)
  if found.len == 1: result = found[0]

type VisibleRow = object
  top: int32
  text: string
  root: HWND

proc visibleRows(port: HWND): seq[VisibleRow] =
  ## Row roots actually intersecting the viewport client area, ordered by y.
  ## Hidden parked rows and rows scrolled fully out of the clip are not visible.
  var client: RECT
  if GetClientRect(port, addr client) == 0: return
  for rowWindow in descendants(port):
    if GetParent(rowWindow) != port or IsWindowVisible(rowWindow) == 0: continue
    var rect: RECT
    if GetWindowRect(rowWindow, addr rect) == 0: continue
    var corners = [POINT(x: rect.left, y: rect.top),
      POINT(x: rect.right, y: rect.bottom)]
    discard MapWindowPoints(nil, port, addr corners[0], 2)
    if corners[1].y <= 0 or corners[0].y >= client.bottom: continue
    result.add(VisibleRow(top: corners[0].y, text: ownLabel(rowWindow),
      root: rowWindow))
  result.sort(proc(a, b: VisibleRow): int = cmp(a.top, b.top))

proc rowTexts(port: HWND): seq[string] =
  for item in visibleRows(port): result.add(item.text)

proc rowLine(port: HWND): string =
  for item in visibleRows(port): result.add("(" & $item.top & "," & item.text & ")")

proc rowChild(rowRoot: HWND, className: string): HWND =
  ## Unique own child of the given class; enumeration order is never used.
  var found: seq[HWND] = @[]
  for child in descendants(rowRoot):
    if GetParent(child) == rowRoot and
        cmpIgnoreCase(nativeClass(child), className) == 0: found.add(child)
  if found.len == 1: result = found[0]

proc viewportAncestor(window: HWND, ports: openArray[HWND]): HWND =
  ## The nearest enclosing list viewport, computed independently of the product:
  ## walk the real parent chain and return the first HWND that is one of `ports`.
  var parent = GetParent(window)
  var depth = 0
  while parent != nil and depth <= 64:
    for port in ports:
      if port == parent: return port
    parent = GetParent(parent)
    inc depth

proc barOf(port: HWND): SCROLLINFO =
  result = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)),
    fMask: SIF_RANGE or SIF_PAGE or SIF_POS)
  if GetScrollInfo(port, SB_VERT, addr result) == 0: result.cbSize = 0

proc viewportDip(port: HWND): float64 =
  var client: RECT
  if GetClientRect(port, addr client) == 0: return 0.0
  let dpi = GetDpiForWindow(port)
  if dpi == 0: return 0.0
  float64(client.bottom - client.top) / (float64(dpi) / 96.0)

proc wheelWp(delta: int32): WPARAM =
  ## `WM_MOUSEWHEEL` keeps the signed delta in the HIGH word; the low word is the
  ## key-state mask, which Win32 sends as 0 for a wheel notch.
  WPARAM(cast[uint32](cast[uint16](int16(delta))) shl 16)

const
  SentinelLines = 0xDEADBEEF'u32       ## no real wheel-lines value can equal this

proc reachDip(): float64 = max(0.0, float64(ItemCount) * RowHeight - ViewportDip)

proc rawSystemParametersInfoW(action, param: UINT, value: pointer, flags: UINT): BOOL
  {.importc: "SystemParametersInfoW", stdcall, dynlib: "user32.dll", raises: [].}

proc readWheelLines(): tuple[queried: bool, lines: UINT] =
  ## Read the system wheel policy through the plain `SystemParametersInfoW` GET.
  ##
  ## This is deliberately NOT `systemWin32Calls().systemParameters`: that wrapper
  ## is the product factory under suspicion (it routes every action through
  ## `SystemParametersInfoForDpi`, which does not support `SPI_GETWHEELSCROLLLINES`
  ## 0x0068 and fails, making the product fall back to 3). Reading the expectation
  ## through the same broken wrapper would hide exactly that defect.
  ##
  ## Read-only: action is the named GET constant only, param and flags are 0, and
  ## nothing is ever written back to the system. No SET action, no registry, no
  ## external probe process.
  var lines: UINT = SentinelLines
  result.queried = rawSystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0'u32,
    addr lines, 0'u32) != 0
  result.lines = lines

proc expectedNotchDip(policy: tuple[queried: bool, lines: UINT]): float64 =
  ## DIP travelled by one real notch, from the *independent* read above: N lines
  ## scroll `N * rowHeight`, `WHEEL_PAGESCROLL` scrolls one page less one row.
  ## A failed query or 0 lines returns 0.0 - the caller must treat that as an
  ## environment block, never as a passing expectation, and there is no fallback
  ## to the product's documented default.
  if not policy.queried: return 0.0
  if cast[uint32](int32(policy.lines)) == cast[uint32](WHEEL_PAGESCROLL):
    return clamp(ViewportDip - RowHeight, RowHeight, reachDip())
  let count = int32(policy.lines)
  if count <= 0: return 0.0
  clamp(float64(count) * RowHeight, RowHeight, reachDip())

proc firstRowAt(offsetDip: float64): int =
  ## The only row index a correct frame can start at, from geometry alone.
  let ratio = min(offsetDip, reachDip()) / RowHeight
  let nearest = round(ratio)
  clamp(if abs(ratio - nearest) < 1e-4: int(nearest) else: int(floor(ratio)),
    0, ItemCount - 1)

proc rowCount(offsetDip, viewportDip: float64): int =
  ## Exact visible row count for an offset. The offset need not be a row multiple,
  ## so the first row may be clipped and the viewport still holds
  ## `ceil((offset %% 24 + viewport) / 24)` rows. Derived, never hard-coded.
  let start = min(offsetDip, reachDip())
  let remainder = start - floor(start / RowHeight) * RowHeight
  clamp(int(ceil((remainder + viewportDip) / RowHeight)), 1, ItemCount)

proc rowLabels(first, count: int): seq[string] =
  for step in 0 ..< count:
    if first + step < ItemCount: result.add("item " & $(first + step))

type Observation = object
  ## Real HWND/applied facts only: what the user would see right now.
  rows: seq[string]
  line: string
  tops: seq[int32]
  revision: uint64
  barOk: bool
  nMin, nMax, nPage, nPos: int32

proc observe(f: Fixture, port: HWND): Observation =
  result.rows = rowTexts(port)
  result.line = rowLine(port)
  for item in visibleRows(port): result.tops.add(item.top)
  result.revision = f.runtime.acceptedRevision
  let bar = barOf(port)
  result.barOk = bar.cbSize != 0
  (result.nMin, result.nMax, result.nPage, result.nPos) =
    (bar.nMin, bar.nMax, int32(bar.nPage), bar.nPos)

proc checkSame(pre, post: Observation, phase: string, withRevision: bool) =
  ## Rows, real row tops, scrollbar range/page/position must be identical.
  ## `revision` is only compared for a message handler (a handler must not commit);
  ## an ordinary turn may legitimately accept a new revision even with no intent,
  ## so turn-level callers pass `withRevision = false`.
  echo "  ", phase, " rows=", post.line, " nPos=", post.nPos, " rev=", post.revision
  check post.rows == pre.rows and post.tops == pre.tops
  check post.barOk == pre.barOk
  check post.nMin == pre.nMin and post.nMax == pre.nMax
  check post.nPage == pre.nPage and post.nPos == pre.nPos
  if withRevision: check post.revision == pre.revision

proc applied(f: Fixture, port: HWND, offset: float64, phase: string): Observation =
  ## A settled list at a known offset. Every scalar is re-derived here from the
  ## frozen fixture: label sequence, first row index, visible count, each row top
  ## in device pixels as `round((index*24 - offset) * dpi/96)` (exact at 96 DPI,
  ## at most 1 px otherwise, because the product rounds the same sum) and the
  ## exact range/page/position. Nothing is read back to form the expectation.
  result = observe(f, port)
  let dpi = int(GetDpiForWindow(port))
  if dpi <= 0:
    check false
    return
  let scale = float64(dpi) / 96.0
  let dip = viewportDip(port)
  let first = firstRowAt(offset)
  let count = rowCount(offset, dip)
  let tol = if dpi == 96: 0.0 else: 1.0
  let wantPos = int32(clamp(round(offset / BarUnit), 0.0, float64(BarUnits)))
  echo "case wheel ", phase, ": dip=", dip, " dpi=", dpi, " offset=", offset,
    " rows=", result.line, " bar(nMin=", result.nMin, ",nMax=", result.nMax,
    ",nPage=", result.nPage, ",nPos=", result.nPos, ") want(nMax=", BarMax,
    ",nPage=", BarPage, ",nPos=", wantPos, ")"
  check result.rows == rowLabels(first, count)
  check result.tops.len == count
  if result.tops.len == count:
    # Each row top is the row's own DIP position scaled by the viewport DPI; the
    # product rounds that same sum, so 96 DPI is exact and any other DPI differs
    # by at most one device pixel.
    for step in 0 ..< count:
      let want = int32(round(
        (float64(first + step) * RowHeight - offset) * scale))
      if abs(float64(result.tops[step] - want)) > tol:
        echo "  row top step=", step, " got=", result.tops[step], " want=", want
      check abs(float64(result.tops[step] - want)) <= tol
      if step > 0:
        # Consecutive rows are exactly one rowHeight apart on screen.
        let delta = float64(result.tops[step] - result.tops[step - 1])
        check abs(delta - RowHeight * scale) <= 2.0 * tol
  check result.barOk
  check result.nMin == 0
  check result.nMax == BarMax
  check result.nPage == BarPage
  check result.nPos == wantPos

proc checkBoth(f: Fixture, preA, preB: Observation, a, b: HWND, phase: string) =
  ## A message handler records intent only: nothing applied in either list.
  checkSame(preA, observe(f, a), "A after " & phase, true)
  checkSame(preB, observe(f, b), "B after " & phase, true)

proc offsets(f: Fixture, desired: bool): seq[int] =
  ## Order-free per-list offsets: which handle is which list is irrelevant, only
  ## how many lists moved and by how much.
  when defined(leafProtocolProbes):
    for entity in f.s.acceptedEntities().values:
      if entity.kind != NodeKind.virtualList: continue
      let probe = f.win.listIntentForTest(entity.handle)
      if not probe.valid: continue
      result.add(int(round(if desired: probe.desiredOffset else: probe.appliedOffset)))
    result.sort()

template checkOffsets(f: Fixture, wantApplied, wantDesired: seq[int],
                       phase: string) =
  when defined(leafProtocolProbes):
    let gotApplied = f.offsets(desired = false)
    let gotDesired = f.offsets(desired = true)
    echo "  ", phase, " applied=", gotApplied, " desired=", gotDesired,
      " want=", wantApplied, "/", wantDesired
    check gotApplied.len == 2 and gotApplied == wantApplied
    check gotDesired.len == 2 and gotDesired == wantDesired
  else:
    echo "  ", phase, ": intent scalars unavailable (no -d:leafProtocolProbes)"

proc mountReady(h: Win32Host): bool =
  ## Both viewports exist, each showing the whole derived 120 DIP window with a
  ## real, non-zero scroll range. Premise only - the exact counts are asserted
  ## in the case body.
  let ports = orderedViewports(h)
  if ports.len != 2: return false
  for port in ports:
    let dip = viewportDip(port)
    if dip <= 0.0 or rowTexts(port).len != rowCount(0.0, dip): return false
    let bar = barOf(port)
    if bar.cbSize == 0 or bar.nMax <= 0: return false
  true

suite "T2 list wheel routing":
  test "child wheel remainders are isolated between sibling lists":
    let f = mounted(listsRender)
    defer: f.h.destroyHost()
    let policy = readWheelLines()
    let notch = expectedNotchDip(policy)
    echo "case wheel: policy queried=", policy.queried, " lines=", policy.lines,
      " one notch=", notch, " DIP, reach=", reachDip()
    runTurn(f, proc() =
      if not policy.queried:
        # A failed read is an environment block too: without an independent policy
        # value there is no honest expectation, and the product's own fallback
        # constant must never be adopted as one.
        echo "BLOCKED(environment): plain SystemParametersInfoW GET for "
        echo "  SPI_GETWHEELSCROLLLINES failed; no independent wheel policy."
        skip()
        return
      if notch < 0.0 or notch == 0.0:
        # A real environment block, stated as such: no assertion becomes a pass
        # and the user's wheel setting is never modified by this suite.
        echo "BLOCKED(environment): SPI_GETWHEELSCROLLLINES reports 0 wheel ",
          "lines, so a notch scrolls nothing."
        skip()
        return
      let notchDips = int(round(notch))
      # Premise: bounded ordinary turns mount both lists. Each one is the same
      # `safeListTurn` the user's session runs; the loop only decides how many
      # identical turns to give it and never reorders anything inside.
      var turns = 0
      f.settle()
      inc turns
      while turns < 4 and not mountReady(f.h):
        f.settle()
        inc turns
      echo "case wheel: mount turns=", turns
      let ports = orderedViewports(f.h)
      check ports.len == 2
      if ports.len != 2: return
      let a = ports[0]                     # upper list, by real screen y
      let b = ports[1]                     # lower list
      var ra, rb: RECT
      check GetWindowRect(a, addr ra) != 0
      check GetWindowRect(b, addr rb) != 0
      echo "case wheel: A.y=", ra.top, " B.y=", rb.top
      check a != b and rb.top >= ra.bottom  # independent, non-overlapping boxes
      # Independent HWNDs with their own parent chain: neither viewport is the
      # other's parent, and neither is the host window itself.
      check GetParent(a) != nil and GetParent(b) != nil
      check GetParent(a) != b and GetParent(b) != a
      check a != f.h.windowHandle and b != f.h.windowHandle
      let dipA = viewportDip(a)
      let dipB = viewportDip(b)
      check abs(dipA - ViewportDip) <= ToleranceDip
      check abs(dipB - ViewportDip) <= ToleranceDip
      var preA = applied(f, a, 0.0, "initial A")
      var preB = applied(f, b, 0.0, "initial B")
      checkOffsets(f, @[0, 0], @[0, 0], "initial")

      # Row targets are resolved from real visible entities; without them the rest
      # of the case cannot observe anything and must not invent an HWND.
      let rowsA = visibleRows(a)
      let rowsB = visibleRows(b)
      check rowsA.len == rowCount(0.0, dipA) and rowsB.len == rowCount(0.0, dipB)
      echo "case wheel: visible A=", rowsA.len, " B=", rowsB.len
      if rowsA.len == 0 or rowsB.len == 0: return
      let editA = rowChild(rowsA[0].root, "EDIT")
      let buttonA = rowChild(rowsA[0].root, "BUTTON")
      let editB = rowChild(rowsB[0].root, "EDIT")
      let buttonB = rowChild(rowsB[0].root, "BUTTON")
      check editA != nil and buttonA != nil and editB != nil and buttonB != nil
      if editA == nil or buttonA == nil or editB == nil or buttonB == nil: return
      echo "case wheel: targets A/", nativeClass(editA), " B/", nativeClass(buttonB)
      # The nearest enclosing list of each child must be the list that owns it.
      check viewportAncestor(editA, [a, b]) == a
      check viewportAncestor(buttonA, [a, b]) == a
      check viewportAncestor(editB, [a, b]) == b
      check viewportAncestor(buttonB, [a, b]) == b

      # (1) -40 to A's in-row EDIT: an incomplete notch accumulates only.
      discard SendMessageW(editA, WM_MOUSEWHEEL, wheelWp(-40), 0)
      checkBoth(f, preA, preB, a, b, "-40 on A row EDIT")
      checkOffsets(f, @[0, 0], @[0, 0], "after -40 on A")
      # An ordinary turn in between must not drop that remainder, must not scroll
      # anything and must not touch either list's geometry.
      f.settle()
      preA = applied(f, a, 0.0, "after turn 1 A")
      preB = applied(f, b, 0.0, "after turn 1 B")
      checkOffsets(f, @[0, 0], @[0, 0], "applied after turn 1")

      # (2) -80 to B's in-row BUTTON: A's -40 remainder must stay invisible to B.
      # A shared remainder would already read -120 and move one list right here.
      discard SendMessageW(buttonB, WM_MOUSEWHEEL, wheelWp(-80), 0)
      checkBoth(f, preA, preB, a, b, "-80 on B row BUTTON")
      checkOffsets(f, @[0, 0], @[0, 0], "after -80 on B")
      f.settle()
      preA = applied(f, a, 0.0, "after turn 2 A")
      preB = applied(f, b, 0.0, "after turn 2 B")
      checkOffsets(f, @[0, 0], @[0, 0], "applied after turn 2")

      # (3) -80 to A's in-row BUTTON: A's own remainder, kept across two ordinary
      # turns, completes exactly one notch - recorded as intent only.
      discard SendMessageW(buttonA, WM_MOUSEWHEEL, wheelWp(-80), 0)
      checkBoth(f, preA, preB, a, b, "A completing notch")
      checkOffsets(f, @[0, 0], @[0, notchDips], "intent after A notch")

      # One ordinary turn applies it, in the upper list only.
      f.settle()
      let movedA = applied(f, a, notch, "after A notch A")
      let movedB = applied(f, b, 0.0, "sibling B still at 0")
      checkOffsets(f, @[0, notchDips], @[0, notchDips], "applied after A notch")
      preA = movedA
      preB = movedB

      # (4) -40 to B's in-row EDIT completes B's own notch.
      discard SendMessageW(editB, WM_MOUSEWHEEL, wheelWp(-40), 0)
      checkBoth(f, preA, preB, a, b, "B completing notch")
      checkOffsets(f, @[0, notchDips], @[notchDips, notchDips],
        "intent after B notch")

      f.settle()
      let finalA = applied(f, a, notch, "final A")
      let finalB = applied(f, b, notch, "final B")
      checkOffsets(f, @[notchDips, notchDips], @[notchDips, notchDips],
        "applied after B notch")
      echo "case wheel: notch=", notchDips, " final nPos A=", finalA.nPos,
        " B=", finalB.nPos, " want=", int32(round(notch / BarUnit)))

  test "wheel policy query succeeds and matches independent read":
    ## F1: the product's `systemWin32Calls().systemParameters` routes every action
    ## through `SystemParametersInfoForDpi`. That API does not support
    ## `SPI_GETWHEELSCROLLLINES` (0x0068), so each call fails with return 0 and
    ## leaves the caller's buffer untouched; `list_host.systemWheelLines` then
    ## falls back to a hard-coded 3 and no test that uses the same wrapper can see
    ## it. This case compares that wrapper against the plain
    ## `SystemParametersInfoW` GET read here, so it is RED on that code without
    ## touching the user's settings: even when the real policy *is* 3, a failing
    ## query is still a failed query and still fails the purity assertions.
    ##
    ## No window and no fixture: the wrapper only needs a DPI hint. Read-only - the
    ## named GET action, param/flags 0, and a sentinel that proves whether the call
    ## wrote anything. `SystemParametersInfoForDpi` is a per-call query, not a
    ## mixed-DPI rendering path, so checking several DPI values does not claim
    ## mixed-DPI coverage.
    let policy = readWheelLines()
    echo "case policy: independent GET(0x", toHex(int64(SPI_GETWHEELSCROLLLINES), 4),
      ") queried=", policy.queried, " lines=", policy.lines
    # The independent reference read must itself work, otherwise this case would
    # be asserting against an unknowable value instead of a real policy.
    check policy.queried
    check policy.lines != SentinelLines
    var productWorks = 0
    for dpi in [96'u32, 120'u32, 144'u32]:
      var value = SentinelLines
      let ok = systemWin32Calls().systemParameters(SPI_GETWHEELSCROLLLINES,
        0'u32, addr value, 0'u32, dpi)
      echo "case policy: product wrapper dpi=", dpi, " returned=", ok,
        " value=0x", toHex(int64(value), 8), " (sentinel=0x",
        toHex(int64(SentinelLines), 8), ") independent=", policy.lines
      # A query that reports failure must not be counted as agreement, even when
      # the buffer happens to still hold a plausible number.
      check ok != 0
      check value != SentinelLines
      check value == policy.lines
      if ok != 0 and value == policy.lines: inc productWorks
    echo "case policy: agreeing dpi values=", productWorks, "/3"
    # On the current product code the wrapper is `SystemParametersInfoForDpi` for
    # every action, so `SPI_GETWHEELSCROLLLINES` returns 0 with the sentinel still
    # in place: this is the RED assertion, not a tolerance.
    check productWorks == 3

# ---------------------------------------------------------------------------
# Nested routing: one virtual list inside another list's row.
#
# Same production path as above (`backend.captureControl` walking the real
# `GetParent` chain to the *nearest* list in `win.lists`), but now two lists sit
# on one ancestor chain. The delta must reach the inner list only; the outer list
# never inherits it, not even at the inner list's own bottom. Only
# `WM_MOUSEWHEEL`/`WM_VSCROLL` are synthesised (message level, real
# `SendMessageW`); no queue state machine, no hover or physical-mouse claim, no
# visual verification, no mixed-DPI claim. The system policy is read once through
# the plain read-only `SystemParametersInfoW` GET above; a failed or 0-lines
# policy is an environment block, and the user's setting is never changed.
# The inner list keeps the frozen fixture (120 x 24 DIP, 120 DIP viewport), so
# `applied` above is reused verbatim. The outer list is a different geometry and
# gets its own exact constants below - it is never run through `applied`.

const
  OuterItems = 20
  OuterRowHeightDip = 168.0           ## 120 DIP list + 24 DIP label + 24 spare
  OuterViewportDip = 168.0            ## exactly one row fits
  OuterReachDip = 3192.0              ## 20 * 168 - 168, far from 0
  OuterBarUnit = 32.0                 ## same MinScrollUnit as any list
  OuterBarUnits = 100'i32             ## ceil(3192 / 32)
  OuterBarPage = 5'i32                ## round(168 / 32)
  OuterBarMax = 104'i32               ## units + (page - 1)

let innerKeys = block:
  var keys: seq[string] = @[]
  for index in 0 ..< ItemCount: keys.add($index)
  keys

proc nestedRow(index: int): Node =
  ## Every outer row is a column: its own label plus one full inner virtual list.
  ## A column/row root would otherwise measure 0 wide through the list.
  column(@[
    text("item " & $index, key = "label"),
    virtualList("inner", innerKeys, proc(item: int): Node = compoundRow(item),
      rowHeight = RowHeight, overscan = 0,
      styles = style({"height": "120", "width": "260"}))], key = "row")

proc nestedRender(): Node =
  var keys: seq[string] = @[]
  for index in 0 ..< OuterItems: keys.add($index)
  column(@[virtualList("outer", keys, proc(index: int): Node = nestedRow(index),
    rowHeight = OuterRowHeightDip, overscan = 0,
    styles = style({"height": "168", "width": "300"}))], key = "root")

proc nestedPorts(h: Win32Host): tuple[outer, inner: HWND] =
  ## The two real viewports told apart by the real parent chain: the outer list is
  ## an actual ancestor of the inner one. Enumeration order is never used.
  let ports = orderedViewports(h)
  if ports.len != 2: return (nil, nil)
  if viewportAncestor(ports[1], [ports[0]]) == ports[0]: return (ports[0], ports[1])
  if viewportAncestor(ports[0], [ports[1]]) == ports[1]: return (ports[1], ports[0])
  (nil, nil)

proc nestedReady(h: Win32Host): bool =
  ## Premise only: the nested pair exists, the outer list shows its single real
  ## row and the inner list shows its whole 5-row window with a real range.
  let p = nestedPorts(h)
  if p.outer == nil or p.inner == nil: return false
  if viewportDip(p.outer) <= 0.0 or viewportDip(p.inner) <= 0.0: return false
  if visibleRows(p.outer).len != 1: return false
  if rowTexts(p.inner).len != rowCount(0.0, viewportDip(p.inner)): return false
  let bar = barOf(p.outer)
  bar.cbSize != 0 and bar.nMax > 0

proc checkOuter(f: Fixture, outer: HWND, phase: string) =
  ## The outer list never moves: exactly one full-height row at top 0 and its own
  ## exact range/page/position. Hand-computed constants, not `applied`, because
  ## the outer geometry is a different fixture.
  let obs = observe(f, outer)
  let dpi = int(GetDpiForWindow(outer))
  check dpi > 0
  if dpi <= 0: return
  let scale = float64(dpi) / 96.0
  let tol = if dpi == 96: 0.0 else: 1.0
  let dip = viewportDip(outer)
  echo "nested outer ", phase, ": dip=", dip, " rows=", obs.line, " bar(nMin=",
    obs.nMin, ",nMax=", obs.nMax, ",nPage=", obs.nPage, ",nPos=", obs.nPos, ")"
  check abs(dip - OuterViewportDip) <= ToleranceDip
  check obs.rows.len == 1
  if obs.rows.len == 1: check obs.rows[0] == "item 0"
  check obs.tops.len == 1
  if obs.tops.len == 1: check abs(float64(obs.tops[0])) <= tol
  let rows = visibleRows(outer)
  check rows.len == 1
  if rows.len == 1:
    var rect: RECT
    if GetWindowRect(rows[0].root, addr rect) != 0:
      var corners = [POINT(x: rect.left, y: rect.top),
        POINT(x: rect.right, y: rect.bottom)]
      discard MapWindowPoints(nil, outer, addr corners[0], 2)
      let height = float64(corners[1].y - corners[0].y) / scale
      check abs(height - OuterRowHeightDip) <= tol
  check obs.barOk
  check obs.nMin == 0
  check obs.nMax == OuterBarMax
  check obs.nPage == OuterBarPage
  check obs.nPos == 0

suite "T2 nested list wheel routing":
  test "nested child wheel stays in nearest list at bottom":
    let f = mounted(nestedRender)
    defer: f.h.destroyHost()
    let policy = readWheelLines()
    let notch = expectedNotchDip(policy)
    echo "nested wheel: queried=", policy.queried, " lines=", policy.lines,
      " one notch=", notch, " DIP, inner reach=", reachDip(), " outer reach=",
      OuterReachDip
    runTurn(f, proc() =
      if not policy.queried or notch <= 0.0:
        echo "BLOCKED(environment): no independent wheel policy (queried=",
          policy.queried, " lines=", policy.lines, "); nothing is scrolled and ",
          "the user's setting is untouched."
        skip()
        return
      let notchDips = int(round(notch))
      # Premise: bounded ordinary turns mount the nested pair (outer row, then the
      # inner list's rows). No sleep, no unbounded retry.
      var turns = 0
      f.settle()
      inc turns
      while turns < 4 and not nestedReady(f.h):
        f.settle()
        inc turns
      echo "nested wheel: mount turns=", turns
      let p = nestedPorts(f.h)
      let outer = p.outer
      let inner = p.inner
      # If nesting is unsupported this fails here as a premise, not as a wheel
      # verdict: the scenario below is then simply not reachable.
      check outer != nil and inner != nil
      if outer == nil or inner == nil: return
      check outer != inner
      let innerParent = GetParent(inner)
      check innerParent != nil
      # The inner viewport's real parent is the outer row, not the host window and
      # not the outer viewport directly.
      check innerParent != f.h.windowHandle and innerParent != outer
      check viewportAncestor(inner, [outer]) == outer
      check viewportAncestor(outer, [inner]) == nil
      var co, ci: RECT
      check GetClientRect(outer, addr co) != 0
      check GetClientRect(inner, addr ci) != 0
      check (co.right - co.left) > 0 and (co.bottom - co.top) > 0
      check (ci.right - ci.left) > 0 and (ci.bottom - ci.top) > 0
      check abs(viewportDip(outer) - OuterViewportDip) <= ToleranceDip
      check abs(viewportDip(inner) - ViewportDip) <= ToleranceDip
      let dipInner = viewportDip(inner)
      let outerRows = visibleRows(outer)
      check outerRows.len == 1
      check rowTexts(inner).len == rowCount(0.0, dipInner)
      check rowTexts(inner) == rowLabels(0, rowCount(0.0, dipInner))
      echo "nested wheel: inner rows=", rowTexts(inner).len, " outer rows=",
        outerRows.len
      # The inner viewport is a real child window embedded in outer row 0's
      # visible band - placement read from real rects, not from a probe.
      if outerRows.len == 1:
        var rowRect: RECT
        if GetWindowRect(outerRows[0].root, addr rowRect) != 0:
          var rc = [POINT(x: rowRect.left, y: rowRect.top),
            POINT(x: rowRect.right, y: rowRect.bottom)]
          var ic = [POINT(x: 0, y: 0), POINT(x: ci.right, y: ci.bottom)]
          discard MapWindowPoints(nil, outer, addr rc[0], 2)
          discard MapWindowPoints(inner, outer, addr ic[0], 2)
          let dpiO = int(GetDpiForWindow(outer))
          check dpiO > 0
          if dpiO > 0:
            let tol = if dpiO == 96: 0'i32 else: 1'i32
            echo "nested wheel: inner client in outer y=", ic[0].y, "..", ic[1].y,
              " row0 y=", rc[0].y, "..", rc[1].y
            check ic[0].y >= rc[0].y - tol and ic[1].y <= rc[1].y + tol
      checkOuter(f, outer, "initial")
      var preOuter = observe(f, outer)
      var preInner = applied(f, inner, 0.0, "inner initial")
      checkOffsets(f, @[0, 0], @[0, 0], "initial nested")
      # Keep the two notch steps inside the inner range for any real policy.
      let step1 = min(notchDips, int(reachDip()))
      let step2 = min(2 * notchDips, int(reachDip()))
      check step1 > 0 and step2 >= step1

      # (1) A full notch on a real visible inner row's EDIT: intent lands on the
      # inner list only and nothing is applied inside the message.
      var rowsInner = visibleRows(inner)
      check rowsInner.len > 0
      if rowsInner.len == 0: return
      var target = rowChild(rowsInner[0].root, "EDIT")
      check target != nil
      if target == nil: return
      discard SendMessageW(target, WM_MOUSEWHEEL, wheelWp(-120), 0)
      checkSame(preInner, observe(f, inner), "inner after notch 1", true)
      checkSame(preOuter, observe(f, outer), "outer after notch 1", true)
      checkOffsets(f, @[0, 0], @[0, step1], "intent inner notch 1")
      f.settle()
      preInner = applied(f, inner, float64(step1), "inner after notch 1")
      checkOuter(f, outer, "after inner notch 1")
      preOuter = observe(f, outer)
      checkOffsets(f, @[0, step1], @[0, step1], "applied inner notch 1")

      # (2) A second notch on a freshly located visible inner row's BUTTON. The
      # first row's child must not be reused once it has scrolled.
      rowsInner = visibleRows(inner)
      check rowsInner.len > 0
      if rowsInner.len == 0: return
      target = rowChild(rowsInner[rowsInner.len - 1].root, "BUTTON")
      check target != nil
      if target == nil: return
      discard SendMessageW(target, WM_MOUSEWHEEL, wheelWp(-120), 0)
      checkSame(preInner, observe(f, inner), "inner after notch 2", true)
      checkSame(preOuter, observe(f, outer), "outer after notch 2", true)
      checkOffsets(f, @[0, step1], @[0, step2], "intent inner notch 2")
      f.settle()
      preInner = applied(f, inner, float64(step2), "inner after notch 2")
      checkOuter(f, outer, "after inner notch 2")
      preOuter = observe(f, outer)
      checkOffsets(f, @[0, step2], @[0, step2], "applied inner notch 2")

      # (3) Real WM_VSCROLL(SB_BOTTOM) on the inner viewport: setup only. Intent
      # jumps to the inner end of the inner range and applies on the next turn.
      discard SendMessageW(inner, WM_VSCROLL, WPARAM(SB_BOTTOM), 0)
      checkSame(preInner, observe(f, inner), "inner after SB_BOTTOM", true)
      checkSame(preOuter, observe(f, outer), "outer after SB_BOTTOM", true)
      checkOffsets(f, @[0, step2], @[0, int(reachDip())], "intent inner bottom")
      f.settle()
      preInner = applied(f, inner, reachDip(), "inner at bottom")
      checkOuter(f, outer, "after inner bottom")
      preOuter = observe(f, outer)
      checkOffsets(f, @[0, int(reachDip())], @[0, int(reachDip())],
        "applied inner bottom")
      # range and position are different fields: nPos is round(2760/32) = 86,
      # the effective maximum is ceil(2760/32) = 87. They are not interchangeable.
      echo "nested wheel: inner bottom nPos=", preInner.nPos, " effectiveMax=",
        BarUnits, " nMax=", preInner.nMax

      # (4) One more full notch at the inner bottom is consumed or clamped by the
      # nearest list. The outer list, with 3192 DIP still reachable, must not
      # inherit it.
      rowsInner = visibleRows(inner)
      check rowsInner.len > 0
      if rowsInner.len == 0: return
      target = rowChild(rowsInner[0].root, "EDIT")
      if target == nil: target = rowChild(rowsInner[0].root, "BUTTON")
      check target != nil
      if target == nil: return
      discard SendMessageW(target, WM_MOUSEWHEEL, wheelWp(-120), 0)
      checkSame(preInner, observe(f, inner), "inner after bottom notch", true)
      checkSame(preOuter, observe(f, outer), "outer after bottom notch", true)
      checkOffsets(f, @[0, int(reachDip())], @[0, int(reachDip())],
        "intent after bottom notch")
      f.settle()
      let finalInner = applied(f, inner, reachDip(), "inner final")
      checkOuter(f, outer, "final")
      checkOffsets(f, @[0, int(reachDip())], @[0, int(reachDip())],
        "applied after bottom notch")
      check OuterReachDip > 0.0
      echo "nested wheel: final inner rows=", finalInner.line, " nPos=",
        finalInner.nPos, "; outer stayed at 0 with ", OuterReachDip,
        " DIP reachable")
