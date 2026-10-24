## Real Host.pump source replacement: queued scroll, then two native button clicks.
## Catches lost event/source wakes and cross-source same-range demand suppression.
## No manual flush/drain, sampling markers, nested pump, or extra settling turns.
when not defined(windows) or not defined(leafProtocolProbes):
  {.error: "Requires real Windows and leafProtocolProbes".}

import std/[tables, options, algorithm, strutils]
import leaf/[core, widgets, components, backend, backend_session, ui_thread,
  native_layout]
import leaf/component_description
import leaf/backends/win32/[api, host, backend]

type
  ProbeFailed = object of CatchableError
  ProbeBlocked = object of CatchableError
  Step = enum mounting, scrolling, inserting, deleting, done
  RowFact = object
    index: int
    key: string
    source: uint64
    window, parent: HWND
    rect: RECT
    visible: bool

var
  pageState: State[int]
  insertCount, deleteCount, callbackSequence: int
  insertSequence, deleteSequence: int
  insertWrite = StateWriteResult.disposed
  deleteWrite = StateWriteResult.disposed

proc require(ok: bool, why: string) =
  if not ok: raise newException(ProbeFailed, why)

proc blocked(why: string) {.noreturn.} =
  raise newException(ProbeBlocked, why)

proc keysFor(phase: int): seq[string] =
  if phase == 1: result = @["insert-0", "insert-1"]
  for i in 0 ..< 20: result.add("a-" & $i)

let PageDef = defineComponent[int, State[int]]("PumpPage",
  proc(ctx: MountContext, props: int): State[int] =
    result = ctx.state(0)
    pageState = result,
  proc(ctx: ComponentContext, props: int, state: State[int]): UiDescription =
    let keys = keysFor(ctx.value(state))
    let list = componentList("list", keys,
      proc(index: int): UiDescription =
        host(row(@[text(keys[index], key = "label")], key = "row",
          styles = style({"height": "24"}))),
      rowHeight = 0.0, estimatedHeight = 24.0, overscan = 0,
      styles = style({"height": "130", "width": "300"}))
    hostShell(column(@[], key = "root"), @[
      host(button("插入 source", key = "insert", onClick = proc(e: Event) =
        inc callbackSequence
        inc insertCount
        insertSequence = callbackSequence
        insertWrite = state.set(1))),
      host(button("删除 source", key = "delete", onClick = proc(e: Event) =
        inc callbackSequence
        inc deleteCount
        deleteSequence = callbackSequence
        deleteWrite = state.set(2))),
      list]))

proc nativeText(window: HWND): string =
  let size = GetWindowTextLengthW(window) + 1
  let value = newWideCString(int(size))
  discard GetWindowTextW(window, cast[WidePtr](unsafeAddr value[0]), size)
  $value

proc nativeClass(window: HWND): string =
  let value = newWideCString(64)
  require(GetClassNameW(window, cast[WidePtr](unsafeAddr value[0]), 64) != 0,
    "GetClassNameW")
  $value

