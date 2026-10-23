## Native scrollable list viewport. One real Unicode child window per virtual
## list owns the row subtrees; this module owns the scroll *facts* (offset,
## visible range, wheel/scrollbar intent) and nothing else: no Runtime, no
## business Node, no row windows and no second scroll authority.
##
## Contract:
## - `desiredOffset` is what the user asked for; `appliedOffset` is what the
##   accepted row frame currently shows. A failed candidate never moves the
##   applied value, so a half-new frame cannot be exposed at a new offset.
## - Scrollbar positions are a bounded, monotonic int32 projection of the DIP
##   offset (`unit` grows with the total, so 1e11 DIP still fits int32).
## - `listVisible` is the only range source and never pre-adds overscan; the
##   Runtime adds it once when it materializes.
## - No message handler lays out, materializes or commits: handlers record
##   intent and wake the owner.
import std/[options, tables, algorithm, math]
import ../../[core, styles, backend, backend_session, native_layout, native_list_layout,
  height_index]
import ./[api, calls]

const
  MaxScrollUnits* = 1_073_741_824'i64
    ## int32-safe thumb space (2^30). The DIP-per-unit step grows as needed so
    ## the mapping stays monotonic for a 1e11 DIP logical total.
  MinScrollUnit* = 32.0
  WheelNotch* = 120'i32

type
  ListGeometryConvergenceError* = object of UiError

  ListRowBox* = object
    ## Pure geometry of one materialised row-subtree window: the parent-local
    ## window rect and the viewport-space clip used for its region. No HWND, no
    ## resource owner, no business Node and no entity copy: a replay resolves the
    ## handle through the typed control store at apply time.
    handle*: NodeHandle
    local*, clip*: DipRect

  ListFrame* = ref object
    ## Private native geometry plan. One frame owns its props, HeightIndex,
    ## offset, visible range, typed materialised rows, measurement context and the
    ## projected row-subtree boxes together; a candidate is never accepted
    ## partially. An accepted frame is immutable and is what a rollback replay
    ## applies verbatim: no layoutSubtree, no measurement and no overwrite.
    props*: HostListProps
    heights*: ref HeightIndex
    offset*: float64
    first*, finish*: int
    sourceGeneration*: uint64
    rows*: seq[NativeRowBinding]
    clientWidth*, viewport*: float64
    dpi*: int32
    fontEpoch*: uint64
      ## Epoch of the actually installed NativeMeasure/control font. Height
      ## measurements cannot survive a width, DPI or installed-font change.
    postClientWidth*, postViewport*: float64
    contextPending*: bool
      ## Readback after the single scrollbar projection. The measured context
      ## above stays immutable; a mismatch is explicitly pending, not valid at
      ## the new client width. A later ordinary turn prepares a new frame.
    measuredRows*: int
    frameId*: uint64
    token*: uint64
      ## Backend-wide plan token: stable for the lifetime of the frame and never
      ## derived from a recreated host, so a replay receipt can prove that the
      ## applied plan is the very frame that was accepted before the failure.
    boxes*: seq[ListRowBox]
      ## Row-subtree projection prepared together with this frame (normal
      ## attempts only). Geometry, commit apply and replay all place from here.
    rowsetReady*: bool
      ## The typed rowset of the attempt is exactly visible + one overscan ring
      ## + protected. Computed once per attempt from scalars; accept never builds
      ## a set and never infers readiness from applied range equality.
    intentAtPrepare*: uint64
      ## Intent counter when this plan's context was read, so a publication cannot
      ## drop an intent that arrived while the attempt was running.
    rowsPending*, trimPending*: bool
      ## rowsPending: required rows are missing; trimPending: extra typed rows
      ## must leave. Either one keeps the list due for a later ordinary fact turn.
    neededFirst*, neededFinish*: int
      ## The exact rowset this plan needs (scalars, for the pending-fact ack).
    barMin*, barMax*: int32
    barPage*: UINT
    barPos*: int32
      ## Scrollbar projection of this plan (its own total/offset/viewport,
      ## computed once after the range was clamped). A replay writes exactly these
      ## values through the same apply helper, so the old bar is really restored.

  Win32ListHost* = ref object
    handle*: NodeHandle
    window*: HWND
    cookie*: uint
    props*: HostListProps
    generation*: uint64
    heights*: ref HeightIndex
    viewport*: float64               ## DIP viewport height (finite, fixed by layout)
    clientWidth*: float64            ## actual DIP client width after the scrollbar
    desiredOffset*, appliedOffset*: float64
    wheelRemainder*: int
    protectedIndices*: seq[int]
    want*: bool                      ## a viewport fact is due this turn
    requestedFirst*, requestedFinish*: int
      ## Bare visible range of the last fact actually handed to the session.
      ## Runtime alone adds overscan. Compare only to a bare frame range, never
      ## expanded neededFirst/neededFinish, when suppressing no-progress facts.
    rowsPending*, trimPending*: bool
      ## Observation of the accepted plan's rowset demand (see ListFrame).
    intentGeneration*: uint64
      ## Monotonic user-intent counter. Only a plan prepared after the latest
      ## intent may clear `want`; an intent recorded during the attempt survives.
    appliedFirst*, appliedFinish*: int
    calls*: Win32Calls
    wake*: proc() {.closure.}
    commands*: proc(receiver: HWND, wp: WPARAM, lp: LPARAM): bool {.closure.}
    scrollbars*: int
    acceptedFrame*: ListFrame
      ## Read-only authority for geometry; only a successful candidate swap
      ## replaces it.
    preparedFrame*: ListFrame
      ## Candidate owned by the current geometry attempt.
    retiredFrame*: ListFrame
      ## One-generation retirement slot freed by a later normal turn.
    failedFrame*: ListFrame
      ## Test-only observation of the candidate that failed placement.
    failedPhase*: string
    nextFrameId*: uint64
    correctionDue*, correctionBlocked*, wakePending*: bool
      ## Ordinary-turn scheduling, separate from business rowset demand. A
      ## correction cannot run again in the turn that created it.

