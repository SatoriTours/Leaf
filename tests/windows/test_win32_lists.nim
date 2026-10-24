## T2 batch 1 RED: a virtual list must become a real scrollable native viewport
## with a bounded set of compound row subtrees, driven by native scroll input.
##
## Every assertion below uses only interfaces that already exist (plus the
## declarative scroll constants added to `win32/api.nim` in the same batch), so
## it fails at *runtime* on the current code instead of failing to compile.
import ../fixture_app
when not defined(windows): {.error: "Real Win32 list suite requires Windows".}
import std/[unittest, strutils, widestrs, algorithm, tables]
import leaf/[core, widgets, backend, backend_session, native_layout,
  native_list_layout, height_index, ui_thread, windows_dpi]
import leaf/backends/win32/[api, calls, host, backend, capabilities, row_pool]

var enumerated: seq[HWND]
proc collect(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  enumerated.add(window)
  1
proc descendants(parent: HWND): seq[HWND] =
  enumerated.setLen(0)
  discard EnumChildWindows(parent, collect, 0)
  enumerated
proc nativeText(window: HWND): string =
  let size = GetWindowTextLengthW(window) + 1
  let value = newWideCString(int(size))
  discard GetWindowTextW(window, cast[WidePtr](unsafeAddr value[0]), size)
  $value
proc nativeClass(window: HWND): string =
  let value = newWideCString(256)
  discard GetClassNameW(window, cast[WidePtr](unsafeAddr value[0]), 256)
  $value
proc styleOf(window: HWND): uint32 =
  uint32(GetWindowLongW(window, GWL_STYLE))
proc openHost(): Win32Host = createHost("T2 lists", DipSize(width: 480, height: 320))

type Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession,
                     runtime: Runtime, activity: UiScopeActivity]