var children: seq[HWND]
proc collect(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  children.add(window)
  BOOL(1)

proc rowCaptions(window: HWND): seq[string] =
  children.setLen(0)
  discard EnumChildWindows(window, collect, 0)
  for child in children:
    if GetParent(child) == window:
      let value = nativeText(child)
      if value.len > 0: result.add(value)

proc localRect(window, port: HWND): RECT =
  require(GetWindowRect(window, addr result) != 0, "GetWindowRect")
  var points = [POINT(x: result.left, y: result.top),
    POINT(x: result.right, y: result.bottom)]
  setLastError(0)
  let mapped = MapWindowPoints(nil, port, addr points[0], 2)
  require(mapped != 0 or lastError() == 0, "MapWindowPoints")
  RECT(left: points[0].x, top: points[0].y,
    right: points[1].x, bottom: points[1].y)

proc rowsOf(win: Win32Backend, session: BackendSession,
            list: NodeHandle): seq[RowFact] =
  for entity in session.acceptedEntities().values:
    if entity.row.isNone or entity.row.get.listHandle != list: continue
    let binding = entity.row.get
    let window = win.rowWindowForTest(entity.handle)
    require(window != nil and IsWindow(window) != 0, "typed row needs live HWND")
    let parent = GetParent(window)
    require(parent != nil, "typed row needs real parent")
    result.add(RowFact(index: binding.itemIndex, key: binding.itemKey,
      source: binding.sourceGeneration, window: window, parent: parent,
      rect: localRect(window, parent), visible: IsWindowVisible(window) != 0))
  result.sort(proc(a, b: RowFact): int = cmp(a.index, b.index))

proc buttonOf(root: HWND, title: string): HWND =
  children.setLen(0)
  discard EnumChildWindows(root, collect, 0)
  for window in children:
    if nativeText(window) == title and
        cmpIgnoreCase(nativeClass(window), "BUTTON") == 0:
      require(result == nil, "ambiguous button " & title)
      result = window

proc checkPhase(win: Win32Backend, session: BackendSession, list: NodeHandle,
                port: HWND, label: string, source: uint64,
                first, offset, keyFirst, barMax, barPos: int) =
  let frame = win.listFrameForTest(list)
  let intent = win.listIntentForTest(list)
  require(frame.hasAccepted and frame.rowsetReady, label & " accepted/ready")
  require(frame.acceptedSource == source, label & " frame source")
  require(frame.acceptedOffset == float64(offset), label & " accepted offset")
  require(frame.acceptedFirst == first and frame.acceptedFinish == first + 6,
    label & " accepted range")
  require(intent.valid and intent.desiredOffset == float64(offset) and
    intent.appliedOffset == float64(offset), label & " desired/applied")
  require(frame.acceptedRows.len == 6, label & " full accepted rows")
  let rows = rowsOf(win, session, list)
  require(rows.len == 6, label & " exactly six real rows")
  var client: RECT
  require(GetClientRect(port, addr client) != 0, label & " client rect")
  require(client.bottom - client.top == 130, label & " client height stays 130")
  var seen: seq[HWND]
  var description: seq[string]
  for n, fact in rows:
    let key = "a-" & $(keyFirst + n)
    let index = first + n
    let top = int32(index * 24 - offset)
    require(fact.index == index and fact.key == key and fact.source == source,
      label & " typed identity at " & $n)
    let accepted = frame.acceptedRows[n]
    require(accepted.index == index and accepted.key == key and
      accepted.height == 24.0 and accepted.prefix == float64(index * 24),
      label & " accepted row identity/measurement at " & $n)
    require(fact.parent == port and fact.visible and fact.window notin seen,
      label & " real parent/visible/unique HWND")
    require(fact.rect.top == top and fact.rect.bottom == top + 24 and
      fact.rect.left == 0 and fact.rect.right == client.right - client.left,
      label & " native row rectangle at " & $n)
    let captions = rowCaptions(fact.window)
    require(captions == @[key], label & " native caption " & captions.join("|"))
    seen.add(fact.window)
    description.add($index & ":" & key & "@" & $top & "=" & captions.join("|"))
  var bar = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: SIF_ALL)
  require(GetScrollInfo(port, SB_VERT, addr bar) != 0, label & " GetScrollInfo")
  require(bar.nMin == 0 and bar.nMax == int32(barMax) and bar.nPage == 4 and
    bar.nPos == int32(barPos), label & " scrollbar literal oracle")
  require((uint32(GetWindowLongW(port, GWL_STYLE)) and WS_VSCROLL) != 0,
    label & " visible scrollbar style")
  echo label, " page=", pageState.read(), " source=", source,
    " token=", frame.acceptedToken, " revision=", session.runtime.acceptedRevision,
    " desired=", intent.desiredOffset, " applied=", intent.appliedOffset,
    " offset=", frame.acceptedOffset, " range=", frame.acceptedFirst, "..",
    frame.acceptedFinish, " rows=", description.join(","),
    " bar=", bar.nMin, "/", bar.nMax, "/", bar.nPage, "/", bar.nPos

proc deadline(window: HWND, message: UINT, timer: UINT_PTR,
              time: DWORD) {.stdcall, raises: [].} =
  discard KillTimer(nil, timer)
  PostQuitMessage(97)

proc postOnce(target: HWND, message: UINT, code: WPARAM, why: string) =
  require(target != nil and IsWindow(target) != 0, why & " target live")
  let posted = PostMessageW(target, message, code, 0)
  echo "post action=", why, " target=", cast[uint](target), " result=", posted
  require(posted != 0, why & " PostMessageW")

