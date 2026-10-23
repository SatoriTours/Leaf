## Same-rowset geometry failure: a real row placement is refused after earlier
## rows moved. One replay must restore the accepted frame, rects, clips and bar;
## one later ordinary turn retries the still-pending user intent.
when not defined(windows) or not defined(leafProtocolProbes):
  {.error: "Requires real Windows and leafProtocolProbes".}

import std/[tables, options, strutils, math]
import leaf/[core, widgets, components, backend, backend_session, ui_thread,
  native_layout]
import leaf/component_description
import leaf/backends/win32/[api, calls, host, backend]

proc GetWindowRgnBox(window: HWND, rect: ptr RECT): int32 {.
  importc: "GetWindowRgnBox", dynlib: "user32.dll", stdcall.}

type RowSample = object
  handle: NodeHandle
  window: HWND
  rect, clip: RECT
  region: int32

var keys: seq[string]
var renders, accepts: int
let RowDef = defineComponent[int, int]("ScrollFailureRow",
  proc(ctx: MountContext, index: int): int = index,
  proc(ctx: ComponentContext, index, model: int): UiDescription =
    host(row(@[text($index, key = "label")], key = "row",
      styles = style({"height": (if index mod 2 == 0: "24" else: "48")}))))
let PageDef = defineComponent[int, int]("ScrollFailurePage",
  proc(ctx: MountContext, value: int): int = value,
  proc(ctx: ComponentContext, value, model: int): UiDescription =
    inc renders
    componentList("list", keys,
      proc(index: int): UiDescription = component(RowDef, index),
      rowHeight = 0.0, estimatedHeight = 24.0, overscan = 1,
      styles = style({"height": "120"})))

proc require(value: bool, message: string) =
  if not value: raise newException(UiError, message)

proc rectOf(window, port: HWND): RECT =
  require(GetWindowRect(window, addr result) != 0, "GetWindowRect sample")
  var points = [POINT(x: result.left, y: result.top),
    POINT(x: result.right, y: result.bottom)]
  setLastError(0)
  let mapped = MapWindowPoints(nil, port, addr points[0], 2)
  require(mapped != 0 or lastError() == 0, "MapWindowPoints sample")
  result = RECT(left: points[0].x, top: points[0].y,
    right: points[1].x, bottom: points[1].y)

proc barOf(port: HWND): SCROLLINFO =
  result = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: SIF_ALL)
  require(GetScrollInfo(port, SB_VERT, addr result) != 0, "GetScrollInfo sample")

proc sameBar(a, b: SCROLLINFO): bool =
  a.nMin == b.nMin and a.nMax == b.nMax and
    a.nPage == b.nPage and a.nPos == b.nPos