proc requestWake*(list: Win32ListHost) =
  if list.wakePending: return
  list.wakePending = true
  if list.wake != nil: list.wake()

proc beginGeometryTurn*(list: Win32ListHost) =
  list.wakePending = false
  list.correctionDue = list.acceptedFrame != nil and
    list.acceptedFrame.contextPending and not list.correctionBlocked

proc noteClientReadback*(list: Win32ListHost, frame: ListFrame,
                         width, viewport: float64) =
  ## Only candidates are written. Detect A -> B -> A under the same input
  ## context from the immediately preceding accepted pending frame; stop rather
  ## than queue another automatic correction. No history chain or retry loop.
  frame.postClientWidth = width
  frame.postViewport = viewport
  frame.contextPending = width != frame.clientWidth or viewport != frame.viewport
  let old = list.acceptedFrame
  if frame.contextPending and old != nil and old.contextPending and
      frame.sourceGeneration == old.sourceGeneration and
      frame.intentAtPrepare == old.intentAtPrepare and
      frame.fontEpoch == old.fontEpoch and frame.dpi == old.dpi and
      frame.props == old.props and
      frame.clientWidth == old.postClientWidth and
      frame.viewport == old.postViewport and
      width == old.clientWidth and viewport == old.viewport:
    list.correctionBlocked = true
    list.correctionDue = false
    raise newException(ListGeometryConvergenceError,
      "list geometry did not converge: scrollbar client size alternates")
  list.correctionBlocked = false
  list.correctionDue = false
  if frame.contextPending: list.requestWake()

