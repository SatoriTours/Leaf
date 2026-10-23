## T2: same-source row-local State, no HWND churn, publish/accept fenced.
## Each row owns its own MountContext.state; one update changes only that row's
## label/checkbox. The parent list source must not change, no row HWND may be
## re-created, and every measured commit is a single publish + single native
## accept with the three Nim allocation counters at 0.
##
## Fences are the accepted allocation-probe method: 3 sentinels -> body -> read the
## three counters + native-call/revision scalars before any diagnostics/format.
## Native value/identity queries run outside the windows. Exit 0 only means this
## whole scope passed; it says nothing about prepare/whole-frame/OS allocation,
## native resources or T2 as a whole.
when not defined(windows):
  {.error: "Row state allocation probe requires Windows".}

import std/[tables, algorithm, strutils, options]
import leaf/[core, widgets, components, backend, backend_session, ui_thread,
  native_layout, native_host_adapter, managed_runtime, host_reconcile]
import leaf/component_description
import leaf/backends/win32/[api, host, backend, calls]
import ../fixture_app

const
  ItemCount = 10_000
  RowsPerFrame = 5
  RowHeight = 24.0
  ViewportHeight = 120.0
  ParkedBudget = 8
  BM_GETCHECK = 0x00F0'u32
  BST_UNCHECKED = 0
  BST_CHECKED = 1

var
  rowZeroState: State[int]
  parentRenders = 0
  nativeAcceptCalls = 0
  lastAcceptRevision = 0'u64
  failures = 0

let RowDef = defineComponent[int, State[int]]("RowStateAllocRow",
  proc(ctx: MountContext, index: int): State[int] =
    result = ctx.state(0)
    if index == 0: rowZeroState = result,
  proc(ctx: ComponentContext, index: int, state: State[int]): UiDescription =
    let version = ctx.value(state)
    host(row(@[
      text("item " & $index & " v" & $version, key = "label"),
      input("", key = "edit"),
      button("act " & $index, key = "button"),
      checkbox("chk " & $index & " v" & $version, (version mod 2) == 1,
        key = "check")], key = "row")))

var pageKeys: seq[string]

