when not defined(windows) or not defined(leafCanvasMeasure):
  {.error: "Canvas CPU instrumentation tests require real Windows and -d:leafCanvasMeasure".}
import std/unittest
import leaf
import leaf/native_layout
import leaf/backends/win32/[host,canvas]
import ../../examples/graphics_lab/scene

suite "real opt-in Canvas CPU measurement":
  test "resource preparation and repaint CPU clocks are separate and cumulative":
    let baseline = canvasResourceCounts()
    for cycle in 0..<3:
      let window = createHost("Leaf Canvas CPU measurement",DipSize(width:960,height:540))
      let surface = newCanvasSurface(window.windowHandle,CanvasRenderer.software)
      try:
        let frame = newLabScene(count=100,load=LabLoad.staticFrame).frameAt(0)
        surface.prepareFrame(frame)
        let prepared = surface.diagnostics()
        check prepared.resourcePreparationNs > 0
        check prepared.drawSubmitNs == 0
        when defined(leafCanvasFixedDiagnostic):
          check prepared.resourcePreparationCycles > 0
          check prepared.drawSubmitCycles == 0
          check prepared.drawRecordCycles == 0
          check prepared.endDrawCycles == 0
        check surface.presentPrepared()
        surface.acceptPrepared()
        let presented = surface.diagnostics()
        check presented.resourcePreparationNs == prepared.resourcePreparationNs
        check presented.drawSubmitNs > 0
        when defined(leafCanvasFixedDiagnostic):
          check presented.resourcePreparationCycles == prepared.resourcePreparationCycles
          check presented.drawSubmitCycles > 0
          check presented.drawRecordCycles > 0
          check presented.endDrawCycles > 0
        check surface.paintAccepted()
        let repainted = surface.diagnostics()
        check repainted.resourcePreparationNs == presented.resourcePreparationNs
        check repainted.drawSubmitNs > presented.drawSubmitNs
        when defined(leafCanvasFixedDiagnostic):
          check repainted.resourcePreparationCycles == presented.resourcePreparationCycles
          check repainted.drawSubmitCycles > presented.drawSubmitCycles
          check repainted.drawRecordCycles > presented.drawRecordCycles
          check repainted.endDrawCycles > presented.endDrawCycles
        check repainted.successfulDraws == presented.successfulDraws+1
      finally:
        surface.close()
        window.requestClose()
        check window.pump() == 0
      check canvasResourceCounts() == baseline
