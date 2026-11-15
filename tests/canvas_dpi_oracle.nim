## Independent oracle for the Win32 Canvas coordinate contract.
##
## graphics.canvasTransform maps a DIP box into the viewBox with uniform "meet"
## scaling, so one DIP covers max(viewBox.x/width, viewBox.y/height) design units.
## The Win32 surface feeds that transform the *measured* client pixels divided by
## the window DPI (backends/win32/canvas.nim draw), so callers must pass a
## measured DIP box, never a declared layout size.
import leaf/graphics

proc designUnitsPerDip*(viewBox, canvasDip: Vec2): float64 =
  max(viewBox.x / canvasDip.x, viewBox.y / canvasDip.y)
