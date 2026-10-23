## T2 diagnostic: the real Leaf list measurement path, one cold cycle, with
## scalar receipts for six existing Win32Calls seams. NOT a test runner entry,
## NOT an oracle, no owner/matching/classification table.
##
## Only hypothesis H is under observation: does the extra GDI increment first
## appear inside the real width-constrained DrawTextW measurement interval and
## stay after the neighbouring DC is restored and released? The probe records raw
## order only; the verdict is an offline reading by the coordinator.
##
## Wrapper discipline: save thread LastError -> sample -> restore TLS -> forward
## the real call unchanged; on return capture result/out/LastError -> post-sample
## -> restore the real LastError. No allocation, output or exception change inside
## a wrapper; a full receipt array only marks the run incomplete while the real
## API is still forwarded. Formatting happens after the close boundary.
when not defined(windows):
  {.error: "Leaf measure resource diagnostic requires Windows".}

import leaf/[core, widgets, backend_session, ui_thread, native_layout]
import leaf/backends/win32/[api, host, backend, calls]
import ../fixture_app

const
  Stages = 5
  StageNames = ["beforeHost", "afterHost", "afterFirstSettle", "afterScrolls",
    "afterClose"]
  ReceiptCapacity = 512
  TextPrefixLen = 16
  RowHeight = 24.0
  ItemCount = 200
  ScrollRounds = 3
  ExpectedScrolls = 1 + ScrollRounds * 2
  ExpectedSettles = 1 + 1 + ScrollRounds * 2
  ExpectedScrollTicks = 24
  ExpectedReused = 24

type
  OpKind = enum
    opCreateFont, opDeleteObject, opGetDC, opSelectObject, opDrawText,
    opReleaseDC

  Receipt = object
    seqIn, seqOut: uint32
    depth: uint16
    op: OpKind
    hasRet, failed, exceptionMark, hasPostSample: bool
    hwndOrDc: uint64          ## HWND for getDC/releaseDC, HDC otherwise
    objOrText: uint64         ## HGDIOBJ / HFONT / text pointer
    argCount: int32           ## DrawText character count
    argFlags: uint32          ## DrawText flags
    ret: int64                ## raw BOOL / int / int-return
    retHandle: uint64         ## returned HDC / HGDIOBJ / HFONT
    inLeft, inTop, inRight, inBottom: int32
    outLeft, outTop, outRight, outBottom: int32
    userBefore, gdiBefore, userAfter, gdiAfter: uint32
    errUserBefore, errGdiBefore, errUserAfter, errGdiAfter: uint32
    callErr: uint32
    hasCallErr: bool
    textPrefix: array[TextPrefixLen, uint16]
    textStored: int32
    excRef: ref CatchableError

var
  receipts: array[ReceiptCapacity, Receipt]
  receiptLen = 0
  receiptOverflow = false
  nextSeq = 0'u32
  depth = 0
  curStage = 0
  stageUser: array[Stages, uint32]
  stageGdi: array[Stages, uint32]
  stageUserErr: array[Stages, uint32]
  stageGdiErr: array[Stages, uint32]
  stageTaken: array[Stages, bool]
  stageSeq: array[Stages, uint32]
  sampleFailed = false
  sampleFailedCounter = 0'i32
  sampleFailedErr = 0'u32

proc sampleNow(user, gdi, userErr, gdiErr: var uint32) {.raises: [].} =
  ## Each counter independently: clear, read, capture the immediate error.
  setLastError(0)
  user = GetGuiResources(GetCurrentProcess(), 1)   # GR_USEROBJECTS
  userErr = lastError()
  setLastError(0)
  gdi = GetGuiResources(GetCurrentProcess(), 0)    # GR_GDIOBJECTS
  gdiErr = lastError()
  if user == 0 and userErr != 0:
    sampleFailed = true
    if sampleFailedErr == 0'u32:
      sampleFailedCounter = 1
      sampleFailedErr = userErr
  if gdi == 0 and gdiErr != 0:
    sampleFailed = true
    if sampleFailedErr == 0'u32:
      sampleFailedCounter = 2
      sampleFailedErr = gdiErr