proc ensureHeightIndex(list: Win32ListHost, props: HostListProps) =
  ## Rebuild on a source generation change: the old index must never give a new
  ## key another row's height.
  if list.heights != nil and list.heights[].len == props.itemCount and
      list.generation == props.sourceGeneration and
      list.props.heightMode == props.heightMode and
      list.props.rowHeight == props.rowHeight and
      list.props.estimate == props.estimate:
    return
  list.props = props
  list.generation = props.sourceGeneration
  let estimate =
    if props.heightMode == HostHeightMode.uniform: props.rowHeight
    else: props.estimate
  list.heights = new HeightIndex
  list.heights[] = initHeightIndex(props.itemCount, estimate)

proc updateSource*(list: Win32ListHost, props: HostListProps) =
  ## Apply-side working metadata only. The immutable accepted frame retains its
  ## old source/index for rollback until the complete candidate is accepted.
  if list.props == props: return
  list.ensureHeightIndex(props)
  list.props = props
  list.want = true
  list.correctionBlocked = false
  list.correctionDue = false
  list.requestWake()

proc newListHost*(handle: NodeHandle, window: HWND, props: HostListProps,
                  calls: Win32Calls): Win32ListHost =
  result = Win32ListHost(handle: handle, window: window, calls: calls)
  result.ensureHeightIndex(props)
  result.desiredOffset = 0.0
  result.appliedOffset = 0.0

proc newFrameId(list: Win32ListHost): uint64 =
  inc list.nextFrameId
  list.nextFrameId

proc prepareFrame*(list: Win32ListHost, props: HostListProps, clientWidth,
                   viewport: float64, dpi: int32, wantedOffset: float64,
                   rows: seq[NativeRowBinding], token, fontEpoch: uint64): ListFrame =
  ## Candidate plan. Same source/mode/count and measurement context -> clone the
  ## accepted heights (one O(itemCount) copy per list per attempt, never per
  ## row); a source/mode/count change starts from a fresh estimate index. The
  ## candidate never aliases the accepted storage.
  result = ListFrame(props: props, clientWidth: clientWidth, viewport: viewport,
    dpi: dpi, fontEpoch: fontEpoch, rows: rows, sourceGeneration: props.sourceGeneration,
    frameId: list.newFrameId(), token: token,
    intentAtPrepare: list.intentGeneration)
  result.heights = new HeightIndex
  let accepted = list.acceptedFrame
  if accepted != nil and accepted.props.sourceGeneration == props.sourceGeneration and
      accepted.props.itemCount == props.itemCount and
      accepted.props.heightMode == props.heightMode and
      accepted.clientWidth == clientWidth and accepted.dpi == dpi and
      accepted.fontEpoch == fontEpoch and
      accepted.heights[].len == props.itemCount:
    result.heights[] = cloneHeightIndex(accepted.heights[])
  else:
    let estimate = if props.heightMode == HostHeightMode.uniform: props.rowHeight
                   else: props.estimate
    if props.itemCount > 0:
      result.heights[] = initHeightIndex(props.itemCount, estimate)
  # Candidate offset comes from the user's registered intent, never from a
  # legacy applied scalar that a previous failed pass may have advanced.
  let reach = max(0.0, result.heights[].total - viewport)
  result.offset = clamp(wantedOffset, 0.0, reach)

proc measureRow*(frame: ListFrame, index: int, height: float64) =
  if frame == nil or frame.heights == nil: return
  if index < 0 or index >= frame.heights[].len: return
  frame.heights[].measure(index, height)
  inc frame.measuredRows

