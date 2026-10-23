## A first visible row shrinks below the accepted intra-row delta.
## Real PageDown reaches key3 +10; shrinking key3 48->6 clamps to its end,
## so key4 begins at y=0 and offset=102. No HeightIndex-derived oracle.
## Removing the anchor delta clamp must fail the offset/native rect assertions.
when not defined(windows) or not defined(leafProtocolProbes):
  {.error: "Requires real Windows and leafProtocolProbes".}

import std/[tables, options, math]
import leaf/[core, widgets, components, backend, backend_session, ui_thread,
  native_layout]
import leaf/component_description
import leaf/backends/win32/[api, host, backend]

var keys: seq[string]
var rowThree: State[int]
var renders, accepts: int
let RowDef = defineComponent[int, State[int]]("ShrinkRow",
  proc(ctx: MountContext, index: int): State[int] =
    result = ctx.state(0)
    if index == 3: rowThree = result,
  proc(ctx: ComponentContext, index: int, state: State[int]): UiDescription =
    let base = if index mod 2 == 0: 24 else: 48
    let height = if index == 3 and ctx.value(state) == 1: 6 else: base
    host(row(@[text($index, key = "label")], key = "row",
      styles = style({"height": $height}))))
let PageDef = defineComponent[int, int]("ShrinkPage",
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
    component(PageDef, 0), "variable-shrink", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  var h: Win32Host
  var primary, secondary: ref CatchableError
  try:
    h = createHost("variable-shrink", DipSize(width: 480, height: 320))
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
    require(rowThree.set(1) == StateWriteResult.queued, "row3 shrink State write")
    discard rt.flush()
    let immediate = win.listFrameForTest(list)
    echo "shrink_commit offset=", immediate.acceptedOffset,
      " first=", immediate.acceptedFirst, " ready=", immediate.rowsetReady
    # Exactly two ordinary turns allow the new trailing row to materialize.
    # No loop extends this schedule when the result is wrong.
    win.safeListTurn()
    win.safeListTurn()
    let after = win.listFrameForTest(list)
    var row3, row4: HWND
    var row3Handle: NodeHandle
    for entity in session.acceptedEntities().values:
      if entity.row.isNone: continue
      let identity = entity.row.get
      require(identity.itemKey == keys[identity.itemIndex], "typed stable key")
      if identity.itemIndex == 3:
        row3 = win.rowWindowForTest(entity.handle)
        row3Handle = entity.handle
      if identity.itemIndex == 4: row4 = win.rowWindowForTest(entity.handle)
    require(row3 != nil and row4 != nil, "anchor and next row remain materialized")
    let anchorRect = rectOf(row3, port)
    let nextRect = rectOf(row4, port)
    echo "shrunk offset=", after.acceptedOffset, " first=", after.acceptedFirst,
      " key3_top_px=", anchorRect.top, " key3_height_px=",
      anchorRect.bottom-anchorRect.top, " key4_top_px=", nextRect.top,
      " desired=", win.listIntentForTest(list).desiredOffset,
      " revision=", rt.acceptedRevision
    require(after.acceptedOffset == 102 and after.acceptedFirst == 4 and
      after.rowsetReady, "shrunk anchor clamps delta10 to row end6 at offset102")
    require(abs(float64(anchorRect.top) + 6.0*scale) <= 1.0 and
      abs(float64(anchorRect.bottom-anchorRect.top) - 6.0*scale) <= 1.0 and
      abs(float64(nextRect.top)) <= 1.0,
      "actual key3 ends at viewport top and key4 starts at zero")
    require(row3 == windows[1] and row3Handle == handles[1],
      "same anchor typed entity and HWND survive shrink")
    require(after.acceptedSource == before.acceptedSource and renders == 1 and
      rt.acceptedRevision > revision, "same source with row-local State commit")
    let settledRevision = rt.acceptedRevision
    let settledAccepts = accepts
    win.safeListTurn()
    win.safeListTurn()
    require(win.listFrameForTest(list).acceptedOffset == 102 and
      win.listIntentForTest(list).desiredOffset == 102 and
      rectOf(row3, port) == anchorRect and rectOf(row4, port) == nextRect,
      "clamped offset remains stable on two later ordinary turns")
    require(rt.acceptedRevision == settledRevision and accepts == settledAccepts,
      "settled shrink needs no extra business publication")
    echo "shrink key=item-3 old_delta=10 new_height=6 offset=102 stable=true"
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
  echo "probe_win32_variable_shrink status=passed"
  0

when isMainModule:
  quit(main())
