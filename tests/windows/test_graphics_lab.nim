when not defined(windows): {.error: "Laboratory drawing tests require real Windows".}
import std/unittest
import leaf
import leaf/native_layout
import leaf/backends/win32/[host, canvas]
import ../../examples/graphics_lab/scene

suite "real laboratory frozen scene drawing":
  test "all nine frozen loads complete EndDraw and release their native resources":
    let baseline = canvasResourceCounts()
    let window = createHost("Leaf laboratory native scenes",DipSize(width:960,height:540))
    let surface = newCanvasSurface(window.windowHandle,CanvasRenderer.software)
    var frames = 0'u64
    try:
      for count in [100,1000,10000]:
        for load in LabLoad:
          let frame = newLabScene(count=count,load=load).frameAt(0.25)
          check frame.commandCount == 3*count
          check frame.pathSegmentCount == 4*(count div 3)
          surface.prepareFrame(frame)
          check surface.presentPrepared()
          surface.acceptPrepared()
          inc frames
          check surface.frameId == frames
          check surface.lastDrawnFrame.commandCount == 3*count
    finally:
      surface.close()
      window.requestClose()
      check window.pump() == 0
    check canvasResourceCounts() == baseline
