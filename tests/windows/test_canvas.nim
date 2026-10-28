when not defined(windows): {.error: "Canvas native tests require real Windows".}
import std/[unittest, options, os, osproc, strtabs, strutils]
import leaf
import leaf/[native_layout, backend_session, ui_thread, canvas_input]
import leaf/backends/win32/[api, host, backend, canvas]
from leaf/canvas_hit import target

if commandLineParams() == @["--canvas-startup-check"]: quit(0)

proc frame(radius: float64): CanvasFrame =
  let builder = newCanvasBuilder(viewBox = some(vec2(640, 360)), background = color("#101820"))
  builder.addRect(vec2(24, 24), vec2(592, 312), 16, paint(fill = some(color("#1B2936"))))
  builder.addCircle(vec2(120, 180), radius, paint(fill = some(color("#5ED5B0"))))
  builder.beginGroup(groupTransform(translate = vec2(300, 100), rotate = 30.deg), some(rectangle(0, 0, 100, 100)))
  builder.addCircle(vec2(50, 50), 60, paint(fill = some(color("#5ED5B080"))))
  builder.endGroup()
  let path = newPathBuilder(FillRule.evenOdd)
  path.moveTo(vec2(60, 260))
  path.curveTo(vec2(180, 260), vec2(220, 80), vec2(560, 80))
  builder.addPath(path.finishPath(), paint(fill = none(Color), stroke = some(color("#5ED5B0")), strokeWidth = 3))
  builder.addText("Leaf 中文 ✓", vec2(48, 48), 16, color("#FFFFFF"))
  builder.finishFrame()

component CanvasPage:
  state:
    radius = 20.0
  view:
    column:
      canvas:
        key: "drawing"
        height: 240
        background: "#101820"
        circle:
          center: (120, 120)
          radius: radius
          fill: "#5ED5B0"
      button "Grow":
        key: "grow"
        onClick:
          radius += 1.0