proc preserveAnchor*(list: Win32ListHost, frame: ListFrame) =
  ## Normal preparation only, after real measurement. Keep the old first
  ## visible typed key and in-row delta when no newer user scroll was requested.
  ## Never infer a key from a node id, sibling position or an unmaterialized row.
  let accepted = list.acceptedFrame
  if frame == nil or accepted == nil or
      frame.props.heightMode != HostHeightMode.variable or
      accepted.props.heightMode != HostHeightMode.variable or
      frame.sourceGeneration != accepted.sourceGeneration or
      frame.props.itemCount != accepted.props.itemCount or
      list.intentGeneration != accepted.intentAtPrepare or
      list.intentGeneration != frame.intentAtPrepare:
    return
  for oldRow in accepted.rows:
    if oldRow.itemIndex != accepted.first: continue
    let delta = max(0.0, accepted.offset -
      accepted.heights[].prefix(oldRow.itemIndex))
    for newRow in frame.rows:
      if newRow.itemKey == oldRow.itemKey:
        frame.offset = frame.heights[].prefix(newRow.itemIndex) +
          min(delta, frame.heights[].height(newRow.itemIndex))
        return
    return

proc refreshRange*(frame: ListFrame) =
  if frame == nil or frame.heights == nil: return
  # The candidate's own total bounds either its user target or preserved anchor.
  let reach = max(0.0, frame.heights[].total - frame.viewport)
  frame.offset = clamp(frame.offset, 0.0, reach)
  let range = frame.heights[].visible(frame.offset, frame.viewport, 0)
  frame.first = range.first
  frame.finish = range.finish

