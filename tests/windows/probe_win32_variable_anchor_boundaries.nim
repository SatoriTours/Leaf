## Anchor transaction boundaries: pending intent, intent during native apply,
## and failed row-local State placement with accepted-frame replay. Literal
## targets202/154 deliberately differ to detect a swallowed user scroll.
when not defined(windows) or not defined(leafProtocolProbes):
  {.error: "Requires real Windows and leafProtocolProbes".}

import std/[tables, options, os, strutils]
import leaf/[core, widgets, components, backend, backend_session, ui_thread,
  native_layout]
import leaf/component_description
import leaf/backends/win32/[api, host, backend, calls]

var keys: seq[string]
var rowTwo: State[int]
var renders, accepts: int
let RowDef = defineComponent[int, State[int]]("AnchorBoundaryRow",
  proc(ctx: MountContext, index: int): State[int] =
    result = ctx.state(0)
    if index == 2: rowTwo = result,
  proc(ctx: ComponentContext, index: int, state: State[int]): UiDescription =
    let base = if index mod 2 == 0: 24 else: 48
    let height = base + int(ctx.value(state)) * 48
    host(row(@[text($index, key = "label")], key = "row",
      styles = style({"height": $height}))))
let PageDef = defineComponent[int, int]("AnchorBoundaryPage",
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
  let mode = if paramCount() > 0: paramStr(1) else: "pending"
  require(mode in ["pending", "during", "failure", "failure-during"], "known boundary scenario")
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
    var port, target: HWND
    var armed, injected: bool
    let system = systemWin32Calls()
    var seam = system
    seam.windowPos = proc(window, after: HWND, x, y, width, height: int32,
                         flags: UINT): BOOL =
      if armed and not injected and window == target and width > 0 and height > 0:
        injected = true
        if mode in ["during", "failure-during"]:
          # Genuine native messages at the actual placement boundary, never
          # a probe setter or fake scrollInfo/trackpos result.
          discard SendMessageW(port, WM_VSCROLL, WPARAM(SB_LINEDOWN), 0)
          discard SendMessageW(port, WM_VSCROLL, WPARAM(SB_LINEDOWN), 0)
        if mode in ["failure", "failure-during"]:
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
    # From key3+10 at106, two LineDown messages request202 (2*48).
    # The height change alone would preserve the old key3 at154. Different
    # literal targets make an anchor overriding user intent observable.
    if mode == "pending":
      discard SendMessageW(port, WM_VSCROLL, WPARAM(SB_LINEDOWN), 0)
      discard SendMessageW(port, WM_VSCROLL, WPARAM(SB_LINEDOWN), 0)
      require(win.listIntentForTest(list).desiredOffset == 202,
        "pending real scroll target must be202")
    target = windows[1]       # key3; key2 has already been placed on failure.
    armed = mode != "pending"
    require(rowTwo.set(1) == StateWriteResult.queued, "row2 height State write")
    var refused: ref CatchableError
    try: discard rt.flush()
    except CatchableError as error: refused = error
    armed = false
    if mode in ["failure", "failure-during"]:
      require(injected and refused != nil and "1234" in refused.msg and
        "SetWindowPos row subtree" in refused.msg,
        "real placement failure must preserve primary error")
      require("accepted-plan replay failed" notin refused.msg,
        "accepted geometry replay must succeed")
      let restored = win.listFrameForTest(list)
      require(restored.acceptedOffset == 106 and
        restored.acceptedToken == before.acceptedToken and
        restored.acceptedRows == before.acceptedRows and
        rt.acceptedRevision == revision,
        "failure restores accepted frame, HeightIndex and Runtime revision")
      # Recovery may recreate native controls; inspect actual current windows
      # through the same typed handles, never the destroyed HWNDs.
      let expected = [-34.0, -10.0, 38.0, 62.0, 110.0, 134.0]
      for index in 0 ..< 6:
        let window = win.rowWindowForTest(handles[index])
        require(window != nil, "replayed typed row has a real HWND")
        let rowPort = GetParent(window)
        require(abs(float64(rectOf(window, rowPort).top) - expected[index] * scale) <= 1.0,
          "replayed actual row top " & $index)
      let intent = win.listIntentForTest(list)
      echo "failure replay offset=", restored.acceptedOffset,
        " desired=", intent.desiredOffset, " generation=", intent.intentGeneration
      if mode == "failure":
        require(intent.desiredOffset == 106 and intent.appliedOffset == 106,
          "recreated host must retain the accepted scroll baseline")
        win.safeListTurn()
        win.safeListTurn()
        require(win.listFrameForTest(list).acceptedOffset == 106 and
          rt.acceptedRevision == revision,
          "next ordinary turns must not jump or publish after rollback")
        echo "failure restored offset=106 stable=true"
      else:
        require(intent.desiredOffset == 202 and intent.appliedOffset == 106,
          "intent arriving during failed apply survives host recreation")
        win.safeListTurn()
        win.safeListTurn()
        let settled = win.listFrameForTest(list)
        require(settled.acceptedOffset == 202 and settled.acceptedFirst == 5 and
          settled.rowsetReady and win.listIntentForTest(list).desiredOffset == 202,
          "later turns apply the pending intent to the restored old heights")
        let window = win.rowWindowForTest(handles[3]) # key5, old prefix168
        require(window != nil and
          abs(float64(rectOf(window, GetParent(window)).top) + 34.0 * scale) <= 1.0,
          "actual restored key5 top must reflect user target202")
        echo "failure-during restored=106 pending=202 later_applied=202 key5_top=-34"
    else:
      require(refused == nil, "height update must succeed")
      let after = win.listFrameForTest(list)
      let intent = win.listIntentForTest(list)
      echo "boundary mode=", mode, " accepted=", after.acceptedOffset,
        " desired=", intent.desiredOffset, " generation=", intent.intentGeneration
      if mode == "pending":
        require(after.acceptedOffset == 202 and intent.desiredOffset == 202,
          "newer user intent takes priority over old key3 anchor154")
      else:
        require(injected and after.acceptedOffset == 154 and intent.desiredOffset == 202,
          "intent arriving during native apply survives anchored publication")
      require(after.acceptedSource == before.acceptedSource and
        rt.acceptedRevision == revision + 1 and accepts == beforeAccepts + 1 and
        renders == 1 and win.diagnostics.creates == creates,
        "initial State candidate is one commit with existing bindings")
      win.safeListTurn()
      win.safeListTurn()
      let settled = win.listFrameForTest(list)
      require(settled.acceptedOffset == 202 and settled.acceptedFirst == 4 and
        settled.rowsetReady and win.listIntentForTest(list).desiredOffset == 202,
        "two fixed turns materialize the requested key4+10 viewport")
      for index in 1 ..< 6:
        require(win.rowWindowForTest(handles[index]) == windows[index],
          "still-materialized keys retain HWND during intent settlement")
      require(abs(float64(rectOf(windows[2], port).top) + 10.0 * scale) <= 1.0,
        "actual key4 top must reflect user target202")
      require(rt.acceptedRevision == revision + 2 and accepts == beforeAccepts + 2 and
        renders == 1, "only the State update and changed rowset publish")
      echo "intent mode=", mode, " offset=202 key=item-4 delta=10 stable=true"
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
  echo "probe_win32_variable_anchor_boundaries mode=" & mode & " status=passed"
  0

when isMainModule:
  quit(main())