suite "real Direct2D Canvas":
  test "Canvas startup does not require the compiler runtime on PATH":
    let environment = newStringTable(modeCaseInsensitive)
    for name, value in envPairs(): environment[name] = value
    let windows = getEnv("SystemRoot")
    environment["PATH"] = windows / "System32" & ";" & windows
    let child = startProcess(getAppFilename(), workingDir = getAppDir(),
      args = @["--canvas-startup-check"], env = environment, options = {poParentStreams})
    defer:
      if child.running: child.terminate()
      child.close()
    check child.waitForExit(5000) == 0

  test "prepared drawing only publishes a successful frame at accept":
    let baseline = canvasResourceCounts()
    let window = createHost("Leaf Canvas native", DipSize(width: 640, height: 360))
    let surface = newCanvasSurface(window.windowHandle, CanvasRenderer.software)
    let first = frame(20)
    surface.prepareFrame(first)
    check surface.frameId == 0
    check surface.presentPrepared()
    check surface.frameId == 0
    surface.acceptPrepared()
    check surface.frameId == 1
    check surface.acceptedFrame == first
    let second = frame(30)
    surface.prepareFrame(second)
    surface.discardPrepared()
    check surface.acceptedFrame == first
    check surface.paintAccepted()
    check surface.frameId == 2
    check surface.diagnostics.renderer == CanvasRenderer.software
    surface.close()
    window.destroyHost()
    check canvasResourceCounts() == baseline

  when defined(leafProtocolProbes):
    test "target loss preserves accepted data and rebuilds once in an ordinary turn":
      let baseline = canvasResourceCounts()
      let window = createHost("Leaf Canvas recovery", DipSize(width: 640, height: 360))
      let surface = newCanvasSurface(window.windowHandle, CanvasRenderer.software)
      defer:
        surface.close()
        window.destroyHost()
        check canvasResourceCounts() == baseline
      let first = frame(20)
      surface.prepareFrame(first)
      discard surface.presentPrepared()
      surface.acceptPrepared()
      let counts = canvasResourceCounts()
      let before = surface.diagnostics
      surface.failNextDrawForTest(cast[int32](0x8899000C'u32))
      surface.handlePaint(busy = false)
      check surface.needsRebuild
      check not surface.diagnostics.faulted
      check surface.frameId == before.frameId
      check surface.lastDrawnFrame == first
      let attempts = surface.diagnostics.drawAttempts
      surface.handlePaint(busy = false)
      check surface.diagnostics.drawAttempts == attempts
      surface.recoverOnce()
      check not surface.needsRebuild
      check not surface.diagnostics.faulted
      check surface.acceptedFrame == first
      check surface.lastDrawnFrame == first
      check surface.frameId == before.frameId + 1
      check canvasResourceCounts() == counts
      let recovered = surface.diagnostics.drawAttempts
      surface.recoverOnce()
      check surface.diagnostics.drawAttempts == recovered

    test "a failed target reconstruction freezes without retry or renderer fallback":
      let baseline = canvasResourceCounts()
      let window = createHost("Leaf Canvas failed recovery", DipSize(width: 640, height: 360))
      let surface = newCanvasSurface(window.windowHandle, CanvasRenderer.software)
      defer:
        surface.close()
        window.destroyHost()
        check canvasResourceCounts() == baseline
      let first = frame(20)
      surface.prepareFrame(first)
      discard surface.presentPrepared()
      surface.acceptPrepared()
      let acceptedId = surface.frameId
      surface.failNextDrawForTest(cast[int32](0x8899000C'u32))
      surface.handlePaint(busy = false)
      surface.failNextRebuildForTest(cast[int32](0x80004005'u32))
      expect UiError: surface.recoverOnce()
      check surface.diagnostics.faulted
      check not surface.needsRebuild
      check surface.diagnostics.renderer == CanvasRenderer.software
      check surface.frameId == acceptedId
      check surface.acceptedFrame == first
      let attempts = surface.diagnostics.drawAttempts
      surface.recoverOnce()
      check surface.diagnostics.drawAttempts == attempts
      expect UiError: discard surface.paintAccepted()

  test "busy paint and hidden surfaces cannot publish a successful draw":
    let baseline = canvasResourceCounts()
    let window = createHost("Leaf Canvas paint scope", DipSize(width: 640, height: 360))
    let surface = newCanvasSurface(window.windowHandle, CanvasRenderer.software)
    defer:
      surface.close()
      window.destroyHost()
      check canvasResourceCounts() == baseline
    surface.prepareFrame(frame(20))
    discard surface.presentPrepared()
    surface.acceptPrepared()
    let before = surface.diagnostics
    surface.handlePaint(busy = true)
    check surface.diagnostics.drawAttempts == before.drawAttempts
    check surface.frameId == before.frameId
    discard ShowWindow(window.windowHandle, SW_HIDE)
    check not surface.paintAccepted()
    check surface.diagnostics.drawAttempts == before.drawAttempts
    check surface.frameId == before.frameId

  test "invalid window does not leak partial factory or target ownership":
    let baseline = canvasResourceCounts()
    expect UiError: discard newCanvasSurface(nil, CanvasRenderer.software)
    check canvasResourceCounts() == baseline

  test "managed host updates one Canvas and closes every native resource":
    let baseline = canvasResourceCounts()
    let activity = newUiScopeActivity()
    let runtime = newRuntime(guardUiApplication(componentApplication(component(CanvasPage, ()), "Leaf Canvas", width=480, height=360),
      proc(): uint64 = uint64(GetCurrentThreadId()), activity))
    let window = createHost("Leaf Canvas", DipSize(width: 480, height: 360))
    window.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate)
    let win = newWin32Backend(window, renderer = CanvasRenderer.software)
    let session = win.attachWin32Backend(runtime)
    let handle = session.handleFor(runtime.find("drawing").id)
    check win.canvasDiagnostics(handle).successfulDraws > 0
    let created = win.diagnostics.creates
    check runtime.dispatch("grow", Event(kind: click))
    check win.diagnostics.creates == created
    check win.canvasDiagnostics(handle).frameId >= 2
    window.destroyHost()
    runtime.closeRuntime()
    check win.diagnostics.liveWindows == 0
    check canvasResourceCounts() == baseline

suite "Canvas SDK containment uses the published drawn scene":
  test "evenOdd holes and text layout use renderer queries, not primitive bounds":
    let baseline = canvasResourceCounts()
    let host = createHost("Canvas hit geometry", DipSize(width: 320, height: 240))
    defer:
      host.destroyHost()
      check canvasResourceCounts() == baseline
    let surface = newCanvasSurface(host.windowHandle, CanvasRenderer.software)
    defer: surface.close()
    let b = newCanvasBuilder()
    let p = newPathBuilder(FillRule.evenOdd)
    p.moveTo(vec2(10, 10)); p.lineTo(vec2(100, 10)); p.lineTo(vec2(100, 100)); p.lineTo(vec2(10, 100)); p.closePath()
    p.moveTo(vec2(30, 30)); p.lineTo(vec2(80, 30)); p.lineTo(vec2(80, 80)); p.lineTo(vec2(30, 80)); p.closePath()
    b.addPath(p.finishPath(), paint())
    b.addInteractionInternal(CanvasInteraction(commandIndex: 0, key: "ring", eventMask: 4, hitTest: true))
    b.addText("Leaf 中文", vec2(120, 20), 18)
    b.addInteractionInternal(CanvasInteraction(commandIndex: 1, key: "text", eventMask: 4, hitTest: true))
    b.addRect(vec2(160, 120), vec2(20, 10), 15)
    b.addInteractionInternal(CanvasInteraction(commandIndex: 2, key: "sdk-rounded", eventMask: 4, hitTest: true))
    let f = b.finishFrame()
    surface.prepareFrame(f)
    check surface.hitDrawn(vec2(15, 15)).isNone # prepare is not publication.
    discard surface.presentPrepared()
    check surface.hitDrawn(vec2(15, 15)).isNone # Candidate draw isn't accepted.
    surface.acceptPrepared()
    check surface.hitDrawn(vec2(15, 15)).get.target.key == "ring"
    check surface.hitDrawn(vec2(50, 50)).isNone
    check surface.hitDrawn(vec2(125, 25)).get.target.key == "text"
    check surface.hitDrawn(vec2(310, 25)).isNone
    check surface.hitDrawn(vec2(170, 125)).get.target.key == "sdk-rounded"
    check surface.hitDrawn(vec2(160, 120)).isNone
    let candidate = newCanvasBuilder()
    candidate.addCircle(vec2(50, 50), 20)
    candidate.addInteractionInternal(CanvasInteraction(commandIndex: 0, key: "candidate", eventMask: 4, hitTest: true))
    surface.prepareFrame(candidate.finishFrame())
    surface.discardPrepared()
    check surface.hitDrawn(vec2(15, 15)).get.target.key == "ring"
    surface.maintain()
    check surface.hitDrawn(vec2(15, 15)).get.target.key == "ring"

suite "Canvas published native pointer projection":
  test "pointer identities and viewport projection publish only after whole-tree accept":
    let baseline = canvasResourceCounts()
    let host = createHost("Canvas input projection", DipSize(width: 320, height: 240))
    defer:
      host.destroyHost()
      check canvasResourceCounts() == baseline
    let surface = newCanvasSurface(host.windowHandle, CanvasRenderer.software)
    defer: surface.close()
    proc scene(key: string): CanvasFrame =
      let b = newCanvasBuilder(viewBox=some(vec2(100, 100)))
      b.addCircle(vec2(50, 50), 10)
      b.addInteractionInternal(CanvasInteraction(commandIndex: 0, key: key, eventMask: 4, hitTest: true))
      b.finishFrame()
    surface.prepareFrame(scene("first"), inputSession=42, inputMount=9)
    discard surface.presentPrepared()
    var origin: POINT
    discard MapWindowPoints(host.windowHandle, nil, addr origin, 1)
    var client: RECT
    check GetClientRect(host.windowHandle, addr client) != 0
    let center = vec2(float64(origin.x)+float64(client.right)/2, float64(origin.y)+float64(client.bottom)/2)
    check surface.pointerAtScreen(center).isNone
    surface.acceptPrepared()
    let first = surface.pointerAtScreen(center).get
    check first.id.session == 42 and first.id.mount == 9
    let machine = newCanvasPointerMachine(vec2(4, 4))
    machine.press(PointerSample(pointerId: 1, screenPosition: center, button: PointerButton.primary,
      buttons: {PointerButton.primary}), first)
    machine.release(PointerSample(pointerId: 1, screenPosition: center, button: PointerButton.primary), some(first), some(first.id))
    let event = machine.drain()[0]
    let position = surface.projectInput(event).get.sourceInternal.canvasPosition
    check abs(position.x-50) < 0.000001 and abs(position.y-50) < 0.000001
    surface.prepareFrame(scene("replacement"), inputSession=42, inputMount=9)
    discard surface.presentPrepared()
    check surface.pointerAtScreen(center).get.id == first.id
    surface.discardPrepared()
    check surface.projectInput(event).isSome
    surface.prepareFrame(scene("replacement"), inputSession=42, inputMount=9)
    discard surface.presentPrepared()
    surface.acceptPrepared()
    check surface.pointerAtScreen(center).get.id != first.id
    check surface.projectInput(event).isNone
    let replacement = surface.pointerAtScreen(center).get.id
    check SetWindowPos(host.windowHandle, nil, 0, 0, 840, 620, 0x0006) != 0
    check surface.paintAccepted()
    check GetClientRect(host.windowHandle, addr client) != 0
    discard MapWindowPoints(host.windowHandle, nil, addr origin, 1)
    let resizedCenter = vec2(float64(origin.x)+float64(client.right)/2,
      float64(origin.y)+float64(client.bottom)/2)
    let resizedHit = surface.pointerAtScreen(resizedCenter)
    check resizedHit.isSome
    if resizedHit.isSome: check resizedHit.get.id == replacement

var nativePointerLog: seq[string]
component NativePointerPage:
  state:
    count = 0
    x = 50.0
    dragging = false
    version = 0
    horizontalScale = 1.0
    visible = true
  view:
    column:
      text count:
        key: "pointer-count"
      text x:
        key: "pointer-x"
      text $dragging:
        key: "pointer-dragging"
      if visible:
        canvas:
          key: "pointer-canvas"
          width: fill
          height: 200
          viewBox: (100, 100)
          group:
            scale: (horizontalScale, 1)
            circle:
              key: "dot" & $version
              center: (x, 50)
              radius: 20
              onClick:
                nativePointerLog.add("click")
                count += 1
              onDragStart:
                nativePointerLog.add("start")
                dragging = true
              onDrag(e):
                nativePointerLog.add("drag")
                x += e.delta.x
              onDragEnd:
                nativePointerLog.add("end")
                dragging = false
              onDragCancel:
                nativePointerLog.add("cancel")
                dragging = false
      button "Reset":
        key: "pointer-reset"
        onClick:
          nativePointerLog.add("reset")
          count = 0
      button "Replace":
        key: "pointer-replace"
        onClick: version += 1
      button "Singular":
        key: "pointer-singular"
        onClick: horizontalScale = 0
      button "Hide":
        key: "pointer-hide"
        onClick: visible = false

when defined(leafProtocolProbes):
  suite "Canvas native mouse messages":
    test "WndProc records click and captured drag without invoking application code":
      nativePointerLog = @[]
      let baseline = canvasResourceCounts()
      let activity = newUiScopeActivity()
      let runtime = newRuntime(guardUiApplication(componentApplication(component(NativePointerPage, ()), "Canvas native input"),
        proc(): uint64 = uint64(GetCurrentThreadId()), activity))
      let host = createHost("Canvas native input", DipSize(width: 320, height: 300))
      host.setStartupScope(proc(): bool = activity.busy or runtime.installingHook or runtime.installingUpdate)
      let win = newWin32Backend(host, renderer=CanvasRenderer.software)
      let session = win.attachWin32Backend(runtime)
      win.bindSession(session)
      defer:
        host.destroyHost()
        runtime.closeRuntime()
        check canvasResourceCounts() == baseline
      let handle = session.handleFor(runtime.find("pointer-canvas").id)
      let window = win.canvasWindowForTest(handle)
      check window != nil
      var client: RECT
      check GetClientRect(window, addr client) != 0
      let cx = client.right div 2
      let cy = client.bottom div 2
      proc position(x: int32): LPARAM = LPARAM(uint32(uint16(x)) or (uint32(uint16(cy)) shl 16))
      discard SendMessageW(window, 0x0201, 1, position(cx))
      check GetCapture() == window
      discard SendMessageW(window, 0x0202, 0, position(cx))
      check GetCapture() != window
      check nativePointerLog.len == 0
      win.safeListTurn()
      check nativePointerLog == @["click"]
      check runtime.find("pointer-count").node.text == "1"
      nativePointerLog = @[]
      discard SendMessageW(window, 0x0201, 1, position(cx))
      discard SendMessageW(window, 0x0200, 1, position(cx+20))
      discard SendMessageW(window, 0x0202, 0, position(cx+20))
      check nativePointerLog.len == 0
      check GetCapture() != window
      win.safeListTurn()
      check nativePointerLog == @["start", "drag", "end"]
      check abs(parseFloat(runtime.find("pointer-x").node.text)-60) < 0.000001
      check runtime.find("pointer-dragging").node.text == "false"
      check runtime.find("pointer-count").node.text == "1"

when defined(leafProtocolProbes):
  template pointerFixture(body: untyped) =
    block:
      nativePointerLog = @[]
      let baseline = canvasResourceCounts()
      let activity = newUiScopeActivity()
      let runtime {.inject.} = newRuntime(guardUiApplication(
        componentApplication(component(NativePointerPage, ()), "Canvas pointer paths"),
        proc(): uint64 = uint64(GetCurrentThreadId()), activity))
      let nativeHost {.inject.} = createHost("Canvas pointer paths", DipSize(width: 320, height: 600))
      nativeHost.setStartupScope(proc(): bool = activity.busy or runtime.installingHook or runtime.installingUpdate)
      let win {.inject.} = newWin32Backend(nativeHost, renderer=CanvasRenderer.software)
      let session {.inject.} = win.attachWin32Backend(runtime)
      win.bindSession(session)
      let window {.inject.} = win.canvasWindowForTest(session.handleFor(runtime.find("pointer-canvas").id))
      defer:
        nativeHost.destroyHost()
        runtime.closeRuntime()
        check canvasResourceCounts() == baseline
        check GetCapture() != window
      var client: RECT
      check GetClientRect(window, addr client) != 0
      let cx = client.right div 2
      let cy = client.bottom div 2
      proc mouse(message: UINT, xOffset = 0'i32, held = true) {.inject.} =
        let point = LPARAM(uint32(uint16(cx+xOffset)) or (uint32(uint16(cy)) shl 16))
        discard SendMessageW(window, message, WPARAM(ord(held)), point)
      body

  suite "Canvas native cancellation and retirement":
    test "focus and capture loss produce a single deferred cancel":
      for loseFocus in [true, false]:
        pointerFixture:
          mouse(0x0201)
          mouse(0x0200, 20)
          if loseFocus:
            discard SendMessageW(window, 0x0008, 0, 0)
          else:
            discard SetCapture(nativeHost.windowHandle)
          check nativePointerLog.len == 0
          check GetCapture() != window
          win.safeListTurn()
          check nativePointerLog == @["start", "drag", "cancel"]
          check runtime.find("pointer-dragging").node.text == "false"
          mouse(0x0202, 20, false)
          win.safeListTurn()
          check nativePointerLog == @["start", "drag", "cancel"]
          if GetCapture() == nativeHost.windowHandle: discard ReleaseCapture()

    test "singular accepted transform cancels without another mouse message":
      pointerFixture:
        mouse(0x0201)
        mouse(0x0200, 20)
        win.safeListTurn()
        nativePointerLog = @[]
        check runtime.dispatch("pointer-singular", Event(kind: click))
        win.safeListTurn()
        check GetCapture() != window
        check nativePointerLog == @["cancel"]
        check runtime.find("pointer-dragging").node.text == "false"

    test "changed key retires capture and drops queued events":
      pointerFixture:
        mouse(0x0201)
        mouse(0x0200, 20)
        check runtime.dispatch("pointer-replace", Event(kind: click))
        win.safeListTurn()
        check GetCapture() != window
        check nativePointerLog.len == 0
        check runtime.find("pointer-x").node.text == "50.0"

    test "unmount retires capture without calling a destroyed owner":
      pointerFixture:
        mouse(0x0201)
        mouse(0x0200, 20)
        check runtime.dispatch("pointer-hide", Event(kind: click))
        win.safeListTurn()
        check GetCapture() != window
        check nativePointerLog.len == 0

    test "captured drag can end outside the client without a click":
      pointerFixture:
        mouse(0x0201)
        mouse(0x0200, -200)
        mouse(0x0202, -200, false)
        win.safeListTurn()
        check nativePointerLog == @["start", "drag", "end"]
        check GetCapture() != window
        check runtime.find("pointer-count").node.text == "0"


when defined(leafProtocolProbes):
  suite "Canvas native input ordering and budget":
    test "system double-click down begins a new captured drag":
      pointerFixture:
        mouse(0x0203)
        check GetCapture() == window
        mouse(0x0200, 20)
        mouse(0x0202, 20, false)
        check nativePointerLog.len == 0
        win.safeListTurn()
        check nativePointerLog == @["start", "drag", "end"]
        check runtime.find("pointer-dragging").node.text == "false"

    test "ordinary capture maintenance never creates a self-waking tick loop":
      pointerFixture:
        mouse(0x0201)
        var pending: MSG
        for i in 0..<64:
          if PeekMessageW(addr pending, nativeHost.windowHandle, WM_HOST_TICK, WM_HOST_TICK, PM_REMOVE) == 0: break
        win.safeListTurn()
        check GetCapture() == window
        check PeekMessageW(addr pending, nativeHost.windowHandle, WM_HOST_TICK, WM_HOST_TICK, PM_REMOVE) == 0
        mouse(0x0202, 0, false)
        win.safeListTurn()

    test "Canvas and native buttons preserve the source FIFO":
      pointerFixture:
        mouse(0x0201)
        mouse(0x0202, 0, false)
        let reset = win.nativeWindowForTest(session.handleFor(runtime.find("pointer-reset").id))
        discard SendMessageW(reset, 0x00F5, 0, 0) # BM_CLICK records a real native command.
        mouse(0x0201)
        mouse(0x0202, 0, false)
        check nativePointerLog.len == 0
        win.safeListTurn()
        check nativePointerLog == @["click", "reset", "click"]
        check runtime.find("pointer-count").node.text == "1"

    test "queue overflow releases capture and freezes before business delivery":
      pointerFixture:
        for i in 0..<MaxCanvasPointerEvents:
          mouse(0x0201)
          mouse(0x0202, 0, false)
        mouse(0x0201)
        mouse(0x0200, 20)
        check GetCapture() != window
        expect UiError: win.safeListTurn()
        check session.faulted
        check nativePointerLog.len == 0

var nativeRawLog: seq[string]
component NativeRawPage:
  state:
    count = 0
  view:
    column:
      button "Before":
        key: "raw-before"
      canvas:
        key: "raw-canvas"
        height: 200
        focusable: true
        accessibleLabel: "交互画布"
        onPointerDown(e):
          nativeRawLog.add("down:" & $e.button & ":" & $(PointerModifier.shift in e.modifiers))
        onPointerMove(e):
          nativeRawLog.add("move")
        onPointerUp(e):
          nativeRawLog.add("up:" & $e.button)
        onWheel(e):
          nativeRawLog.add("wheel:" & $e.wheelDelta.y)
          count += int(e.wheelDelta.y)
        onKeyDown(e):
          nativeRawLog.add("key:" & $e.keyCode)
          count += 1
        circle:
          center: (50, 50)
          radius: 20
      text count:
        key: "raw-count"
      button "After":
        key: "raw-after"

when defined(leafProtocolProbes):
  suite "Canvas native raw input and focus":
    test "mouse buttons, wheel, keyboard, native focus and label reach one deferred channel":
      nativeRawLog = @[]
      let activity = newUiScopeActivity()
      let runtime = newRuntime(guardUiApplication(componentApplication(component(NativeRawPage, ()), "Raw input"),
        proc(): uint64 = uint64(GetCurrentThreadId()), activity))
      let host = createHost("Raw input", DipSize(width: 320, height: 400))
      host.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate)
      let win = newWin32Backend(host, renderer=CanvasRenderer.software)
      let session = win.attachWin32Backend(runtime)
      win.bindSession(session)
      defer:
        host.destroyHost()
        runtime.closeRuntime()
      let window = win.canvasWindowForTest(session.handleFor(runtime.find("raw-canvas").id))
      check (GetWindowLongW(window, -16) and int32(WS_TABSTOP)) != 0
      check (GetWindowLongW(window, -16) and 0x100) != 0 # STATIC must not return HTTRANSPARENT.
      check GetWindowTextLengthW(window) == 4
      let p = LPARAM(50'u32 or (100'u32 shl 16))
      discard SendMessageW(window, 0x0201, 5, p) # primary + shift
      check GetFocus() == window
      discard SendMessageW(window, 0x0200, 5, p)
      discard SendMessageW(window, 0x0202, 4, p)
      discard SendMessageW(window, 0x0204, 2, p)
      discard SendMessageW(window, 0x0205, 0, p)
      var point = POINT(x: 50, y: 100)
      check ClientToScreen(window, addr point) != 0
      let screen = LPARAM(uint32(uint16(point.x)) or (uint32(uint16(point.y)) shl 16))
      discard SendMessageW(window, WM_MOUSEWHEEL, WPARAM(120'u32 shl 16), screen)
      discard SendMessageW(window, WM_KEYDOWN, 39, 1)
      check nativeRawLog.len == 0
      win.safeListTurn()
      check nativeRawLog == @["down:primary:true", "move", "up:primary",
        "down:secondary:false", "up:secondary", "wheel:1.0", "key:39"]
      check runtime.find("raw-count").node.text == "2"
      let dialogCode = SendMessageW(window, WM_GETDLGCODE, 9, 0)
      check (dialogCode and DLGC_WANTALLKEYS) == 0 # Tab remains native traversal.


suite "Canvas native scalar boundary":
  test "finite double overflow is rejected before publishing native commands":
    let baseline=canvasResourceCounts()
    let window=createHost("Canvas scalar boundary",DipSize(width:320,height:240))
    let surface=newCanvasSurface(window.windowHandle,CanvasRenderer.software)
    try:
      for value in [1e39,-1e39,1e100,-1e100]:
        let b=newCanvasBuilder()
        b.addCircle(vec2(value,0),1)
        expect UiError:surface.prepareFrame(b.finishFrame())
      for value in [0.0,-0.0,1e-320,-1e-320,3.4028234663852886e38,-3.4028234663852886e38]:
        let b=newCanvasBuilder()
        b.addCircle(vec2(value,0),1)
        surface.prepareFrame(b.finishFrame())
        surface.discardPrepared()
      surface.prepareFrame(frame(17))
      check surface.presentPrepared()
      surface.acceptPrepared()
      check surface.paintAccepted()
    finally:
      surface.close()
      window.requestClose()
      check window.pump()==0
    check canvasResourceCounts()==baseline

suite "Canvas scene-local immutable path reuse":
  test "equal path values share one SDK geometry without sharing paint or transforms":
    let baseline=canvasResourceCounts()
    let window=createHost("Canvas local paths",DipSize(width:320,height:240))
    let surface=newCanvasSurface(window.windowHandle,CanvasRenderer.software)
    let sceneBaseline=canvasResourceCounts()
    try:
      for distinctRule in [false,true]:
        let b=newCanvasBuilder()
        for index in 0..<2:
          let p=newPathBuilder(if distinctRule and index==1:FillRule.evenOdd else:FillRule.nonZero)
          p.moveTo(vec2(0,0));p.lineTo(vec2(40,0));p.lineTo(vec2(0,40));p.closePath()
          b.beginGroup(groupTransform(translate=vec2(index*60+10,10)))
          b.addPath(p.finishPath(),paint(fill=some(if index==0:color("#ff0000") else:color("#0000ff"))))
          b.endGroup()
        surface.prepareFrame(b.finishFrame())
        check canvasResourceCounts().geometries==baseline.geometries+(if distinctRule:2 else:1)
        check surface.presentPrepared()
        surface.discardPrepared() # Includes drawn/rejected candidates; no publication.
        check canvasResourceCounts()==sceneBaseline
    finally:
      surface.close();window.requestClose();check window.pump()==0
    check canvasResourceCounts()==baseline

  test "scene pools stay live through hit publication rejection replacement and target rebuild":
    let baseline=canvasResourceCounts()
    let window=createHost("Canvas path pool lifetime",DipSize(width:320,height:240))
    let surface=newCanvasSurface(window.windowHandle,CanvasRenderer.software)
    proc pooled(offset:float64):CanvasFrame=
      let b=newCanvasBuilder()
      for i in 0..<2:
        let p=newPathBuilder()
        p.moveTo(vec2(0,0));p.lineTo(vec2(40,0));p.lineTo(vec2(0,40));p.closePath()
        b.beginGroup(groupTransform(translate=vec2(offset+float64(i*60),10)))
        b.addPath(p.finishPath(),paint(fill=some(color("#eeeeee"))))
        b.addInteractionInternal(CanvasInteraction(commandIndex:i*3+1,key: $i,eventMask:4,hitTest:true))
        b.endGroup()
      b.finishFrame()
    try:
      surface.prepareFrame(pooled(10))
      check surface.presentPrepared()
      surface.acceptPrepared()
      check surface.hitDrawn(vec2(15,15)).get.target.key=="0"
      check surface.hitDrawn(vec2(75,15)).get.target.key=="1"
      check canvasResourceCounts().geometries==baseline.geometries+1
      surface.prepareFrame(pooled(20))
      check canvasResourceCounts().geometries==baseline.geometries+2 # Pools do not cross scenes.
      check surface.presentPrepared()
      surface.discardPrepared()
      surface.maintain()
      check surface.hitDrawn(vec2(15,15)).get.target.key=="0"
      check canvasResourceCounts().geometries==baseline.geometries+1
      surface.prepareFrame(pooled(20))
      check surface.presentPrepared()
      surface.acceptPrepared()
      surface.maintain()
      check surface.hitDrawn(vec2(15,15)).isNone
      check surface.hitDrawn(vec2(25,15)).get.target.key=="0"
      check surface.hitDrawn(vec2(85,15)).get.target.key=="1"
      check canvasResourceCounts().geometries==baseline.geometries+1
      when defined(leafProtocolProbes):
        surface.failNextDrawForTest(cast[int32](0x8899000C'u32))
        surface.handlePaint(busy=false)
        check surface.needsRebuild
        check surface.hitDrawn(vec2(25,15)).isNone
        surface.recoverOnce()
        check not surface.needsRebuild
        check surface.hitDrawn(vec2(25,15)).get.target.key=="0"
        check canvasResourceCounts().geometries==baseline.geometries+1
    finally:
      surface.close();window.requestClose();check window.pump()==0
    check canvasResourceCounts()==baseline