proc main(): int =
  let activity = newUiScopeActivity()
  let rt = newRuntime(guardUiApplication(componentApplication(
    component(PageDef, 0), "source-pump", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  var h: Win32Host
  var primary, secondary: ref CatchableError
  var status = "FAIL-unset"
  var step = mounting
  var ticks = 0
  var timer: UINT_PTR
  try:
    h = createHost("source-pump", DipSize(width: 480, height: 320))
    h.setStartupScope(proc(): bool = activity.busy or rt.installingUpdate or rt.installingHook)
    let win = newWin32Backend(h)
    let session = win.attachWin32Backend(rt)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    var list = NoHandle
    var port, insertButton, deleteButton: HWND
    var sourceA, sourceB: uint64

    proc observe() =
      inc ticks
      require(ticks <= 32, "ordinary tick budget exceeded at " & $step)
      require(insertCount <= 1 and deleteCount <= 1, "duplicate business callback")
      echo "tick=", ticks, " phase=", step, " callbacks=", callbackSequence,
        " insert=", insertCount, "/", insertSequence, "/", insertWrite,
        " delete=", deleteCount, "/", deleteSequence, "/", deleteWrite
      if step == mounting:
        for entity in session.acceptedEntities().values:
          if entity.kind == NodeKind.virtualList:
            require(list == NoHandle or list == entity.handle, "one virtualList")
            list = entity.handle
        if list == NoHandle: return
        let frame = win.listFrameForTest(list)
        if not (frame.hasAccepted and frame.rowsetReady): return
        let rows = rowsOf(win, session, list)
        require(rows.len > 0, "ready mount needs native rows")
        port = rows[0].parent
        if GetDpiForWindow(port) != 96: blocked("literal pixel oracle needs 96 DPI")
        var client: RECT
        if GetClientRect(port, addr client) == 0: blocked("initial client rect unavailable")
        if client.bottom - client.top != 130 or client.right <= client.left:
          blocked("initial fixture needs height130/positive width")
        insertButton = buttonOf(h.windowHandle, "插入 source")
        deleteButton = buttonOf(h.windowHandle, "删除 source")
        if insertButton == nil or deleteButton == nil: blocked("initial native buttons missing")
        require(GetParent(insertButton) == GetParent(port) and
          GetParent(deleteButton) == GetParent(port), "buttons outside viewport")
        require(IsWindowVisible(insertButton) != 0 and IsWindowVisible(deleteButton) != 0,
          "native buttons visible")
        require(pageState.read() == 0 and callbackSequence == 0, "initial page/callbacks")
        sourceA = frame.acceptedSource
        checkPhase(win, session, list, port, "prime", sourceA, 0, 0, 0, 14, 0)
        step = scrolling
        postOnce(port, WM_VSCROLL, WPARAM(SB_PAGEDOWN), "PageDown")
      elif step == scrolling:
        let frame = win.listFrameForTest(list)
        if not frame.rowsetReady or frame.acceptedOffset != 106.0: return
        require(callbackSequence == 0 and pageState.read() == 0, "scroll before callbacks")
        checkPhase(win, session, list, port, "A", sourceA, 4, 106, 4, 14, 3)
        discard SetFocus(insertButton)
        require(GetFocus() == insertButton, "focus real insert button")
        step = inserting
        postOnce(insertButton, BM_CLICK, 0, "insert")
      elif step == inserting:
        if insertCount == 0: return
        require(insertCount == 1 and insertSequence == 1 and deleteCount == 0 and
          callbackSequence == 1 and insertWrite == StateWriteResult.queued,
          "exact first queued business callback")
        let frame = win.listFrameForTest(list)
        if pageState.read() != 1 or not frame.rowsetReady or
            frame.acceptedSource == sourceA: return
        sourceB = frame.acceptedSource
        checkPhase(win, session, list, port, "B", sourceB, 4, 106, 2, 16, 3)
        discard SetFocus(deleteButton)
        require(GetFocus() == deleteButton, "focus real delete button")
        step = deleting
        postOnce(deleteButton, BM_CLICK, 0, "delete")
      elif step == deleting:
        if deleteCount == 0: return
        require(insertCount == 1 and deleteCount == 1 and insertSequence == 1 and
          deleteSequence == 2 and callbackSequence == 2 and
          deleteWrite == StateWriteResult.queued, "exact second queued business callback")
        let frame = win.listFrameForTest(list)
        if pageState.read() != 2 or not frame.rowsetReady or
            frame.acceptedSource == sourceB: return
        require(frame.acceptedSource != sourceA, "C is a fresh generation")
        checkPhase(win, session, list, port, "C", frame.acceptedSource, 4, 106, 4, 14, 3)
        step = done
        h.requestClose()

    h.setSafeTick(proc() =
      require(ticks < 32, "ordinary tick budget exhausted before native turn")
      win.safeListTurn()                 # production order; observer cannot flush
      observe())
    timer = SetTimer(nil, 0, 10_000, deadline)
    require(timer != 0, "deadline timer creation")
    var pumpExit: int
    try: pumpExit = h.pump()
    finally:
      discard KillTimer(nil, timer)
      timer = 0
    echo "pump_exit=", pumpExit, " ticks=", ticks, " phase=", step
    require(pumpExit == 0 and step == done, "pump deadline/incomplete phases")
    status = "PASS-source-pump"
  except ProbeBlocked as error:
    primary = error
    status = "NotRun-invalid-or-premise"
  except CatchableError as error:
    primary = error
    status = "FAIL-contract"
  if h != nil:
    try: h.destroyHost()
    except CatchableError as error: secondary = error
    if not h.resourcesReleasedInternal() and secondary == nil:
      secondary = newException(UiError, "host cleanup incomplete")
  if secondary == nil:
    try: rt.closeRuntime()
    except CatchableError as error: secondary = error
  if primary != nil: echo "actual_primary phase=", step, " msg=", primary.msg
  if secondary != nil:
    echo "actual_secondary msg=", secondary.msg
    status = "FAIL-close"
  echo "close_attempts=", (if h == nil: 0 else: 1)
  echo "probe_win32_list_source_pump status=", status
  if status.startsWith("NotRun"): return 2
  if status == "PASS-source-pump": return 0
  1

when isMainModule:
  quit(main())
