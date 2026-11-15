## Contract coverage: graphics primitives plus the documented Canvas pointer
## arithmetic only. This suite composes canvasTransform/inverse with the surface's
## 96/dpi factor itself; it does NOT execute the Win32 backend, so it cannot catch a
## backend wiring change, and it does not replace a real 150/200% desktop run.
##
## The Win32 Canvas reports pointer positions in physical client pixels and hands
## component code viewBox design units, so 100/125/150/200 percent displays are
## covered here without touching a real DPI setting.
import std/[unittest, options]
import leaf/graphics
import ../canvas_dpi_oracle

proc designDelta(viewBox, canvasDip, physical: Vec2, dpi: int): Vec2 =
  doAssert dpi > 0
  let inverse = canvasTransform(some(viewBox), canvasDip).inverse
  doAssert inverse.isSome, "the fixture DIP box must be invertible"
  let canvasFromClient = inverse.get * groupTransform(
    scale = vec2(96.0 / float64(dpi), 96.0 / float64(dpi)))
  canvasFromClient.transformVector(physical)

suite "Canvas pointer DPI mapping":
  test "20 DIP of real motion is ten design units at every DPI":
    let viewBox = vec2(100.0, 100.0)
    let canvasDip = vec2(320.0, 200.0) # width: fill, height: 200 DIP
    check designUnitsPerDip(viewBox, canvasDip) == 0.5
    for dpi in [96, 120, 144, 192]:
      let physical = vec2(20.0 * float64(dpi) / 96.0, 0) # 20 DIP of hand motion
      let delta = designDelta(viewBox, canvasDip, physical, dpi)
      check abs(delta.x - 10.0) < 1e-9
      check abs(delta.y) < 1e-12

  test "a fixed physical delta shrinks with DPI instead of staying at 96 DPI":
    let viewBox = vec2(100.0, 100.0)
    let canvasDip = vec2(320.0, 200.0)
    let physical = vec2(20.0, 0) # exactly what a SendMessage test drags
    for dpi in [96, 120, 144, 192]:
      let expected = 20.0 * 96.0 / float64(dpi) * 0.5
      check abs(designDelta(viewBox, canvasDip, physical, dpi).x - expected) < 1e-9
    # The 96 DPI fixture value 60 is only the 96 DPI member of this series.
    check abs(designDelta(viewBox, canvasDip, physical, 96).x - 10.0) < 1e-9
    check abs(designDelta(viewBox, canvasDip, physical, 144).x - 6.666666666666667) < 1e-9
    check abs(designDelta(viewBox, canvasDip, physical, 192).x - 5.0) < 1e-9

  test "non-unit viewBox keeps its own meet scale at every DPI":
    let viewBox = vec2(200.0, 100.0)
    let canvasDip = vec2(320.0, 200.0) # 1.6 DIP per design unit
    check abs(designUnitsPerDip(viewBox, canvasDip) - 0.625) < 1e-12
    for dpi in [96, 120, 144, 192]:
      let dipStep = 20.0
      let physical = vec2(dipStep * float64(dpi) / 96.0, 0)
      check abs(designDelta(viewBox, canvasDip, physical, dpi).x - dipStep * 0.625) < 1e-9
    # Same physical drag as the unit-viewBox page, different design delta.
    let physical = vec2(20.0, 0)
    check abs(designDelta(viewBox, canvasDip, physical, 96).x - 12.5) < 1e-9
    check abs(designDelta(viewBox, canvasDip, physical, 144).x - 8.333333333333334) < 1e-9
