## Native vertical scroll viewport for the standard ScrollArea.
##
## Ownership: the scroll root control window IS the viewport (created with
## WS_VSCROLL, so GetClientRect already excludes the system bar). The content
## column is its persistent child window and owns the form controls. Scrolling
## only moves that one window; every descendant keeps its full content-space
## rectangle and its own region, so the viewport ancestor does the clipping and a
## control that scrolls into view is neither hidden nor re-created.
##
## The window callback never throws and never runs business code: it records one
## bounded queue of intents (line/page/top/bottom/track/wheel/reveal). The ordinary turn
## takes that intent, computes the candidate geometry, applies it, and only then
## publishes offset/range. Any API failure is raised to the existing recovery /
## fault path with the primary error preserved.
when not defined(windows): {.error: "Win32 scroll areas require Windows".}
import std/[math]
import ../../core
import ../../scroll_area_protocol
import ../../overlay_geometry
import ./[api, calls]

const
  SbVert = 1
  SbLineUp = 0
  SbLineDown = 1
  SbPageUp = 2
  SbPageDown = 3
  SbThumbTrack = 5
  SbThumbPosition = 4
  SbTop = 6
  SbBottom = 7
  SifRange = 0x0001'u32
  SifPage = 0x0002'u32
  SifPos = 0x0004'u32
  SifTrackPos = 0x0010'u32
  WsVScrollStyle* = 0x00200000'u32

type
  ScrollIntentKind = enum
    siNone, siDelta, siTop, siBottom, siAbsolute, siReveal

  ScrollIntent = object
    kind: ScrollIntentKind
    delta, absolute: float64
    top, bottom: float64

  Win32ScrollArea* = ref object
    calls: Win32Calls
    viewport*, content*: HWND
    scale*: float64
    viewportWidth*, viewportHeight*, contentHeight*: float64
    offset*, range*: float64
    published*: bool
      ## True only after the candidate geometry AND the native apply both
      ## succeeded; a failed apply never publishes a fake offset.
    intents: seq[ScrollIntent]
    intentFailure: bool

proc nativeError(operation: string) {.noreturn.} =
  fail(operation & " failed: Win32 error " & $lastError())

proc attached*(host: Win32ScrollArea): bool {.raises: [].} =
  host != nil and host.viewport != nil and host.content != nil

proc newScrollArea*(calls: Win32Calls, viewport: HWND,
                    scale = 1.0): Win32ScrollArea {.raises: [CatchableError].} =
  if viewport == nil: fail("scroll area requires a viewport window")
  if classify(scale) in {fcNan, fcInf, fcNegInf} or scale <= 0.0:
    fail("scroll area scale must be finite and positive")
  Win32ScrollArea(calls: calls, viewport: viewport, scale: scale)

proc attachContent*(host: Win32ScrollArea, content: HWND) {.raises: [CatchableError].} =
  if host == nil: fail("scroll area is nil")
  if content == nil: fail("scroll area content window is nil")
  if GetParent(content) != host.viewport:
    fail("scroll area content must be a child of the viewport")
  host.content = content

proc dipToPx(host: Win32ScrollArea, dip: float64): int32 {.raises: [].} =
  let scaled = round(dip * host.scale)
  if scaled > float64(high(int32) - 1): high(int32) - 1
  elif scaled < 0.0: 0
  else: int32(scaled)