proc takeStage(stage: int) =
  inc nextSeq
  stageSeq[stage] = nextSeq
  var rec: Receipt
  sampleNow(rec.userBefore, rec.gdiBefore, rec.errUserBefore, rec.errGdiBefore)
  stageUser[stage] = rec.userBefore
  stageGdi[stage] = rec.gdiBefore
  stageUserErr[stage] = rec.errUserBefore
  stageGdiErr[stage] = rec.errGdiBefore
  stageTaken[stage] = true
  curStage = stage

proc beginReceipt(op: OpKind, hwndOrDc, objOrText: uint64, count: int32,
                  flags: uint32, text: WidePtr): int {.raises: [].} =
  var rec: Receipt
  rec.op = op
  rec.hwndOrDc = hwndOrDc
  rec.objOrText = objOrText
  rec.argCount = count
  rec.argFlags = flags
  rec.seqIn = nextSeq
  inc nextSeq
  rec.depth = uint16(depth)
  inc depth
  if text != nil and count > 0:
    let chars = cast[ptr UncheckedArray[WCHAR]](text)
    let n = min(int(count), TextPrefixLen)
    for i in 0 ..< n: rec.textPrefix[i] = chars[i]
    rec.textStored = int32(n)
  sampleNow(rec.userBefore, rec.gdiBefore, rec.errUserBefore, rec.errGdiBefore)
  if receiptLen >= ReceiptCapacity:
    receiptOverflow = true
    return -1
  receipts[receiptLen] = rec
  result = receiptLen
  inc receiptLen

proc endReceipt(idx: int, ret: int64, retHandle: uint64, hasRet: bool,
                rect: ptr RECT, callErr: uint32, failed: bool) {.raises: [].} =
  dec depth
  inc nextSeq                       # the end marker always advances
  let outSeq = nextSeq
  if idx < 0: return                # overflow: real API already forwarded
  var rec = receipts[idx]
  rec.seqOut = outSeq
  rec.hasRet = hasRet
  rec.ret = ret
  rec.retHandle = retHandle
  if rect != nil:
    rec.outLeft = rect.left
    rec.outTop = rect.top
    rec.outRight = rect.right
    rec.outBottom = rect.bottom
  rec.callErr = callErr
  rec.hasCallErr = true
  rec.failed = failed
  rec.hasPostSample = true
  sampleNow(rec.userAfter, rec.gdiAfter, rec.errUserAfter, rec.errGdiAfter)
  receipts[idx] = rec

proc endReceiptException(idx: int, error: ref CatchableError,
                         callErr: uint32) {.raises: [].} =
  ## No Native return value exists on this path: no result and no post sample.
  dec depth
  inc nextSeq                       # the end marker always advances
  let outSeq = nextSeq
  if idx < 0: return
  var rec = receipts[idx]
  rec.seqOut = outSeq
  rec.hasPostSample = false
  rec.exceptionMark = true
  rec.excRef = error
  rec.callErr = callErr
  rec.hasCallErr = true
  receipts[idx] = rec