proc mounted(render: proc(): Node, c: Win32Calls = systemWin32Calls()): Fixture =
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(
    fixtureApplication(render, "T2 lists", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = openHost()
  h.setStartupScope(proc(): bool =
    activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win = newWin32Backend(h, c)
  let session = win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime, activity)


const
  RowHeight = 24.0
  ItemCount = 200

proc compoundRow(index: int): Node =
  ## One compound row: text + button + checkbox, so the row subtree is not a
  ## single native control.
  row(@[
    text("item " & $index, key = "label"),
    button("act " & $index, key = "button"),
    checkbox("chk " & $index, false, key = "check")], key = "row")

proc listRender(): Node =
  var keys: seq[string]
  for index in 0 ..< ItemCount: keys.add($index)
  # Explicit finite viewport: 120 DIP / 24 DIP row height = 5 visible rows.
  column(@[virtualList("list", keys, proc(index: int): Node = compoundRow(index),
    rowHeight = RowHeight, overscan = 0,
    styles = style({"height": "120"}))], key = "root")

proc viewports(h: Win32Host): seq[HWND] =
  for window in descendants(h.windowHandle):
    if (styleOf(window) and WS_VSCROLL) != 0: result.add(window)

proc rowRoots(viewport: HWND): seq[HWND] =
  ## Row roots are the direct children of the viewport window.
  for window in descendants(viewport):
    if GetParent(window) == viewport: result.add(window)

proc clippedRows(viewport: HWND): seq[tuple[y: int32, text: string]] =
  ## Row roots that are actually shown inside the viewport client area. Hidden
  ## parked rows and protected rows scrolled out of the clip are not "visible".
  var client: RECT
  check GetClientRect(viewport, addr client) != 0
  for rowWindow in rowRoots(viewport):
    if IsWindowVisible(rowWindow) == 0: continue
    var rect: RECT
    if GetWindowRect(rowWindow, addr rect) == 0: continue
    var corners = [POINT(x: rect.left, y: rect.top), POINT(x: rect.right, y: rect.bottom)]
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

proc hiddenRowRoots(viewport: HWND): int =
  ## Hidden rows are parked slots or protected rows outside the clip; they are
  ## bounded, not destroyed, and never counted as visible.
  for rowWindow in rowRoots(viewport):
    if IsWindowVisible(rowWindow) == 0: inc result

proc settle(f: Fixture) =
  ## The production safe turn itself: events -> viewport facts -> bounded drain
  ## -> one geometry pass. The test never substitutes its own ordering.
  f.win.safeListTurn()

proc systemWheelLines(host: Win32Host): int =
  ## Read-only system policy for one wheel notch, queried with the plain
  ## `SystemParametersInfoW`: the ForDpi variant does not support
  ## `SPI_GETWHEELSCROLLLINES` and would silently report its fallback. Only the
  ## named GET action is used, param and flags are 0, and the user's
  ## configuration is never modified. `host` is kept for call-site stability but
  ## the line count is not a per-DPI quantity.
  discard host
  var lines: UINT = 3
  if SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0'u32, addr lines,
      0'u32) == 0:
    return 3
  if int32(lines) == WHEEL_PAGESCROLL: return -1   # page scroll policy
  int(lines)

proc runTurn(f: Fixture, body: proc()) =
  f.h.setSafeTick(proc() =
    body()
    f.h.requestClose())
  check f.h.pump() == 0

suite "T2 batch 1: native list viewport and scroll":
  test "the Win32 backend declares the virtual list control it now implements":
    check NodeKind.virtualList in win32Capabilities().kinds

  test "a virtual list mounts a real scrollable viewport with bounded row windows":
    let f = mounted(listRender)
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.settle()
      let ports = viewports(f.h)
      check ports.len == 1
      if ports.len != 1: return
      let port = ports[0]
      # A real Unicode child viewport, clipped, with its own scrollbar.
      check (styleOf(port) and WS_CLIPCHILDREN) != 0
      var rect: RECT
      check GetClientRect(port, addr rect) != 0
      check rect.right - rect.left > 0
      check rect.bottom - rect.top > 0
      # Only the visible range (plus the pool bound) has native row subtrees.
      let roots = rowRoots(port)
      check roots.len >= 1
      # 120 DIP viewport / 24 DIP rows = 5 visible rows; hidden roots are parked
      # or protected rows and have their own bound.
      check clippedRows(port).len >= 1
      check clippedRows(port).len <= 5
      check hiddenRowRoots(port) <= 8
      check roots.len <= 5 + 8
      # The visible rows are the first items, in order.
      let texts = orderedRowTexts(port)
      check texts.len >= 1
      check texts[0] == "item 0"
      if texts.len > 1: check texts[1] == "item 1"
      # A row is a compound subtree: text + button + checkbox live in it.
      check descendants(port).len >= roots.len * 3)

  test "a line scroll moves the applied offset and rebinds the visible rows":
    let f = mounted(listRender)
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.settle()
      let ports = viewports(f.h)
      check ports.len == 1
      if ports.len != 1: return
      let port = ports[0]
      check orderedRowTexts(port)[0] == "item 0"
      # Native scrollbar line-down: only records intent, never renders.
      discard SendMessageW(port, WM_VSCROLL, WPARAM(SB_LINEDOWN), 0)
      check orderedRowTexts(port)[0] == "item 0"  # callback recorded only
      f.settle()
      let after = orderedRowTexts(port)
      check after.len >= 1
      check after[0] == "item 1")

  test "wheel deltas accumulate and follow the system line policy":
    let f = mounted(listRender)
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.settle()
      let ports = viewports(f.h)
      check ports.len == 1
      if ports.len != 1: return
      let port = ports[0]
      # The number of rows one notch scrolls comes from the real system policy
      # (or a page for WHEEL_PAGESCROLL); the product must not hard-code 1.
      let lines = systemWheelLines(f.h)
      let viewportDips = 120.0
      let perNotch =
        if lines < 0: int(viewportDips / RowHeight) - 1
        else: lines
      check perNotch >= 1
      discard SendMessageW(port, WM_MOUSEWHEEL, WPARAM(0xFF88'u32 shl 16), 0)
      f.settle()
      let afterNotch = orderedRowTexts(port)
      check afterNotch.len >= 1
      let expected = "item " & $perNotch
      if perNotch < int(ItemCount): check afterNotch[0] == expected
      # Partial deltas accumulate: nothing moves until the notch is completed.
      discard SendMessageW(port, WM_MOUSEWHEEL, WPARAM(0xFFD8'u32 shl 16), 0)
      f.settle()
      check orderedRowTexts(port) == afterNotch
      discard SendMessageW(port, WM_MOUSEWHEEL, WPARAM(0xFFB0'u32 shl 16), 0)
      f.settle()
      let afterAccumulated = orderedRowTexts(port)
      check afterAccumulated.len >= 1
      if perNotch * 2 < int(ItemCount):
        check afterAccumulated[0] == "item " & $(perNotch * 2))

## r1 (主控阅读发现，非运行发现): the pool must hand over one slot exactly
## once and must not treat two different topologies with the same kind sequence
## as interchangeable. Assertions fix the chosen semantics:
## `take(signature, slot) -> bool` moves ownership out of the pool in one step.
suite "row pool claim semantics":
  test "a single parked slot is claimed exactly once and keeps its windows":
    var pool: RowPool
    var parked = RowSlot(owner: 1'u64, signature: rowSignature([row, text], [-1, 0]),
      root: cast[HWND](0x11), windows: @[cast[HWND](0x11), cast[HWND](0x12)], parents: @[-1, 0])
    check pool.park(parked)
    check pool.len == 1
    var taken: RowSlot
    check pool.take(1'u64, parked.signature, taken)
    check pool.len == 0
    check taken.windows == @[cast[HWND](0x11), cast[HWND](0x12)]
    check taken.parents == @[-1, 0]
    check taken.root == cast[HWND](0x11)
    # A second claim cannot steal anything: the slot left the pool once.
    var again: RowSlot
    check not pool.take(1'u64, parked.signature, again)
    check again.windows.len == 0

  test "multiple slots claim only their own signature":
    var pool: RowPool
    check pool.park(RowSlot(owner: 1'u64, signature: rowSignature([row, text], [-1, 0]),
      root: cast[HWND](0x21), windows: @[cast[HWND](0x21), cast[HWND](0x22)], parents: @[-1, 0]))
    check pool.park(RowSlot(owner: 2'u64, signature: rowSignature([row, column, text], [-1, 0, 1]),
      root: cast[HWND](0x31), windows: @[cast[HWND](0x31), cast[HWND](0x32), cast[HWND](0x33)],
      parents: @[-1, 0, 1]))
    var taken: RowSlot
    check pool.take(2'u64, rowSignature([row, column, text], [-1, 0, 1]), taken)
    check taken.windows == @[cast[HWND](0x31), cast[HWND](0x32), cast[HWND](0x33)]
    check pool.len == 1
    check pool.take(1'u64, rowSignature([row, text], [-1, 0]), taken)
    check taken.windows == @[cast[HWND](0x21), cast[HWND](0x22)]
    check pool.len == 0
    check not pool.take(1'u64, rowSignature([row, text], [-1, 0]), taken)

  test "same kind sequence with a different topology is not reusable":
    let flat = rowSignature([row, column, text, text], [-1, 0, 1, 0])
    let chain = rowSignature([row, column, text, text], [-1, 0, 1, 1])
    check flat.len > 0
    check flat != chain
    var pool: RowPool
    check pool.park(RowSlot(owner: 1'u64, signature: flat, root: cast[HWND](0x41),
      windows: @[cast[HWND](0x41), cast[HWND](0x42), cast[HWND](0x43), cast[HWND](0x44)],
      parents: @[-1, 0, 1, 0]))
    var taken: RowSlot
    check not pool.take(1'u64, chain, taken)
    check pool.len == 1
    check taken.windows.len == 0
    check pool.take(1'u64, flat, taken)
    check taken.parents == @[-1, 0, 1, 0]
    check pool.len == 0

  test "slots are claimed only by their owning list and clearOwner returns them":
    var pool: RowPool
    let shape = rowSignature([row, text], [-1, 0])
    check pool.park(RowSlot(owner: 7'u64, signature: shape,
      root: cast[HWND](0x51), windows: @[cast[HWND](0x51), cast[HWND](0x52)],
      parents: @[-1, 0]))
    check pool.park(RowSlot(owner: 8'u64, signature: shape,
      root: cast[HWND](0x61), windows: @[cast[HWND](0x61), cast[HWND](0x62)],
      parents: @[-1, 0]))
    var taken: RowSlot
    check not pool.take(9'u64, shape, taken)     # no such owner
    check taken.windows.len == 0
    check pool.len == 2
    check pool.take(8'u64, shape, taken)         # only the matching owner
    check taken.root == cast[HWND](0x61)
    check pool.len == 1
    let owned = pool.clearOwner(7'u64)
    check owned.len == 1
    check owned[0].root == cast[HWND](0x51)
    check pool.len == 0                          # nothing smuggled across owners
    check pool.clearOwner(7'u64).len == 0

## T2 r0 后续覆盖（批量 RED）：真实窗口的整树复用、身份与资源边界。
## 契约要点（主控校正）：原生 HWND 不按 item 保留亲和；只有焦点/IME 保护行
## 才要求跨离屏同 HWND。item 离开活动绑定后再次出现，可来自**任何**先前真正
## 闲置的兼容槽；断言观察"真实复用发生 + 内容/绑定正确"，不要求拿回自己的旧
## HWND。冷启动与热循环的边界都按显式池/交接预算推导，不用拍脑袋小常数。
proc userObjects(): DWORD = GetGuiResources(GetCurrentProcess(), 1)  # USER
proc gdiObjects(): DWORD = GetGuiResources(GetCurrentProcess(), 0)   # GDI

proc scrollTo(port: HWND, code: int) =
  discard SendMessageW(port, WM_VSCROLL, WPARAM(code), 0)

proc visibleRowTexts(port: HWND): seq[string] =
  for item in clippedRows(port): result.add(item.text)

proc rowWindowOf(port: HWND, text: string): HWND =
  for rowWindow in rowRoots(port):
    if IsWindowVisible(rowWindow) == 0: continue
    for child in descendants(rowWindow):
      if GetParent(child) == rowWindow and nativeText(child) == text:
        return rowWindow

proc childWindowOf(port: HWND, rowText, text: string): HWND =
  let rowWindow = rowWindowOf(port, rowText)
  if rowWindow == nil: return nil
  for child in descendants(rowWindow):
    if child != rowWindow and nativeText(child) == text: return child

const
  NodesPerRow = 4          ## compoundRow: row + text + button + checkbox
  VisibleRows = 5          ## 120 DIP viewport / 24 DIP row height
  PoolBudgetRows = 8       ## RowPool.MaxParkedRows
  ChildBudget = NodesPerRow * (VisibleRows + PoolBudgetRows) + 8
    ## live visible rows + one bounded pool of parked rows + list/host windows.

suite "T2 hand-off frames: real row subtree reuse":
  test "a row that stays in the visible range keeps its HWND, and returning rows reuse idle slots":
    let f = mounted(listRender)
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.settle()
      let ports = viewports(f.h)
      check ports.len == 1
      if ports.len != 1: return
      let port = ports[0]
      check visibleRowTexts(port) == @["item 0", "item 1", "item 2", "item 3", "item 4"]
      # pageDown = viewport - rowHeight = 96 DIP = 4 rows: item 4 overlaps the
      # two frames and must keep exactly its native subtree.
      let overlapping = rowWindowOf(port, "item 4")
      let overlappingChild = childWindowOf(port, "item 4", "act 4")
      check overlapping != nil
      check overlappingChild != nil
      scrollTo(port, SB_PAGEDOWN)
      f.settle()
      check visibleRowTexts(port) == @["item 4", "item 5", "item 6", "item 7", "item 8"]
      check rowWindowOf(port, "item 4") == overlapping
      check childWindowOf(port, "item 4", "act 4") == overlappingChild
      # Back to the top: item 0 may come back on a different idle slot, but the
      # return must be a real pool hand-off and the content/bindings must be
      # correct for the new items.
      scrollTo(port, SB_TOP)
      f.settle()
      check visibleRowTexts(port) == @["item 0", "item 1", "item 2", "item 3", "item 4"]
      check f.win.diagnostics.reusedRows > 0
      for index in 0 ..< VisibleRows:
        check childWindowOf(port, "item " & $index, "chk " & $index) != nil)

  test "cold hand-off growth is bounded by the row topology, then repeats stay flat":
    let userBaseline = userObjects()
    let gdiBaseline = gdiObjects()
    let f = mounted(listRender)
    defer: f.h.destroyHost()            # idempotent; also the failure owner
    let hostWindow = f.h.windowHandle   # saved before any close
    let childrenCold = descendants(hostWindow).len
    let createsCold = f.win.diagnostics.creates
    runTurn(f, proc() =
      f.settle()
      let ports = viewports(f.h)
      check ports.len == 1
      if ports.len != 1: return
      let port = ports[0]
      # Cold first hand-off may create one extra frame of rows (prepare must not
      # steal rows that are still visible in the accepted frame).
      let beforeCold = f.win.diagnostics.creates
      scrollTo(port, SB_PAGEDOWN)
      f.settle()
      check int(f.win.diagnostics.creates - beforeCold) <=
        NodesPerRow * (VisibleRows + 1)
      # Warm: repeated same-signature frames must reuse, not create.
      let warmCreates = f.win.diagnostics.creates
      for round in 0 ..< 3:
        scrollTo(port, SB_PAGEDOWN)
        f.settle()
        scrollTo(port, SB_TOP)
        f.settle()
      check int(f.win.diagnostics.creates - warmCreates) <=
        NodesPerRow * (VisibleRows + 1)
      check f.win.diagnostics.reusedRows > 0
      # Bounded native resources across repeated hand-offs: live + one pool +
      # list/host windows, never an unbounded cache of scrolled rows.
      check descendants(hostWindow).len <= ChildBudget
      check f.win.diagnostics.parkedRows <= PoolBudgetRows)
    # Close: only the saved HWND is inspected; live getters must not be called
    # after destroyHost, and no EnumChildWindows on a dead/nil handle.
    let childrenLive = descendants(hostWindow).len
    f.h.destroyHost()
    check f.h.resourcesReleasedInternal()
    check childrenLive <= ChildBudget
    check IsWindow(hostWindow) == 0
    check userObjects() <= userBaseline + 2
    check gdiObjects() <= gdiBaseline + 2

  test "a focused row keeps its HWND and focus across the off-screen range":
    let f = mounted(listRender)
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.settle()
      let ports = viewports(f.h)
      check ports.len == 1
      if ports.len != 1: return
      let port = ports[0]
      let rowWindow = rowWindowOf(port, "item 0")
      check rowWindow != nil
      if rowWindow == nil: return
      let act = childWindowOf(port, "item 0", "act 0")
      check act != nil           # the focus target must really exist
      if act == nil: return
      discard SetFocus(act)
      check GetFocus() == act    # focus protection is genuinely exercised
      # Scroll far away: the protected row must keep the same HWND, parent and
      # focus instead of being parked or destroyed.
      scrollTo(port, SB_BOTTOM)
      f.settle()
      # The protected row is hidden/clipped, not destroyed or parked: inspect the
      # saved HWNDs directly instead of a visibility-filtered lookup.
      check IsWindow(rowWindow) != 0
      check GetParent(rowWindow) == port
      check IsWindow(act) != 0
      check GetParent(act) == rowWindow
      check GetFocus() == act
      # Returning to the top keeps the same native identity for the focused row.
      scrollTo(port, SB_TOP)
      f.settle()
      check rowWindowOf(port, "item 0") == rowWindow
      check GetFocus() == act)

## T2 批次8（预检修订）：真实子控件几何 / EDIT 重绑 / 跨列表池归属。只读真实
## 窗口状态；selection 用 EM_GETSEL 读取、EM_SETSEL 设置后读回证明。行身份用
## 唯一 label，不靠重复 caption。
const
  Bands = 3                ## 0..99 old / 100..199 empty / 200..299 new
  BandSpan = 100

proc bandRow(index: int): Node =
  let band = index div BandSpan
  let value = case band
    of 0: "old " & $index
    of 1: ""
    else: "new " & $index
  let hint = if band == 0: "old hint" else: "new hint"
  row(@[
    text("L" & $index, key = "label"),
    input(value, key = "field", placeholder = hint),
    checkbox("chk" & $index, band == 0, key = "check")], key = "row")

proc bandRender(count: int): Node =
  var keys: seq[string]
  for index in 0 ..< count: keys.add($index)
  column(@[virtualList("list", keys, proc(index: int): Node = bandRow(index),
    rowHeight = RowHeight, overscan = 0, styles = style({"height": "120"}))], key = "root")

proc twoListRender(): Node =
  var keys: seq[string]
  for index in 0 ..< ItemCount: keys.add($index)
  column(@[
    virtualList("left", keys, proc(index: int): Node =
      row(@[text("L" & $index, key = "tag")], key = "row"),
      rowHeight = RowHeight, overscan = 0, styles = style({"height": "120"})),
    virtualList("right", keys, proc(index: int): Node =
      row(@[text("R" & $index, key = "tag")], key = "row"),
      rowHeight = RowHeight, overscan = 0, styles = style({"height": "120"}))], key = "root")

proc viewportOf(h: Win32Host, index: int): HWND =
  let ports = viewports(h)
  if index < ports.len: ports[index] else: nil

proc screenRect(window: HWND): RECT = discard GetWindowRect(window, addr result)
proc intersects(a, b: RECT): bool =
  a.left < b.right and b.left < a.right and a.top < b.bottom and b.top < a.bottom

proc selectionOf(edit: HWND): tuple[first, last: int] =
  ## EM_GETSEL(0x00B0) with real pointers; never EM_SETSEL for reading.
  var first, last: DWORD
  discard SendMessageW(edit, EM_GETSEL, cast[WPARAM](addr first), cast[LPARAM](addr last))
  (int(first), int(last))

proc setSelection(edit: HWND, first, last: int) =
  discard SendMessageW(edit, EM_SETSEL, WPARAM(first), LPARAM(last))

proc editIn(port: HWND, label: string): HWND =
  let rowWindow = rowWindowOf(port, label)
  if rowWindow == nil: return nil
  for child in descendants(rowWindow):
    if GetParent(child) == rowWindow and
        nativeClass(child).toLowerAscii == "edit": return child

proc cueOf(edit: HWND): tuple[ok: bool, value: string] =
  let cue = newWideCString(128)
  let ok = SendMessageW(edit, EM_GETCUEBANNER, cast[WPARAM](unsafeAddr cue[0]), 128) != 0
  (ok, $cue)

proc rowLabels(port: HWND): seq[string] =
  for item in clippedRows(port): result.add(item.text)

suite "T2 real sub-control geometry and rebind semantics":
  test "A: every compound child of a visible row has real clipped geometry":
    let f = mounted(listRender)
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.settle()
      let port = viewportOf(f.h, 0)
      check port != nil
      if port == nil: return
      var client: RECT
      check GetClientRect(port, addr client) != 0
      var corners = [POINT(x: 0, y: 0), POINT(x: client.right, y: client.bottom)]
      discard MapWindowPoints(port, nil, addr corners[0], 2)
      let viewportScreen = RECT(left: corners[0].x, top: corners[0].y,
        right: corners[1].x, bottom: corners[1].y)
      let rowWindow = rowWindowOf(port, "item 0")
      check rowWindow != nil
      if rowWindow == nil: return
      let rowRect = screenRect(rowWindow)
      check rowRect.right > rowRect.left
      var children: seq[HWND]
      for child in descendants(rowWindow):
        if GetParent(child) == rowWindow: children.add(child)
      check children.len == 3                     # text + button + checkbox
      var previousX = low(int32)
      for child in children:
        check IsWindowVisible(child) != 0
        let rect = screenRect(child)
        check rect.right > rect.left                 # real, not 0x0
        check rect.bottom > rect.top
        check intersects(rect, rowRect)              # inside its row clip
        check intersects(rect, viewportScreen)       # inside the viewport clip
        check rect.left >= previousX                 # declared row order
        previousX = rect.left)

  test "B1: an idle old-value slot is reused for an empty new binding":
    # 200 items: band 0 = 0..99 (old), band 1 = 100..199 (empty); bottom shows 195..199.
    let f = mounted(proc(): Node = bandRender(200))
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.settle()
      let port = viewportOf(f.h, 0)
      check port != nil
      if port == nil: return
      let oldEdit = editIn(port, "L0")
      check oldEdit != nil
      check nativeText(oldEdit) == "old 0"
      setSelection(oldEdit, 1, 3)
      check selectionOf(oldEdit) == (1, 3)          # SET really landed
      let coldSelection = selectionOf(editIn(port, "L1"))  # fresh EDIT baseline
      # Hand-off 1 creates idle long-value slots (the old frame leaves).
      scrollTo(port, SB_PAGEDOWN)
      f.settle()
      let reusedBefore = f.win.diagnostics.reusedRows
      # Now bind the empty band: rows must come from those idle slots.
      scrollTo(port, SB_BOTTOM)
      f.settle()
      check f.win.diagnostics.reusedRows > reusedBefore
      check rowLabels(port) == @["L195", "L196", "L197", "L198", "L199"]
      var checked = 0
      var emptyEdits = 0
      for rowWindow in rowRoots(port):
        if IsWindowVisible(rowWindow) == 0: continue
        for child in descendants(rowWindow):
          if GetParent(child) != rowWindow: continue
          if nativeClass(child).toLowerAscii == "edit":
            inc emptyEdits
            check nativeText(child) == ""            # new binding, not old text
            let cue = cueOf(child)
            check cue.ok                              # getter must succeed
            check cue.value == "new hint"
            # No old selection/reset/transient leaks into the new binding.
            check selectionOf(child) == coldSelection
          elif nativeClass(child).toLowerAscii == "button":
            inc checked
            check SendMessageW(child, BM_GETCHECK, 0, 0) == 0
      check emptyEdits >= 1
      check checked >= 1)

  test "B2: a non-empty new binding never inherits the previous selection":
    # 300 items: band 2 = 200..299 (non-empty "new i"); bottom shows 295..299.
    let f = mounted(proc(): Node = bandRender(300))
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.settle()
      let port = viewportOf(f.h, 0)
      check port != nil
      if port == nil: return
      setSelection(editIn(port, "L0"), 2, 4)
      check selectionOf(editIn(port, "L0")) == (2, 4)
      let coldSelection = selectionOf(editIn(port, "L1"))
      scrollTo(port, SB_PAGEDOWN)
      f.settle()
      scrollTo(port, SB_BOTTOM)
      f.settle()
      check rowLabels(port) == @["L295", "L296", "L297", "L298", "L299"]
      var found = 0
      for rowWindow in rowRoots(port):
        if IsWindowVisible(rowWindow) == 0: continue
        for child in descendants(rowWindow):
          if GetParent(child) != rowWindow: continue
          if nativeClass(child).toLowerAscii != "edit": continue
          inc found
          check nativeText(child).startsWith("new ")
          check selectionOf(child) == coldSelection
      check found >= 1)

  test "B3: a row staying in the visible range keeps HWND and selection":
    let f = mounted(proc(): Node = bandRender(200))
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.settle()
      let port = viewportOf(f.h, 0)
      check port != nil
      if port == nil: return
      let edit4 = editIn(port, "L4")
      check edit4 != nil
      if edit4 == nil: return
      setSelection(edit4, 1, 3)
      check selectionOf(edit4) == (1, 3)
      scrollTo(port, SB_PAGEDOWN)             # 4 rows: item 4 stays visible
      f.settle()
      check editIn(port, "L4") == edit4
      check selectionOf(edit4) == (1, 3))

  test "C: a slot reused across lists is re-parented and never mixes sources":
    let f = mounted(twoListRender)
    defer: f.h.destroyHost()
    runTurn(f, proc() =
      f.settle()
      # Select viewports by content, not by enumeration order.
      var left: HWND
      var right: HWND
      for port in viewports(f.h):
        let labels = rowLabels(port)
        if labels.len == 5 and labels[0].startsWith("L"): left = port
        elif labels.len == 5 and labels[0].startsWith("R"): right = port
      check left != nil
      check right != nil
      if left == nil or right == nil: return
      check rowLabels(left) == @["L0", "L1", "L2", "L3", "L4"]
      check rowLabels(right) == @["R0", "R1", "R2", "R3", "R4"]
      # Park the left rows first (this only *may* make global slots available;
      # a per-viewport pool is a legal implementation and is not required to
      # share them).
      scrollTo(left, SB_BOTTOM)
      f.settle()
      let reuseBefore = f.win.diagnostics.reusedRows
      scrollTo(right, SB_BOTTOM)
      f.settle()
      # Exact expected content: five specific items, never old R0..R4, never L.
      check rowLabels(right) == @["R195", "R196", "R197", "R198", "R199"]
      for rowWindow in rowRoots(right):
        if IsWindowVisible(rowWindow) == 0: continue
        check GetParent(rowWindow) == right       # re-parented into its viewport
        for child in descendants(rowWindow):
          if GetParent(child) != rowWindow: continue
          let value = nativeText(child)
          if value.len == 0: continue
          check value.startsWith("R")             # no left-list source leak
      # Reuse is proven on the right list's own warm hand-off (page up then page
      # down again), so a per-viewport pool passes and still shows real reuse.
      scrollTo(right, SB_PAGEUP)
      f.settle()
      check f.win.diagnostics.reusedRows > reuseBefore
      scrollTo(right, SB_PAGEDOWN)
      f.settle()
      check rowLabels(right) == @["R191", "R192", "R193", "R194", "R195"] or
        rowLabels(right) == @["R195", "R196", "R197", "R198", "R199"])
