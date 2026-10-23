## T2 resource-slice RED: owner and lifecycle of *real* HWNDs for parked rows,
## row borrowing, viewport removal, `retiring`, `restore`, pool-full fallback and
## close/dispose retries.
##
## Observation model: every Win32 call the backend makes flows through a wrapped
## `Win32Calls` table, so each scenario gets the exact call sequence, the
## target's liveness at call time and the raw OS answer. All assertions are made
## on that ledger plus before/after snapshots of the *actually alive* created
## windows - never on `liveWindows`-style counters. A scenario drives
## `safeListTurn` (the production list turn) and a bounded, explicitly numbered
## sequence of `destroyHost`/`dispose`/`restore` calls; there is no `pump`, no
## safe-tick loop, no implicit `defer` release and no hidden post-assertion
## cleanup.
##
## Retry budget (ordinals are unique inside a case and never reused):
##   * cases 1..9 and 12..15: at most two explicit close/dispose/restore calls
##     (case 12/13/14 use one `restore` plus one or two closes);
##   * case 10 and case 11: exactly three, because two consecutive refusals are
##     the scenario (10) or dispose-then-idempotent-dispose-plus-host-close is
##     the scenario (11).
## A case whose *primary* assertion fails may therefore end with a live Host.
## That is intentional: the native RED phase must run one case per process, e.g.
##   test_win32_list_failures "2) refused parked child*"
## (`std/unittest` filters on positional globs and `suite::test`). OS process
## exit is *not* treated as resource release; every case proves release (or the
## exact retained owner) with the before/after window snapshot it captured.
##
## LastError discipline: every wrapper pre-observes parent/liveness, clears the
## error, performs (or refuses) the call, captures the raw result immediately,
## logs without any further OS query and then restores the raw error, so the
## backend observes exactly one consistent OS answer. `SetWindowLongPtrW`
## returns the *previous* id (0 is legal); a refusal is delivered like the OS
## does - 0 plus a real `ERROR_INVALID_WINDOW_HANDLE` (1400) - so a 0 return is
## never mistaken for a legal previous id. `RemoveWindowSubclass`'s last-error
## is not promised by Win32: it is recorded only, never interpreted.
import ../fixture_app
when not defined(windows): {.error: "Win32 list cleanup suite requires Windows".}
import std/[unittest, sets, tables, options, os, syncio, strutils]
import leaf/[core, widgets, backend, backend_session, native_layout, ui_thread]
import leaf/backends/win32/[api, calls, host, backend, row_pool]

const
  ItemCount = 200
  RowHeight = 24.0
  RowGroup = 4
    ## text + button + checkbox + their row root.
  RefusalError = 1400'u32
    ## ERROR_INVALID_WINDOW_HANDLE: the OS answer for a stale native identity.

type
  Rec = object
    seq: int
    op: string
    hwnd: uint64
    parent: uint64
    ok: int
      ## BOOL result, or the previous id for `setCtrlId`.
    raw: uint64
      ## window style on `create`, id on subclass calls, 0 elsewhere.
    err: uint64
      ## raw last-error observed for this call
    live: bool
      ## the target was a live window when the call was attempted
    aux: uint64
      ## subclass id (subclass calls), 0 otherwise
    aux2: uint64
      ## subclass callback identity (subclass calls), 0 otherwise
    turn: int
    attempt: int
    stage: string

  Injection = ref object
    ## Bucket-addressed refusal counters: refuse exactly N matching calls.
    refuseDestroy, refuseRemoveSubclass, refuseSetSubclass, refuseSetCtrlId: int
    destroyFilter, removeFilter, subclassFilter, ctrlIdFilter:
      proc(window: HWND): bool {.closure, raises: [].}

  Fixture = object
    h: Win32Host
    win: Win32Backend
    s: BackendSession
    r: Runtime
    inj: Injection
    host: uint64

var
  recs: seq[Rec]
  stage = "mount"
  attempt = 0
  turn = 0

proc note(op: string, hwnd, parent: HWND, ok: int, raw: uint64, err: DWORD,
          live: bool, aux = 0'u64, aux2 = 0'u64) {.raises: [].} =
  recs.add(Rec(seq: recs.len, op: op, hwnd: uint64(cast[uint](hwnd)),
    parent: uint64(cast[uint](parent)), ok: ok, raw: raw, err: uint64(err),
    live: live, aux: aux, aux2: aux2, turn: turn, attempt: attempt, stage: stage))

proc wrap(c: var Win32Calls, inj: Injection) =
  let realCreate = c.createWindow
  let realDestroy = c.destroyWindow
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
    note("create", r, parent, ord(r != nil), uint64(style), err, r != nil)
    setLastError(err)
    r
  c.destroyWindow = proc(window: HWND): BOOL =
    let parent = GetParent(window)
    let live = IsWindow(window) != 0
    setLastError(0)
    var op = "destroy"
    var r: BOOL
    var err = RefusalError
    if inj.refuseDestroy > 0 and
        (inj.destroyFilter == nil or inj.destroyFilter(window)):
      dec inj.refuseDestroy
      op = "destroy-refused"
    else:
      r = realDestroy(window)
      err = lastError()
    note(op, window, parent, ord(r != 0), 0, err, live)
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
    note(op, window, parent, ord(r != 0), uint64(id), err, live, uint64(id),
      cast[uint](callback))
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
    if inj.refuseRemoveSubclass > 0 and
        (inj.removeFilter == nil or inj.removeFilter(window)):
      dec inj.refuseRemoveSubclass
      op = "removeSubclass-refused"
    else:
      r = realDelSub(window, callback, id)
      # Win32 does not promise a meaningful last-error here: record only.
      err = lastError()
    note(op, window, parent, ord(r != 0), uint64(id), err, live, uint64(id),
      cast[uint](callback))
    setLastError(err)
    r
  c.setCtrlId = proc(window: HWND, value: int): int =
    let parent = GetParent(window)
    let live = IsWindow(window) != 0
    setLastError(0)
    var op = "setCtrlId"
    var r: int
    var err = RefusalError
    if inj.refuseSetCtrlId > 0 and
        (inj.ctrlIdFilter == nil or inj.ctrlIdFilter(window)):
      dec inj.refuseSetCtrlId
      op = "setCtrlId-refused"
    else:
      r = realSetCid(window, value)
      err = lastError()
    note(op, window, parent, r, 0, err, live)
    setLastError(err)
    r

# ---- ledger queries -------------------------------------------------------

