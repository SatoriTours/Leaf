## Typed vertical scroll-area contract plus pure scroll geometry. No OS objects
## and no Win32 import: the caller supplies the allocated width/height, the real
## bar thickness in DIP and a measurement closure, so the plan is unit-testable
## anywhere and the Win32 viewport only applies it.
##
## First slice: vertical only. Horizontal content that does not fit the viewport
## is an explicit refusal (never a silent horizontal clip), nested scroll areas
## are refused by the caller that knows the tree, and the offset is always
## clamped into [0, range].
import std/[math]
import ./overlay_geometry

const
  MaxScrollAreaHeight* = 20_000.0
    ## Bounded viewport height in DIP; a larger value is a construction error.
  ScrollAreaEpsilon* = OverlayEpsilon

type
  ScrollAreaPlan* = object
    ## Resolved vertical viewport plan in DIP.
    viewportWidth*, viewportHeight*: float64
    contentWidth*, contentHeight*: float64
    range*, offset*: float64
    barWidth*: float64
    verticalBar*: bool
    contentOverflowsWidth*: bool

proc scrollAreaHeightReason*(height: float64): string =
  ## Construction/prepare refusal reason for a declared viewport height.
  if classify(height) in {fcNan, fcInf, fcNegInf}:
    return "scroll area height must be finite"
  if height <= 0.0: return "scroll area height must be positive"
  if height > MaxScrollAreaHeight:
    return "scroll area height exceeds " & $MaxScrollAreaHeight & " DIP"
  ""

proc planVerticalScroll*(clientWidth, clientHeight, barWidth, offset: float64,
    measure: proc(width: float64): tuple[width, height: float64] {.closure.}):
    ScrollAreaPlan =
  ## One vertical-only plan. Bar decision, width re-measure and offset clamping
  ## come from the shared monotonic geometry so a bar can never oscillate.
  if measure == nil: raise newException(ValueError, "scroll area requires a measurement")
  if classify(barWidth) in {fcNan, fcInf, fcNegInf} or barWidth < 0.0:
    raise newException(ValueError, "scroll area bar width must be finite and non-negative")
  let reason = scrollAreaHeightReason(clientHeight)
  if reason.len != 0: raise newException(ValueError, reason)
  let geom = planOverlayGeometry(clientWidth, clientHeight, barWidth, 0.0,
    measure, 0.0, offset)
  result = ScrollAreaPlan(
    viewportWidth: geom.viewportWidth, viewportHeight: geom.viewportHeight,
    contentWidth: geom.contentWidth, contentHeight: geom.contentHeight,
    range: geom.rangeY, offset: geom.scrollY, barWidth: barWidth,
    verticalBar: geom.verticalBar,
    contentOverflowsWidth: geom.rangeX > ScrollAreaEpsilon)
