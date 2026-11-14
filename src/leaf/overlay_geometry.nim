## Pure two-axis scroll geometry for one modal level. No OS objects and no
## Win32 import: the caller supplies the client size, the scrollbar thickness
## in DIP and a measurement closure, so the plan can be unit tested anywhere.
import std/[math]

const
  OverlayEpsilon* = 0.5
    ## DIP tolerance so a fractional measurement does not flip a bar on/off.
  MaxOverlayBarRounds* = 4
    ## Monotonic enabling is bounded: each round may only turn a bar on, so the
    ## fixpoint is reached in at most four rounds even when a horizontal bar
    ## reduces the height enough to require the vertical one (and the reverse).

type
  OverlayGeometry* = object
    ## One level plan in DIP. `viewport` is the content area inside the client
    ## (bars already removed); ranges are content minus page, never negative.
    clientWidth*, clientHeight*: float64
    viewportX*, viewportY*, viewportWidth*, viewportHeight*: float64
    contentWidth*, contentHeight*: float64   # natural size at the final viewport width
    rangeX*, rangeY*: float64
    scrollX*, scrollY*: float64
    verticalBar*, horizontalBar*: bool
    barWidth*, barHeight*: float64

proc clampOffset*(value, range: float64): float64 =
  if range <= 0.0: 0.0
  else: min(max(value, 0.0), range)

proc planOverlayGeometry*(clientWidth, clientHeight, barWidth, barHeight: float64,
    measure: proc(width: float64): tuple[width, height: float64] {.closure.},
    scrollX = 0.0, scrollY = 0.0): OverlayGeometry =
  ## Single source of truth for the two-axis bar decision. Bars are enabled
  ## monotonically until the geometry is stable; a bar is never disabled in a
  ## later round, so bar/page/rng values cannot oscillate.
  if measure == nil: raise newException(ValueError, "overlay geometry requires a measurement")
  let cw = max(1.0, clientWidth)
  let ch = max(1.0, clientHeight)
  var wantV = false
  var wantH = false
  var natural = (width: cw, height: ch)
  for round in 0 ..< MaxOverlayBarRounds:
    let innerW = max(1.0, cw - (if wantV: barWidth else: 0.0))
    let innerH = max(1.0, ch - (if wantH: barHeight else: 0.0))
    natural = measure(innerW)
    let needV = natural.height > innerH + OverlayEpsilon
    let needH = natural.width > innerW + OverlayEpsilon
    if needV == wantV and needH == wantH: break
    wantV = wantV or needV
    wantH = wantH or needH
  let innerW = max(1.0, cw - (if wantV: barWidth else: 0.0))
  let innerH = max(1.0, ch - (if wantH: barHeight else: 0.0))
  # Measure once more with the final viewport width so the reported content
  # height matches the width the layout will really give it.
  natural = measure(innerW)
  result = OverlayGeometry(
    clientWidth: cw, clientHeight: ch,
    viewportX: 0.0, viewportY: 0.0,
    viewportWidth: innerW, viewportHeight: innerH,
    contentWidth: max(natural.width, innerW),
    contentHeight: natural.height,
    rangeX: max(0.0, natural.width - innerW),
    rangeY: max(0.0, natural.height - innerH),
    verticalBar: wantV, horizontalBar: wantH,
    barWidth: barWidth, barHeight: barHeight)
  result.scrollX = clampOffset(scrollX, result.rangeX)
  result.scrollY = clampOffset(scrollY, result.rangeY)

proc barRects*(g: OverlayGeometry): tuple[vertical, horizontal: tuple[x, y, width, height: float64]] =
  ## Bar rectangles inside the client, sharing the bottom-right corner when both
  ## are present so neither overlaps the viewport.
  let vw = if g.verticalBar: g.barWidth else: 0.0
  let hh = if g.horizontalBar: g.barHeight else: 0.0
  result.vertical = (g.clientWidth - vw, 0.0, vw,
    max(0.0, g.clientHeight - hh))
  result.horizontal = (0.0, g.clientHeight - hh,
    max(0.0, g.clientWidth - vw), hh)

proc scrollbarPixels*(g: OverlayGeometry, scale: float64):
    tuple[rangeXPx, rangeYPx, pageXPx, pageYPx, posXPx, posYPx: int32] =
  ## Native scrollbar units are device pixels; the plan stays in DIP.
  if classify(scale) in {fcNan, fcInf, fcNegInf} or scale <= 0.0:
    raise newException(ValueError, "overlay geometry scale must be finite and positive")
  proc px(value: float64): int32 =
    let scaled = round(value * scale)
    if scaled > float64(high(int32) - 1): high(int32) - 1
    elif scaled < 0.0: 0
    else: int32(scaled)
  (px(g.rangeX), px(g.rangeY), px(g.viewportWidth), px(g.viewportHeight),
   px(g.scrollX), px(g.scrollY))