proc alive(hwnd: uint64): bool {.raises: [].} =
  hwnd != 0 and IsWindow(cast[HWND](hwnd)) != 0

proc createdWindows(): seq[uint64] {.raises: [].} =
  var seen: HashSet[uint64]
  for item in recs:
    if item.op != "create" or item.hwnd == 0 or item.hwnd in seen: continue
    seen.incl(item.hwnd)
    result.add(item.hwnd)

proc aliveSet(): HashSet[uint64] {.raises: [].} =
  ## Snapshot of the created windows that are actually alive right now.
  for hwnd in createdWindows():
    if alive(hwnd): result.incl(hwnd)

proc subset(a, b: HashSet[uint64]): bool {.raises: [].} =
  for item in a:
    if item notin b: return false
  true

proc createRec(hwnd: uint64): Rec {.raises: [].} =
  ## The creation record of one native identity. Parents are recorded here, so
  ## the native topology stays observable after the windows are gone.
  for item in recs:
    if item.op == "create" and item.hwnd == hwnd: return item
  Rec(seq: -1)

proc parentOf(hwnd: uint64): uint64 {.raises: [].} = createRec(hwnd).parent

proc childrenOf(hwnd: uint64): seq[uint64] {.raises: [].} =
  for item in recs:
    if item.op == "create" and item.parent == hwnd and item.hwnd != hwnd:
      result.add(item.hwnd)

proc groupOf(root: uint64): seq[uint64] {.raises: [].} =
  ## One row group: its root plus every child created under it.
  result.add(root)
  for item in childrenOf(root): result.add(item)

proc subtreeOf(root: uint64): seq[uint64] {.raises: [].} =
  ## Recursive pre-order of the recorded native topology.
  result.add(root)
  for item in childrenOf(root):
    for nested in subtreeOf(item): result.add(nested)

proc rootUnder(hwnd, port: uint64): uint64 {.raises: [].} =
  ## Nearest ancestor (self included) that is a direct child of the viewport.
  var current = hwnd
  var depth = 0
  while current != 0 and depth < 8:
    let parent = parentOf(current)
    if parent == port: return current
    if parent == 0: return 0
    current = parent
    inc depth
  0

proc createdBefore(hwnd: uint64, stampturn: int): bool {.raises: [].} =
  let item = createRec(hwnd)
  item.seq >= 0 and item.turn < stampturn

proc viewports(): seq[uint64] {.raises: [].} =
  ## A viewport is the created control that asks for WS_VSCROLL.
  for hwnd in createdWindows():
    if (createRec(hwnd).raw and uint64(WS_VSCROLL)) != 0 and alive(hwnd):
      result.add(hwnd)

proc rowRoots(port: uint64): seq[uint64] {.raises: [].} =
  for item in recs:
    if item.op == "create" and item.parent == port and item.hwnd != port:
      result.add(item.hwnd)

proc aliveRows(port: uint64): seq[uint64] {.raises: [].} =
  for hwnd in rowRoots(port):
    if alive(hwnd): result.add(hwnd)

proc visibleRows(port: uint64): seq[uint64] {.raises: [].} =
  for hwnd in rowRoots(port):
    if alive(hwnd) and IsWindowVisible(cast[HWND](hwnd)) != 0:
      result.add(hwnd)

proc parkedRoots(port: uint64): seq[uint64] {.raises: [].} =
  ## Parked slots hide their subtree root; rows of the accepted frame are shown
  ## by the geometry pass.
  for hwnd in rowRoots(port):
    if alive(hwnd) and IsWindowVisible(cast[HWND](hwnd)) == 0:
      result.add(hwnd)

proc countOp(op: string): int {.raises: [].} =
  for item in recs:
    if item.op == op: inc result

proc lastRec(op: string): Rec {.raises: [].} =
  for index in countdown(recs.len - 1, 0):
    if recs[index].op == op: return recs[index]
  Rec(seq: -1)

proc recordsOf(op: string, hwnd: uint64): seq[Rec] {.raises: [].} =
  for item in recs:
    if item.op == op and item.hwnd == hwnd: result.add(item)

proc removerRecords(hwnd: uint64): seq[Rec] {.raises: [].} =
  for item in recs:
    if item.hwnd == hwnd and
        (item.op == "removeSubclass" or item.op == "removeSubclass-refused"):
      result.add(item)

proc removerCalls(hwnd: uint64, round: int): int {.raises: [].} =
  for item in removerRecords(hwnd):
    if item.attempt == round: inc result

proc succeededInAttempt(op: string, hwnd: uint64, round: int): bool {.raises: [].} =
  for item in recs:
    if item.op == op and item.hwnd == hwnd and item.attempt == round and
        item.ok != 0:
      return true
  false

proc succeededInTurn(op: string, hwnd: uint64, stamp: int): bool {.raises: [].} =
  for item in recs:
    if item.op == op and item.hwnd == hwnd and item.turn == stamp and
        item.ok != 0 and item.attempt == 0:
      return true
  false

proc callsInTurn(op: string, stamp: int): int {.raises: [].} =
  ## Real (or refused) calls of one op issued during one list turn.
  for item in recs:
    if item.op == op and item.turn == stamp and item.attempt == 0: inc result

proc onlyLiveDestroyCalls(): bool {.raises: [].} =
  ## DestroyWindow is never called on an already released identity.
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
  ## No window may vanish because an ancestor was destroyed: every released
  ## identity has its own recorded successful DestroyWindow.
  var freed: HashSet[uint64]
  for item in recs:
    if item.op == "destroy" and item.ok != 0: freed.incl(item.hwnd)
  for hwnd in createdWindows():
    if not alive(hwnd) and hwnd notin freed: return false
  true

proc windowsAccountedOrAlive(items: seq[uint64]): bool {.raises: [].} =
  ## After a failed candidate both outcomes are legal: a window is either still
  ## owned (alive) or was released with its own successful record. Nothing may
  ## be lost and nothing may be released implicitly by an ancestor.
  for hwnd in items:
    if alive(hwnd): continue
    var freed = false
    for item in recs:
      if item.op == "destroy" and item.hwnd == hwnd and item.ok != 0: freed = true
    if not freed: return false
  true

proc destroyCallsClean(round: int): bool {.raises: [].} =
  ## Every real DestroyWindow of this pass hit a live window and succeeded; the
  ## only failure of the pass is therefore the injected refusal.
  for item in recs:
    if item.op == "destroy" and item.attempt == round and
        (item.ok == 0 or not item.live):
      return false
  true

