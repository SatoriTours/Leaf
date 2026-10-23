## Variable-height source replacement must discard old measurements and anchor.
## A has 24/48-DIP rows; PageDown reaches offset106/key3+10. B swaps keys3/5,
## all rows are24 DIP. Numeric intent106 must stay106: key4 is at-10,key3 at14.
## Reusing A's HeightIndex or preserving its key3 anchor makes these checks fail.
## Empty+refill then verifies accepted geometry and old-source request rejection.
when not defined(windows) or not defined(leafProtocolProbes):
  {.error: "Requires real Windows and leafProtocolProbes".}

import std/[tables, options, os, strutils]
import leaf/[core, widgets, components, backend, backend_session, ui_thread,
  native_layout]
import leaf/component_description
import leaf/backends/win32/[api, host, backend, calls]

var sourceState: State[int]
var rowStates: Table[string, State[int]]
var renders, accepts: int

type RowProps = tuple[index, phase: int, key: string]
let RowDef = defineComponent[RowProps, State[int]]("SourceRow",
  proc(ctx: MountContext, props: RowProps): State[int] =
    result = ctx.state(0)
    rowStates[props.key] = result,
  proc(ctx: ComponentContext, props: RowProps, state: State[int]): UiDescription =
    let height = case props.phase
      of 0: (if props.index mod 2 == 0: 24 else: 48)
      of 1: 24
      else: 48
    host(row(@[text(props.key & ":" & $ctx.value(state), key="label")],
      key="row", styles=style({"height": $height}))))
