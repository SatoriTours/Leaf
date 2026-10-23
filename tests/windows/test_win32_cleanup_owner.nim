## Focused owner regressions for the Win32 private resource protocol.
##
## 1) A closed caller scope must release the whole native fixture graph: real
##    HWNDs, the disposed Session and both beacons captured by the product
##    (calls table/runtime driver). Nothing may stay rooted by a thread-global
##    cookie table after a successful release.
## 2) A refused remover on the deepest window of a legal 40-level chain keeps the
##    failed window **and every ancestor**; nothing is released in that pass, and
##    the exact retry (same callback/id) then releases the whole chain.
## 3) A failed borrow keeps the installed root's callback/id/cookie and its
##    remover progress, so the next cleanup retries precisely that identity; the
##    child whose subclass install failed is never asked to remove.
##
## Every case is one process under the `std/unittest` positional filter. A case
## that ends with a retained owner (the documented failure state) may leave its
## Host alive; the reasons are asserted, never hidden.
import ../fixture_app
when not defined(windows): {.error: "Win32 cleanup owner suite requires Windows".}
import std/[unittest, sets, tables, options, strutils, os, syncio]
import leaf/[core, widgets, backend, backend_session, native_layout, ui_thread]
import leaf/backends/win32/[api, calls, host, backend]

const
  ItemCount = 200
  RowHeight = 24.0
  ChainDepth = 40          ## business levels; host + 40 columns + text = 42
  RefusalError = 1400'u32  ## ERROR_INVALID_WINDOW_HANDLE
  WsVScroll = 0x00200000'u32

type
  Rec = object
    seq: int
    op: string
    hwnd: uint64
    parent: uint64
    style: uint64
    ok: int
    err: uint64
    live: bool
    aux: uint64
    aux2: uint64
    attempt: int

  Injection = ref object
    refuseDestroy, refuseRemoveSubclass, refuseSetSubclass, refuseSetCtrlId: int
    destroyFilter, removeFilter, subclassFilter:
      proc(window: HWND): bool {.closure, raises: [].}
    raiseDestroy, raiseRemove: ref CatchableError
      ## pre-created exceptions: a matching call records the refusal and raises
      ## this exact object (the Win32Calls contract allows CatchableError).
    raiseDestroyFilter, raiseRemoveFilter:
      proc(window: HWND): bool {.closure, raises: [].}
    raiseShow: ref CatchableError
    showFilter: proc(window: HWND, command: int32): bool {.closure, raises: [].}

var
  recs: seq[Rec]
  stage = "mount"
  attempt = 0
  tracePath = ""
  traceBroken = false

proc initTrace() {.raises: [].} =
  try: tracePath = getEnv("LEAF_WIN32_CLEANUP_LOG")
  except CatchableError: tracePath = ""

proc trace(line: string) {.raises: [].} =
  if tracePath.len == 0: return
  let saved = lastError()
  try:
    var handle: File
    if open(handle, tracePath, fmAppend):
      try:
        handle.writeLine(line)
        flushFile(handle)
      finally: handle.close()
    else: traceBroken = true
  except CatchableError: traceBroken = true
  setLastError(saved)

initTrace()