proc removerCallsClean(round: int): bool {.raises: [].} =
  for item in recs:
    if item.op == "removeSubclass" and item.attempt == round and item.ok == 0:
      return false
  true

proc allReleaseRules(): bool {.raises: [].} =
  onlyLiveDestroyCalls() and noDoubleRelease() and releasesAccounted()

proc releasedEverywhere(f: Fixture): bool =
  f.h.resourcesReleasedInternal() and aliveSet().len == 0

# ---- optional diagnostics ledger -----------------------------------------
#
# `LEAF_WIN32_CLEANUP_LOG=<path>` turns on an append-only dump of the native
# call ledger and of every judged boundary (list turn, explicit
# close/dispose/restore): full primitive record fields, the primary exception
# (type, object identity, message) and the alive-window sets before/after.
# Logging runs only at scenario boundaries, never inside a wrapper or a foreign
# callback, and restores the thread last-error around every write, so it cannot
# change a call's effect or the error the backend observes. Every line is
# flushed; a failed write is reported on stderr and marked in the log, so an
# incomplete log is never mistaken for complete evidence.

var
  logTarget = ""
  logBroken = false
  logMark = 0
  currentCase = ""

proc initLog() {.raises: [].} =
  ## Read the optional log target once. Unset/empty means no I/O at all.
  try: logTarget = getEnv("LEAF_WIN32_CLEANUP_LOG")
  except CatchableError: logTarget = ""

proc logLine(line: string) {.raises: [].} =
  if logTarget.len == 0: return
  let saved = lastError()
  try:
    var handle: File
    if not open(handle, logTarget, fmAppend):
      logBroken = true
      try: stderr.writeLine("T2-CLEANUP-LOG-ERROR: cannot open " & logTarget)
      except CatchableError: discard
    else:
      try:
        handle.writeLine(line)
        flushFile(handle)
      finally: handle.close()
  except CatchableError:
    logBroken = true
    try: stderr.writeLine("T2-CLEANUP-LOG-ERROR: " & getCurrentExceptionMsg())
    except CatchableError: discard
  setLastError(saved)

proc fmtWindow(hwnd: uint64): string {.raises: [].} =
  if hwnd == 0: "0" else: "0x" & toHex(hwnd, 16)

proc fmtAlive(items: HashSet[uint64]): string {.raises: [].} =
  var parts: seq[string]
  for hwnd in createdWindows():
    if hwnd in items: parts.add(fmtWindow(hwnd))
  "[" & parts.join(",") & "]"

proc errorTypeName(error: ref CatchableError): string {.raises: [].} =
  if error == nil: return "none"
  if error of Win32RunError: "Win32RunError"
  elif error of UiError: "UiError"
  elif error of IOError: "IOError"
  elif error of OSError: "OSError"
  elif error of ValueError: "ValueError"
  else: "CatchableError"

proc dumpRecords() {.raises: [].} =
  if logTarget.len == 0: return
  for index in logMark ..< recs.len:
    let item = recs[index]
    logLine("NATIVE case=" & currentCase & " seq=" & $item.seq & " op=" & item.op &
      " hwnd=" & fmtWindow(item.hwnd) & " parent=" & fmtWindow(item.parent) &
      " ok=" & $item.ok & " raw=" & $item.raw & " err=" & $item.err &
      " live=" & $item.live & " aux=" & $item.aux &
      " aux2=" & fmtWindow(item.aux2) & " turn=" & $item.turn &
      " attempt=" & $item.attempt & " stage=" & item.stage)
  logMark = recs.len

proc dumpBoundary(tag: string, before, after: HashSet[uint64],
                  error: ref CatchableError) {.raises: [].} =
  if logTarget.len == 0: return
  dumpRecords()
  logLine("BOUNDARY case=" & currentCase & " tag=" & tag & " aliveBefore=" &
    fmtAlive(before) & " aliveAfter=" & fmtAlive(after))
  logLine("PRIMARY case=" & currentCase & " tag=" & tag & " type=" &
    errorTypeName(error) & " identity=" &
    (if error == nil: "0"
     else: "0x" & toHex(uint64(cast[uint](cast[pointer](error))), 16)) &
    " msg=" & (if error == nil: "" else: error.msg.replace("\n", "\\n")))
  if logBroken: logLine("LOG-INCOMPLETE case=" & currentCase & " tag=" & tag)

proc beginCase(tag: string) {.raises: [].} =
  currentCase = tag
  dumpRecords()
  logLine("CASE-BEGIN case=" & tag & " alive=" & fmtAlive(aliveSet()))

initLog()

# ---- filters --------------------------------------------------------------

proc onlyWindow(target: uint64): proc(window: HWND): bool {.closure, raises: [].} =
  proc(window: HWND): bool {.closure, raises: [].} =
    uint64(cast[uint](window)) == target

proc onlyWindows(targets: HashSet[uint64]): proc(window: HWND): bool {.closure, raises: [].} =
  proc(window: HWND): bool {.closure, raises: [].} =
    uint64(cast[uint](window)) in targets

proc parkedRootFilter(port: uint64): proc(window: HWND): bool {.closure, raises: [].} =
  ## A live, hidden direct child of the viewport: the root of a parked slot.
  proc(window: HWND): bool {.closure, raises: [].} =
    if IsWindow(window) == 0 or IsWindowVisible(window) != 0: return false
    parentOf(uint64(cast[uint](window))) == port

proc parkedChildFilter(port: uint64): proc(window: HWND): bool {.closure, raises: [].} =
  ## A live, hidden grandchild of the viewport: a child of a parked row root.
  proc(window: HWND): bool {.closure, raises: [].} =
    if IsWindow(window) == 0 or IsWindowVisible(window) != 0: return false
    let parent = uint64(cast[uint](GetParent(window)))
    parent != 0 and parentOf(parent) == port

proc borrowRootFilter(port: uint64,
    stamp: int): proc(window: HWND): bool {.closure, raises: [].} =
  ## A live, hidden root that existed before the borrow turn: the first window
  ## the backend re-keys for a borrowed slot.
  proc(window: HWND): bool {.closure, raises: [].} =
    if IsWindow(window) == 0 or IsWindowVisible(window) != 0: return false
    parentOf(uint64(cast[uint](window))) == port and
      createdBefore(uint64(cast[uint](window)), stamp)