let PageDef = defineComponent[int, State[int]]("SourcePage",
  proc(ctx: MountContext, value: int): State[int] =
    result = ctx.state(0)
    sourceState = result,
  proc(ctx: ComponentContext, value: int, state: State[int]): UiDescription =
    inc renders
    let phase = ctx.value(state)
    var keys: seq[string]
    if phase != 2:
      for index in 0 ..< 20: keys.add("item-" & $index)
      if phase == 1: swap(keys[3], keys[5])
    componentList("list", keys,
      proc(index: int): UiDescription =
        component(RowDef, (index: index, phase: phase, key: keys[index])),
      rowHeight=0.0, estimatedHeight=24.0, overscan=1,
      styles=style({"height": "130"})))

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
  let failureMode = paramCount() > 0 and paramStr(1) == "failure"
  let activity = newUiScopeActivity()
  let rt = newRuntime(guardUiApplication(componentApplication(
    component(PageDef, 0), "variable-source", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  var h: Win32Host
  var primary, secondary: ref CatchableError
  try:
    h = createHost("variable-source", DipSize(width:480, height:320))
    h.setStartupScope(proc(): bool = activity.busy or rt.installingUpdate or rt.installingHook)
    var armed, injected: bool
    var port: HWND
    let system = systemWin32Calls()
    var seam = system
    seam.windowPos = proc(window, after: HWND, x,y,width,height: int32,
                         flags: UINT): BOOL =
      if armed and not injected and width > 0 and height > 0 and
          GetParent(window) == port:
        injected = true
        setLastError(1234)
        return 0
      system.windowPos(window,after,x,y,width,height,flags)
    let win = newWin32Backend(h,seam)
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
    for entity in session.acceptedEntities().values:
      if entity.kind == NodeKind.virtualList: list=entity.handle
      if entity.row.isSome:
        port=GetParent(win.rowWindowForTest(entity.handle))
    require(list != NoHandle and port != nil, "prime native list/viewport")
    let dpi=GetDpiForWindow(port)
    require(dpi == 96, "this literal pixel oracle requires actual96 DPI")
    discard SendMessageW(port, WM_VSCROLL, WPARAM(SB_PAGEDOWN), 0)
    win.safeListTurn()
    win.safeListTurn()
    let before=win.listFrameForTest(list)
    require(before.rowsetReady and before.acceptedOffset == 106 and
      before.acceptedFirst == 3, "sourceA PageDown key3+10")
    let oldState=rowStates["item-3"]
    let oldRequest=RowViewportRequest(sessionId:session.sessionId,
      mountGeneration:session.mountGeneration, listHandle:list,
      sourceGeneration:before.acceptedSource, first:2, finish:8, protected: @[])
    require(oldState.set(7) == StateWriteResult.queued, "set old key3 State")
    discard rt.flush()
    if failureMode:
      let stableBefore=win.listFrameForTest(list)
      let revisionBefore=rt.acceptedRevision
      armed=true
      require(sourceState.set(1) == StateWriteResult.queued, "failing sourceB update")
      var refused: ref CatchableError
      try: discard rt.flush()
      except CatchableError as error: refused=error
      armed=false
      require(injected and refused != nil and "1234" in refused.msg and
        "accepted-plan replay failed" notin refused.msg,
        "source switch placement fails once and keeps primary1234")
      let replay=win.listFrameForTest(list)
      require(replay.acceptedToken == stableBefore.acceptedToken and
        replay.acceptedSource == before.acceptedSource and
        replay.acceptedOffset == 106 and replay.acceptedRows == stableBefore.acceptedRows and
        rt.acceptedRevision == revisionBefore and sourceState.read() == 0 and
        oldState.read() == 7, "source switch failure replays accepted source/geometry/State")
      var restored=0
      for entity in session.acceptedEntities().values:
        if entity.row.isNone: continue
        let binding=entity.row.get
        let window=win.rowWindowForTest(entity.handle)
        require(window != nil, "replayed sourceA row has HWND")
        port=GetParent(window)
        let expectedTop=case binding.itemIndex
          of 2: -34
          of 3: -10
          of 4: 38
          of 5: 62
          of 6: 110
          of 7: 134
          else: -10000
        require(binding.sourceGeneration == before.acceptedSource and
          binding.itemKey == "item-" & $binding.itemIndex and
          rectOf(window,port).top == int32(expectedTop),
          "actual replay rect and typed source match accepted sourceA")
        inc restored
      require(restored == 6, "replayed six sourceA rows")
      win.safeListTurn()
      win.safeListTurn()
      require(rt.acceptedRevision == revisionBefore and
        win.listFrameForTest(list).acceptedOffset == 106,
        "failed business source replacement has no hidden retry")
      echo "source_failure primary=1234 source=", replay.acceptedSource,
        " replay_token=", replay.acceptedToken,
        " offset=106 rows=6 state=7 idle_retry=0"
    require(sourceState.set(1) == StateWriteResult.queued, "sourceB parent update")
    discard rt.flush()
    # Fixed schedule, never extended on failure.
    for turn in 0 ..< 4: win.safeListTurn()
    let changed=win.listFrameForTest(list)
    echo "sourceB old=", before.acceptedSource, " new=", changed.acceptedSource,
      " offset=", changed.acceptedOffset, " first=", changed.acceptedFirst,
      " finish=", changed.acceptedFinish, " ready=", changed.rowsetReady,
      " rows=", changed.acceptedRows
    require(changed.rowsetReady and changed.acceptedSource != before.acceptedSource and
      changed.acceptedOffset == 106 and changed.acceptedFirst == 4 and
      changed.acceptedFinish == 10, "sourceB uses fresh24-DIP heights and numeric intent106")
    var row4, moved: HWND
    var count=0
    for entity in session.acceptedEntities().values:
      if entity.row.isNone: continue
      let binding=entity.row.get
      inc count
      let expectedKey=case binding.itemIndex
        of 3: "item-5"
        of 5: "item-3"
        else: "item-" & $binding.itemIndex
      require(binding.sourceGeneration == changed.acceptedSource and
        binding.itemIndex in 3 .. 10 and binding.itemKey == expectedKey,
        "sourceB accepted typed key/index/source")
      let window=win.rowWindowForTest(entity.handle)
      require(window != nil and GetParent(window) == port, "same viewport HWND")
      let rect=rectOf(window,port)
      require(rect.top == int32(binding.itemIndex*24-106) and
        rect.bottom-rect.top == 24, "sourceB actual row rect follows24-DIP literal fixture")
      if binding.itemIndex == 4: row4=window
      if binding.itemKey == "item-3": moved=window
    require(count == 8 and row4 != nil and moved != nil,
      "sourceB bounded eight rows contains moved old key")
    require(rectOf(row4,port).top == -10 and rectOf(moved,port).top == 14,
      "sourceB must not preserve old key3 anchor at new index5")
    require(oldState.set(8) == StateWriteResult.disposed and
      rowStates["item-3"].read() == 0, "new source replaces row State owners")
    require(not session.queueRows(oldRequest), "old source viewport request is rejected")
    echo "sourceB key4_top=-10 moved_key3_top=14 stale_request=rejected old_state=disposed"
    require(sourceState.set(2) == StateWriteResult.queued, "empty source update")
    discard rt.flush()
    for turn in 0 ..< 4: win.safeListTurn()
    let empty=win.listFrameForTest(list)
    var emptyRows=0
    for entity in session.acceptedEntities().values:
      if entity.row.isSome: inc emptyRows
    echo "empty offset=", empty.acceptedOffset, " rows=", emptyRows,
      " ready=", empty.rowsetReady, " source=", empty.acceptedSource
    require(empty.hasAccepted and empty.rowsetReady and empty.acceptedOffset == 0 and
      empty.acceptedRows.len == 0 and emptyRows == 0 and
      empty.acceptedSource != changed.acceptedSource, "empty accepted source clamps offset and retires rows")
    require(sourceState.set(3) == StateWriteResult.queued, "refill source update")
    discard rt.flush()
    for turn in 0 ..< 4: win.safeListTurn()
    let filled=win.listFrameForTest(list)
    echo "refill offset=", filled.acceptedOffset, " first=", filled.acceptedFirst,
      " finish=", filled.acceptedFinish, " ready=", filled.rowsetReady,
      " rows=", filled.acceptedRows
    require(filled.rowsetReady and filled.acceptedOffset == 0 and
      filled.acceptedFirst == 0 and filled.acceptedFinish == 3 and
      filled.acceptedSource != empty.acceptedSource, "refill starts at zero with48-DIP rows")
    var filledRows=0
    for entity in session.acceptedEntities().values:
      if entity.row.isNone: continue
      inc filledRows
      let binding=entity.row.get
      let rect=rectOf(win.rowWindowForTest(entity.handle),port)
      require(binding.sourceGeneration == filled.acceptedSource and
        binding.itemIndex in 0 .. 3 and binding.itemKey == "item-" & $binding.itemIndex and
        rect.top == int32(binding.itemIndex*48) and rect.bottom-rect.top == 48,
        "refill typed rows and actual rects")
    require(filledRows == 4, "refill four bounded physical rows")
    let stableRevision=rt.acceptedRevision
    let stableAccepts=accepts
    win.safeListTurn()
    win.safeListTurn()
    require(rt.acceptedRevision == stableRevision and accepts == stableAccepts and
      win.listFrameForTest(list).acceptedOffset == 0 and
      win.listIntentForTest(list).desiredOffset == 0 and
      renders == (if failureMode: 5 else: 4),
      "two quiet turns preserve settled refill without extra publication")
    echo "source_replace reordered=true empty=true refill=true stable=true"
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
  echo "probe_win32_variable_source status=passed"
  0

when isMainModule:
  quit(main())
