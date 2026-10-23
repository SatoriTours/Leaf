## T2 variable-row first RED input (instrumentation only; no measurement or frame
## implementation). One managed component Runtime + real Win32 backend: a 20-key
## list with rowHeight=0/estimatedHeight=24/overscan=0 and alternating native row
## root heights 24/48, observed exactly two production safeListTurns.
##
## Two turns as specified: turn 1 materializes the raw estimated frame, turn 2 is
## the corrected-range turn. The probe asserts the typed accepted rowset and the
## real geometry; failures are the RED, while missing API/flags/hook availability
## or a non-120-DIP viewport are NotRun/blocked (never called a product RED).
##
## Read-only oracle: session.acceptedEntities() typed NativeRowBinding plus the
## probe-only backend.rowWindowForTest(rootHandle); no node-id parsing, no
## sibling-index guessing, no caption-based ownership. Region evidence uses a
## probe-local read-only GetWindowRgnBox declaration (no GDI object is created).
when not defined(windows):
  {.error: "Variable-row probe requires Windows".}

import std/[tables, algorithm, strutils, options]
import leaf/[core, widgets, components, backend, backend_session, ui_thread,
  native_layout]
import leaf/component_description
import leaf/backends/win32/[api, host, backend, calls]
import ../fixture_app

const
  ItemCount = 20
  EstimatedHeight = 24.0
  RowHeight0 = 24.0
  RowHeight1 = 48.0
  ViewportDip = 120.0
  ExpectedIndices = [0, 1, 2, 3]
  ExpectedTops = [0.0, 24.0, 72.0, 96.0]
  ExpectedHeights = [24.0, 48.0, 24.0, 48.0]
  TolerancePx = 1.0

proc GetWindowRgnBox(hwnd: HWND, box: ptr RECT): int32 {.
  importc: "GetWindowRgnBox", dynlib: "user32.dll", stdcall.}
const
  RegionError = 0        ## GetWindowRgnBox: no custom window region
  RegionNull = 1         ## empty region (nothing visible)
  RegionSimple = 2       ## non-empty simple region
  RegionComplex = 3      ## non-empty complex region

var failures = 0
var blocked = ""
var pageKeys: seq[string]

let RowDef = defineComponent[int, int]("VariableRowProbeRow",
  proc(ctx: MountContext, index: int): int = index,
  proc(ctx: ComponentContext, index: int, model: int): UiDescription =
    let height = if (index mod 2) == 0: "24" else: "48"
    host(row(@[text("row " & $index, key = "label")], key = "row",
      styles = style({"height": height}))))

let PageDef = defineComponent[int, int]("VariableRowProbePage",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, model: int): UiDescription =
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

proc viewportOf(h: Win32Host): seq[HWND] =
  for window in descendants(h.windowHandle):
    if (styleOf(window) and WS_VSCROLL) != 0: result.add(window)

proc checkValue(condition: bool, label: string) =
  if not condition:
    echo "check_failed ", label
    inc failures

type
  RowFact = object
    found: bool
    source: uint64
    index: int
    key: string
    root: uint64
    window: HWND
    parent: HWND
    left, top, right, bottom: int32   ## viewport client coordinates (px)
    dipTop, dipHeight: float64
    rectOk: int32
    rectErr: uint32
    mapRet: int32
    mapErr: uint32
    sampled: bool
    rgnReturn: int32
    rgnLeft, rgnTop, rgnRight, rgnBottom: int32

proc rowFacts(win: Win32Backend, session: BackendSession, port: HWND,
              scale: float64): seq[RowFact] =
  ## Typed accepted rows only; every HWND comes from the read-only probe hook.
  let entities = session.acceptedEntities()
  var listHandle = NoHandle
  for entity in entities.values:
    if entity.kind == NodeKind.virtualList: listHandle = entity.handle
  if listHandle == NoHandle: return
  for entity in entities.values:
    if entity.row.isNone: continue
    let binding = entity.row.get
    if binding.listHandle != listHandle: continue
    var fact = RowFact(found: true, source: binding.sourceGeneration,
      index: binding.itemIndex, key: binding.itemKey, root: uint64(entity.handle))
    fact.window = win.rowWindowForTest(entity.handle)
    if fact.window != nil:
      fact.parent = GetParent(fact.window)
      var rect: RECT
      setLastError(0)
      fact.rectOk = int32(GetWindowRect(fact.window, addr rect))
      fact.rectErr = lastError()
      var mapped = false
      var corners = [POINT(), POINT()]
      if fact.rectOk != 0:
        corners = [POINT(x: rect.left, y: rect.top),
          POINT(x: rect.right, y: rect.bottom)]
        setLastError(0)
        fact.mapRet = int32(MapWindowPoints(nil, port, addr corners[0], 2))
        fact.mapErr = lastError()
        # A 0 return with no error is a legal "no offset" mapping; only a
        # non-zero immediate error marks a failed query.
        mapped = fact.mapRet != 0 or fact.mapErr == 0'u32
      if fact.rectOk != 0 and mapped:
        fact.sampled = true
        fact.left = corners[0].x
        fact.top = corners[0].y
        fact.right = corners[1].x
        fact.bottom = corners[1].y
        fact.dipTop = float64(fact.top) / scale
        fact.dipHeight = float64(fact.bottom - fact.top) / scale
      var box: RECT
      fact.rgnReturn = GetWindowRgnBox(fact.window, addr box)
      fact.rgnLeft = box.left
      fact.rgnTop = box.top
      fact.rgnRight = box.right
      fact.rgnBottom = box.bottom
    result.add(fact)
  result.sort(proc(a, b: RowFact): int = cmp(a.index, b.index))

