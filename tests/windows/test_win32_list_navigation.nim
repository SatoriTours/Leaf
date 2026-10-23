## T2 navigation gate: 10k first/last frame and native scroll-range readback.
## New standalone test file; the old lists suite is NOT imported (it would run its
## own sixteen cases). The fixture/query helpers are copied minimally from the
## frozen suite so this file has no extra Runtime, GPUI or business authority.
##
## Both cases use the real managed Runtime, a real Win32Host/BackendSession and
## the production safeListTurn; the scrollbar is only touched through real
## SendMessage WM_VSCROLL / GetScrollInfo, never a wrapper or fake client rect.
when not defined(windows):
  {.error: "Win32 list navigation suite requires Windows".}

import std/[unittest, strutils, algorithm, widestrs, math]
import ../fixture_app
import leaf/[core, widgets, backend, backend_session, native_layout, ui_thread]
import leaf/backends/win32/[api, calls, host, backend]

const
  ItemCount = 10_000
  RowHeight = 24.0
  HighRowHeight = 1024.0
  MaxScrollUnits = 1_073_741_824.0   ## same int32-safe thumb space as list_host
  MinScrollUnit = 32.0
  PoolBudgetRows = 8                 ## RowPool.MaxParkedRows
  VisibleRows = 5                    ## 120 DIP / 24 DIP

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

type Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession,
                     runtime: Runtime, activity: UiScopeActivity]

proc openHost(): Win32Host =
  createHost("T2 navigation", DipSize(width: 480, height: 320))

