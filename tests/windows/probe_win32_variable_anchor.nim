## Same-source variable-height anchor, exercised through real native scrolling
## and a row-local State update. Literal coordinates follow the fixture's
## 24/48 DIP heights; they are not recomputed with the production HeightIndex.
when not defined(windows) or not defined(leafProtocolProbes):
  {.error: "Requires real Windows and leafProtocolProbes".}

import std/[tables, options, math]
import leaf/[core, widgets, components, backend, backend_session, ui_thread,
  native_layout]
import leaf/component_description
import leaf/backends/win32/[api, host, backend]

var keys: seq[string]
var rowTwo: State[int]
var renders, accepts: int
let RowDef = defineComponent[int, State[int]]("AnchorRow",
  proc(ctx: MountContext, index: int): State[int] =
    result = ctx.state(0)
    if index == 2: rowTwo = result,
  proc(ctx: ComponentContext, index: int, state: State[int]): UiDescription =
    let base = if index mod 2 == 0: 24 else: 48
    let height = base + int(ctx.value(state)) * 48
    host(row(@[text($index, key = "label")], key = "row",
      styles = style({"height": $height}))))
let PageDef = defineComponent[int, int]("AnchorPage",
  proc(ctx: MountContext, value: int): int = value,
  proc(ctx: ComponentContext, value, model: int): UiDescription =
    inc renders
    componentList("list", keys,
      proc(index: int): UiDescription = component(RowDef, index),
      rowHeight = 0.0, estimatedHeight = 24.0, overscan = 1,
      styles = style({"height": "130"})))

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

proc main(): int =
  for index in 0 ..< 20: keys.add("item-" & $index)
  let activity = newUiScopeActivity()
  let rt = newRuntime(guardUiApplication(componentApplication(
    component(PageDef, 0), "variable-anchor", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  var h: Win32Host
  var primary, secondary: ref CatchableError
  try:
    h = createHost("variable-anchor", DipSize(width: 480, height: 320))
    h.setStartupScope(proc(): bool = activity.busy or rt.installingUpdate or rt.installingHook)
    let win = newWin32Backend(h)
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
    var primeRows: int
    for entity in session.acceptedEntities().values:
      if entity.kind == NodeKind.virtualList: list = entity.handle
      if entity.row.isNone: continue
      inc primeRows
      require(entity.row.get.itemIndex in 0 .. 4, "prime typed row outside 0..4")
      let window = win.rowWindowForTest(entity.handle)
      require(window != nil, "prime row missing HWND")
      let parent = GetParent(window)
      require(parent != nil and (port == nil or port == parent), "prime native parent")
      port = parent
    require(primeRows == 5 and list != NoHandle, "prime requires five typed rows")
    let dpi = GetDpiForWindow(port)
    var client: RECT
    require(dpi > 0 and GetClientRect(port, addr client) != 0, "client sample")
    let scale = float64(dpi) / 96.0
    require(abs(float64(client.bottom - client.top) - 130.0 * scale) <= 1.0,
      "viewport must be 130 DIP")
    let prime = win.listFrameForTest(list)
    require(prime.hasAccepted and prime.rowsetReady and prime.acceptedOffset == 0,
      "prime measured frame must be ready")
    # PageDown moves by viewport130 - first-row24 = 106 DIP. Key3 starts
    # at96, so the actual first visible row has an in-row delta of10.
    discard SendMessageW(port, WM_VSCROLL, WPARAM(SB_PAGEDOWN), 0)
    win.safeListTurn()
    win.safeListTurn()
    let before = win.listFrameForTest(list)
    echo "scrolled offset=", before.acceptedOffset, " first=", before.acceptedFirst,
      " finish=", before.acceptedFinish, " ready=", before.rowsetReady,
      " rows=", before.acceptedRows
    require(before.rowsetReady and before.acceptedOffset == 106 and
      before.acceptedFirst == 3 and before.acceptedFinish == 7,
      "real PageDown must reach key3 plus delta10")
    var handles: array[6, NodeHandle]
    var windows: array[6, HWND]
    var count: int
    for entity in session.acceptedEntities().values:
      if entity.row.isNone: continue
      let index = entity.row.get.itemIndex
      require(index in 2 .. 7 and entity.row.get.itemKey == keys[index],
        "scrolled typed identity must be key2..key7")
      inc count
      handles[index - 2] = entity.handle
      windows[index - 2] = win.rowWindowForTest(entity.handle)
      require(windows[index - 2] != nil and GetParent(windows[index - 2]) == port,
        "scrolled row shares native viewport")
    require(count == 6, "scrolled rowset has six rows")
    let beforeRect = rectOf(windows[1], port)
    require(abs(float64(beforeRect.top) + 10.0 * scale) <= 1.0,
      "real key3 top before update must be -10 DIP")
    let revision = rt.acceptedRevision
    let beforeAccepts = accepts
    let creates = win.diagnostics.creates
    require(rowTwo.set(1) == StateWriteResult.queued, "row2 height State write")
    discard rt.flush()
    let after = win.listFrameForTest(list)
    let afterRect = rectOf(windows[1], port)
    echo "updated offset=", after.acceptedOffset, " first=", after.acceptedFirst,
      " key3_top_px=", afterRect.top, " desired=",
      win.listIntentForTest(list).desiredOffset, " revision=", rt.acceptedRevision
    # Row2 grows24 ->72 (+48); key3 prefix96 ->144. Preserve key3+10:
    # accepted offset154 and the same -10 DIP actual native row top.
    require(after.acceptedOffset == 154 and after.acceptedFirst == 3 and
      after.rowsetReady, "height update must preserve key3 plus delta10 at offset154")
    require(afterRect == beforeRect, "native anchor row must not move or resize")
    require(after.acceptedSource == before.acceptedSource,
      "row-local height update keeps source generation")
    for index in 0 ..< 6:
      require(win.rowWindowForTest(handles[index]) == windows[index],
        "height update preserves every materialized HWND")
    require(rt.acceptedRevision == revision + 1 and accepts == beforeAccepts + 1 and
      renders == 1 and win.diagnostics.creates == creates,
      "row-local update commits once without parent render or native creation")
    # Fixed ordinary turns catch stale desiredOffset pulling the accepted anchor
    # back to106. Never extend the schedule until it happens to become green.
    win.safeListTurn()
    win.safeListTurn()
    require(win.listFrameForTest(list).acceptedOffset == 154 and
      win.listIntentForTest(list).desiredOffset == 154 and
      rectOf(windows[1], port) == beforeRect,
      "anchored offset remains the next turn's scroll authority")
    require(rt.acceptedRevision == revision + 1 and accepts == beforeAccepts + 1,
      "settled anchor needs no extra business publication")
    echo "anchor key=item-3 delta=10 offset=154 stable=true creates_delta=0"
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
  echo "probe_win32_variable_anchor status=passed"
  0

when isMainModule:
  quit(main())