proc wrapCalls(base: Win32Calls): Win32Calls =
  result = base
  let createFont = base.createFont
  let deleteObject = base.deleteObject
  let getDC = base.getDC
  let releaseDC = base.releaseDC
  let selectObject = base.selectObject
  let drawText = base.drawText

  result.createFont = proc(font: ptr LOGFONTW): HFONT {.closure,
      raises: [CatchableError].} =
    let tls = lastError()
    let idx = beginReceipt(opCreateFont, 0, cast[uint64](font), 0, 0, nil)
    setLastError(tls)
    try:
      result = createFont(font)
      let after = lastError()
      endReceipt(idx, if result == nil: 0 else: 1, cast[uint64](result), true,
        nil, after, result == nil)
      setLastError(after)
    except CatchableError as error:
      let after = lastError()
      endReceiptException(idx, error, after)
      setLastError(after)
      raise error

  result.deleteObject = proc(obj: HGDIOBJ): BOOL {.closure,
      raises: [CatchableError].} =
    let tls = lastError()
    let idx = beginReceipt(opDeleteObject, 0, cast[uint64](obj), 0, 0, nil)
    setLastError(tls)
    try:
      result = deleteObject(obj)
      let after = lastError()
      endReceipt(idx, int64(result), 0, true, nil, after, result == 0)
      setLastError(after)
    except CatchableError as error:
      let after = lastError()
      endReceiptException(idx, error, after)
      setLastError(after)
      raise error

  result.getDC = proc(window: HWND): HDC {.closure, raises: [CatchableError].} =
    let tls = lastError()
    let idx = beginReceipt(opGetDC, cast[uint64](window), 0, 0, 0, nil)
    setLastError(tls)
    try:
      result = getDC(window)
      let after = lastError()
      endReceipt(idx, if result == nil: 0 else: 1, cast[uint64](result), true,
        nil, after, result == nil)
      setLastError(after)
    except CatchableError as error:
      let after = lastError()
      endReceiptException(idx, error, after)
      setLastError(after)
      raise error

  result.releaseDC = proc(window: HWND, dc: HDC): int32 {.closure,
      raises: [CatchableError].} =
    let tls = lastError()
    let idx = beginReceipt(opReleaseDC, cast[uint64](window), cast[uint64](dc),
      0, 0, nil)
    setLastError(tls)
    try:
      result = releaseDC(window, dc)
      let after = lastError()
      endReceipt(idx, int64(result), 0, true, nil, after, result == 0)
      setLastError(after)
    except CatchableError as error:
      let after = lastError()
      endReceiptException(idx, error, after)
      setLastError(after)
      raise error

  result.selectObject = proc(dc: HDC, obj: HGDIOBJ): HGDIOBJ {.closure,
      raises: [CatchableError].} =
    let tls = lastError()
    let idx = beginReceipt(opSelectObject, cast[uint64](dc), cast[uint64](obj),
      0, 0, nil)
    setLastError(tls)
    try:
      result = selectObject(dc, obj)
      let after = lastError()
      let failed = result == nil or result == cast[HGDIOBJ](-1)
      endReceipt(idx, if result == nil: 0 else: 1, cast[uint64](result), true,
        nil, after, failed)
      setLastError(after)
    except CatchableError as error:
      let after = lastError()
      endReceiptException(idx, error, after)
      setLastError(after)
      raise error

  result.drawText = proc(dc: HDC, text: WidePtr, count: int32, rect: ptr RECT,
      flags: UINT): int32 {.closure, raises: [CatchableError].} =
    let tls = lastError()
    let idx = beginReceipt(opDrawText, cast[uint64](dc), cast[uint64](text),
      count, uint32(flags), text)
    if idx >= 0 and rect != nil:
      receipts[idx].inLeft = rect.left
      receipts[idx].inTop = rect.top
      receipts[idx].inRight = rect.right
      receipts[idx].inBottom = rect.bottom
    setLastError(tls)
    try:
      result = drawText(dc, text, count, rect, flags)
      let after = lastError()
      endReceipt(idx, int64(result), 0, true, rect, after, result == 0)
      setLastError(after)
    except CatchableError as error:
      let after = lastError()
      endReceiptException(idx, error, after)
      setLastError(after)
      raise error

# --- frozen 5507 cold fixture, copied minimally (one cycle) -------------------

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

type Facts = object
  complete: bool
  reason: string
  pumpOk, closeComplete: bool
  cleanupError: ref CatchableError
  ports, firstRows, scrolls, settles, scrollTicksDelta, reusedDelta: int
  creates, liveRows, parkedRows, reusedRows, setTexts, liveWindows: int
  liveFonts, liveSubclasses, liveRoots: int
  hostLiveWindows, hostLiveRoots: int
  revision: uint64

