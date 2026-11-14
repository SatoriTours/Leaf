import std/[math, unittest]
import leaf/[overlay_geometry]

proc fixed(width, height: float64): proc(w: float64): tuple[width, height: float64] {.closure.} =
  result = proc(w: float64): tuple[width, height: float64] = (width, height)

proc wrapping(lineHeight, perWidth: float64): proc(w: float64): tuple[width, height: float64] {.closure.} =
  ## Narrower viewports wrap into more lines: height grows as width shrinks.
  result = proc(w: float64): tuple[width, height: float64] =
    let lines = ceil(perWidth / max(1.0, w))
    (w, lines * lineHeight)

suite "overlay two-axis scroll geometry":
  test "content that fits keeps no bars and a full viewport":
    let g = planOverlayGeometry(400, 300, 17, 17, fixed(200, 100))
    check not g.verticalBar
    check not g.horizontalBar
    check g.viewportWidth == 400
    check g.viewportHeight == 300
    check g.rangeX == 0 and g.rangeY == 0
    check g.scrollX == 0 and g.scrollY == 0

  test "vertical overflow enables only the vertical bar":
    let g = planOverlayGeometry(400, 120, 17, 17, fixed(300, 600))
    check g.verticalBar
    check not g.horizontalBar
    check g.viewportWidth == 383
    check g.viewportHeight == 120
    check g.rangeY == 480

  test "uncompressible wide content enables the horizontal bar (rangeX not collapsed)":
    let g = planOverlayGeometry(400, 300, 17, 17, fixed(700, 100))
    check g.horizontalBar
    check not g.verticalBar
    check g.contentWidth == 700
    check g.rangeX == 300
    check g.viewportHeight == 283

  test "a horizontal bar can trigger the vertical bar in the same plan":
    ## Height fits at full width, but the horizontal bar removes 17 DIP and the
    ## content then needs more height than the reduced viewport.
    let measure = proc(w: float64): tuple[width, height: float64] =
      (700.0, (if w >= 400.0: 290.0 else: 300.0))
    let g = planOverlayGeometry(400, 300, 17, 17, measure)
    check g.horizontalBar
    check g.verticalBar
    check g.viewportWidth == 383
    check g.viewportHeight == 283

  test "both bars are required for genuinely wide and tall content":
    let g = planOverlayGeometry(400, 120, 17, 17, fixed(700, 600))
    check g.verticalBar
    check g.horizontalBar
    check g.viewportWidth == 383
    check g.viewportHeight == 103
    check g.rangeX == 317
    check g.rangeY == 497
    let rects = g.barRects()
    check rects.vertical.x == 383.0
    check rects.vertical.height == 103.0
    check rects.horizontal.y == 103.0
    check rects.horizontal.width == 383.0

  test "offsets clamp to the ranges and the maximum reveals the bottom-right":
    let g = planOverlayGeometry(400, 120, 17, 17, fixed(700, 600), scrollX = 9999, scrollY = -5)
    check g.scrollX == g.rangeX
    check g.scrollY == 0
    let maxed = planOverlayGeometry(400, 120, 17, 17, fixed(700, 600),
      scrollX = 9999, scrollY = 9999)
    check maxed.scrollX + maxed.viewportWidth == maxed.contentWidth
    check maxed.scrollY + maxed.viewportHeight == maxed.contentHeight

  test "monotonic enabling terminates within the bounded rounds":
    var calls = 0
    let measure = proc(w: float64): tuple[width, height: float64] =
      inc calls
      ## Every round demands the other bar: still terminates by monotonicity.
      ((if w < 400.0: 900.0 else: 100.0), (if w < 400.0: 300.0 else: 300.0))
    let g = planOverlayGeometry(400, 120, 17, 17, measure)
    check calls <= MaxOverlayBarRounds + 1
    check g.verticalBar
    check g.horizontalBar

  test "native scrollbar units are device pixels":
    let g = planOverlayGeometry(400, 120, 17, 17, fixed(700, 600))
    let px = g.scrollbarPixels(1.5)
    check px.rangeYPx == int32(round(g.rangeY * 1.5))
    check px.pageYPx == int32(round(g.viewportHeight * 1.5))
    check px.posYPx == 0