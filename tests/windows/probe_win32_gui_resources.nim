## T2 diagnostic input: fresh-process cold USER/GDI ledger (rev3).
## NOT part of any test runner, NOT an oracle, NOT an allocation-fence probe.
## One fresh process runs N = 3 identical cold cycles of the frozen list fixture.
## Each cycle records five stage snapshots of the process USER/GDI totals plus a
## transparent per-handle/epoch ledger taken inside the existing Win32Calls seams.
##
## Ledger semantics (fixed, auditable):
##   * `add` mints exactly one event id per record; a successful acquire reuses
##     that same id for its live entry, so every match id refers to a real,
##     earlier acquire record (verified by `verifyIntegrity` at the safe
##     boundary);
##   * every successful release/transfer resolves a live acquire and stores its
##     match id/epoch; no match => `unmatched`, several candidates => `ambiguous`
##     with no fabricated identity (a group-balance consume at most, never a
##     batch clear);
##   * a window-owned region is keyed by the window's own acquire id/epoch, and is
##     only credited as indirectly terminated by that window's successful
##     DestroyWindow or by a successful replacement on the same owner identity;
##   * raw events are written out in full after the close boundary (id, cycle,
##     stage, op, kind, handle, owner/owner2, owner acquire id/epoch, epoch,
##     raw return or N/A, failure lastError or N/A, match id/state).
##
## Fixed reading rules: exit 0 = status=diagnostic_completed only (never a budget
## PASS, never a product RED); growth across cycles => `unattributed_growth`; a
## first-cycle-only delta => `first_observed_delta` (not an OS attribution);
## own-API residuals, unmatched and ambiguous entries are evidence only.
## Overflow, an integrity miss, a missing stage or a missing executed path =>
## non-zero `status=diagnostic_incomplete`. The original `<= baseline + 2`
## criterion is untouched.
when not defined(windows):
  {.error: "Win32 GUI resource diagnostic requires Windows".}

import std/tables
import leaf/[core, widgets, backend_session, ui_thread, native_layout]
import leaf/backends/win32/[api, host, backend, calls]
import ../fixture_app

const
  Cycles = 3
  Stages = 5
  LedgerCapacity = 24576
  LiveCapacity = 8192
  RowHeight = 24.0
  ItemCount = 200
  ScrollRounds = 3
  ExpectedScrolls = 1 + ScrollRounds * 2
  ExpectedSettles = 1 + 1 + ScrollRounds * 2

type
  OpKind = enum
    opWindowCreate, opWindowDestroy, opClassRegister, opClassUnregister,
    opFontCreate, opFontDelete, opDcGet, opDcRelease, opThemeOpen, opThemeClose,
    opRegionCreate, opRegionTransfer, opRegionDelete, opTimerSet, opTimerKill,
    opImcGet, opImcRelease

  ObjKind = enum
    objNone, objWindow, objClass, objFont, objDc, objTheme, objRegion,
    objTimer, objImc

  MatchState = enum
    mNone, mMatched, mAmbiguous, mUnmatched

  LedgerRec = object
    id: uint32
    op: OpKind
    kind: ObjKind
    handle: uint64
    owner: uint64          ## parent / dc or imc window / transfer target window
    owner2: uint64         ## class name hash / timer id
    ownerId: uint32        ## stable owner-window acquire id (transfers)
    ownerEpoch: uint32
    ret: int64
    hasRet: bool
    failed: bool
    err: uint32
    hasErr: bool
    epoch: uint32
    matchId: uint32
    match: MatchState
    cycle: uint8
    stage: uint8

  LiveEntry = object
    id: uint32             ## same id as the acquire's raw record
    epoch: uint32
    kind: ObjKind
    handle: uint64
    owner: uint64
    owner2: uint64
    cycle: uint8
    live: bool

var
  ledger: array[LedgerCapacity, LedgerRec]
  ledgerLen = 0
  ledgerOverflow = false
  liveTable: array[LiveCapacity, LiveEntry]
  liveLen = 0
  liveOverflow = false
  nextEventId = 0'u32
  epochOfKind: array[ObjKind, uint32]
  curCycle = 0
  curStage = 0
  stageUser: array[Cycles * Stages, DWORD]
  stageGdi: array[Cycles * Stages, DWORD]
  stageTaken: array[Cycles * Stages, bool]

const
  StageNames = ["beforeHost", "afterHost", "afterFirstSettle", "afterScrolls",
    "afterDestroy"]
  OpNames = ["windowCreate", "windowDestroy", "classRegister",
    "classUnregister", "fontCreate", "fontDelete", "dcGet", "dcRelease",
    "themeOpen", "themeClose", "regionCreate", "regionTransfer",
    "regionDelete", "timerSet", "timerKill", "imcGet", "imcRelease"]
  KindNames = ["none", "window", "class", "font", "dc", "theme", "region",
    "timer", "imc"]
  MatchNames = ["none", "matched", "ambiguous", "unmatched"]

proc stageIndex(cycle, stage: int): int = cycle * Stages + stage

proc takeStage(cycle, stage: int) =
  let index = stageIndex(cycle, stage)
  stageUser[index] = GetGuiResources(GetCurrentProcess(), 1) # GR_USEROBJECTS
  stageGdi[index] = GetGuiResources(GetCurrentProcess(), 0)  # GR_GDIOBJECTS
  stageTaken[index] = true