proc pixelExtent(host: Win32ScrollArea): tuple[page, extent, maxPos: int32]
    {.raises: [].} =
  ## Windows semantics: nMax is INCLUSIVE, so the real scrollable maximum is
  ## nMax - (nPage - 1). nMax is therefore built from the content extent, never
  ## from the range (that would subtract the page twice).
  let extent = max(1'i32, host.dipToPx(host.contentHeight))
  let page = min(extent, max(1'i32, host.dipToPx(host.viewportHeight)))
  let maxPos = max(0'i32, extent - page)
  (page, extent, maxPos)

proc syncScrollbar(host: Win32ScrollArea): bool {.raises: [CatchableError].} =
  ## Apply the pixel range/page/pos and verify it with a real GetScrollInfo
  ## readback. SetScrollInfo's return value is the resulting position, not a
  ## success flag, so it is never treated as failure.
  let (page, extent, maxPos) = host.pixelExtent()
  let pos = min(max(0'i32, host.dipToPx(host.offset)), maxPos)
  var info: SCROLLINFO
  info.cbSize = UINT(sizeof(SCROLLINFO))
  info.fMask = SifRange or SifPos or SifPage
  info.nMin = 0
  info.nMax = extent - 1
  info.nPage = UINT(page)
  info.nPos = pos
  discard host.calls.setScrollInfo(host.viewport, SbVert, addr info, 1)
  var readback: SCROLLINFO
  readback.cbSize = UINT(sizeof(SCROLLINFO))
  readback.fMask = SifRange or SifPos or SifPage
  if host.calls.scrollInfo(host.viewport, SbVert, addr readback) == 0: return false
  readback.nMax == info.nMax and int32(readback.nPage) == page and
    readback.nPos == pos

proc moveContent(host: Win32ScrollArea): bool {.raises: [CatchableError].} =
  if host.content == nil: return false
  let width = max(1'i32, host.dipToPx(host.viewportWidth))
  let height = max(1'i32, host.dipToPx(max(host.contentHeight, host.viewportHeight)))
  let top = -host.dipToPx(host.offset)
  host.calls.windowPos(host.content, nil, 0, top, width, height,
    0x0004'u32 or 0x0010'u32) != 0 # SWP_NOZORDER|SWP_NOACTIVATE

proc applyNative(host, candidate: Win32ScrollArea) =
  ## The public receipt and the real bar must agree even if content movement
  ## fails. Capture native state, restore it on failure, and preserve the primary
  ## error if rollback itself fails (the enclosing runtime then faults/cleans up).
  var previous = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)),
    fMask: SifRange or SifPage or SifPos)
  if host.calls.scrollInfo(host.viewport, SbVert, addr previous) == 0:
    nativeError("GetScrollInfo before scroll apply")
  try:
    if not candidate.syncScrollbar(): nativeError("SetScrollInfo scroll area viewport")
    if not candidate.moveContent(): nativeError("SetWindowPos scroll area content")
  except CatchableError as primary:
    try:
      discard host.calls.setScrollInfo(host.viewport, SbVert, addr previous, 1)
      var restored = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: previous.fMask)
      if host.calls.scrollInfo(host.viewport, SbVert, addr restored) == 0 or
          restored.nMin != previous.nMin or restored.nMax != previous.nMax or
          restored.nPage != previous.nPage or restored.nPos != previous.nPos:
        nativeError("scroll area scrollbar rollback")
    except CatchableError as secondary:
      primary.msg.add("; scrollbar rollback secondary: " & secondary.msg)
    raise primary

proc applyPlan*(host: Win32ScrollArea, plan: ScrollAreaPlan,
                scale: float64) {.raises: [CatchableError].} =
  ## Candidate first, then the native apply, then publication. A failed step
  ## leaves the previously published offset/range untouched.
  if host == nil: fail("scroll area is nil")
  if classify(scale) in {fcNan, fcInf, fcNegInf} or scale <= 0.0:
    fail("scroll area scale must be finite and positive")
  if host.content == nil: return
  let candidate = Win32ScrollArea(calls: host.calls, viewport: host.viewport,
    content: host.content, scale: scale, viewportWidth: plan.viewportWidth,
    viewportHeight: plan.viewportHeight, contentHeight: plan.contentHeight,
    offset: clampOffset(plan.offset, plan.range), range: plan.range)
  host.applyNative(candidate)
  host.scale = candidate.scale
  host.viewportWidth = candidate.viewportWidth
  host.viewportHeight = candidate.viewportHeight
  host.contentHeight = candidate.contentHeight
  host.range = candidate.range
  host.offset = candidate.offset
  host.published = true

proc scrollTo*(host: Win32ScrollArea, offset: float64) {.raises: [CatchableError].} =
  if host == nil or host.content == nil or not host.published: return
  let next = clampOffset(offset, host.range)
  if abs(next - host.offset) < 0.01: return
  let candidate = Win32ScrollArea()
  candidate[] = host[]
  candidate.offset = next
  host.applyNative(candidate)
  host.offset = next

proc scrollBy*(host: Win32ScrollArea, dip: float64) {.raises: [CatchableError].} =
  if host == nil: return
  host.scrollTo(host.offset + dip)

# --- intent collection (window callback: bounded, no throw, no business) -----

proc enqueue(host: Win32ScrollArea, intent: ScrollIntent) =
  if intent.kind == siNone: return
  if host.intents.len >= 256:
    host.intentFailure = true # surfaced in an ordinary turn, never through WndProc
  else: host.intents.add(intent)

proc noteCommand*(host: Win32ScrollArea, code: int) =
  if host == nil or not host.attached: return
  var intent: ScrollIntent
  case code
  of SB_LINEUP: intent = ScrollIntent(kind: siDelta, delta: -24.0)
  of SB_LINEDOWN: intent = ScrollIntent(kind: siDelta, delta: 24.0)
  of SB_PAGEUP: intent = ScrollIntent(kind: siDelta, delta: -max(24.0, host.viewportHeight * 0.85))
  of SB_PAGEDOWN: intent = ScrollIntent(kind: siDelta, delta: max(24.0, host.viewportHeight * 0.85))
  of SB_TOP: intent = ScrollIntent(kind: siTop)
  of SB_BOTTOM: intent = ScrollIntent(kind: siBottom)
  of SB_THUMBPOSITION, SB_THUMBTRACK:
    var info = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: SIF_TRACKPOS)
    if host.calls.scrollInfo(host.viewport, SB_VERT, addr info) == 0:
      host.intentFailure = true
    else: intent = ScrollIntent(kind: siAbsolute, absolute: float64(info.nTrackPos) / host.scale)
  else: discard
  host.enqueue(intent)

proc noteWheel*(host: Win32ScrollArea, delta: float64) =
  if host == nil or not host.attached: return
  host.enqueue(ScrollIntent(kind: siDelta, delta: -delta * 48.0))

proc noteReveal*(host: Win32ScrollArea, top, bottom: float64) =
  if host == nil or not host.attached: return
  host.enqueue(ScrollIntent(kind: siReveal, top: top, bottom: bottom))

proc hasIntent*(host: Win32ScrollArea): bool =
  host != nil and (host.intents.len > 0 or host.intentFailure)

proc takeIntent*(host: Win32ScrollArea): ScrollIntent =
  if host == nil: return
  if host.intentFailure: fail("scroll area input capture failed or exceeded its bounded queue")
  if host.intents.len == 0: return
  result = host.intents[0]
  host.intents.delete(0)

proc applyIntent*(host: Win32ScrollArea, intent: ScrollIntent)
    {.raises: [CatchableError].} =
  ## Ordinary-turn application of one collected intent.
  case intent.kind
  of siDelta: host.scrollBy(intent.delta)
  of siTop: host.scrollTo(0.0)
  of siBottom: host.scrollTo(host.range)
  of siAbsolute: host.scrollTo(intent.absolute)
  of siReveal:
    if intent.top < host.offset: host.scrollTo(intent.top)
    elif intent.bottom > host.offset + host.viewportHeight:
      host.scrollTo(intent.bottom - host.viewportHeight)
  of siNone: discard

proc close*(host: Win32ScrollArea) {.raises: [].} =
  ## The viewport/content windows are ordinary controls released by the backend's
  ## existing resource path; this only drops routing state.
  if host == nil: return
  host.content = nil
  host.offset = 0.0
  host.range = 0.0
  host.published = false
  host.intents.setLen(0)
  host.intentFailure = false