let PageDef = defineComponent[int, int]("RowStateAllocPage",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, model: int): UiDescription =
    inc parentRenders
    componentList("list", pageKeys,
      proc(index: int): UiDescription = component(RowDef, index),
      rowHeight = RowHeight, overscan = 0,
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

proc nativeText(window: HWND): string =
  let size = GetWindowTextLengthW(window) + 1
  let value = newWideCString(int(size))
  discard GetWindowTextW(window, cast[WidePtr](unsafeAddr value[0]), size)
  $value

proc nativeClass(window: HWND): string =
  let value = newWideCString(128)
  discard GetClassNameW(window, cast[WidePtr](unsafeAddr value[0]), 128)
  $value

proc directChildren(parent: HWND): seq[HWND] =
  for window in descendants(parent):
    if GetParent(window) == parent: result.add(window)

proc viewportOf(h: Win32Host): HWND =
  for window in descendants(h.windowHandle):
    if (styleOf(window) and WS_VSCROLL) != 0: return window

proc rowWindow(port: HWND, index: int): HWND =
  ## The visible row root whose own STATIC label starts with "item <index> v".
  let prefix = "item " & $index & " v"
  for row in directChildren(port):
    if IsWindowVisible(row) == 0: continue
    for child in directChildren(row):
      let value = nativeText(child)
      if value.len >= prefix.len and value[0 ..< prefix.len] == prefix:
        return row

proc childByPrefix(row: HWND, prefix: string): HWND =
  for child in directChildren(row):
    let value = nativeText(child)
    if value.len >= prefix.len and value[0 ..< prefix.len] == prefix:
      return child

proc childByClass(row: HWND, className: string): HWND =
  for child in directChildren(row):
    if nativeClass(child).toLowerAscii == className: return child

proc subtreeWindows(port: HWND): seq[HWND] =
  result.add(port)
  for window in descendants(port): result.add(window)
  result.sort()

proc fingerprint(windows: seq[HWND]): uint64 =
  ## Order-stable scalar fingerprint of the current window set: printed as an
  ## observation only; the assertion is still the real set equality.
  var hash = 1469598103934665603'u64
  for window in windows:
    let value = uint64(cast[uint](window))
    hash = (hash xor (value and 0xFFFF'u64)) * 1099511628211'u64
    hash = (hash xor (value shr 16)) * 1099511628211'u64
  hash

proc checkValue(condition: bool, label: string) =
  if not condition:
    echo "check_failed ", label
    inc failures

proc rowBindingFacts(session: BackendSession, listHandle: NodeHandle,
                     index: int): tuple[found: bool, source: uint64,
                     item: int, key: string, handle: uint64] =
  ## Accepted typed metadata only (materialized outside any measured window).
  let entities = session.acceptedEntities()
  for entity in entities.values:
    if entity.row.isSome:
      let binding = entity.row.get
      if binding.listHandle == listHandle and binding.itemIndex == index:
        return (true, binding.sourceGeneration, binding.itemIndex,
          binding.itemKey, uint64(entity.handle))

type Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession,
                     rt: Runtime]

var
  winManaged = -1
  winHost = -1
  winNative = -1
  winCalls = 0
  winPublishes = 0
  winLastRevision = 0'u64

template window(rt: Runtime, label: string, body: untyped) =
  block:
    managedPublishAllocations = -1
    hostPublishAllocations = -1
    nativeAcceptAllocations = -1
    let callsBefore = nativeAcceptCalls
    let publishBefore = rt.acceptedRevision
    var phaseError: ref CatchableError = nil
    try:
      body
    except CatchableError as error:
      phaseError = error
    winManaged = managedPublishAllocations
    winHost = hostPublishAllocations
    winNative = nativeAcceptAllocations
    winCalls = nativeAcceptCalls - callsBefore
    winPublishes = int(rt.acceptedRevision - publishBefore)
    winLastRevision = lastAcceptRevision
    echo label, " native_calls=", winCalls, " publishes=", winPublishes,
      " managed=", winManaged, " host=", winHost, " native=", winNative,
      " last_accept_revision=", winLastRevision,
      " revision=", rt.acceptedRevision
    if phaseError != nil:
      echo label, " error=", phaseError.msg
      inc failures

proc attachScope(label: string) =
  ## Attach is measured like the accepted e468 method: exactly one native accept,
  ## native accept fence 0, and the managed/host publish fences only when that
  ## route really published (0 => -1 N/A, 1 => both 0; anything else fails).
  if winCalls != 1:
    echo label, " expected one native accept, got ", winCalls
    inc failures
    return
  if winNative < 0:
    echo label, " native accept fence not triggered"
    inc failures
    return
  if winNative != 0:
    echo label, " native accept fence not zero: ", winNative
    inc failures
  if winPublishes == 0:
    if winManaged != -1 or winHost != -1:
      echo label, " publish fences ran without a publish managed=", winManaged,
        " host=", winHost
      inc failures
    echo label, " publish=not_applicable managed=-1 host=-1"
  elif winPublishes == 1:
    if winManaged != 0 or winHost != 0:
      echo label, " publish fences not zero managed=", winManaged, " host=",
        winHost
      inc failures
  else:
    echo label, " publish window expected 0..1 got ", winPublishes
    inc failures

proc rowScope(label: string) =
  ## A row commit must be exactly one publish + one native accept with the three
  ## Nim counters at 0 (a multi-commit window ending in 0 is not accepted).
  if winCalls != 1:
    echo label, " expected one native accept, got ", winCalls
    inc failures
    return
  if winPublishes != 1:
    echo label, " expected publishes=1 got ", winPublishes
    inc failures
  if winManaged != 0 or winHost != 0 or winNative != 0:
    echo label, " fences not zero managed=", winManaged, " host=", winHost,
      " native=", winNative
    inc failures

proc main(): int =
  when not (defined(leafProtocolProbes) and defined(nimAllocStats) and
      defined(release) and defined(gcOrc)):
    echo "probe_win32_row_state_alloc status=requires-release-orc-alloc-probes"
    return 2
  pageKeys = @[]
  for index in 0 ..< ItemCount: pageKeys.add($index)

  let activity = newUiScopeActivity()
  let rt = newRuntime(guardUiApplication(
    componentApplication(component(PageDef, 0), "row-state-alloc", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("row-state-alloc", DipSize(width: 480, height: 320))
  h.setStartupScope(proc(): bool =
    activity.busy or rt.installingUpdate or rt.installingHook)
  let win = newWin32Backend(h)
  # Thin native-accept witness: still the real callback, only scalars counted.
  let realAccepted = win.asBackend.acceptedDelta
  if realAccepted == nil:
    echo "probe_win32_row_state_alloc status=requires-accepted-delta-channel"
    h.destroyHost()
    return 2
  win.asBackend.acceptedDelta = proc(delta: HostAcceptedDelta) {.raises: [].} =
    inc nativeAcceptCalls
    lastAcceptRevision = delta.revision
    realAccepted(delta)

  var session: BackendSession
  window(rt, "attach"):
    session = win.attachWin32Backend(rt)
  attachScope("attach")
  if session == nil:
    echo "probe_win32_row_state_alloc status=diagnostic_incomplete reason=no_session"
    h.destroyHost()
    return 3
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  let listNode = rt.find("list")
  let listHandle = session.handleFor(listNode.id)
  let sourceBefore = listNode.node.listSource.generation
  echo "scope list_handle=", uint64(listHandle), " source_before=", sourceBefore,
    " parent_renders=", parentRenders

  proc request(first, finish: int): RowViewportRequest =
    RowViewportRequest(sessionId: session.sessionId,
      mountGeneration: session.mountGeneration, listHandle: listHandle,
      sourceGeneration: rt.find("list").node.listSource.generation,
      first: first, finish: finish, protected: @[])

  var queued = session.queueRows(request(0, RowsPerFrame))
  if not queued:
    echo "probe_win32_row_state_alloc status=diagnostic_incomplete reason=queue_refused"
    h.destroyHost()
    return 3
  var drained = 0
  window(rt, "initial_rows"):
    drained = session.drainRowRequests()
  rowScope("initial_rows")
  if drained != 1:
    echo "initial_rows drain=", drained
    inc failures
  let port = viewportOf(h)
  if port == nil:
    echo "probe_win32_row_state_alloc status=diagnostic_incomplete reason=no_viewport"
    h.destroyHost()
    return 3
  let initialWindows = subtreeWindows(port)
  let initialRow = rowWindow(port, 0)
  checkValue(initialRow != nil, "initial row 0")
  if initialRow == nil:
    echo "probe_win32_row_state_alloc status=diagnostic_incomplete reason=no_row0"
    h.destroyHost()
    return 3
  let initialLabel = childByPrefix(initialRow, "item 0 v")
  let initialEdit = childByClass(initialRow, "edit")
  let initialButton = childByPrefix(initialRow, "act ")
  let initialCheck = childByPrefix(initialRow, "chk 0 v")
  checkValue(initialLabel != nil and initialEdit != nil and
    initialButton != nil and initialCheck != nil, "initial row children")
  if initialLabel == nil or initialEdit == nil or initialButton == nil or
      initialCheck == nil:
    echo "probe_win32_row_state_alloc status=diagnostic_incomplete reason=missing_child"
    h.destroyHost()
    return 3
  checkValue(nativeText(initialLabel) == "item 0 v0", "initial label value")
  checkValue(int(SendMessageW(initialCheck, BM_GETCHECK, 0, 0)) == BST_UNCHECKED,
    "initial checkbox unchecked")
  checkValue(parentRenders == 1, "one parent render after mount")

  var previousBinding = rowBindingFacts(session, listHandle, 0)
  checkValue(previousBinding.found and previousBinding.source == sourceBefore and
    previousBinding.item == 0 and previousBinding.key == "0", "initial row binding")
  var initialBindings: array[RowsPerFrame, tuple[found: bool, source: uint64,
    item: int, key: string, handle: uint64]]
  for row in 0 ..< RowsPerFrame:
    initialBindings[row] = rowBindingFacts(session, listHandle, row)
    checkValue(initialBindings[row].found and
      initialBindings[row].source == sourceBefore and
      initialBindings[row].item == row and initialBindings[row].key == $row,
      "initial binding row " & $row)
  echo "initial binding source=", previousBinding.source, " item=",
    previousBinding.item, " key=", previousBinding.key, " handle=",
    previousBinding.handle, " windows=", initialWindows.len,
    " live_rows=", win.diagnostics.liveRows, " parked=",
    win.diagnostics.parkedRows, " creates=", win.diagnostics.creates
  checkValue(initialWindows.len == 1 + RowsPerFrame * 5,
    "initial window census viewport+5x(root+4children)")

  for version in 1 .. 2:
    let label = "row_local_" & $version
    let createsBefore = win.diagnostics.creates
    let rendersBefore = parentRenders
    let write = rowZeroState.set(version)        # queued outside the window
    checkValue(write == StateWriteResult.queued, label & " state write queued")
    if write != StateWriteResult.queued:
      echo "probe_win32_row_state_alloc status=diagnostic_incomplete reason=state_not_queued"
      h.destroyHost()
      return 3
    window(rt, label):
      discard rt.flush()                         # the single commit
    rowScope(label)

    let currentBinding = rowBindingFacts(session, listHandle, 0)
    let expectedLabel = "item 0 v" & $version
    let visibleWindows = subtreeWindows(port)
    let row = rowWindow(port, 0)
    echo label, " binding source=", currentBinding.source, " item=",
      currentBinding.item, " key=", currentBinding.key, " handle=",
      currentBinding.handle, " creates=", win.diagnostics.creates,
      " live_rows=", win.diagnostics.liveRows, " parked=",
      win.diagnostics.parkedRows, " source_now=",
      rt.find("list").node.listSource.generation, " renders=", parentRenders
    checkValue(currentBinding.found, label & " binding present")
    checkValue(currentBinding.source == sourceBefore, label & " source unchanged")
    checkValue(currentBinding.item == 0 and currentBinding.key == "0",
      label & " item/key unchanged")
    checkValue(currentBinding.handle == previousBinding.handle,
      label & " row root handle unchanged")
    checkValue(rt.find("list").node.listSource.generation == sourceBefore,
      label & " list source generation unchanged")
    checkValue(parentRenders == rendersBefore,
      label & " parent did not re-render")
    checkValue(win.diagnostics.creates == createsBefore,
      label & " no native creations")
    checkValue(visibleWindows == initialWindows, label & " HWND set unchanged")
    checkValue(win.diagnostics.liveRows == RowsPerFrame, label & " live rows 5")
    checkValue(win.diagnostics.parkedRows <= ParkedBudget, label & " parked budget")
    checkValue(row != nil, label & " row 0 present")
    # Native readback (values stored in scalars before printing; outside fences).
    var labelText = ""
    var editText = ""
    var checkState = -1
    if row != nil:
      let lbl = childByPrefix(row, "item 0 v")
      let edit = childByClass(row, "edit")
      let check = childByPrefix(row, "chk 0 v")
      if lbl != nil: labelText = nativeText(lbl)
      if edit != nil: editText = nativeText(edit)
      if check != nil: checkState = int(SendMessageW(check, BM_GETCHECK, 0, 0))
      echo label, " native label=", labelText, " edit=", editText,
        " check=", checkState, " windows=", visibleWindows.len,
        " fingerprint=", fingerprint(visibleWindows)
      checkValue(row == initialRow, label & " row window identity")
      checkValue(lbl != nil and labelText == expectedLabel,
        label & " label value " & expectedLabel)
      checkValue(edit != nil and edit == initialEdit and editText == "",
        label & " edit unchanged")
      checkValue(check != nil and check == initialCheck, label & " checkbox HWND")
      let wanted = if (version mod 2) == 1: BST_CHECKED else: BST_UNCHECKED
      checkValue(check != nil and checkState == wanted, label & " checkbox state")
      for other in 1 ..< RowsPerFrame:
        let otherRow = rowWindow(port, other)
        checkValue(otherRow != nil, label & " other row " & $other & " present")
        if otherRow != nil:
          let otherLabel = childByPrefix(otherRow, "item " & $other & " v")
          checkValue(otherLabel != nil and
            nativeText(otherLabel) == "item " & $other & " v0",
            label & " other row " & $other & " unchanged")
        let otherBinding = rowBindingFacts(session, listHandle, other)
        checkValue(otherBinding.found and
          otherBinding.source == initialBindings[other].source and
          otherBinding.item == initialBindings[other].item and
          otherBinding.key == initialBindings[other].key and
          otherBinding.handle == initialBindings[other].handle,
          label & " other binding row " & $other & " unchanged")
    previousBinding = currentBinding

  h.destroyHost()
  if not h.resourcesReleasedInternal():
    echo "close_complete=false"
    inc failures
  echo "probe_win32_row_state_alloc failures=", failures,
    " parent_renders=", parentRenders
  if failures == 0:
    echo "probe_win32_row_state_alloc status=row_state_alloc_completed"
    echo "scope note: publish/accept Nim fences only; not prepare/whole-frame/OS allocation"
    return 0
  echo "probe_win32_row_state_alloc status=diagnostic_incomplete reason=check_failures"
  3

when isMainModule:
  quit(main())