proc note(op: string, hwnd, parent: HWND, ok: int, err: DWORD, live: bool,
          style = 0'u64, aux = 0'u64, aux2 = 0'u64) {.raises: [].} =
  recs.add(Rec(seq: recs.len, op: op, hwnd: uint64(cast[uint](hwnd)),
    parent: uint64(cast[uint](parent)), style: style, ok: ok, err: uint64(err),
    live: live, aux: aux, aux2: aux2, attempt: attempt))
  trace("NATIVE seq=" & $recs.len & " op=" & op & " hwnd=0x" &
    toHex(uint64(cast[uint](hwnd)), 16) & " parent=0x" &
    toHex(uint64(cast[uint](parent)), 16) & " ok=" & $ok & " err=" & $uint64(err) &
    " live=" & $live & " aux=" & $aux & " aux2=0x" & toHex(aux2, 16) &
    " attempt=" & $attempt & " stage=" & stage)

proc wrap(c: var Win32Calls, inj: Injection) =
  let realCreate = c.createWindow
  let realDestroy = c.destroyWindow
  let realShow = c.showWindow
  let realAddSub = c.setSubclass
  let realDelSub = c.removeSubclass
  let realSetCid = c.setCtrlId
  c.createWindow = proc(exStyle: DWORD, className, title: WidePtr, style: DWORD,
      x, y, width, height: int32, parent: HWND, menu: HMENU, instance: HINSTANCE,
      param: pointer): HWND =
    setLastError(0)
    let r = realCreate(exStyle, className, title, style, x, y, width, height,
      parent, menu, instance, param)
    let err = lastError()
    note("create", r, parent, ord(r != nil), err, r != nil, style = uint64(style))
    setLastError(err)
    r
  c.destroyWindow = proc(window: HWND): BOOL =
    let parent = GetParent(window)
    let live = IsWindow(window) != 0
    setLastError(0)
    var op = "destroy"
    var r: BOOL
    var err = RefusalError
    if inj.raiseDestroy != nil and
        (inj.raiseDestroyFilter == nil or inj.raiseDestroyFilter(window)):
      let raised = inj.raiseDestroy
      inj.raiseDestroy = nil
      note("destroy-raise", window, parent, 0, 0, live)
      raise raised
    if inj.refuseDestroy > 0 and
        (inj.destroyFilter == nil or inj.destroyFilter(window)):
      dec inj.refuseDestroy
      op = "destroy-refused"
    else:
      r = realDestroy(window)
      err = lastError()
    note(op, window, parent, ord(r != 0), err, live)
    setLastError(err)
    r
  c.showWindow = proc(window: HWND, command: int32): BOOL =
    let parent = GetParent(window)
    let live = IsWindow(window) != 0
    if inj.raiseShow != nil and
        (inj.showFilter == nil or inj.showFilter(window, command)):
      let raised = inj.raiseShow
      inj.raiseShow = nil
      note("show-raise", window, parent, 0, 0, live, aux = uint64(command))
      raise raised
    setLastError(0)
    let r = realShow(window, command)
    let err = lastError()
    note("show", window, parent, ord(r != 0), err, live, aux = uint64(command))
    setLastError(err)
    r
  c.setSubclass = proc(window: HWND, callback: SUBCLASSPROC, id: UINT_PTR,
      data: DWORD_PTR): BOOL =
    let parent = GetParent(window)
    let live = IsWindow(window) != 0
    setLastError(0)
    var op = "setSubclass"
    var r: BOOL
    var err = RefusalError
    if inj.refuseSetSubclass > 0 and
        (inj.subclassFilter == nil or inj.subclassFilter(window)):
      dec inj.refuseSetSubclass
      op = "setSubclass-refused"
    else:
      r = realAddSub(window, callback, id, data)
      err = lastError()
    note(op, window, parent, ord(r != 0), err, live, aux = uint64(id),
      aux2 = cast[uint](callback))
    setLastError(err)
    r
  c.removeSubclass = proc(window: HWND, callback: SUBCLASSPROC,
      id: UINT_PTR): BOOL =
    let parent = GetParent(window)
    let live = IsWindow(window) != 0
    setLastError(0)
    var op = "removeSubclass"
    var r: BOOL
    var err = RefusalError
    if inj.raiseRemove != nil and
        (inj.raiseRemoveFilter == nil or inj.raiseRemoveFilter(window)):
      let raised = inj.raiseRemove
      inj.raiseRemove = nil
      note("removeSubclass-raise", window, parent, 0, 0, live, aux = uint64(id),
        aux2 = cast[uint](callback))
      raise raised
    if inj.refuseRemoveSubclass > 0 and
        (inj.removeFilter == nil or inj.removeFilter(window)):
      dec inj.refuseRemoveSubclass
      op = "removeSubclass-refused"
    else:
      r = realDelSub(window, callback, id)
      err = lastError()
    note(op, window, parent, ord(r != 0), err, live, aux = uint64(id),
      aux2 = cast[uint](callback))
    setLastError(err)
    r
  c.setCtrlId = proc(window: HWND, value: int): int =
    let parent = GetParent(window)
    let live = IsWindow(window) != 0
    setLastError(0)
    var op = "setCtrlId"
    var r: int
    var err = RefusalError
    if inj.refuseSetCtrlId > 0:
      dec inj.refuseSetCtrlId
      op = "setCtrlId-refused"
    else:
      r = realSetCid(window, value)
      err = lastError()
    note(op, window, parent, r, err, live)
    setLastError(err)
    r

# ---- ledger ---------------------------------------------------------------

proc alive(hwnd: uint64): bool {.raises: [].} =
  hwnd != 0 and IsWindow(cast[HWND](hwnd)) != 0

proc createdWindows(): seq[uint64] {.raises: [].} =
  var seen: HashSet[uint64]
  for item in recs:
    if item.op != "create" or item.hwnd == 0 or item.hwnd in seen: continue
    seen.incl(item.hwnd)
    result.add(item.hwnd)

proc aliveSet(): HashSet[uint64] {.raises: [].} =
  for hwnd in createdWindows():
    if alive(hwnd): result.incl(hwnd)

proc createRec(hwnd: uint64): Rec {.raises: [].} =
  for item in recs:
    if item.op == "create" and item.hwnd == hwnd: return item
  Rec(seq: -1)

proc parentOf(hwnd: uint64): uint64 {.raises: [].} = createRec(hwnd).parent

proc depthOf(hwnd: uint64): int {.raises: [].} =
  var current = hwnd
  while current != 0:
    current = parentOf(current)
    inc result
    if result > 128: break

proc chainOf(hwnd: uint64): seq[uint64] {.raises: [].} =
  ## Deepest first, host last (recorded creation parents, not a live query).
  var current = hwnd
  while current != 0:
    result.add(current)
    current = parentOf(current)

proc recordsOf(op: string, hwnd: uint64): seq[Rec] {.raises: [].} =
  for item in recs:
    if item.op == op and item.hwnd == hwnd: result.add(item)

proc countOp(op: string): int {.raises: [].} =
  for item in recs:
    if item.op == op: inc result

proc lastRec(op: string): Rec {.raises: [].} =
  for index in countdown(recs.len - 1, 0):
    if recs[index].op == op: return recs[index]
  Rec(seq: -1)

proc onlyLiveDestroyCalls(): bool {.raises: [].} =
  for item in recs:
    if item.op == "destroy" and not item.live: return false
  true

proc noDoubleRelease(): bool {.raises: [].} =
  var freed: HashSet[uint64]
  for item in recs:
    if item.op != "destroy" or item.ok == 0: continue
    if item.hwnd in freed: return false
    freed.incl(item.hwnd)
  true

proc releasesAccounted(): bool {.raises: [].} =
  var freed: HashSet[uint64]
  for item in recs:
    if item.op == "destroy" and item.ok != 0: freed.incl(item.hwnd)
  for hwnd in createdWindows():
    if not alive(hwnd) and hwnd notin freed: return false
  true

proc removersFor(hwnd: uint64, cookie: uint64,
                 callback: uint64): seq[Rec] {.raises: [].} =
  ## Only the removers carrying the *borrow* identity: parkRow retires the old
  ## slot subclass earlier with its own cookie and must not be confused with the
  ## retried install.
  for item in recordsOf("removeSubclass", hwnd):
    if item.aux == cookie and item.aux2 == callback: result.add(item)

proc refusedRemoversFor(hwnd: uint64, cookie: uint64,
                        callback: uint64): seq[Rec] {.raises: [].} =
  for item in recs:
    if item.op == "removeSubclass-refused" and item.hwnd == hwnd and
        item.aux == cookie and item.aux2 == callback:
      result.add(item)

proc childrenOf(hwnd: uint64): seq[uint64] {.raises: [].} =
  for item in recs:
    if item.op == "create" and item.parent == hwnd: result.add(item.hwnd)

proc groupOf(root: uint64): seq[uint64] {.raises: [].} =
  result.add(root)
  for item in childrenOf(root): result.add(item)

proc onlyWindow(target: uint64): proc(window: HWND): bool {.closure, raises: [].} =
  proc(window: HWND): bool {.closure, raises: [].} =
    uint64(cast[uint](window)) == target

# ---- fixtures -------------------------------------------------------------

proc compoundRow(index: int): Node =
  row(@[text("item " & $index, key = "label"),
    button("act " & $index, key = "button"),
    checkbox("chk " & $index, false, key = "check")], key = "row")

proc listRender(): Node =
  var keys: seq[string]
  for index in 0 ..< ItemCount: keys.add($index)
  column(@[virtualList("list", keys, proc(index: int): Node = compoundRow(index),
    rowHeight = RowHeight, overscan = 0, styles = style({"height": "120"}))],
    key = "root")

proc deepRender(): Node =
  ## One legal business chain: 40 nested columns and one text leaf.
  var node: Node = text("leaf", key = "leaf")
  for level in countdown(ChainDepth - 1, 0):
    node = column(@[node], key = "c" & $level)
  node

type Fixture = object
  h: Win32Host
  win: Win32Backend
  s: BackendSession
  r: Runtime
  host: uint64

proc mounted(render: proc(): Node, inj: Injection,
             width = 480, height = 320): Fixture =
  recs.setLen(0)
  attempt = 0
  stage = "mount"
  var c = systemWin32Calls()
  wrap(c, inj)
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(
    fixtureApplication(render, "cleanup owner", width, height),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("cleanup owner host",
    DipSize(width: float64(width), height: float64(height)), c)
  h.setStartupScope(proc(): bool =
    activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win = newWin32Backend(h, c)
  result = Fixture(h: h, win: win, r: runtime,
    host: uint64(cast[uint](h.windowHandle)))
  result.s = win.attachWin32Backend(runtime)
  win.bindSession(result.s)
  h.bindSession(result.s, proc(): bool = activity.busy)

proc settle(f: Fixture) =
  stage = "turn"
  f.win.safeListTurn()

proc scroll(port: uint64, code: int) =
  discard SendMessageW(cast[HWND](port), WM_VSCROLL, WPARAM(code), 0)

proc closeAttempt(f: Fixture, round: int): ref CatchableError =
  attempt = round
  stage = "close"
  try: f.h.destroyHost()
  except CatchableError as error: result = error
  trace("CLOSE round=" & $round & " error=" &
    (if result == nil: "none" else: result.msg))

proc viewport(): uint64 {.raises: [].} =
  for hwnd in createdWindows():
    if (createRec(hwnd).style and uint64(WsVScroll)) != 0 and alive(hwnd):
      return hwnd
  0

# ---- 1) closed caller scope releases the whole fixture graph --------------

var beaconGone: array[3, bool]
type
  BeaconPayload = object
    kind: int
  Beacon = ref BeaconPayload

proc `=destroy`(payload: var BeaconPayload) =
  beaconGone[payload.kind] = true

proc renderWithBeacon(kept: Beacon): proc(): Node =
  result = proc(): Node =
    var keys: seq[string]
    for index in 0 ..< ItemCount: keys.add($index)
    column(@[virtualList("list", keys, proc(index: int): Node =
      doAssert kept.kind == 2
      compoundRow(index), rowHeight = RowHeight, overscan = 0,
      styles = style({"height": "120"}))], key = "root")

type ScopeFacts = object
  closed, windowsGone, backendHeld, runtimeHeld: bool

proc closedScope(): ScopeFacts =
  ## All reference-valued fixture data is immutable and function-local: nothing
  ## is nil'ed to change what the product holds and nothing escapes via result.
  let beaconB = Beacon(kind: 1)
  let beaconR = Beacon(kind: 2)
  var created: seq[uint64]
  var c = systemWin32Calls()
  let realCreate = c.createWindow
  let realDestroy = c.destroyWindow
  let realRemove = c.removeSubclass
  c.createWindow = proc(exStyle: DWORD, className, title: WidePtr, style: DWORD,
      x, y, width, height: int32, parent: HWND, menu: HMENU,
      instance: HINSTANCE, param: pointer): HWND =
    doAssert beaconB.kind == 1
    setLastError(0)
    let window = realCreate(exStyle, className, title, style, x, y, width,
      height, parent, menu, instance, param)
    let err = lastError()
    if window != nil: created.add(uint64(cast[uint](window)))
    setLastError(err)
    window
  c.destroyWindow = proc(window: HWND): BOOL =
    setLastError(0)
    let answer = realDestroy(window)
    let err = lastError()
    setLastError(err)
    answer
  c.removeSubclass = proc(window: HWND, callback: SUBCLASSPROC,
      id: UINT_PTR): BOOL =
    setLastError(0)
    let answer = realRemove(window, callback, id)
    let err = lastError()
    setLastError(err)
    answer
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(
    fixtureApplication(renderWithBeacon(beaconR), "scope owner", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("scope owner", DipSize(width: 480, height: 320), c)
  h.setStartupScope(proc(): bool =
    activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win = newWin32Backend(h, c)
  let session = win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  win.safeListTurn()
  doAssert win.diagnostics.liveRows == 5
  h.destroyHost()
  result.closed = session.disposed and h.resourcesReleasedInternal()
  result.windowsGone = true
  for raw in created:
    if IsWindow(cast[HWND](raw)) != 0: result.windowsGone = false
  GC_fullCollect()
  # Both beacons are still strongly held by this function while it runs.
  result.backendHeld = not beaconGone[1] and beaconB.kind == 1
  result.runtimeHeld = not beaconGone[2] and beaconR.kind == 2

# ---- scenarios ------------------------------------------------------------

suite "Win32 cleanup owner protocol":
  test "1) a closed caller scope releases the whole fixture graph":
    let facts = closedScope()
    GC_fullCollect()
    GC_fullCollect()
    check facts.closed
    check facts.windowsGone
    check facts.backendHeld          # still held *inside* the scope
    check facts.runtimeHeld
    check beaconGone[1]              # gone after the caller scope returned
    check beaconGone[2]

  test "2) a refused remover keeps the deepest window and every ancestor":
    let inj = Injection()
    let f = mounted(deepRender, inj)
    block scenario:
      # The mount creates the host + 40 columns + the text leaf, nothing else.
      check createdWindows().len == ChainDepth + 2
      var deepest = 0'u64
      var deepestDepth = -1
      for hwnd in createdWindows():
        let depth = depthOf(hwnd)
        if depth > deepestDepth: deepestDepth = depth; deepest = hwnd
      check deepest != 0
      check deepestDepth == ChainDepth + 2
      let chain = chainOf(deepest)
      check chain.len == ChainDepth + 2
      let snapBefore = aliveSet()
      check snapBefore.len == ChainDepth + 2
      inj.refuseRemoveSubclass = 1
      inj.removeFilter = onlyWindow(deepest)
      let firstError = closeAttempt(f, 1)
      check firstError != nil
      check countOp("removeSubclass-refused") == 1
      let refused = lastRec("removeSubclass-refused")
      check refused.seq >= 0
      check refused.live and refused.hwnd == deepest and refused.attempt == 1
      if refused.seq < 0: break scenario
      # Child-before-parent never ran: the failed window and *all* ancestors stay.
      let snapAfter = aliveSet()
      check snapAfter.len == snapBefore.len
      for hwnd in chain: check hwnd in snapAfter
      for hwnd in chain: check recordsOf("destroy", hwnd).len == 0
      check not f.h.resourcesReleasedInternal()
      check onlyLiveDestroyCalls()
      inj.refuseRemoveSubclass = 0
      let secondError = closeAttempt(f, 2)
      check secondError == nil
      check f.h.resourcesReleasedInternal()
      check aliveSet().len == 0
      # The retry reuses the exact installed identity, before the destroy.
      let removers = recordsOf("removeSubclass", deepest)
      check removers.len == 1
      if removers.len == 1:
        check removers[0].attempt == 2
        check removers[0].ok != 0
        check removers[0].aux == refused.aux and removers[0].aux2 == refused.aux2
        let destroys = recordsOf("destroy", deepest)
        check destroys.len == 1
        if destroys.len == 1: check removers[0].seq < destroys[0].seq
      check onlyLiveDestroyCalls()
      check noDoubleRelease()
      check releasesAccounted()

  test "3) a failed borrow keeps the root identity and cleanup retries it":
    let inj = Injection()
    let f = mounted(listRender, inj)
    block scenario:
      settle(f)
      let port = viewport()
      check port != 0
      if port == 0: break scenario
      scroll(port, SB_PAGEDOWN)
      settle(f)
      # The child install fails (root installed first), then the abandon remover
      # of the installed root is refused too.
      inj.refuseSetSubclass = 1
      inj.subclassFilter = proc(window: HWND): bool {.closure, raises: [].} =
        let parent = uint64(cast[uint](GetParent(window)))
        parent != 0 and parentOf(parent) == port and
          IsWindowVisible(window) == 0
      inj.refuseRemoveSubclass = 1
      scroll(port, SB_TOP)
      var raised: ref CatchableError
      try: settle(f)
      except CatchableError as error: raised = error
      check raised != nil
      # The primary keeps its own identity/text; the abandon refusal is secondary.
      if raised != nil: check raised.msg.contains("SetWindowSubclass")
      check countOp("setSubclass-refused") == 1
      check countOp("removeSubclass-refused") == 1
      let childRefusal = lastRec("setSubclass-refused")
      let rootRefusal = lastRec("removeSubclass-refused")
      check childRefusal.seq >= 0 and rootRefusal.seq >= 0
      if childRefusal.seq < 0 or rootRefusal.seq < 0: break scenario
      check childRefusal.live and rootRefusal.live
      check parentOf(childRefusal.hwnd) == rootRefusal.hwnd
      check parentOf(rootRefusal.hwnd) == port
      # The child was never installed with the borrow cookie: cleanup must not
      # ask for its remover (the earlier parkRow remover used the old cookie).
      check removersFor(childRefusal.hwnd, childRefusal.aux,
        childRefusal.aux2).len == 0
      check refusedRemoversFor(childRefusal.hwnd, childRefusal.aux,
        childRefusal.aux2).len == 0
      # The failed group is still owned: root alive, no release recorded yet.
      check alive(rootRefusal.hwnd)
      check recordsOf("destroy", rootRefusal.hwnd).len == 0
      check not f.h.resourcesReleasedInternal()
      let group = chainOf(childRefusal.hwnd)  # child, root, viewport, ...
      check group.len >= 3
      check group[0] == childRefusal.hwnd
      check group[1] == rootRefusal.hwnd
      check group[2] == port
      for hwnd in group: check alive(hwnd)
      let secondError = closeAttempt(f, 1)
      check secondError == nil
      check f.h.resourcesReleasedInternal()
      check aliveSet().len == 0
      # Exactly one successful retry of the same installed root identity, and it
      # happens before that root is destroyed. The parkRow remover of the old
      # slot cookie is a different identity and is not counted.
      check refusedRemoversFor(rootRefusal.hwnd, rootRefusal.aux,
        rootRefusal.aux2).len == 1
      let retries = removersFor(rootRefusal.hwnd, rootRefusal.aux,
        rootRefusal.aux2)
      check retries.len == 1
      if retries.len == 1:
        check retries[0].ok != 0
        check retries[0].aux == rootRefusal.aux
        check retries[0].aux2 == rootRefusal.aux2
        let destroys = recordsOf("destroy", rootRefusal.hwnd)
        check destroys.len == 1
        if destroys.len == 1: check retries[0].seq < destroys[0].seq
      check onlyLiveDestroyCalls()
      check noDoubleRelease()
      check releasesAccounted()

  test "4) a raising DestroyWindow keeps the parked owner and every ancestor":
    let inj = Injection()
    let f = mounted(listRender, inj)
    block scenario:
      settle(f)
      let port = viewport()
      check port != 0
      if port == 0: break scenario
      scroll(port, SB_PAGEDOWN)
      settle(f)
      check f.win.diagnostics.parkedRows >= 2
      # A real parked child: live, hidden grandchild of the viewport.
      let primary = newException(UiError,
        "probe: destroyWindow refused by raising wrapper")
      inj.raiseDestroy = primary
      inj.raiseDestroyFilter = proc(window: HWND): bool {.closure, raises: [].} =
        if IsWindow(window) == 0 or IsWindowVisible(window) != 0: return false
        let parent = uint64(cast[uint](GetParent(window)))
        parent != 0 and parentOf(parent) == port
      let firstError = closeAttempt(f, 1)
      check firstError != nil
      if firstError != nil:
        # Same exception object and the original text, not a wrapper error.
        check cast[uint](cast[pointer](firstError)) ==
          cast[uint](cast[pointer](primary))
        check firstError.msg == primary.msg
      let raised = lastRec("destroy-raise")
      check raised.seq >= 0 and raised.live and raised.hwnd != 0
      if raised.seq < 0: break scenario
      # The failed window and every ancestor are still owned and alive.
      check alive(raised.hwnd)
      var current = raised.hwnd
      var guard = 0
      while parentOf(current) != 0 and guard < 64:
        current = parentOf(current)
        check alive(current)
        inc guard
      check current == f.host
      # The failed plain parked slot is still counted by the backend owner.
      check f.win.diagnostics.parkedRows >= 1
      check onlyLiveDestroyCalls()
      inj.raiseDestroy = nil
      let secondError = closeAttempt(f, 2)
      check secondError == nil
      check f.h.resourcesReleasedInternal()
      check aliveSet().len == 0
      # Every released window has its own credential: no implicit ancestor kill.
      check onlyLiveDestroyCalls()
      check noDoubleRelease()
      check releasesAccounted()

  test "5) a raising RemoveWindowSubclass keeps its identity for the exact retry":
    let inj = Injection()
    let f = mounted(listRender, inj)
    block scenario:
      settle(f)
      let port = viewport()
      check port != 0
      if port == 0: break scenario
      scroll(port, SB_PAGEDOWN)
      settle(f)
      check f.win.diagnostics.parkedRows >= 2
      let primary = newException(UiError,
        "probe: removeSubclass refused by raising wrapper")
      inj.raiseRemove = primary
      inj.raiseRemoveFilter = onlyWindow(port)
      let firstError = closeAttempt(f, 1)
      check firstError != nil
      if firstError != nil:
        check cast[uint](cast[pointer](firstError)) ==
          cast[uint](cast[pointer](primary))
        check firstError.msg == primary.msg
      let raised = lastRec("removeSubclass-raise")
      check raised.seq >= 0 and raised.hwnd == port and raised.live
      check raised.aux != 0 and raised.aux2 != 0
      if raised.seq < 0: break scenario
      # The failed identity is retained; releasing independent siblings is legal,
      # so this case does not require every parked group to survive.
      check alive(port)
      check onlyLiveDestroyCalls()
      inj.raiseRemove = nil
      let secondError = closeAttempt(f, 2)
      check secondError == nil
      check f.h.resourcesReleasedInternal()
      check aliveSet().len == 0
      let retries = removersFor(port, raised.aux, raised.aux2)
      check retries.len == 1
      if retries.len == 1:
        check retries[0].ok != 0
        let destroys = recordsOf("destroy", port)
        check destroys.len == 1
        if destroys.len == 1: check retries[0].seq < destroys[0].seq
      check onlyLiveDestroyCalls()
      check noDoubleRelease()
      check releasesAccounted()

  test "6) a raising park SW_HIDE is credited per window, never via an ancestor":
    let inj = Injection()
    let f = mounted(listRender, inj)
    block scenario:
      settle(f)
      let port = viewport()
      check port != 0
      if port == 0: break scenario
      check f.win.diagnostics.parkedRows == 0
      let primary = newException(UiError,
        "probe: park ShowWindow refused by raising wrapper")
      inj.raiseShow = primary
      # The selected park row: its root hide (parent = viewport) is allowed to
      # run; the next hide of one of that root's children raises. Shed hides and
      # layout hides happen before the root hide and are never matched.
      var parkRoot: HWND
      inj.showFilter = proc(window: HWND, command: int32): bool
          {.closure, raises: [].} =
        if command != SW_HIDE: return false
        let parent = GetParent(window)
        if parent == nil: return false
        if uint64(cast[uint](parent)) == port:
          parkRoot = window
          return false
        if parkRoot != nil and parent == parkRoot:
          return true
        false
      let armSeq = recs.len
      scroll(port, SB_PAGEDOWN)
      var raised: ref CatchableError
      try: settle(f)
      except CatchableError as error: raised = error
      check raised != nil
      if raised != nil:
        check cast[uint](cast[pointer](raised)) ==
          cast[uint](cast[pointer](primary))
        check raised.msg == primary.msg
      let shown = lastRec("show-raise")
      check shown.seq >= 0 and shown.live
      check uint64(shown.aux) == uint64(SW_HIDE)
      if shown.seq < 0: break scenario
      let root = parentOf(shown.hwnd)
      check root != 0 and parentOf(root) == port
      # The prefix root was already hidden and retired inside the same park
      # before the failing hide of its child.
      var prefixHidden = false
      for index in armSeq ..< recs.len:
        let item = recs[index]
        if item.op == "show" and uint64(item.aux) == uint64(SW_HIDE) and
            item.parent == port and item.hwnd == uint64(cast[uint](root)):
          prefixHidden = true
      check prefixHidden
      check IsWindowVisible(cast[HWND](root)) == 0
      let row = groupOf(root)
      check row.len == 4
      # The recovery after the failed park (adapter restore) and the explicit
      # close must credit every window of the park group on its own: no ancestor
      # may release the prefix/suffix implicitly and nothing is released twice.
      check onlyLiveDestroyCalls()
      inj.raiseShow = nil
      let closeError = closeAttempt(f, 1)
      check closeError == nil
      check f.h.resourcesReleasedInternal()
      check aliveSet().len == 0
      for hwnd in row:
        check recordsOf("destroy", hwnd).len == 1
      check onlyLiveDestroyCalls()
      check noDoubleRelease()
      check releasesAccounted()