proc runSingleCycle(calls: Win32Calls, hostOut: var Win32Host): Facts =
  var facts: Facts
  takeStage(0)                              # beforeHost
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(
    fixtureApplication(listRender, "T2 leaf measure resources", 480, 320),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("T2 leaf measure resources",
    DipSize(width: 480, height: 320), calls)
  hostOut = h
  takeStage(1)                              # afterHost, before backend/attach
  h.setStartupScope(proc(): bool =
    activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win = newWin32Backend(h, calls)
  let session = win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  h.setSafeTick(proc() =
    let ticksBefore = win.diagnostics.scrollTicks
    let reusedBefore = win.diagnostics.reusedRows
    win.safeListTurn()                      # first settle
    inc facts.settles
    facts.firstRows = win.diagnostics.liveRows
    takeStage(2)                            # afterFirstSettle
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
    let diag = win.diagnostics
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
    takeStage(3)                            # afterScrolls (live)
    h.requestClose())
  facts.pumpOk = h.pump() == 0
  facts.closeComplete = h.resourcesReleasedInternal()
  takeStage(4)                              # afterClose: OS totals only
  result = facts
  try: h.destroyHost()                      # idempotent confirmation, no retry
  except CatchableError as error:
    result.cleanupError = error
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
  elif result.scrollTicksDelta != ExpectedScrollTicks:
    result.reason = "scroll_ticks_delta=" & $result.scrollTicksDelta
  elif result.reusedDelta != ExpectedReused:
    result.reason = "reused_delta=" & $result.reusedDelta
  for stage in 0 ..< Stages:
    if not stageTaken[stage] and result.reason.len == 0:
      result.reason = "missing stage " & StageNames[stage]
  result.complete = result.reason.len == 0

proc main(): int =
  let base = systemWin32Calls()
  let calls = wrapCalls(base)
  var facts: Facts
  var host: Win32Host = nil
  var primary: ref CatchableError = nil
  var cleanupError: ref CatchableError = nil
  try:
    facts = runSingleCycle(calls, host)
  except CatchableError as error:
    primary = error
  if primary != nil and host != nil:
    # One bounded own cleanup attempt on our own host, before any formatting;
    # the primary ref stays primary and no retry loop runs.
    try: host.destroyHost()
    except CatchableError as error: cleanupError = error
  var drawTextCount = 0
  for i in 0 ..< receiptLen:
    if receipts[i].op == opDrawText: inc drawTextCount
  var receiptExceptions = 0
  for i in 0 ..< receiptLen:
    if receipts[i].exceptionMark: inc receiptExceptions

  # Safe boundary: everything below may allocate and print.
  echo "probe_win32_leaf_measure_resources stages=", Stages,
    " receipts=", receiptLen, " capacity=", ReceiptCapacity,
    " overflow=", receiptOverflow, " drawtext=", drawTextCount
  for stage in 0 ..< Stages:
    if stageTaken[stage]:
      echo "stage ", StageNames[stage], " seq=", stageSeq[stage],
        " user=", stageUser[stage],
        " user_err=", stageUserErr[stage], " gdi=", stageGdi[stage],
        " gdi_err=", stageGdiErr[stage]
    else:
      echo "stage ", StageNames[stage], " taken=false"
  if facts.reason.len != 0 or primary != nil:
    echo "path complete=false reason=", facts.reason
  else:
    echo "path complete=true ports=", facts.ports, " first_rows=",
      facts.firstRows, " scrolls=", facts.scrolls, " settles=",
      facts.settles, " scroll_ticks_delta=", facts.scrollTicksDelta,
      " reused_delta=", facts.reusedDelta, " creates=", facts.creates,
      " live_rows=", facts.liveRows, " parked=", facts.parkedRows,
      " reused=", facts.reusedRows, " set_texts=", facts.setTexts,
      " live_windows=", facts.liveWindows, " live_fonts=", facts.liveFonts,
      " live_subclasses=", facts.liveSubclasses, " live_roots=",
      facts.liveRoots, " host_live_windows=", facts.hostLiveWindows,
      " host_live_roots=", facts.hostLiveRoots, " revision=", facts.revision,
      " close_complete=", facts.closeComplete
  for i in 0 ..< receiptLen:
    let r = receipts[i]
    var line = "receipt seq=" & $r.seqIn & ".." & $r.seqOut & " depth=" &
      $r.depth & " op=" & $r.op & " hwnd_dc=" & $r.hwndOrDc & " obj_text=" &
      $r.objOrText
    if r.op == opDrawText:
      line.add(" count=" & $r.argCount & " flags=" & $r.argFlags &
        " in_rect=" & $r.inLeft & "," & $r.inTop & "," & $r.inRight & "," &
        $r.inBottom & " out_rect=" & $r.outLeft & "," & $r.outTop & "," &
        $r.outRight & "," & $r.outBottom)
      var text = ""
      for k in 0 ..< int(r.textStored): text.add(char(r.textPrefix[k]))
      line.add(" text=" & text)
    if r.hasRet:
      line.add(" ret=" & $r.ret)
      if r.retHandle != 0'u64: line.add(" ret_handle=" & $r.retHandle)
    else:
      line.add(" ret=N/A")
    line.add(" failed=" & $r.failed)
    if r.hasCallErr: line.add(" call_err=" & $r.callErr)
    else: line.add(" call_err=N/A")
    if r.hasPostSample: line.add(" post=sampled")
    else: line.add(" post=N/A")
    line.add(" user=" & $r.userBefore & "->" & $r.userAfter & " gdi=" &
      $r.gdiBefore & "->" & $r.gdiAfter)
    if r.errUserBefore != 0 or r.errGdiBefore != 0 or r.errUserAfter != 0 or
        r.errGdiAfter != 0:
      line.add(" sample_err=" & $r.errUserBefore & "/" & $r.errGdiBefore & "/" &
        $r.errUserAfter & "/" & $r.errGdiAfter)
    if r.exceptionMark:
      line.add(" exception=" & $r.excRef.name & ": " & $r.excRef.msg)
    echo line

  var incomplete = ""
  if primary != nil:
    incomplete = "cycle raised " & $primary.name
  elif not facts.complete:
    incomplete = facts.reason
  elif receiptOverflow:
    incomplete = "receipt capacity overflow (" & $ReceiptCapacity & ")"
  elif sampleFailed:
    incomplete = "sampling failed counter=" & $sampleFailedCounter & " err=" &
      $sampleFailedErr
  elif receiptExceptions != 0:
    incomplete = "observed call raised: " & $receiptExceptions
  elif drawTextCount == 0:
    incomplete = "premise_not_met: no width-constrained DrawTextW call"
  if incomplete.len != 0:
    if primary != nil:
      echo "cycle error type=", primary.name, " msg=", primary.msg
    if facts.cleanupError != nil:
      echo "cleanup error type=", facts.cleanupError.name, " msg=",
        facts.cleanupError.msg
    if cleanupError != nil:
      echo "host cleanup error type=", cleanupError.name, " msg=",
        cleanupError.msg
    echo "final user=", stageUser[4], " gdi=", stageGdi[4],
      " prior_leaf_cycle user=4 gdi=10"
    echo "probe_win32_leaf_measure_resources status=diagnostic_incomplete",
      " reason=", incomplete
    return 3
  echo "final user=", stageUser[4], " gdi=", stageGdi[4],
    " prior_leaf_cycle user=4 gdi=10 pattern_matches=",
    (stageUser[4] == 4'u32 and stageGdi[4] == 10'u32)
  echo "probe_win32_leaf_measure_resources status=diagnostic_completed"
  0

when isMainModule:
  quit(main())