proc borrowChildFilter(port: uint64,
    stamp: int): proc(window: HWND): bool {.closure, raises: [].} =
  ## A live, hidden grandchild that existed before the borrow turn: a mid-group
  ## window of a slot being re-keyed (fresh controls of the same turn are not).
  proc(window: HWND): bool {.closure, raises: [].} =
    if IsWindow(window) == 0 or IsWindowVisible(window) != 0: return false
    let parent = uint64(cast[uint](GetParent(window)))
    parent != 0 and parentOf(parent) == port and
      createdBefore(uint64(cast[uint](window)), stamp)

# ---- fixture --------------------------------------------------------------

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

proc twoViewportRender(): Node =
  var keys: seq[string]
  for index in 0 ..< ItemCount: keys.add($index)
  column(@[
    virtualList("left", keys, proc(index: int): Node = compoundRow(index),
      rowHeight = RowHeight, overscan = 0, styles = style({"height": "120"})),
    virtualList("right", keys, proc(index: int): Node = compoundRow(index),
      rowHeight = RowHeight, overscan = 0, styles = style({"height": "120"}))],
    key = "root")

proc threeViewportRender(): Node =
  var keys: seq[string]
  for index in 0 ..< ItemCount: keys.add($index)
  column(@[
    virtualList("a", keys, proc(index: int): Node = compoundRow(index),
      rowHeight = RowHeight, overscan = 0, styles = style({"height": "120"})),
    virtualList("b", keys, proc(index: int): Node = compoundRow(index),
      rowHeight = RowHeight, overscan = 0, styles = style({"height": "120"})),
    virtualList("c", keys, proc(index: int): Node = compoundRow(index),
      rowHeight = RowHeight, overscan = 0, styles = style({"height": "120"}))],
    key = "root")