proc main(): int =
  for index in 0 ..< 20: keys.add($index)
  let activity = newUiScopeActivity()
  let rt = newRuntime(guardUiApplication(componentApplication(
    component(PageDef, 0), "scroll-failure", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  var h: Win32Host
  var primary, secondary: ref CatchableError
  try:
    h = createHost("scroll-failure", DipSize(width: 480, height: 320))
    h.setStartupScope(proc(): bool = activity.busy or rt.installingUpdate or rt.installingHook)
    var armed, injected: bool
    var target: HWND
    var targetY: int32
    let system = systemWin32Calls()
    var seam = system
    seam.windowPos = proc(window, after: HWND, x, y, width, height: int32,
                         flags: UINT): BOOL =
      if armed and not injected and window == target and
          y == targetY and width > 0 and height > 0:
        injected = true
        echo "injected row=2 y=", y, " error=1234"
        setLastError(1234)
        return 0
      system.windowPos(window, after, x, y, width, height, flags)
    let win = newWin32Backend(h, seam)
    let realAccept = win.asBackend.acceptedDelta
    win.asBackend.acceptedDelta = proc(delta: HostAcceptedDelta) {.raises: [].} =
      inc accepts
      realAccept(delta)
    let session = win.attachWin32Backend(rt)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    win.safeListTurn()
    win.safeListTurn()
    var list: NodeHandle
    var port: HWND
    var rows: array[5, RowSample]
    var count: int
    for entity in session.acceptedEntities().values:
      if entity.kind == NodeKind.virtualList: list = entity.handle
      if entity.row.isNone: continue
      let index = entity.row.get.itemIndex
      require(index in 0 .. 4, "prime contains extra typed row")
      inc count
      rows[index].handle = entity.handle
      rows[index].window = win.rowWindowForTest(entity.handle)
      require(rows[index].window != nil, "prime row missing HWND")
      let parent = GetParent(rows[index].window)
      require(parent != nil and (port == nil or parent == port), "row parent sample")
      port = parent
    require(count == 5 and list != NoHandle, "prime requires five typed rows")
    let dpi = GetDpiForWindow(port)
    var client: RECT
    require(dpi > 0 and GetClientRect(port, addr client) != 0, "client sample")
    let scale = float64(dpi) / 96.0
    require(abs(float64(client.bottom - client.top) - 120.0 * scale) <= 1.0,
      "prime viewport must be 120 DIP")
    for row in rows.mitems:
      row.rect = rectOf(row.window, port)
      row.region = GetWindowRgnBox(row.window, addr row.clip)
      require(row.region in 1'i32 .. 3'i32, "prime region sample")
    let before = win.listFrameForTest(list)
    require(before.hasAccepted and before.rowsetReady and before.acceptedOffset == 0,
      "prime accepted measured frame")
    let bar = barOf(port)
    let revision = rt.acceptedRevision
    let creates = win.diagnostics.creates
    let beforeAccepts = accepts
    target = rows[2].window
    targetY = int32(round(48.0 * scale))
    discard SendMessageW(port, WM_VSCROLL, WPARAM(SB_LINEDOWN), 0)
    armed = true
    var refused: ref CatchableError
    try: win.safeListTurn()
    except CatchableError as error: refused = error
    armed = false
    require(injected and refused != nil, "must reach injected row placement refusal")
    require("SetWindowPos row subtree" in refused.msg and "1234" in refused.msg,
      "original placement error must survive replay")
    require("accepted-plan replay failed" notin refused.msg, "replay must succeed")
    let restored = win.listFrameForTest(list)
    require(restored.acceptedToken == before.acceptedToken and
      restored.acceptedFrameId == before.acceptedFrameId and
      restored.acceptedOffset == before.acceptedOffset and
      restored.acceptedRows == before.acceptedRows and not restored.hasPrepared,
      "failure must preserve old accepted frame and index")
    require(sameBar(barOf(port), bar), "old native scrollbar must be replayed")
    for row in rows:
      require(win.rowWindowForTest(row.handle) == row.window, "replay keeps typed HWND")
      require(rectOf(row.window, port) == row.rect, "old native row rect must be replayed")
      var clip: RECT
      let region = GetWindowRgnBox(row.window, addr clip)
      require(region == row.region, "old region kind must be replayed")
      if region in 2'i32 .. 3'i32:
        require(clip == row.clip, "old nonempty clip box must be replayed")
    let pending = win.listIntentForTest(list)
    require(pending.valid and pending.desiredOffset == 24 and pending.appliedOffset == 0,
      "failed geometry retains pending user intent")
    require(rt.acceptedRevision == revision and accepts == beforeAccepts,
      "failure and replay do not publish business state")
    echo "replay token=", restored.acceptedToken, " offset=0 revision=", revision,
      " rects_clips_bar_restored=true"
    win.safeListTurn()              # One fixed retry turn; never poll until green.
    let after = win.listFrameForTest(list)
    require(after.acceptedOffset == 24 and after.rowsetReady and
      after.acceptedToken != before.acceptedToken, "later turn retries intent")
    let expected = [-24.0, 0.0, 48.0, 72.0, 120.0]
    for index, row in rows:
      let rect = rectOf(row.window, port)
      require(abs(float64(rect.top) - expected[index] * scale) <= 1.0,
        "retry actual row top " & $index)
      require(win.rowWindowForTest(row.handle) == row.window, "retry keeps HWND")
    require(rt.acceptedRevision == revision and accepts == beforeAccepts and
      renders == 1 and win.diagnostics.creates == creates,
      "retry is pure geometry without render, accept, revision or HWND churn")
    require(barOf(port).nPos == 1, "retry native scrollbar reflects offset24")
    echo "retry offset=24 revision=", rt.acceptedRevision, " native_accept_delta=",
      accepts - beforeAccepts, " creates_delta=", win.diagnostics.creates - creates
  except CatchableError as error: primary = error
  if h != nil:
    try: h.destroyHost()
    except CatchableError as error: secondary = error
    if not h.resourcesReleasedInternal() and secondary == nil:
      secondary = newException(UiError, "host cleanup incomplete")
  if secondary == nil:
    try: rt.closeRuntime()
    except CatchableError as error: secondary = error
  if primary != nil: echo "primary: ", primary.name, " ", primary.msg
  if secondary != nil: echo "secondary: ", secondary.name, " ", secondary.msg
  if primary != nil or secondary != nil: return 1
  echo "probe_win32_variable_scroll_failure status=passed"
  0

when isMainModule:
  quit(main())