proc mounted(render: proc(): Node): Fixture =
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(
    fixtureApplication(render, "T2 navigation", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = openHost()
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
  row(@[
    text("item " & $index, key = "label"),
    button("act " & $index, key = "button"),
    checkbox("chk " & $index, false, key = "check")], key = "row")

proc listRender(): Node =
  var keys: seq[string] = @[]
  for index in 0 ..< ItemCount: keys.add($index)
  column(@[virtualList("list", keys, proc(index: int): Node = compoundRow(index),
    rowHeight = RowHeight, overscan = 0,
    styles = style({"height": "120"}))], key = "root")

proc highRowRender(): Node =
  var keys: seq[string] = @[]
  for index in 0 ..< ItemCount: keys.add($index)
  column(@[virtualList("list", keys, proc(index: int): Node = compoundRow(index),
    rowHeight = HighRowHeight, overscan = 0,
    styles = style({"height": "120"}))], key = "root")

proc viewports(h: Win32Host): seq[HWND] =
  for window in descendants(h.windowHandle):
    if (styleOf(window) and WS_VSCROLL) != 0: result.add(window)

proc rowRoots(viewport: HWND): seq[HWND] =
  for window in descendants(viewport):
    if GetParent(window) == viewport: result.add(window)

proc clippedRows(viewport: HWND): seq[tuple[y: int32, text: string]] =
  ## Row roots actually intersecting the viewport client area, with their first
  ## own child text; a fully off-screen caption is never reported as visible.
  var client: RECT
  check GetClientRect(viewport, addr client) != 0
  check client.right > 0
  check client.bottom > 0
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

proc scrollTo(port: HWND, code: int) =
  discard SendMessageW(port, WM_VSCROLL, WPARAM(code), 0)

# --- public projection mirror (frozen list_host.scrollUnit/scrollUnits/
# scrollPage/scrollPosForOffset); recomputed here from known total and measured
# viewport, never copied from the current nMax, and not a second authority ------

proc mirrorMaxOffset(total, viewport: float64): float64 =
  max(0.0, total - viewport)

proc mirrorUnit(total, viewport: float64): float64 =
  max(MinScrollUnit, max(mirrorMaxOffset(total, viewport), viewport) /
    MaxScrollUnits)

proc mirrorUnits(total, viewport: float64): int32 =
  let reach = mirrorMaxOffset(total, viewport)
  if reach <= 0.0: return 0
  int32(min(MaxScrollUnits, ceil(reach / mirrorUnit(total, viewport))))

proc mirrorPage(total, viewport: float64): int32 =
  if viewport <= 0.0: return 0
  int32(max(1.0, round(viewport / mirrorUnit(total, viewport))))

proc mirrorPos(offset, total, viewport: float64): int32 =
  let unit = mirrorUnit(total, viewport)
  int32(clamp(round(offset / unit), 0.0,
    float64(mirrorUnits(total, viewport))))

suite "T2 list navigation: 10k first/last frame":
  test "SB_BOTTOM and SB_TOP move the applied frame without overrun":
    let f = mounted(listRender)
    defer: f.h.destroyHost()
    var hostWindow: HWND = nil
    runTurn(f, proc() =
      f.settle()
      let ports = viewports(f.h)
      check ports.len == 1
      if ports.len != 1: return
      let port = ports[0]
      var client: RECT
      check GetClientRect(port, addr client) != 0
      check client.right > 0
      check client.bottom > 0
      let first = orderedRowTexts(port)
      echo "case1 initial rows=", first
      check first.len == VisibleRows
      check first == @["item 0", "item 1", "item 2", "item 3", "item 4"]
      check f.win.diagnostics.liveRows == VisibleRows

      let revisionBefore = f.runtime.acceptedRevision
      scrollTo(port, SB_BOTTOM)                 # intent only
      let afterIntent = orderedRowTexts(port)
      echo "case1 after intent rows=", afterIntent,
        " revision=", f.runtime.acceptedRevision
      check afterIntent == first
      check f.runtime.acceptedRevision == revisionBefore

      f.settle()                                # the accepted frame moves
      let bottomRows = orderedRowTexts(port)
      echo "case1 bottom rows=", bottomRows,
        " revision=", f.runtime.acceptedRevision,
        " row_roots=", rowRoots(port).len
      check bottomRows.len == VisibleRows
      check bottomRows == @["item 9995", "item 9996", "item 9997",
        "item 9998", "item 9999"]
      check rowRoots(port).len <= VisibleRows + PoolBudgetRows
      check f.win.diagnostics.liveRows == VisibleRows

      scrollTo(port, SB_BOTTOM)                 # repeat at the end: no overrun
      f.settle()
      let again = orderedRowTexts(port)
      echo "case1 repeated bottom rows=", again,
        " row_roots=", rowRoots(port).len
      check again == bottomRows
      check rowRoots(port).len <= VisibleRows + PoolBudgetRows

      scrollTo(port, SB_TOP)
      f.settle()
      let topRows = orderedRowTexts(port)
      echo "case1 top rows=", topRows
      check topRows.len == VisibleRows
      check topRows == first
      hostWindow = f.h.windowHandle)
    f.h.destroyHost()
    check f.h.resourcesReleasedInternal()
    check hostWindow != nil
    check IsWindow(hostWindow) == 0

  test "10k high rows expose a native range beyond 16 bits with a consistent position":
    let f = mounted(highRowRender)
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.settle()
      let ports = viewports(f.h)
      check ports.len == 1
      if ports.len != 1: return
      let port = ports[0]
      var client: RECT
      check GetClientRect(port, addr client) != 0
      check client.bottom > 0
      if client.bottom <= 0: return        # failed check above; no division
      let dpi = GetDpiForWindow(f.h.windowHandle)
      check dpi > 0
      if dpi == 0: return                  # failed check above; no division
      let scale = float64(dpi) / 96.0
      let viewportDip = float64(client.bottom - client.top) / scale
      check viewportDip > 0.0
      if viewportDip <= 0.0: return        # failed check above; no projection
      let total = float64(ItemCount) * HighRowHeight
      check total > viewportDip
      let maxOffset = mirrorMaxOffset(total, viewportDip)
      let wantedUnits = mirrorUnits(total, viewportDip)
      let wantedPage = mirrorPage(total, viewportDip)
      let wantedBottom = mirrorPos(maxOffset, total, viewportDip)

      var info = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)),
        fMask: SIF_RANGE or SIF_PAGE or SIF_POS)
      check GetScrollInfo(port, SB_VERT, addr info) != 0
      echo "case2 top client_dip=", viewportDip, " dpi=", dpi, " total=", total,
        " unit=", mirrorUnit(total, viewportDip), " wanted_units=", wantedUnits,
        " wanted_page=", wantedPage, " nMin=", info.nMin, " nMax=", info.nMax,
        " nPage=", info.nPage, " nPos=", info.nPos
      check info.nMin == 0
      check info.nPage >= 1'u32
      check info.nPos == 0
      check wantedUnits > 65_535
      check info.nMax > 65_535

      scrollTo(port, SB_BOTTOM)
      f.settle()
      let rows = clippedRows(port)
      var rowLine = ""
      for item in rows: rowLine.add("(" & $item.y & "," & item.text & ")")
      var bottom = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)),
        fMask: SIF_RANGE or SIF_PAGE or SIF_POS)
      check GetScrollInfo(port, SB_VERT, addr bottom) != 0
      echo "case2 bottom rows=", rowLine, " nMin=", bottom.nMin,
        " nMax=", bottom.nMax, " nPage=", bottom.nPage, " nPos=", bottom.nPos,
        " wanted_bottom=", wantedBottom
      check rows.len == 1
      if rows.len == 1:
        check rows[0].text == "item 9999"
        check rows[0].y < 0                    # top clipped: only the bottom shows
      check bottom.nPos > 65_535
      # Independent Wanted from the frozen public projection and known geometry:
      let delta = abs(int64(bottom.nPos) - int64(wantedBottom))
      echo "case2 nPos delta=", delta, " tolerance=1 unit"
      check delta <= 1

      scrollTo(port, SB_TOP)
      f.settle()
      var top = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)),
        fMask: SIF_RANGE or SIF_PAGE or SIF_POS)
      check GetScrollInfo(port, SB_VERT, addr top) != 0
      echo "case2 back to top nMin=", top.nMin, " nMax=", top.nMax,
        " nPage=", top.nPage, " nPos=", top.nPos
      check top.nPos == 0)
    f.h.destroyHost()
    check f.h.resourcesReleasedInternal()