proc mounted(render: proc(): Node, inj: Injection, width = 480,
             height = 320): Fixture =
  recs.setLen(0)
  turn = 0
  attempt = 0
  stage = "mount"
  logMark = 0
  currentCase = ""
  var c = systemWin32Calls()
  wrap(c, inj)
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(
    fixtureApplication(render, "cleanup", width, height),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("cleanup host",
    DipSize(width: float64(width), height: float64(height)), c)
  h.setStartupScope(proc(): bool =
    activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win = newWin32Backend(h, c)
  result = Fixture(h: h, win: win, r: runtime, inj: inj,
    host: uint64(cast[uint](h.windowHandle)))
  result.s = win.attachWin32Backend(runtime)
  win.bindSession(result.s)
  h.bindSession(result.s, proc(): bool = activity.busy)

proc settle(f: Fixture, phase = "") =
  ## One ordinary native list turn: recorded viewport facts, one bounded row
  ## drain and one geometry pass. Never a window callback. `phase` only labels
  ## the stage/boundary (e.g. a borrow turn), it changes no product call.
  let before = aliveSet()
  inc turn
  let tag = if phase.len > 0: phase else: "turn"
  stage = tag
  var raised: ref CatchableError
  try: f.win.safeListTurn()
  except CatchableError as error: raised = error
  dumpBoundary(tag & "#" & $turn, before, aliveSet(), raised)
  if raised != nil: raise raised

proc scroll(port: uint64, code: int) =
  discard SendMessageW(cast[HWND](port), WM_VSCROLL, WPARAM(code), 0)

proc closeAttempt(f: Fixture, round: int): ref CatchableError =
  let before = aliveSet()
  attempt = round
  stage = "close"
  try:
    f.h.destroyHost()
  except CatchableError as error:
    result = error
  dumpBoundary("close#" & $round, before, aliveSet(), result)

proc disposeAttempt(f: Fixture, round: int): ref CatchableError =
  let before = aliveSet()
  attempt = round
  stage = "dispose"
  try:
    f.win.asBackend.dispose()
  except CatchableError as error:
    result = error
  dumpBoundary("dispose#" & $round, before, aliveSet(), result)

proc restoreAttempt(f: Fixture, round: int): ref CatchableError =
  let before = aliveSet()
  attempt = round
  stage = "restore"
  try:
    f.win.asBackend.restore(f.s.acceptedEntities())
  except CatchableError as error:
    result = error
  dumpBoundary("restore#" & $round, before, aliveSet(), result)

# ---- scenario helpers -----------------------------------------------------

type
  BorrowKind = enum bkCtrlId, bkSubclass
  BorrowProbe = object
    raised: ref CatchableError
    refused: Rec
    root: uint64
    group: seq[uint64]
    retained: int
    stamp: int
    revisionBefore, revisionAfter: uint64
    reusedBefore, reusedAfter: int

proc probeBorrow(f: Fixture, port: uint64, kind: BorrowKind,
                 mid: bool): BorrowProbe =
  ## Park a frame, then commit the top frame from parked slots with exactly one
  ## refused metadata insert. The refusal target is a pre-existing parked window
  ## of this list: the slot root (first) or a mid-group child.
  let stamp = turn + 1
  result.stamp = stamp
  case kind
  of bkCtrlId:
    f.inj.refuseSetCtrlId = 1
    if mid: f.inj.ctrlIdFilter = borrowChildFilter(port, stamp)
  of bkSubclass:
    f.inj.refuseSetSubclass = 1
    f.inj.subclassFilter =
      if mid: borrowChildFilter(port, stamp) else: borrowRootFilter(port, stamp)
  result.revisionBefore = f.r.acceptedRevision
  result.reusedBefore = int(f.win.diagnostics.reusedRows)
  stage = "borrow"
  scroll(port, SB_TOP)          # the borrow trigger: commit the top frame
  try: settle(f, "borrow")
  except CatchableError as error: result.raised = error
  result.revisionAfter = f.r.acceptedRevision
  result.reusedAfter = int(f.win.diagnostics.reusedRows)
  result.refused = lastRec(if kind == bkCtrlId: "setCtrlId-refused"
                           else: "setSubclass-refused")
  if result.refused.seq >= 0:
    result.root = rootUnder(result.refused.hwnd, port)
    if result.root != 0: result.group = groupOf(result.root)
    for hwnd in result.group:
      if alive(hwnd): inc result.retained

proc shedVisibleRowChild(f: Fixture, port: uint64): uint64 =
  ## Real delta through the public backend contract: remove one child of a live
  ## compound row and keep the row root, so the child lands in `retiring`.
  ## Returns the retired child's HWND (0 when the fixture could not be built).
  let entities = f.s.acceptedEntities()
  var rootHandle = NoHandle
  var childHandle = NoHandle
  for handle, entity in entities:
    if entity.row.isSome:
      rootHandle = handle
      break
  if rootHandle == NoHandle: return 0
  for handle, entity in entities:
    if entity.parent == rootHandle and entity.kind in
        {NodeKind.text, NodeKind.button, NodeKind.checkbox}:
      childHandle = handle
      break
  if childHandle == NoHandle: return 0
  let batch = UpdateBatch(revision: f.r.acceptedRevision, isDelta: true,
    ops: @[UpdateOp(kind: opRemove, handle: childHandle)])
  stage = "shed"
  f.win.asBackend.prepare(batch)
  f.win.asBackend.apply(batch)
  # The retired child is the one live, hidden grandchild whose row root is a
  # visible row of the accepted frame.
  for hwnd in createdWindows():
    if not alive(hwnd) or IsWindowVisible(cast[HWND](hwnd)) != 0: continue
    let parent = parentOf(hwnd)
    if parent != 0 and parentOf(parent) == port and
        IsWindowVisible(cast[HWND](parent)) != 0:
      if result != 0: return 0
      result = hwnd

# ---- scenarios ------------------------------------------------------------

suite "T2 list cleanup RED (real HWND owners)":
  test "1) natural close releases a parked compound row once":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("1")
    block scenario:
      settle(f)                                # accepted frame: 5 compound rows
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      check visibleRows(port).len == 5
      scroll(port, SB_PAGEDOWN)                # four rows leave the frame
      settle(f)
      check f.win.diagnostics.parkedRows >= 2
      let parked = parkedRoots(port)
      check parked.len >= 2
      let snapBefore = aliveSet()
      check port in snapBefore
      for slot in parked: check slot in snapBefore
      let closeError = closeAttempt(f, 1)
      check closeError == nil
      let snapAfter = aliveSet()
      check subset(snapAfter, snapBefore)      # nothing resurrected
      check snapAfter.len == 0                 # nothing left owned or alive
      check releasedEverywhere(f)
      # No released identity is destroyed again, and no ancestor release hides
      # a window: the OS answer is never swallowed.
      check allReleaseRules()
    # No post-assertion cleanup: this case is primary-assertion-clean or RED.

  test "2) refused parked child keeps it and ancestors, siblings go on":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("2")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      scroll(port, SB_PAGEDOWN)
      settle(f)
      let parked = parkedRoots(port)
      check f.win.diagnostics.parkedRows >= 2   # one owner, >= 2 real slots
      check parked.len >= 2
      if parked.len < 2: break scenario
      let snapBefore = aliveSet()
      let revisionBefore = f.r.acceptedRevision
      inj.refuseDestroy = 1
      inj.destroyFilter = parkedChildFilter(port)
      let firstError = closeAttempt(f, 1)
      check firstError != nil
      check countOp("destroy-refused") == 1
      let refused = lastRec("destroy-refused")
      check refused.seq >= 0
      check refused.live                       # the product tried a live child
      check refused.attempt == 1
      if refused.seq < 0: break scenario
      let root = rootUnder(refused.hwnd, port)
      check root != 0 and root != refused.hwnd
      check root in parked                     # it belongs to a parked slot
      if root == 0: break scenario
      let snapAfter = aliveSet()
      check subset(snapAfter, snapBefore)
      # The refused child and its ancestors stay owned by the same owner.
      check refused.hwnd in snapAfter
      check root in snapAfter
      check port in snapAfter
      # Independent siblings of the refused child were released immediately.
      for kid in childrenOf(root):
        if kid != refused.hwnd: check kid notin snapAfter
      # Other slots of the same owner are independent siblings too.
      var otherSlots = 0
      for other in parked:
        if other == root: continue
        inc otherSlots
        check other notin snapAfter
        for kid in childrenOf(other): check kid notin snapAfter
      check otherSlots >= 1
      check f.r.acceptedRevision == revisionBefore
      check destroyCallsClean(1)               # only the injected refusal failed
      check allReleaseRules()
      inj.refuseDestroy = 0
      let secondError = closeAttempt(f, 2)
      check secondError == nil
      check releasedEverywhere(f)
      check succeededInAttempt("destroy", refused.hwnd, 2)  # retried remainder
      check f.r.acceptedRevision == revisionBefore
      check allReleaseRules()

  test "3) same-owner slots and the other viewport stay isolated":
    let inj = Injection()
    let f = mounted(twoViewportRender, inj)
    beginCase("3")
    block scenario:
      settle(f)                                # both lists materialize a frame
      let ports = viewports()
      check ports.len == 2
      if ports.len != 2: break scenario
      let a = ports[0]
      let b = ports[1]
      check visibleRows(a).len == 5
      check visibleRows(b).len == 5            # a real, non-empty second list
      let bWindows = subtreeOf(b)
      check bWindows.len >= 1 + 5 * RowGroup   # every group is non-empty
      scroll(a, SB_PAGEDOWN)                   # only list a parks rows
      settle(f)
      let parked = parkedRoots(a)
      check parked.len >= 2
      check visibleRows(b).len == 5            # b's accepted frame untouched
      if parked.len < 2: break scenario
      let snapBefore = aliveSet()
      let revisionBefore = f.r.acceptedRevision
      check b in snapBefore
      inj.refuseDestroy = 1
      inj.destroyFilter = parkedChildFilter(a)
      let firstError = closeAttempt(f, 1)
      check firstError != nil
      check countOp("destroy-refused") == 1
      let refused = lastRec("destroy-refused")
      check refused.seq >= 0
      check refused.live
      check refused.attempt == 1
      if refused.seq < 0: break scenario
      let root = rootUnder(refused.hwnd, a)
      check root in parked
      if root == 0: break scenario
      let snapAfter = aliveSet()
      check subset(snapAfter, snapBefore)
      check refused.hwnd in snapAfter
      check root in snapAfter
      check a in snapAfter                     # a's owner is retained
      for other in parked:
        if other == root: continue
        check other notin snapAfter
        for kid in childrenOf(other): check kid notin snapAfter
      for kid in childrenOf(root):
        if kid != refused.hwnd: check kid notin snapAfter
      # b was released by its own owner in the same pass, in full.
      for hwnd in bWindows: check hwnd notin snapAfter
      check f.r.acceptedRevision == revisionBefore
      check destroyCallsClean(1)
      check allReleaseRules()
      inj.refuseDestroy = 0
      let secondError = closeAttempt(f, 2)
      check secondError == nil
      check releasedEverywhere(f)
      check allReleaseRules()

  test "4) a successful viewport remover is never replayed":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("4")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      scroll(port, SB_PAGEDOWN)
      settle(f)
      check parkedRoots(port).len >= 2
      # The viewport remover runs before the parked slots, so a later slot
      # failure must not repeat the already-successful remover.
      let snapBefore = aliveSet()
      let revisionBefore = f.r.acceptedRevision
      inj.refuseDestroy = 1
      inj.destroyFilter = parkedRootFilter(port)
      let firstError = closeAttempt(f, 1)
      check firstError != nil
      let removers = removerRecords(port)
      check removers.len == 1
      if removers.len == 1:
        check removers[0].attempt == 1
        check removers[0].ok != 0              # it really succeeded
        check removers[0].aux != 0             # subclass id is logged
        check removers[0].aux2 != 0            # callback identity is logged
      # The failure of this pass is exactly the injected refusal: no accidental
      # dead-target or wrong-BOOL failure hides it.
      check countOp("destroy-refused") == 1
      let refused = lastRec("destroy-refused")
      check refused.live and refused.attempt == 1
      check rootUnder(refused.hwnd, port) == refused.hwnd
      check subset(aliveSet(), snapBefore)     # nothing resurrected
      check f.r.acceptedRevision == revisionBefore
      check destroyCallsClean(1)
      check removerCallsClean(1)
      inj.refuseDestroy = 0
      let secondError = closeAttempt(f, 2)
      check secondError == nil
      # No replay of the same remover identity on the retry.
      if removers.len == 1:
        var replayed = false
        for item in removerRecords(port):
          if item.attempt == 2 and item.aux == removers[0].aux and
              item.aux2 == removers[0].aux2: replayed = true
        check not replayed
      check removerCalls(port, 2) == 0
      check releasedEverywhere(f)
      check f.r.acceptedRevision == revisionBefore
      check allReleaseRules()

  test "5) a refused viewport remover keeps the viewport and is retried once":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("5")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      scroll(port, SB_PAGEDOWN)
      settle(f)
      check parkedRoots(port).len >= 2
      let firstRemover = removerRecords(port)
      check firstRemover.len == 0              # not yet removed
      let snapBefore = aliveSet()
      let revisionBefore = f.r.acceptedRevision
      inj.refuseRemoveSubclass = 1
      inj.removeFilter = onlyWindow(port)
      let firstError = closeAttempt(f, 1)
      check firstError != nil
      check countOp("removeSubclass-refused") == 1
      let refused = lastRec("removeSubclass-refused")
      check refused.live and refused.hwnd == port and refused.attempt == 1
      check alive(port)                        # the owned viewport is retained
      check removerCalls(port, 1) == 1
      check subset(aliveSet(), snapBefore)
      check f.r.acceptedRevision == revisionBefore
      check removerCallsClean(1)               # taller rows were removed cleanly
      check destroyCallsClean(1)
      inj.refuseRemoveSubclass = 0
      let secondError = closeAttempt(f, 2)
      check secondError == nil
      # Exactly one real retry of the remover, with the same identity.
      let retries = removerCalls(port, 2)
      check retries == 1
      if refused.seq >= 0:
        var same = false
        for item in removerRecords(port):
          if item.attempt == 2 and item.aux == refused.aux and
              item.aux2 == refused.aux2 and item.ok != 0: same = true
        check same
      check releasedEverywhere(f)
      check f.r.acceptedRevision == revisionBefore
      check allReleaseRules()

  test "6) refused borrow setCtrlId on the slot root, then a cleanup refusal":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("6")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      scroll(port, SB_PAGEDOWN)
      settle(f)
      check parkedRoots(port).len >= 2
      let probe = probeBorrow(f, port, bkCtrlId, mid = false)
      check probe.refused.seq >= 0
      if probe.refused.seq < 0: break scenario
      check probe.refused.live
      check probe.refused.attempt == 0
      check createdBefore(probe.refused.hwnd, probe.stamp)
      check probe.root == probe.refused.hwnd   # first window of the first slot
      check countOp("setCtrlId-refused") == 1
      # A refused metadata insert is a real failure: it surfaces, is not counted
      # as a reuse and does not advance the accepted revision.
      check probe.raised != nil
      check probe.reusedAfter == probe.reusedBefore
      check probe.revisionAfter == probe.revisionBefore
      check windowsAccountedOrAlive(probe.group)
      check allReleaseRules()
      # Cleanup after the failed candidate: both outcomes are legal (a retained
      # owner or a complete, accounted rollback); each one is asserted exactly.
      inj.refuseSetCtrlId = 0
      let snapBefore = aliveSet()
      if probe.retained > 0:
        inj.refuseDestroy = 1
        inj.destroyFilter = onlyWindows(probe.group.toHashSet)
        let firstError = closeAttempt(f, 1)
        check firstError != nil
        check countOp("destroy-refused") == 1
        let refusal = lastRec("destroy-refused")
        check refusal.live
        check refusal.attempt == 1
        check refusal.hwnd in probe.group
        let snapHeld = aliveSet()
        check subset(snapHeld, snapBefore)
        # The refused child and its ancestors are still owned by the failure
        # owner; independent windows were released.
        check refusal.hwnd in snapHeld
        check probe.root in snapHeld
        check port in snapHeld
        check windowsAccountedOrAlive(probe.group)
        check destroyCallsClean(1)
        inj.refuseDestroy = 0
        let secondError = closeAttempt(f, 2)
        check secondError == nil
        check releasedEverywhere(f)
        check succeededInAttempt("destroy", refusal.hwnd, 2)
        check allReleaseRules()
      else:
        let closeError = closeAttempt(f, 1)
        check countOp("destroy-refused") == 0  # nothing was left to refuse
        check closeError == nil
        check releasedEverywhere(f)
        check allReleaseRules()

  test "7) refused borrow setCtrlId on a mid-group window":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("7")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      scroll(port, SB_PAGEDOWN)
      settle(f)
      check parkedRoots(port).len >= 2
      let probe = probeBorrow(f, port, bkCtrlId, mid = true)
      check probe.refused.seq >= 0
      if probe.refused.seq < 0: break scenario
      check probe.refused.live
      check probe.refused.attempt == 0
      check createdBefore(probe.refused.hwnd, probe.stamp)
      check probe.root != 0 and probe.root != probe.refused.hwnd
      check parentOf(probe.refused.hwnd) == probe.root
      check countOp("setCtrlId-refused") == 1
      check probe.raised != nil
      check probe.reusedAfter == probe.reusedBefore
      check probe.revisionAfter == probe.revisionBefore
      check windowsAccountedOrAlive(probe.group)
      check allReleaseRules()
      inj.refuseSetCtrlId = 0
      let snapBefore = aliveSet()
      let closeError = closeAttempt(f, 1)
      check closeError == nil
      check subset(aliveSet(), snapBefore)
      check releasedEverywhere(f)
      check allReleaseRules()

  test "8) refused borrow setSubclass on the slot root":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("8")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      scroll(port, SB_PAGEDOWN)
      settle(f)
      check parkedRoots(port).len >= 2
      let probe = probeBorrow(f, port, bkSubclass, mid = false)
      check probe.refused.seq >= 0
      if probe.refused.seq < 0: break scenario
      check probe.refused.live
      check probe.refused.attempt == 0
      check createdBefore(probe.refused.hwnd, probe.stamp)
      check probe.root == probe.refused.hwnd
      check countOp("setSubclass-refused") == 1
      check probe.raised != nil
      check probe.reusedAfter == probe.reusedBefore
      check probe.revisionAfter == probe.revisionBefore
      # No window may be left dead without its own release record: an unowned
      # prefix must not be dropped on the floor.
      check windowsAccountedOrAlive(probe.group)
      check allReleaseRules()
      inj.refuseSetSubclass = 0
      let snapBefore = aliveSet()
      let closeError = closeAttempt(f, 1)
      check closeError == nil
      check subset(aliveSet(), snapBefore)
      check releasedEverywhere(f)
      check allReleaseRules()

  test "9) refused borrow setSubclass on a mid-group window, then a cleanup refusal":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("9")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      scroll(port, SB_PAGEDOWN)
      settle(f)
      check parkedRoots(port).len >= 2
      let probe = probeBorrow(f, port, bkSubclass, mid = true)
      check probe.refused.seq >= 0
      if probe.refused.seq < 0: break scenario
      check probe.refused.live
      check probe.refused.attempt == 0
      check createdBefore(probe.refused.hwnd, probe.stamp)
      check probe.root != 0 and probe.root != probe.refused.hwnd
      check parentOf(probe.refused.hwnd) == probe.root
      check countOp("setSubclass-refused") == 1
      check probe.raised != nil
      check probe.reusedAfter == probe.reusedBefore
      check probe.revisionAfter == probe.revisionBefore
      check windowsAccountedOrAlive(probe.group)
      check allReleaseRules()
      inj.refuseSetSubclass = 0
      let snapBefore = aliveSet()
      if probe.retained > 0:
        inj.refuseDestroy = 1
        inj.destroyFilter = onlyWindows(probe.group.toHashSet)
        let firstError = closeAttempt(f, 1)
        check firstError != nil
        check countOp("destroy-refused") == 1
        let refusal = lastRec("destroy-refused")
        check refusal.live
        check refusal.attempt == 1
        check refusal.hwnd in probe.group
        let snapHeld = aliveSet()
        check subset(snapHeld, snapBefore)
        check refusal.hwnd in snapHeld
        check probe.root in snapHeld
        check port in snapHeld
        check windowsAccountedOrAlive(probe.group)
        check destroyCallsClean(1)
        inj.refuseDestroy = 0
        let secondError = closeAttempt(f, 2)
        check secondError == nil
        check releasedEverywhere(f)
        check succeededInAttempt("destroy", refusal.hwnd, 2)
        check allReleaseRules()
      else:
        let closeError = closeAttempt(f, 1)
        check countOp("destroy-refused") == 0
        check closeError == nil
        check releasedEverywhere(f)
        check allReleaseRules()

  test "10) two consecutive refused cleanup passes keep the slot enumerable":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("10")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      scroll(port, SB_PAGEDOWN)
      settle(f)
      let parked = parkedRoots(port)
      check parked.len >= 2
      if parked.len < 2: break scenario
      let snapBefore = aliveSet()
      inj.destroyFilter = parkedChildFilter(port)
      inj.refuseDestroy = 1
      let firstError = closeAttempt(f, 1)
      check firstError != nil
      let refused = lastRec("destroy-refused")
      check refused.seq >= 0
      check refused.live
      check refused.attempt == 1
      if refused.seq < 0: break scenario
      let root = rootUnder(refused.hwnd, port)
      check root != 0
      if root == 0: break scenario
      check refused.hwnd in aliveSet()
      check root in aliveSet()
      check port in aliveSet()
      check windowsAccountedOrAlive(groupOf(root))
      check subset(aliveSet(), snapBefore)
      # The retained failure is enumerable: the next pass retries exactly it.
      inj.refuseDestroy = 1
      let secondError = closeAttempt(f, 2)
      check secondError != nil
      check countOp("destroy-refused") == 2
      let again = lastRec("destroy-refused")
      check again.seq >= 0 and again.hwnd == refused.hwnd
      check again.live and again.attempt == 2
      check refused.hwnd in aliveSet()
      check root in aliveSet()
      check port in aliveSet()
      check subset(aliveSet(), snapBefore)
      check onlyLiveDestroyCalls()
      check noDoubleRelease()
      inj.refuseDestroy = 0
      let thirdError = closeAttempt(f, 3)
      check thirdError == nil
      check releasedEverywhere(f)
      check succeededInAttempt("destroy", refused.hwnd, 3)
      check allReleaseRules()

  test "11) direct dispose owns parked compound rows and is idempotent":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("11")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      scroll(port, SB_PAGEDOWN)
      settle(f)
      check parkedRoots(port).len >= 2
      # `dispose` is the cleanup owner; it must release every parked slot
      # without relying on an ancestor destroy. Ordinals 1 (dispose), 2
      # (idempotent dispose), 3 (host close) are unique.
      let snapBefore = aliveSet()
      let firstError = disposeAttempt(f, 1)
      check firstError == nil
      let afterFirst = recs.len
      check subset(aliveSet(), snapBefore)
      check aliveSet() == toHashSet(@[f.host])  # only the borrowed host survives
      check allReleaseRules()                   # every backend window accounted
      let secondError = disposeAttempt(f, 2)
      check secondError == nil
      if firstError == nil:
        check recs.len == afterFirst            # idempotent: no native call
      let hostError = closeAttempt(f, 3)
      check hostError == nil
      check releasedEverywhere(f)
      check allReleaseRules()

  test "12) the retiring owner destroys a shed child before its row root":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("12")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      let child = shedVisibleRowChild(f, port)
      check child != 0
      if child == 0: break scenario
      let rowRoot = parentOf(child)
      check rowRoot != 0 and parentOf(rowRoot) == port
      check alive(child) and alive(rowRoot)
      check IsWindowVisible(cast[HWND](child)) == 0   # hidden by the shed
      check IsWindowVisible(cast[HWND](rowRoot)) != 0 # its row is still current
      check recordsOf("destroy", child).len == 0      # owned, not released yet
      let snapBefore = aliveSet()
      inj.refuseDestroy = 1
      inj.destroyFilter = onlyWindow(child)
      let firstError = closeAttempt(f, 1)
      check firstError != nil
      check countOp("destroy-refused") == 1
      let refused = lastRec("destroy-refused")
      check refused.live and refused.hwnd == child and refused.attempt == 1
      let snapAfter = aliveSet()
      check subset(snapAfter, snapBefore)
      check child in snapAfter                  # the refused child survives
      check rowRoot in snapAfter                # ... and so does its ancestor
      check port in snapAfter
      check destroyCallsClean(1)
      check allReleaseRules()
      inj.refuseDestroy = 0
      let secondError = closeAttempt(f, 2)
      check secondError == nil
      check releasedEverywhere(f)
      check succeededInAttempt("destroy", child, 2)
      check allReleaseRules()

  test "13) restore releases parked slots and rebuilds the accepted tree":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("13")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      scroll(port, SB_PAGEDOWN)
      settle(f)
      check parkedRoots(port).len >= 2
      let revisionBefore = f.r.acceptedRevision
      let restoreError = restoreAttempt(f, 1)
      check restoreError == nil                 # a direct restore must converge
      check f.r.acceptedRevision == revisionBefore
      let rebuilt = viewports()
      check rebuilt.len == 1
      if rebuilt.len == 1:
        check aliveRows(rebuilt[0]).len == 5    # accepted frame rebuilt
      let snapRebuilt = aliveSet()
      check snapRebuilt.len > 0
      let closeError = closeAttempt(f, 2)
      check closeError == nil
      check subset(aliveSet(), snapRebuilt)
      check releasedEverywhere(f)
      check allReleaseRules()

  test "14) a refused restore keeps its group and cleanup releases the rest":
    let inj = Injection()
    let f = mounted(listRender, inj)
    beginCase("14")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 1
      if ports.len != 1: break scenario
      let port = ports[0]
      scroll(port, SB_PAGEDOWN)
      settle(f)
      let parked = parkedRoots(port)
      check parked.len >= 2
      if parked.len < 2: break scenario
      let revisionBefore = f.r.acceptedRevision
      let snapBefore = aliveSet()
      inj.refuseDestroy = 1
      inj.destroyFilter = parkedChildFilter(port)
      let restoreError = restoreAttempt(f, 1)
      check restoreError != nil
      check countOp("destroy-refused") == 1
      let refused = lastRec("destroy-refused")
      check refused.seq >= 0
      check refused.live and refused.attempt == 1
      if refused.seq < 0: break scenario
      let root = rootUnder(refused.hwnd, port)
      check root != 0 and root != refused.hwnd
      check root in parked
      if root == 0: break scenario
      let snapAfter = aliveSet()
      check subset(snapAfter, snapBefore)
      check refused.hwnd in snapAfter
      check root in snapAfter
      check port in snapAfter
      for other in parked:
        if other == root: continue
        check other notin snapAfter
        for kid in childrenOf(other): check kid notin snapAfter
      for kid in childrenOf(root):
        if kid != refused.hwnd: check kid notin snapAfter
      check destroyCallsClean(1)
      check f.r.acceptedRevision == revisionBefore
      check allReleaseRules()
      inj.refuseDestroy = 0
      let closeError = closeAttempt(f, 2)
      check closeError == nil
      check releasedEverywhere(f)
      check succeededInAttempt("destroy", refused.hwnd, 2)
      check allReleaseRules()

  test "15) a full pool makes the third owner release its departing rows":
    let inj = Injection()
    let f = mounted(threeViewportRender, inj, 480, 560)
    beginCase("15")
    block scenario:
      settle(f)
      let ports = viewports()
      check ports.len == 3
      if ports.len != 3: break scenario
      let pa = ports[0]
      let pb = ports[1]
      let pc = ports[2]
      for port in ports: check visibleRows(port).len == 5
      # Two owners fill the global pool; an owner never borrows another owner's
      # slot, so both pages park four slots each.
      scroll(pa, SB_PAGEDOWN)
      settle(f)
      check f.win.diagnostics.parkedRows == 4
      scroll(pb, SB_PAGEDOWN)
      settle(f)
      check f.win.diagnostics.parkedRows == 8
      check f.win.diagnostics.parkedRows <= MaxParkedRows
      check f.win.diagnostics.reusedRows == 0
      let slots = parkedRoots(pa) & parkedRoots(pb)
      check slots.len == 8
      let rowsC = rowRoots(pc)
      check rowsC.len == 5
      let snapBefore = aliveSet()
      for slot in slots: check slot in snapBefore   # parked before this turn
      for row in rowsC: check row in snapBefore     # current before this turn
      let turnStamp = turn + 1
      scroll(pc, SB_PAGEDOWN)                    # own slots: none -> fallback
      var turnError: ref CatchableError
      try: settle(f)
      except CatchableError as error: turnError = error
      check turnError == nil                     # the fallback owner must converge
      if turnError != nil: break scenario
      check f.win.diagnostics.parkedRows == 8    # bounded, still full
      check f.win.diagnostics.reusedRows == 0    # no cross-owner reuse
      for slot in slots: check slot in aliveSet()
      var kept = 0
      var released = 0
      var expectedGone: HashSet[uint64]
      for row in rowsC:
        if row in aliveSet():
          inc kept
        else:
          inc released
          for hwnd in groupOf(row):
            expectedGone.incl(hwnd)
            check hwnd notin aliveSet()
            check succeededInTurn("destroy", hwnd, turnStamp)
      check kept == 1
      check released == 4
      # The before/after snapshot: only the departing row groups disappeared.
      var unexpected = 0
      for hwnd in snapBefore:
        if hwnd notin aliveSet() and hwnd notin expectedGone: inc unexpected
      check unexpected == 0
      # No slot of another owner was re-keyed for the third list.
      check callsInTurn("setCtrlId", turnStamp) == 0
      check destroyCallsClean(0)
      let closeError = closeAttempt(f, 1)
      check closeError == nil
      check releasedEverywhere(f)
      check allReleaseRules()