proc projectBar*(frame: ListFrame) =
  ## One scrollbar projection per plan, from the frame's own total/offset/
  ## viewport. A replay writes these exact scalars instead of recomputing from a
  ## live legacy value, and SetScrollInfo returning 0 stays a legal position.
  if frame == nil or frame.heights == nil: return
  let unit = max(MinScrollUnit,
    max(max(0.0, frame.heights[].total - frame.viewport), frame.viewport) /
      float64(MaxScrollUnits))
  let reach = max(0.0, frame.heights[].total - frame.viewport)
  let units = if reach <= 0.0: 0'i64
              else: int64(min(float64(MaxScrollUnits), ceil(reach / unit)))
  let page = if frame.viewport <= 0.0: 0'i64
             else: int64(max(1.0, round(frame.viewport / unit)))
  frame.barMin = 0
  frame.barMax = int32(clamp(units + max(0'i64, page - 1), 0'i64,
    int64(high(int32))))
  frame.barPage = UINT(clamp(page, 0'i64, int64(high(UINT))))
  frame.barPos = int32(clamp(round(frame.offset / unit), 0.0, float64(units)))

proc rowRectOf*(frame: ListFrame, binding: NativeRowBinding,
                viewport: DipRect): DipRect =
  ## Same projection as `listRowRect`, computed from the frame's own index without
  ## copying the height index per row.
  if frame == nil or frame.heights == nil: return
  let index = binding.itemIndex
  if index < 0 or index >= frame.heights[].len: return
  let top = frame.heights[].prefix(index)
  DipRect(x: viewport.x, y: viewport.y + top - frame.offset,
    width: viewport.width, height: frame.heights[].height(index))

proc settleFrameDemand*(list: Win32ListHost, frame: ListFrame) {.raises: [].} =
  ## Accept/replay side of the rowset readiness ack: scalars only, no set, no
  ## sequence and no allocation. A plan whose typed rowset is not the required
  ## one keeps the list due for a later ordinary fact turn; the identical fact
  ## that already failed to make progress is not re-issued by itself (no
  ## permanent wake), it waits for a genuinely new turn.
  if frame == nil: return
  let pending = not frame.rowsetReady
  list.rowsPending = frame.rowsPending
  list.trimPending = frame.trimPending
  # An intent recorded after this plan read its context is never dropped by the
  # publication, and the identical fact that already produced no progress is not
  # re-issued by itself. Both signatures below are bare visible ranges; the
  # expanded neededFirst/neededFinish are rowset readiness facts, not requests.
  let newIntent = list.intentGeneration != frame.intentAtPrepare
  list.want = newIntent or
    (pending and
     not (frame.first == list.requestedFirst and
          frame.finish == list.requestedFinish))

proc noteRowFactRequested*(list: Win32ListHost, first, finish: int) {.raises: [].} =
  ## Scalar ack of the bare visible fact actually handed to the session.
  list.requestedFirst = first
  list.requestedFinish = finish

proc installFrame*(list: Win32ListHost, frame: ListFrame,
                   desiredOffset: float64, intentGeneration: uint64) =
  ## Rollback replay: the pinned accepted plan is the authority for props, height
  ## index, offset, range and the viewport/DPI context. Its own context is what
  ## the recreated host exposes, never a live legacy scalar.
  if frame == nil: return
  list.acceptedFrame = frame
  list.props = frame.props
  list.generation = frame.sourceGeneration
  list.heights = frame.heights
  list.appliedOffset = frame.offset
  list.desiredOffset = desiredOffset
  list.intentGeneration = intentGeneration
  list.appliedFirst = frame.first
  list.appliedFinish = frame.finish
  list.clientWidth = frame.clientWidth
  list.viewport = frame.viewport
  # A replayed plan keeps a demand for a later ordinary turn; the recreated host
  # has no fact history to compare against yet.
  list.rowsPending = frame.rowsPending
  list.trimPending = frame.trimPending
  list.want = not frame.rowsetReady or desiredOffset != frame.offset or
    intentGeneration != frame.intentAtPrepare

proc publishPreparedFrame*(list: Win32ListHost) {.raises: [].} =
  ## Non-failing swap of an already successful candidate: no OS call, no
  ## allocation and no measurement. The replaced frame stays referenced in the
  ## one-generation retirement slot until a later normal turn drops it.
  let frame = list.preparedFrame
  if frame == nil: return
  list.retiredFrame = list.acceptedFrame
  list.acceptedFrame = frame
  list.preparedFrame = nil
  list.props = frame.props
  list.generation = frame.sourceGeneration
  # Pointer handover only: the single accepted frame stays the height authority,
  # so acceptance copies no sequence and allocates nothing.
  list.heights = frame.heights
  list.appliedOffset = frame.offset
  # A successful anchor/clamp becomes the next turn's baseline, without
  # fabricating user intent. An intent arriving during native apply survives.
  if list.intentGeneration == frame.intentAtPrepare:
    list.desiredOffset = frame.offset
  list.appliedFirst = frame.first
  list.appliedFinish = frame.finish
  list.clientWidth = frame.clientWidth
  list.viewport = frame.viewport
  list.settleFrameDemand(frame)

proc discardPreparedFrame*(list: Win32ListHost) =
  list.preparedFrame = nil

proc retireFrames*(list: Win32ListHost) =
  list.retiredFrame = nil

proc rowHeight(list: Win32ListHost): float64 =
  ## Height of the current first row (variable lists use the measured value).
  if list.heights == nil or list.heights[].len == 0: return 1.0
  let index = min(max(0, list.heights[].rowAt(list.appliedOffset)),
    list.heights[].len - 1)
  let measured = list.heights[].height(index)
  if measured > 0.0: measured else: 1.0

proc total*(list: Win32ListHost): float64 =
  if list.heights == nil: 0.0 else: list.heights[].total
proc maxOffset*(list: Win32ListHost): float64 =
  max(0.0, list.total - list.viewport)

proc scrollUnit*(list: Win32ListHost): float64 =
  ## DIP per scrollbar unit: monotonic and int32-bounded for any finite total.
  let reach = max(list.maxOffset, list.viewport)
  max(MinScrollUnit, reach / float64(MaxScrollUnits))

proc scrollUnits*(list: Win32ListHost): int32 =
  let reach = list.maxOffset
  if reach <= 0.0: return 0
  int32(min(float64(MaxScrollUnits), ceil(reach / list.scrollUnit)))

proc scrollPage*(list: Win32ListHost): int32 =
  if list.viewport <= 0.0: return 0
  int32(max(1.0, round(list.viewport / list.scrollUnit)))

proc scrollPosForOffset*(list: Win32ListHost, offset: float64): int32 =
  let unit = list.scrollUnit
  int32(clamp(round(offset / unit), 0.0, float64(list.scrollUnits)))

proc offsetForScrollPos*(list: Win32ListHost, pos: int32): float64 =
  clamp(float64(max(0'i32, pos)) * list.scrollUnit, 0.0, list.maxOffset)

proc requestViewport*(list: Win32ListHost, requested: float64) =
  ## Record the user's intent only. Message handlers never lay out or commit.
  ## A non-finite or out-of-range request is clamped, not applied blindly.
  let next = clampListOffset(list.total, list.viewport, requested)
  if next != list.desiredOffset:
    list.desiredOffset = next
    list.want = true
    inc list.intentGeneration
  if list.wake != nil: list.wake()

proc requestRelative*(list: Win32ListHost, delta: float64) =
  list.requestViewport(list.desiredOffset + delta)

proc scrollLines*(list: Win32ListHost, lines: float64) =
  if lines == 0.0: return
  list.requestRelative(lines * list.rowHeight)

proc syncScrollbar*(list: Win32ListHost) =
  ## Project the same offset onto the native scrollbar. `SetScrollInfo` returns
  ## the previous position, where 0 is a legal value - never a failure.
  ##
  ## Win32 derives the effective maximum scroll position from the *inclusive*
  ## range and the page: `nMax - max(nPage-1, 0)`. `scrollUnits` already projects
  ## the maximum *offset* (total - viewport), so the page term has to be added
  ## back here; otherwise the viewport would be deducted twice and the readable
  ## position would fall short of `scrollPosForOffset`. int64 intermediates keep
  ## the sum exact before the explicit int32 bound.
  var info = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)),
    fMask: SIF_RANGE or SIF_PAGE or SIF_POS)
  info.nMin = 0
  let units = int64(max(0'i32, list.scrollUnits))
  let page = int64(max(0'i32, list.scrollPage))
  info.nMax = int32(clamp(units + max(0'i64, page - 1), 0'i64,
    int64(high(int32))))
  info.nPage = UINT(clamp(page, 0'i64, int64(high(UINT))))
  info.nPos = list.scrollPosForOffset(list.appliedOffset)
  discard list.calls.setScrollInfo(list.window, SB_VERT, addr info, 1)
  inc list.scrollbars

proc syncScrollbarFrame*(list: Win32ListHost, frame: ListFrame) =
  ## Same projection as `syncScrollbar`, but written from the plan's own stored
  ## scrollbar scalars: a replay restores exactly the accepted bar. SetScrollInfo
  ## returning 0 is a legal previous position, never a failure.
  if frame == nil or frame.heights == nil: return
  var info = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)),
    fMask: SIF_RANGE or SIF_PAGE or SIF_POS)
  info.nMin = frame.barMin
  info.nMax = frame.barMax
  info.nPage = frame.barPage
  info.nPos = frame.barPos
  discard list.calls.setScrollInfo(list.window, SB_VERT, addr info, 1)
  inc list.scrollbars

proc trackedPosition*(list: Win32ListHost): int32 =
  ## 32-bit thumb position (`SIF_TRACKPOS`), never the 16-bit HIWORD.
  var info = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: SIF_TRACKPOS)
  if list.calls.scrollInfo(list.window, SB_VERT, addr info) == 0:
    return list.scrollPosForOffset(list.desiredOffset)
  info.nTrackPos

proc handleScrollCode*(list: Win32ListHost, code: int): bool =
  ## One native scrollbar notification. Only intent is recorded.
  case code
  of SB_LINEUP: list.scrollLines(-1.0); true
  of SB_LINEDOWN: list.scrollLines(1.0); true
  of SB_PAGEUP: list.requestRelative(-max(list.rowHeight, list.viewport - list.rowHeight)); true
  of SB_PAGEDOWN: list.requestRelative(max(list.rowHeight, list.viewport - list.rowHeight)); true
  of SB_TOP: list.requestViewport(0.0); true
  of SB_BOTTOM: list.requestViewport(list.maxOffset); true
  of SB_THUMBTRACK, SB_THUMBPOSITION:
    list.requestViewport(list.offsetForScrollPos(list.trackedPosition)); true
  of SB_ENDSCROLL: true
  else: false

proc systemWheelLines*(list: Win32ListHost, dpi: int): float64 =
  ## Read the user's system policy; never hard-code a line count in the product.
  var lines: UINT = 3
  if list.calls.systemParameters(SPI_GETWHEELSCROLLLINES, 0, addr lines, 0,
      UINT(max(96, dpi))) == 0:
    return 3.0
  if int32(lines) == WHEEL_PAGESCROLL:
    return max(1.0, list.viewport / list.rowHeight) - 1.0
  float64(lines)

proc handleWheel*(list: Win32ListHost, delta: int32, dpi: int) =
  ## High-precision wheels deliver partial deltas: accumulate them so a
  ## -40/-80 pair scrolls exactly as much as one full notch, and never drop it.
  list.wheelRemainder += int(delta)
  let notch = int(WheelNotch)
  while list.wheelRemainder <= -notch:
    list.wheelRemainder += notch
    list.scrollLines(list.systemWheelLines(dpi))
  while list.wheelRemainder >= notch:
    list.wheelRemainder -= notch
    list.scrollLines(-list.systemWheelLines(dpi))

proc visibleRange*(list: Win32ListHost): VisibleRange =
  list.heights[].visible(list.appliedOffset, list.viewport, overscan = 0)

proc desiredRange*(list: Win32ListHost): VisibleRange =
  list.heights[].visible(list.desiredOffset, list.viewport, overscan = 0)

proc rowRect*(list: Win32ListHost, binding: NativeRowBinding,
              viewport: DipRect): DipRect =
  listRowRect(list.heights[], binding, viewport, list.appliedOffset)

proc measureRow*(list: var Win32ListHost, itemIndex, height: float64) =
  ## Variable-height measurement for one applied row (prepare/geometry side).
  if list.heights == nil or itemIndex < 0.0 or
      int(itemIndex) >= list.heights[].len: return
  list.heights[].measure(int(itemIndex), height)

proc setViewportSize*(list: Win32ListHost, width, height: float64) =
  ## Actual client size in DIP, already excluding the scrollbar. A changed width
  ## invalidates variable measurements (the caller re-measures rows).
  list.clientWidth = max(0.0, width)
  list.viewport = max(0.0, height)
  list.desiredOffset = clampListOffset(list.total, list.viewport, list.desiredOffset)
  list.appliedOffset = clampListOffset(list.total, list.viewport, list.appliedOffset)
  list.want = true

proc confirmOffset*(list: Win32ListHost, offset: float64, first, finish: int) =
  ## Commit the applied frame only after the candidate rows were accepted.
  list.appliedOffset = clampListOffset(list.total, list.viewport, offset)
  list.appliedFirst = first
  list.appliedFinish = finish
  list.want = false
  list.syncScrollbar()

proc viewportFact*(list: Win32ListHost, sessionId, mountGeneration: uint64,
                   protected: seq[int]): RowViewportRequest =
  ## The owned fact the session may execute on a safe turn. No Node, closure or
  ## platform pointer crosses this seam.
  let range = list.desiredRange
  RowViewportRequest(sessionId: sessionId, mountGeneration: mountGeneration,
    listHandle: list.handle, sourceGeneration: list.generation,
    first: range.first, finish: range.finish, protected: protected)

proc clampToTotal*(list: Win32ListHost) =
  list.desiredOffset = clampListOffset(list.total, list.viewport, list.desiredOffset)
  list.appliedOffset = clampListOffset(list.total, list.viewport, list.appliedOffset)