proc describe(rows: seq[RowFact]): string =
  for row in rows:
    result.add("[" & $row.index & " key=" & row.key & " root=" & $row.root &
      " hwnd=" & $uint64(cast[uint](row.window)) & " parent=" &
      $uint64(cast[uint](row.parent)) & " src=" & $row.source & " px=" &
      $row.left & "," & $row.top & "," & $row.right & "," & $row.bottom &
      " dip=" & $row.dipTop & "+" & $row.dipHeight & " rect_ok=" & $row.rectOk &
      " rect_err=" & $row.rectErr & " map_ret=" & $row.mapRet & " map_err=" &
      $row.mapErr & " sampled=" & $row.sampled & " rgn=" & $row.rgnReturn &
      " box=" & $row.rgnLeft & "," & $row.rgnTop & "," & $row.rgnRight & "," &
      $row.rgnBottom & "]")

proc main(): int =
  # `-d:leafProtocolProbes` is a compile-time requirement of the probe-only hook
  # (a build without it is NotRun by construction); the runtime gate below only
  # covers release/orc/alloc-stats, which the coordinator also enforces in argv.
  when not (defined(release) and defined(gcOrc) and defined(nimAllocStats)):
    echo "probe_win32_variable_rows status=requires-release-orc-alloc-stats"
    return 2
  pageKeys = @[]
  for index in 0 ..< ItemCount: pageKeys.add($index)
  let activity = newUiScopeActivity()
  let rt = newRuntime(guardUiApplication(
    componentApplication(component(PageDef, 0), "variable-rows", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("variable-rows", DipSize(width: 480, height: 320))
  h.setStartupScope(proc(): bool =
    activity.busy or rt.installingUpdate or rt.installingHook)
  let win = newWin32Backend(h)
  var session: BackendSession = nil
  var primary: ref CatchableError = nil
  var primaryPhase = ""
  var blocked = ""
  var port: HWND = nil
  var scale = 1.0
  var clientPx = 0'i32
  var phase = "attach"
  try:
    session = win.attachWin32Backend(rt)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)

    phase = "viewport"
    let ports = viewportOf(h)
    echo "viewports=", ports.len
    if ports.len != 1:
      blocked = "expected exactly one WS_VSCROLL viewport, got " & $ports.len
    else:
      port = ports[0]

    if blocked.len == 0:
      phase = "geometry"
      var client: RECT
      if GetClientRect(port, addr client) == 0:
        blocked = "GetClientRect failed"
      else:
        clientPx = client.bottom - client.top
        let dpi = GetDpiForWindow(port)
        if dpi == 0:
          blocked = "GetDpiForWindow(viewport) failed"
        else:
          scale = float64(dpi) / 96.0
          echo "viewport dpi=", dpi, " client_px=", client.right - client.left,
            "x", clientPx, " scale=", scale
          # 120 DIP in real pixels, compared with a 1 px tolerance.
          if clientPx <= 0 or
              abs(float64(clientPx) - ViewportDip * scale) > TolerancePx:
            blocked = "viewport client height is not 120 DIP: " &
              $clientPx & " px at dpi " & $dpi

    if blocked.len == 0:
      # Exactly two production safe turns; no host pump, so the host tick cannot
      # run an extra hidden turn.
      phase = "turns"
      for turn in 1 .. 2:
        win.safeListTurn()
        let rows = rowFacts(win, session, port, scale)
        echo "turn", turn, " accepted_rows=", rows.len, " scroll_ticks=",
          win.diagnostics.scrollTicks, " revision=", rt.acceptedRevision,
          " rows=", rows.describe

      phase = "assertions"
      let rows = rowFacts(win, session, port, scale)
      let listSource = rt.find("list").node.listSource.generation
      echo "final accepted_rows=", rows.len, " list_source=", listSource,
        " live_rows=", win.diagnostics.liveRows, " parked=",
        win.diagnostics.parkedRows
      # Sampling failures block the run instead of being judged as geometry.
      var unsampled = ""
      for row in rows:
        if row.window == nil:
          inc failures
          echo "check_failed row ", row.index, " has no window"
        elif not row.sampled:
          unsampled = "row " & $row.index & " rect query failed rect_ok=" &
            $row.rectOk & " rect_err=" & $row.rectErr & " map_ret=" &
            $row.mapRet & " map_err=" & $row.mapErr
          break
      if unsampled.len != 0:
        blocked = unsampled
      else:
        checkValue(rows.len == ExpectedIndices.len,
          "accepted materialized rows count " & $rows.len)
        for position, row in rows:
          checkValue(row.parent == port,
            "row " & $row.index & " parent is viewport")
          checkValue(row.source == listSource,
            "row " & $row.index & " source matches list source")
          if position < ExpectedIndices.len:
            checkValue(row.index == ExpectedIndices[position],
              "row position " & $position & " index " & $row.index)
            checkValue(row.key == $ExpectedIndices[position],
              "row position " & $position & " key " & row.key)
            if row.sampled:
              let topPx = float64(row.top)
              let expectedTop = ExpectedTops[position] * scale
              checkValue(abs(topPx - expectedTop) <= TolerancePx,
                "row " & $row.index & " top px " & $topPx & " expected " &
                $expectedTop)
              let heightPx = float64(row.bottom - row.top)
              let expectedHeight = ExpectedHeights[position] * scale
              checkValue(abs(heightPx - expectedHeight) <= TolerancePx,
                "row " & $row.index & " height px " & $heightPx & " expected " &
                $expectedHeight)
              let hasRegion = row.rgnReturn == RegionSimple or
                row.rgnReturn == RegionComplex
              if position == ExpectedIndices.len - 1:
                # Partially visible 4th row: a real non-empty clip limited to
                # the viewport is required (rect intersection is not proof).
                checkValue(hasRegion, "row " & $row.index &
                  " clip region present rgn=" & $row.rgnReturn)
                if hasRegion:
                  let expectedClip = float64(clientPx) - float64(row.top)
                  checkValue(row.rgnBottom > 0 and
                    abs(float64(row.rgnBottom) - expectedClip) <= TolerancePx,
                    "row " & $row.index & " clip box bottom " & $row.rgnBottom &
                    " expected " & $expectedClip)
              else:
                # A fully inside row may legitimately have no custom region;
                # an empty region on a visible row is not acceptable.
                checkValue(row.rgnReturn != RegionNull, "row " & $row.index &
                  " empty region on a visible row")
                if hasRegion:
                  checkValue(abs(float64(row.rgnBottom) -
                    float64(row.bottom - row.top)) <= TolerancePx,
                    "row " & $row.index & " region covers the whole row")
        for row in rows:
          checkValue(row.index < ExpectedIndices.len,
            "unexpected accepted row index " & $row.index)
        for position in 1 ..< rows.len:
          checkValue(rows[position].top >= rows[position - 1].bottom,
            "row " & $position & " overlaps previous row")
        checkValue(win.diagnostics.liveRows == ExpectedIndices.len,
          "live row count " & $win.diagnostics.liveRows)
  except CatchableError as error:
    primary = error
    primaryPhase = phase

  var cleanupError: ref CatchableError = nil
  if primary != nil or blocked.len != 0:
    try: h.destroyHost()
    except CatchableError as error: cleanupError = error
    if primary != nil:
      echo "primary error phase=", primaryPhase, " type=", primary.name,
        " msg=", primary.msg
    if cleanupError != nil:
      echo "cleanup error type=", cleanupError.name, " msg=", cleanupError.msg
    let reason = if blocked.len != 0: blocked
                 elif primary != nil: primaryPhase & " raised"
                 else: "unknown"
    echo "probe_win32_variable_rows status=not_run reason=", reason
    return 2

  try:
    h.destroyHost()
  except CatchableError as error:
    cleanupError = error
  let closeComplete = h.resourcesReleasedInternal()
  echo "close_complete=", closeComplete, " failures=", failures
  if cleanupError != nil:
    echo "cleanup error type=", cleanupError.name, " msg=", cleanupError.msg
    inc failures
  if not closeComplete:
    echo "check_failed close_complete=false"
    inc failures
  if failures == 0:
    echo "probe_win32_variable_rows status=variable_rows_passed"
    return 0
  echo "probe_win32_variable_rows status=variable_rows_red failures=", failures
  1

when isMainModule:
  quit(main())