proc isAcquire(op: OpKind): bool =
  op in {opWindowCreate, opClassRegister, opFontCreate, opDcGet, opThemeOpen,
    opRegionCreate, opTimerSet, opImcGet}

proc add(op: OpKind, kind: ObjKind, handle, owner, owner2: uint64, ret: int64,
         hasRet, failed: bool, err: uint32 = 0, hasErr = false,
         matchId = 0'u32, match = mNone, epoch = 0'u32, ownerId = 0'u32,
         ownerEpoch = 0'u32): uint32 {.raises: [], discardable.} =
  ## Mints exactly one event id for this record; 0 means capacity overflow.
  ## Pre-sized scalar writes only: no allocation, no output, no API call.
  if ledgerLen >= LedgerCapacity:
    ledgerOverflow = true
    return 0'u32
  inc nextEventId
  result = nextEventId
  ledger[ledgerLen] = LedgerRec(id: result, op: op, kind: kind, handle: handle,
    owner: owner, owner2: owner2, ownerId: ownerId, ownerEpoch: ownerEpoch,
    ret: ret, hasRet: hasRet, failed: failed, err: err, hasErr: hasErr,
    epoch: epoch, matchId: matchId, match: match, cycle: uint8(curCycle),
    stage: uint8(curStage))
  inc ledgerLen

proc addAcquire(op: OpKind, kind: ObjKind, handle, owner, owner2: uint64,
                ret: int64, hasRet, failed: bool, err: uint32 = 0,
                hasErr = false): uint32 {.raises: [], discardable.} =
  ## One stable acquire identity per successful create/borrow, sharing the id of
  ## its own raw record.
  if failed:
    result = add(op, kind, handle, owner, owner2, ret, hasRet, true, err, hasErr)
    return
  inc epochOfKind[kind]
  let epoch = epochOfKind[kind]
  let id = add(op, kind, handle, owner, owner2, ret, hasRet, false, epoch = epoch)
  if id == 0'u32: return 0'u32
  if liveLen >= LiveCapacity:
    liveOverflow = true
    return id
  liveTable[liveLen] = LiveEntry(id: id, epoch: epoch, kind: kind, handle: handle,
    owner: owner, owner2: owner2, cycle: uint8(curCycle), live: true)
  inc liveLen
  id

proc resolve(kind: ObjKind, handle, owner, owner2: uint64,
             ignoreHandle = false): tuple[index: int, id: uint32,
             epoch: uint32, state: MatchState] {.raises: [].} =
  ## Bounded backward scan of the fixed live table: no allocation. Several live
  ## candidates are reported ambiguous without a fabricated identity.
  var found = -1
  var count = 0
  var i = liveLen - 1
  while i >= 0:
    let e = liveTable[i]
    if e.live and e.kind == kind:
      var ok = true
      if not ignoreHandle and e.handle != handle: ok = false
      if owner != 0'u64 and e.owner != owner: ok = false
      if owner2 != 0'u64 and e.owner2 != owner2: ok = false
      if ok:
        if found < 0: found = i
        inc count
    dec i
  if count == 0: return (-1, 0'u32, 0'u32, mUnmatched)
  if count > 1: return (found, 0'u32, 0'u32, mAmbiguous)
  (found, liveTable[found].id, liveTable[found].epoch, mMatched)

proc nameHash(name: WidePtr): uint64 {.raises: [].} =
  ## FNV-1a over at most 128 WCHARs: identity prepared before the real call.
  if name == nil: return 0'u64
  let chars = cast[ptr UncheckedArray[WCHAR]](name)
  var hash = 1469598103934665603'u64
  var i = 0
  while i < 128:
    let ch = uint64(chars[i])
    if ch == 0: break
    hash = (hash xor ch) * 1099511628211'u64
    inc i
  hash

proc wrapCalls(base: Win32Calls): Win32Calls =
  result = base
  let registerClass = base.registerClass
  let unregisterClass = base.unregisterClass
  let createWindow = base.createWindow
  let destroyWindow = base.destroyWindow
  let createFont = base.createFont
  let deleteObject = base.deleteObject
  let getDC = base.getDC
  let releaseDC = base.releaseDC
  let openTheme = base.openTheme
  let closeTheme = base.closeTheme
  let rectRegion = base.rectRegion
  let setRegion = base.setRegion
  let setTimer = base.setTimer
  let killTimer = base.killTimer
  let immContext = base.immContext
  let immRelease = base.immRelease

  result.registerClass = proc(windowClass: ptr WNDCLASSEXW): ATOM {.
      closure, raises: [CatchableError].} =
    var instance = 0'u64
    var hash = 0'u64
    if windowClass != nil:
      instance = cast[uint64](windowClass.hInstance)
      hash = nameHash(windowClass.lpszClassName)
    try:
      result = registerClass(windowClass)
      addAcquire(opClassRegister, objClass, uint64(result), instance, hash,
        int64(result), true, result == 0,
        if result == 0: lastError() else: 0'u32, result == 0)
    except CatchableError as error:
      add(opClassRegister, objClass, 0, instance, hash, 0, false, true,
        lastError(), true)
      raise error

  result.unregisterClass = proc(name: WidePtr, instance: HINSTANCE): BOOL {.
      closure, raises: [CatchableError].} =
    let hash = nameHash(name)
    let owner = cast[uint64](instance)
    let live = resolve(objClass, 0, owner, hash, ignoreHandle = true)
    try:
      result = unregisterClass(name, instance)
      let failed = result == 0
      if not failed and live.state == mMatched:
        liveTable[live.index].live = false
      add(opClassUnregister, objClass, 0, owner, hash, int64(result), true,
        failed, if failed: lastError() else: 0'u32, failed,
        matchId = live.id, match = live.state, epoch = live.epoch)
    except CatchableError as error:
      add(opClassUnregister, objClass, 0, owner, hash, 0, false, true,
        lastError(), true, matchId = live.id, match = live.state,
        epoch = live.epoch)
      raise error

  result.createWindow = proc(exStyle: DWORD, className, title: WidePtr,
      style: DWORD, x, y, width, height: int32, parent: HWND, menu: HMENU,
      instance: HINSTANCE, param: pointer): HWND {.closure,
      raises: [CatchableError].} =
    try:
      result = createWindow(exStyle, className, title, style, x, y, width,
        height, parent, menu, instance, param)
      addAcquire(opWindowCreate, objWindow, cast[uint64](result),
        cast[uint64](parent), 0, 0, false, result == nil,
        if result == nil: lastError() else: 0'u32, result == nil)
    except CatchableError as error:
      add(opWindowCreate, objWindow, 0, cast[uint64](parent), 0, 0, false, true,
        lastError(), true)
      raise error

  result.destroyWindow = proc(window: HWND): BOOL {.closure,
      raises: [CatchableError].} =
    let live = resolve(objWindow, cast[uint64](window), 0, 0)
    try:
      result = destroyWindow(window)
      let failed = result == 0
      if not failed and live.state == mMatched:
        liveTable[live.index].live = false
      add(opWindowDestroy, objWindow, cast[uint64](window), 0, 0,
        int64(result), true, failed, if failed: lastError() else: 0'u32, failed,
        matchId = live.id, match = live.state, epoch = live.epoch)
    except CatchableError as error:
      add(opWindowDestroy, objWindow, cast[uint64](window), 0, 0, 0, false, true,
        lastError(), true, matchId = live.id, match = live.state,
        epoch = live.epoch)
      raise error

  result.createFont = proc(font: ptr LOGFONTW): HFONT {.closure,
      raises: [CatchableError].} =
    try:
      result = createFont(font)
      addAcquire(opFontCreate, objFont, cast[uint64](result), 0, 0, 0, false,
        result == nil, if result == nil: lastError() else: 0'u32,
        result == nil)
    except CatchableError as error:
      add(opFontCreate, objFont, 0, 0, 0, 0, false, true, lastError(), true)
      raise error

  result.deleteObject = proc(obj: HGDIOBJ): BOOL {.closure,
      raises: [CatchableError].} =
    let handle = cast[uint64](obj)
    let font = resolve(objFont, handle, 0, 0)
    let region = resolve(objRegion, handle, 0, 0)
    try:
      result = deleteObject(obj)
      let failed = result == 0
      if font.state == mMatched:
        if not failed: liveTable[font.index].live = false
        add(opFontDelete, objFont, handle, 0, 0, int64(result), true, failed,
          if failed: lastError() else: 0'u32, failed,
          matchId = font.id, match = font.state, epoch = font.epoch)
      elif region.state == mMatched:
        if not failed: liveTable[region.index].live = false
        add(opRegionDelete, objRegion, handle, 0, 0, int64(result), true, failed,
          if failed: lastError() else: 0'u32, failed,
          matchId = region.id, match = region.state, epoch = region.epoch)
      elif font.state == mAmbiguous or region.state == mAmbiguous:
        add(opFontDelete, objNone, handle, 0, 0, int64(result), true, failed,
          if failed: lastError() else: 0'u32, failed, match = mAmbiguous)
      else:
        add(opFontDelete, objNone, handle, 0, 0, int64(result), true, failed,
          if failed: lastError() else: 0'u32, failed, match = mUnmatched)
    except CatchableError as error:
      let known = if font.state == mMatched: objFont
                  elif region.state == mMatched: objRegion else: objNone
      let matchId = if font.state == mMatched: font.id
                    elif region.state == mMatched: region.id else: 0'u32
      let match = if font.state == mMatched: font.state
                  elif region.state == mMatched: region.state else: mUnmatched
      let epoch = if font.state == mMatched: font.epoch
                  elif region.state == mMatched: region.epoch else: 0'u32
      add(opFontDelete, known, handle, 0, 0, 0, false, true, lastError(), true,
        matchId = matchId, match = match, epoch = epoch)
      raise error

  result.getDC = proc(window: HWND): HDC {.closure, raises: [CatchableError].} =
    try:
      result = getDC(window)
      addAcquire(opDcGet, objDc, cast[uint64](result), cast[uint64](window), 0,
        0, false, result == nil, if result == nil: lastError() else: 0'u32,
        result == nil)
    except CatchableError as error:
      add(opDcGet, objDc, 0, cast[uint64](window), 0, 0, false, true,
        lastError(), true)
      raise error

  result.releaseDC = proc(window: HWND, dc: HDC): int32 {.closure,
      raises: [CatchableError].} =
    let live = resolve(objDc, cast[uint64](dc), cast[uint64](window), 0)
    try:
      result = releaseDC(window, dc)
      let failed = result == 0
      if not failed and (live.state == mMatched or live.state == mAmbiguous):
        # Group balance: exactly one borrow is consumed; ambiguity never claims
        # which individual lease ended.
        liveTable[live.index].live = false
      add(opDcRelease, objDc, cast[uint64](dc), cast[uint64](window), 0,
        int64(result), true, failed, if failed: lastError() else: 0'u32, failed,
        matchId = live.id, match = live.state, epoch = live.epoch)
    except CatchableError as error:
      add(opDcRelease, objDc, cast[uint64](dc), cast[uint64](window), 0, 0,
        false, true, lastError(), true, matchId = live.id, match = live.state,
        epoch = live.epoch)
      raise error

  result.openTheme = proc(window: HWND, classList: WidePtr, dpi: UINT): HTHEME {.
      closure, raises: [CatchableError].} =
    try:
      result = openTheme(window, classList, dpi)
      addAcquire(opThemeOpen, objTheme, cast[uint64](result),
        cast[uint64](window), 0, 0, false, result == nil,
        if result == nil: lastError() else: 0'u32, result == nil)
    except CatchableError as error:
      add(opThemeOpen, objTheme, 0, cast[uint64](window), 0, 0, false, true,
        lastError(), true)
      raise error

  result.closeTheme = proc(theme: HTHEME): int32 {.closure,
      raises: [CatchableError].} =
    let live = resolve(objTheme, cast[uint64](theme), 0, 0)
    try:
      result = closeTheme(theme)
      let failed = result < 0
      if not failed and (live.state == mMatched or live.state == mAmbiguous):
        # A shared handle can be open several times: one close consumes exactly
        # one borrow; the individual pairing is not observable.
        liveTable[live.index].live = false
      add(opThemeClose, objTheme, cast[uint64](theme), 0, 0, int64(result), true,
        failed, matchId = live.id, match = live.state, epoch = live.epoch)
    except CatchableError as error:
      add(opThemeClose, objTheme, cast[uint64](theme), 0, 0, 0, false, true,
        lastError(), true, matchId = live.id, match = live.state,
        epoch = live.epoch)
      raise error

  result.rectRegion = proc(left, top, right, bottom: int32): HRGN {.closure,
      raises: [CatchableError].} =
    try:
      result = rectRegion(left, top, right, bottom)
      addAcquire(opRegionCreate, objRegion, cast[uint64](result), 0, 0, 0, false,
        result == nil, if result == nil: lastError() else: 0'u32,
        result == nil)
    except CatchableError as error:
      add(opRegionCreate, objRegion, 0, 0, 0, 0, false, true, lastError(), true)
      raise error

  result.setRegion = proc(window: HWND, region: HRGN, redraw: BOOL): int32 {.
      closure, raises: [CatchableError].} =
    let live = resolve(objRegion, cast[uint64](region), 0, 0)
    let ownerLive = resolve(objWindow, cast[uint64](window), 0, 0)
    try:
      result = setRegion(window, region, redraw)
      let failed = result == 0
      if not failed and live.state == mMatched:
        # Ownership moves to the window; it is no longer caller-owned.
        liveTable[live.index].live = false
      add(opRegionTransfer, objRegion, cast[uint64](region),
        cast[uint64](window), 0, int64(result), true, failed,
        if failed: lastError() else: 0'u32, failed, matchId = live.id,
        match = live.state, epoch = live.epoch,
        ownerId = (if ownerLive.state == mMatched: ownerLive.id else: 0'u32),
        ownerEpoch = (if ownerLive.state == mMatched: ownerLive.epoch else: 0'u32))
    except CatchableError as error:
      add(opRegionTransfer, objRegion, cast[uint64](region),
        cast[uint64](window), 0, 0, false, true, lastError(), true,
        matchId = live.id, match = live.state, epoch = live.epoch)
      raise error

  result.setTimer = proc(window: HWND, timer: UINT_PTR, interval: UINT,
      callback: TIMERPROC): UINT_PTR {.closure, raises: [CatchableError].} =
    let existing = resolve(objTimer, uint64(timer), cast[uint64](window), 0)
    try:
      result = setTimer(window, timer, interval, callback)
      let failed = result == 0
      if not failed:
        if existing.state == mMatched:
          # Same (window, id): a reset/replacement, not a new outstanding owner.
          add(opTimerSet, objTimer, uint64(result), cast[uint64](window),
            uint64(timer), int64(result), true, false, 0, false,
            matchId = existing.id, match = mMatched, epoch = existing.epoch)
        else:
          addAcquire(opTimerSet, objTimer, uint64(result), cast[uint64](window),
            uint64(timer), int64(result), true, false)
      else:
        add(opTimerSet, objTimer, 0, cast[uint64](window), uint64(timer), 0,
          false, true, lastError(), true)
    except CatchableError as error:
      add(opTimerSet, objTimer, 0, cast[uint64](window), uint64(timer), 0, false,
        true, lastError(), true)
      raise error

  result.killTimer = proc(window: HWND, timer: UINT_PTR): BOOL {.closure,
      raises: [CatchableError].} =
    let live = resolve(objTimer, uint64(timer), cast[uint64](window), 0)
    try:
      result = killTimer(window, timer)
      let failed = result == 0
      if not failed and live.state == mMatched:
        liveTable[live.index].live = false
      add(opTimerKill, objTimer, uint64(timer), cast[uint64](window), 0,
        int64(result), true, failed, if failed: lastError() else: 0'u32, failed,
        matchId = live.id, match = live.state, epoch = live.epoch)
    except CatchableError as error:
      add(opTimerKill, objTimer, uint64(timer), cast[uint64](window), 0, 0, false,
        true, lastError(), true, matchId = live.id, match = live.state,
        epoch = live.epoch)
      raise error

  result.immContext = proc(window: HWND): HIMC {.closure,
      raises: [CatchableError].} =
    try:
      result = immContext(window)
      addAcquire(opImcGet, objImc, cast[uint64](result), cast[uint64](window), 0,
        0, false, result == nil, if result == nil: lastError() else: 0'u32,
        result == nil)
    except CatchableError as error:
      add(opImcGet, objImc, 0, cast[uint64](window), 0, 0, false, true,
        lastError(), true)
      raise error

  result.immRelease = proc(window: HWND, context: HIMC): BOOL {.closure,
      raises: [CatchableError].} =
    let live = resolve(objImc, cast[uint64](context), cast[uint64](window), 0)
    try:
      result = immRelease(window, context)
      let failed = result == 0
      if not failed and (live.state == mMatched or live.state == mAmbiguous):
        liveTable[live.index].live = false
      add(opImcRelease, objImc, cast[uint64](context), cast[uint64](window), 0,
        int64(result), true, failed, if failed: lastError() else: 0'u32, failed,
        matchId = live.id, match = live.state, epoch = live.epoch)
    except CatchableError as error:
      add(opImcRelease, objImc, cast[uint64](context), cast[uint64](window), 0, 0,
        false, true, lastError(), true, matchId = live.id, match = live.state,
        epoch = live.epoch)
      raise error

# --- frozen cold fixture, copied minimally (the test file is not imported) ----

proc compoundRow(index: int): Node =
  row(@[
    text("item " & $index, key = "label"),
    button("act " & $index, key = "button"),
    checkbox("chk " & $index, false, key = "check")], key = "row")

proc listRender(): Node =
  var keys: seq[string]
  for index in 0 ..< ItemCount: keys.add($index)
  column(@[virtualList("list", keys, proc(index: int): Node = compoundRow(index),
    rowHeight = RowHeight, overscan = 0,
    styles = style({"height": "120"}))], key = "root")

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

proc viewports(h: Win32Host): seq[HWND] =
  for window in descendants(h.windowHandle):
    if (styleOf(window) and WS_VSCROLL) != 0: result.add(window)

proc scrollTo(port: HWND, code: int) =
  discard SendMessageW(port, WM_VSCROLL, WPARAM(code), 0)

type CycleFacts = object
  complete: bool
  reason: string
  pumpOk, closeComplete: bool
  cleanupError: ref CatchableError
  ports, firstRows, scrolls, settles, scrollTicksDelta, reusedDelta: int
  creates, liveRows, parkedRows, reusedRows, setTexts, liveWindows: int
  liveFonts, liveSubclasses, liveRoots: int
  hostLiveWindows, hostLiveRoots: int
  revision: uint64

proc runCycle(index: int, calls: Win32Calls, hostOut: var Win32Host):
    CycleFacts =
  curCycle = index
  var facts: CycleFacts
  facts.reason = ""
  # beforeHost is sampled before the managed Runtime exists (no warm-up first).
  curStage = 0
  takeStage(index, 0)
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(
    fixtureApplication(listRender, "T2 gui resources", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("T2 gui resources", DipSize(width: 480, height: 320), calls)
  hostOut = h
  curStage = 1
  takeStage(index, 1)                       # afterHost, before backend/attach
  h.setStartupScope(proc(): bool =
    activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win = newWin32Backend(h, calls)
  let session = win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  h.setSafeTick(proc() =
    # Live product facts are captured here: the host release runs inside pump,
    # so anything read after pump() is a closed view, never a "before close" one.
    let ticksBefore = win.diagnostics.scrollTicks
    let reusedBefore = win.diagnostics.reusedRows
    win.safeListTurn()                      # first settle (one safe turn)
    inc facts.settles
    facts.firstRows = win.diagnostics.liveRows
    curStage = 2
    takeStage(index, 2)                     # afterFirstSettle
    let ports = viewports(h)
    facts.ports = ports.len
    if ports.len == 1:
      let port = ports[0]
      scrollTo(port, SB_PAGEDOWN)           # cold hand-off
      inc facts.scrolls
      win.safeListTurn()
      inc facts.settles
      for round in 0 ..< ScrollRounds:
        scrollTo(port, SB_PAGEDOWN)
        inc facts.scrolls
        win.safeListTurn()
        inc facts.settles
        scrollTo(port, SB_TOP)
        inc facts.scrolls
        win.safeListTurn()
        inc facts.settles
    let diag = win.diagnostics               # live, inside the turn
    let hostDiag = h.diagnostics
    facts.creates = int(diag.creates)
    facts.liveRows = diag.liveRows
    facts.parkedRows = diag.parkedRows
    facts.reusedRows = diag.reusedRows
    facts.setTexts = int(diag.setTexts)
    facts.liveWindows = diag.liveWindows
    facts.liveFonts = diag.liveFonts
    facts.liveSubclasses = diag.liveSubclasses
    facts.liveRoots = diag.liveRoots
    facts.hostLiveWindows = hostDiag.liveWindows
    facts.hostLiveRoots = hostDiag.liveRoots
    facts.scrollTicksDelta = diag.scrollTicks - ticksBefore
    facts.reusedDelta = diag.reusedRows - reusedBefore
    facts.revision = runtime.acceptedRevision
    curStage = 3
    takeStage(index, 3)                     # afterCold + warm scrolls (live)
    h.requestClose())                       # explicit close phase starts here
  facts.pumpOk = h.pump() == 0
  facts.closeComplete = h.resourcesReleasedInternal()
  curStage = 4
  takeStage(index, 4)                       # afterDestroy: OS totals only
  result = facts
  try: h.destroyHost()                      # idempotent confirmation, no retry
  except CatchableError as error:
    result.cleanupError = error             # keep the real ref for the report
    result.reason = "idempotent destroyHost raised: " & $error.name
    result.complete = false
    return result
  if not result.pumpOk:
    result.reason = "pump failed"
  elif not result.closeComplete:
    result.reason = "close incomplete"
  elif result.ports != 1:
    result.reason = "expected exactly one viewport, got " & $result.ports
  elif result.firstRows != 5:
    result.reason = "first settle rows=" & $result.firstRows
  elif result.scrolls != ExpectedScrolls:
    result.reason = "executed scrolls=" & $result.scrolls
  elif result.settles != ExpectedSettles:
    result.reason = "executed settles=" & $result.settles
  elif result.scrollTicksDelta < 1:
    result.reason = "no scroll fact published"
  elif result.reusedDelta <= 0:
    result.reason = "warm reuse not observed"
  for stage in 0 ..< Stages:
    if not stageTaken[stageIndex(index, stage)] and result.reason.len == 0:
      result.reason = "missing stage " & StageNames[stage]
  result.complete = result.reason.len == 0

# --- analysis (after all cycles; allocation and printing allowed here) -------

type
  Tally = object
    acquired, released, transferred, unmatched, ambiguous, resets: int
    indirectOk, indirectUnverified: int
    liveUnresolved: int

  RegionState = enum rsLive, rsWindowOwned, rsReleased, rsIndirect

proc countRelease(t: var Tally, rec: LedgerRec) =
  case rec.match
  of mMatched: inc t.released
  of mAmbiguous: inc t.ambiguous
  else: inc t.unmatched

proc summarize(): array[Cycles, array[ObjKind, Tally]] =
  ## Everything below is derived from recorded match ids and owner identities,
  ## never from call counts.
  var regionState: Table[uint32, RegionState]
  var regionCycle: Table[uint32, int]
  var windowRegions: Table[uint32, uint32]  # window acquire id -> region id
  for i in 0 ..< ledgerLen:
    let rec = ledger[i]
    let c = int(rec.cycle)
    if c >= Cycles: continue
    if rec.failed:
      case rec.match
      of mUnmatched: inc result[c][rec.kind].unmatched
      of mAmbiguous: inc result[c][rec.kind].ambiguous
      else: discard
      continue
    case rec.op
    of opWindowCreate, opFontCreate, opDcGet, opThemeOpen, opRegionCreate,
        opClassRegister, opImcGet:
      inc result[c][rec.kind].acquired
      if rec.op == opRegionCreate:
        regionState[rec.id] = rsLive
        regionCycle[rec.id] = c
    of opTimerSet:
      if rec.match == mMatched: inc result[c][objTimer].resets
      else: inc result[c][objTimer].acquired
    of opWindowDestroy:
      if rec.match == mMatched:
        inc result[c][objWindow].released
        if windowRegions.hasKey(rec.matchId):
          let region = windowRegions[rec.matchId]
          if regionState.getOrDefault(region) == rsWindowOwned:
            regionState[region] = rsIndirect
            inc result[regionCycle.getOrDefault(region, c)][objRegion].indirectOk
          windowRegions.del(rec.matchId)
      elif rec.match == mAmbiguous:
        inc result[c][objWindow].ambiguous
      else:
        inc result[c][objWindow].unmatched
      # An unmatched/ambiguous destroy never credits a region termination.
    of opFontDelete, opDcRelease, opThemeClose, opClassUnregister, opImcRelease,
        opTimerKill:
      countRelease(result[c][rec.kind], rec)
    of opRegionDelete:
      if rec.kind != objRegion:
        inc result[c][objRegion].unmatched
      elif rec.match == mMatched:
        if regionState.getOrDefault(rec.matchId) == rsWindowOwned:
          # Deleting a window-owned region: own-API anomaly, not a release.
          inc result[c][objRegion].unmatched
        else:
          regionState[rec.matchId] = rsReleased
          inc result[c][objRegion].released
      else:
        countRelease(result[c][objRegion], rec)
    of opRegionTransfer:
      if rec.match == mMatched:
        inc result[c][objRegion].transferred
        if rec.ownerId == 0'u32:
          # Owner identity unresolved: not caller-owned any more, but the
          # indirect termination cannot be attributed.
          regionState[rec.matchId] = rsIndirect
          inc result[regionCycle.getOrDefault(rec.matchId, c)][objRegion].indirectUnverified
        else:
          if windowRegions.hasKey(rec.ownerId) and
              windowRegions[rec.ownerId] != rec.matchId:
            let previous = windowRegions[rec.ownerId]
            if regionState.getOrDefault(previous) == rsWindowOwned:
              regionState[previous] = rsIndirect   # documented replacement
              inc result[regionCycle.getOrDefault(previous, c)][objRegion].indirectOk
          windowRegions[rec.ownerId] = rec.matchId
          regionState[rec.matchId] = rsWindowOwned
      else:
        countRelease(result[c][objRegion], rec)
  for i in 0 ..< liveLen:
    let entry = liveTable[i]
    if entry.live and int(entry.cycle) < Cycles:
      inc result[int(entry.cycle)][entry.kind].liveUnresolved
  for _, region in windowRegions:
    if regionState.getOrDefault(region) == rsWindowOwned:
      inc result[regionCycle.getOrDefault(region, 0)][objRegion].indirectUnverified

proc verifyIntegrity(): string =
  ## Referential integrity over the real recorded arrays. Any miss becomes a
  ## diagnostic_incomplete reason; no matched/indirect credit is printed then.
  for i in 0 ..< ledgerLen:
    let rec = ledger[i]
    if rec.id != uint32(i + 1):
      return "event id " & $rec.id & " at index " & $i & " is not sequential"
    if rec.match == mMatched:
      if rec.matchId == 0'u32 or int(rec.matchId) >= int(rec.id):
        return "event " & $rec.id & " has a matched id that is not earlier"
      let acquire = ledger[int(rec.matchId) - 1]
      if acquire.failed or not isAcquire(acquire.op):
        return "event " & $rec.id & " matched a non-acquire record"
      if acquire.kind != rec.kind:
        return "event " & $rec.id & " matched a different kind"
      if rec.op != opClassUnregister and acquire.handle != rec.handle:
        return "event " & $rec.id & " matched a different handle"
      if rec.epoch != 0'u32 and acquire.epoch != rec.epoch:
        return "event " & $rec.id & " matched a different epoch"
    if rec.match == mAmbiguous and rec.matchId != 0'u32:
      return "event " & $rec.id & " claims an id for an ambiguous match"
    if rec.ownerId != 0'u32:
      if int(rec.ownerId) >= int(rec.id):
        return "event " & $rec.id & " owner id is not earlier"
      let owner = ledger[int(rec.ownerId) - 1]
      if owner.failed or owner.op != opWindowCreate:
        return "event " & $rec.id & " owner is not a successful window acquire"
      if owner.epoch != rec.ownerEpoch:
        return "event " & $rec.id & " owner epoch mismatch"
  for i in 0 ..< liveLen:
    let entry = liveTable[i]
    if not entry.live: continue
    if entry.id == 0'u32 or int(entry.id) > ledgerLen:
      return "live entry id out of range"
    let acquire = ledger[int(entry.id) - 1]
    if acquire.id != entry.id or acquire.failed or not isAcquire(acquire.op):
      return "live entry " & $entry.id & " is not its own acquire record"
    if acquire.kind != entry.kind or acquire.handle != entry.handle:
      return "live entry " & $entry.id & " kind/handle mismatch"
    if acquire.epoch != entry.epoch or acquire.cycle != entry.cycle:
      return "live entry " & $entry.id & " epoch/cycle mismatch"
  for index in 0 ..< Cycles:
    for stage in 0 ..< Stages:
      if not stageTaken[stageIndex(index, stage)]:
        return "stage " & $index & "/" & StageNames[stage] & " not taken"
  ""

proc main(): int =
  let base = systemWin32Calls()
  let calls = wrapCalls(base)
  var facts: array[Cycles, CycleFacts]
  var secondaryErrors: array[Cycles, ref CatchableError]
  var completed = 0
  var incomplete = ""
  var originalError: ref CatchableError = nil
  var originalCycle = -1
  for index in 0 ..< Cycles:
    if incomplete.len != 0: break
    var host: Win32Host = nil
    try:
      facts[index] = runCycle(index, calls, host)
      if facts[index].complete:
        inc completed
      else:
        incomplete = "cycle" & $index & ": " & facts[index].reason
    except CatchableError as error:
      originalError = error       # keep the reference; format it later
      originalCycle = index
      incomplete = "cycle" & $index & " raised " & $error.name
      if host != nil:
        try: host.destroyHost()   # one bounded cleanup attempt, no retry loop
        except CatchableError as secondary: secondaryErrors[index] = secondary

  # Safe boundary: full raw event trace first, then the derived summary.
  echo "probe_win32_gui_resources cycles=", Cycles, " item_count=", ItemCount,
    " row_height=", RowHeight, " viewport=120 host=480x320",
    " events=", ledgerLen, " ledger_overflow=", ledgerOverflow,
    " live_overflow=", liveOverflow
  for i in 0 ..< ledgerLen:
    let rec = ledger[i]
    var line = "event id=" & $rec.id & " cycle=" & $rec.cycle & " stage=" &
      $rec.stage & " op=" & OpNames[ord(rec.op)] & " kind=" &
      KindNames[ord(rec.kind)] & " handle=" & $rec.handle & " owner=" &
      $rec.owner & " owner2=" & $rec.owner2
    if rec.ownerId != 0'u32:
      line.add(" owner_id=" & $rec.ownerId & " owner_epoch=" & $rec.ownerEpoch)
    else:
      line.add(" owner_id=N/A")
    if rec.epoch != 0'u32: line.add(" epoch=" & $rec.epoch)
    else: line.add(" epoch=N/A")
    if rec.hasRet: line.add(" ret=" & $rec.ret)
    else: line.add(" ret=N/A")
    line.add(" failed=" & $rec.failed)
    if rec.hasErr: line.add(" err=" & $rec.err)
    else: line.add(" err=N/A")
    if rec.match != mNone: line.add(" match=" & MatchNames[ord(rec.match)])
    if rec.matchId != 0'u32: line.add(" match_id=" & $rec.matchId)
    echo line
  for i in 0 ..< liveLen:
    let entry = liveTable[i]
    if entry.live:
      echo "live_unresolved id=", entry.id, " kind=", KindNames[ord(entry.kind)],
        " handle=", entry.handle, " owner=", entry.owner, " owner2=",
        entry.owner2, " epoch=", entry.epoch, " cycle=", entry.cycle
  for index in 0 ..< Cycles:
    for stage in 0 ..< Stages:
      let i = stageIndex(index, stage)
      if stageTaken[i]:
        echo "cycle", index, " stage=", StageNames[stage], " taken=true user=",
          stageUser[i], " gdi=", stageGdi[i]
      else:
        echo "cycle", index, " stage=", StageNames[stage], " taken=false"
    if facts[index].complete:
      echo "cycle", index, " facts complete=true ports=", facts[index].ports,
        " first_rows=", facts[index].firstRows,
        " scrolls=", facts[index].scrolls, " settles=", facts[index].settles,
        " scroll_ticks_delta=", facts[index].scrollTicksDelta,
        " reused_delta=", facts[index].reusedDelta,
        " creates=", facts[index].creates,
        " live_rows=", facts[index].liveRows,
        " parked=", facts[index].parkedRows,
        " reused=", facts[index].reusedRows,
        " set_texts=", facts[index].setTexts,
        " live_windows=", facts[index].liveWindows,
        " live_fonts=", facts[index].liveFonts,
        " live_subclasses=", facts[index].liveSubclasses,
        " live_roots=", facts[index].liveRoots,
        " host_live_windows=", facts[index].hostLiveWindows,
        " host_live_roots=", facts[index].hostLiveRoots,
        " revision=", facts[index].revision,
        " close_complete=", facts[index].closeComplete
    else:
      echo "cycle", index, " facts complete=false reason=", facts[index].reason
    if facts[index].cleanupError != nil:
      echo "cycle", index, " cleanup_error type=", facts[index].cleanupError.name,
        " msg=", facts[index].cleanupError.msg
    if secondaryErrors[index] != nil:
      echo "cycle", index, " cleanup_secondary type=",
        secondaryErrors[index].name, " msg=", secondaryErrors[index].msg

  let integrity = verifyIntegrity()
  if integrity.len != 0:
    echo "integrity=failed reason=", integrity
  else:
    echo "integrity=ok"

  let ready = completed == Cycles and not ledgerOverflow and not liveOverflow and
    integrity.len == 0
  if ready:
    let tallies = summarize()
    var residualTotal = 0
    for index in 0 ..< Cycles:
      for kind in [objWindow, objClass, objFont, objDc, objTheme, objRegion,
          objTimer, objImc]:
        let t = tallies[index][kind]
        residualTotal += t.liveUnresolved
        echo "cycle", index, " ledger kind=", KindNames[ord(kind)], " acquired=",
          t.acquired, " released=", t.released, " transferred=", t.transferred,
          " resets=", t.resets, " unmatched=", t.unmatched, " ambiguous=",
          t.ambiguous, " indirect_ok=", t.indirectOk, " indirect_unverified=",
          t.indirectUnverified, " live_unresolved=", t.liveUnresolved
    var grew = false
    for index in 1 ..< Cycles:
      if stageUser[stageIndex(index, 4)] > stageUser[stageIndex(index - 1, 4)] or
          stageGdi[stageIndex(index, 4)] > stageGdi[stageIndex(index - 1, 4)]:
        grew = true
    let firstUser = int64(stageUser[stageIndex(0, 4)]) -
      int64(stageUser[stageIndex(0, 0)])
    let firstGdi = int64(stageGdi[stageIndex(0, 4)]) -
      int64(stageGdi[stageIndex(0, 0)])
    echo "after_destroy delta cycle1 user=", firstUser, " gdi=", firstGdi
    if grew: echo "classification=unattributed_growth"
    elif firstUser > 0 or firstGdi > 0:
      echo "classification=first_observed_delta (cycle1 only; cause unassigned,",
        " not an OS attribution)"
    else: echo "classification=no_growth_observed (diagnostic only)"
    if residualTotal > 0:
      echo "own_api_residual live_unresolved_total=", residualTotal,
        " (evidence only; a formal requirement RED is still required)"
  else:
    echo "classification=unverified (required cycles incomplete, integrity",
      " failure or ledger overflow)"

  if not ready:
    var reason = incomplete
    if reason.len == 0 and ledgerOverflow: reason = "ledger capacity overflow"
    if reason.len == 0 and liveOverflow: reason = "live table capacity overflow"
    if reason.len == 0 and integrity.len != 0: reason = integrity
    if originalError != nil:
      echo "cycle", originalCycle, " error type=", originalError.name,
        " msg=", originalError.msg
    echo "probe_win32_gui_resources status=diagnostic_incomplete reason=", reason
    return 3
  echo "probe_win32_gui_resources status=diagnostic_completed"
  0

when isMainModule:
  quit(main())
