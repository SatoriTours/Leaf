import std/unittest
import leaf
import leaf/[backend, backend_session, native_host_adapter]
import leaf/backends/headless
import std/tables

var targetEvaluations = 0
proc targetRadius(value: float64): float64 =
  inc targetEvaluations
  value

component TransitionDot:
  state:
    radius = 10.0
  view:
    column:
      canvas:
        key: "drawing"
        viewBox: (200, 200)
        circle:
          key: "dot"
          center: (100, 100)
          radius: targetRadius(radius)
          fill: "#000000"
          transition:
            properties: [radius, fill]
            duration: 100.ms
            easing: linear
      text radius:
        key: "target"
      button "grow":
        key: "grow"
        onClick: radius = 30.0
      button "small":
        key: "small"
        onClick: radius = 10.0

proc radiusAt(rt: Runtime): float64 =
  rt.find("drawing").node.canvasFrame.get.commandAt(0).radius

suite "Canvas accepted presentation transitions":
  test "initial value is immediate and later presentation frames never re-evaluate target view":
    targetEvaluations = 0
    let rt = newRuntime(componentApplication(component(TransitionDot, ()), "transition"))
    defer: rt.closeRuntime()
    check rt.radiusAt == 10.0
    check not rt.animationPumpPending
    check rt.dispatch("grow", Event(kind: click))
    check rt.find("target").node.text == "30.0"
    check rt.radiusAt == 10.0
    let evaluations = targetEvaluations
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(50)
    check rt.radiusAt == 20.0
    check targetEvaluations == evaluations
    discard rt.pumpAnimations(100)
    check rt.radiusAt == 30.0
    check not rt.animationPumpPending

  test "retarget starts from current accepted sample rather than the previous target":
    let rt = newRuntime(componentApplication(component(TransitionDot, ()), "transition"))
    defer: rt.closeRuntime()
    discard rt.dispatch("grow", Event(kind: click))
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(50)
    discard rt.dispatch("small", Event(kind: click))
    check rt.radiusAt == 20.0
    discard rt.pumpAnimations(50)
    discard rt.pumpAnimations(100)
    check rt.radiusAt == 15.0
    discard rt.pumpAnimations(150)
    check rt.radiusAt == 10.0

  test "a rejected target cannot start a transition":
    let rt = newRuntime(componentApplication(component(TransitionDot, ()), "transition"))
    defer: rt.closeRuntime()
    rt.setValidator(proc(snapshot: Snapshot) =
      if snapshot.root.children[1].node.text == "30.0":
        raise newException(UiError, "reject target"))
    expect UiError: discard rt.dispatch("grow", Event(kind: click))
    check rt.radiusAt == 10.0
    check not rt.animationPumpPending

  test "a rejected presentation frame keeps the accepted anchor and catches up once":
    let rt = newRuntime(componentApplication(component(TransitionDot, ()), "transition"))
    defer: rt.closeRuntime()
    discard rt.dispatch("grow", Event(kind: click))
    discard rt.pumpAnimations(0)
    var reject = false
    rt.setValidator(proc(snapshot: Snapshot) =
      if reject: raise newException(UiError, "reject frame"))
    reject = true
    expect UiError: discard rt.pumpAnimations(50)
    check rt.radiusAt == 10.0
    reject = false
    discard rt.pumpAnimations(75)
    check rt.radiusAt == 25.0

  test "window hidden time freezes and reduced policy skips transitions":
    let rt = newRuntime(componentApplication(component(TransitionDot, ()), "transition"))
    defer: rt.closeRuntime()
    discard rt.dispatch("grow", Event(kind: click))
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(50)
    discard rt.pumpAnimations(50, false)
    discard rt.pumpAnimations(5000, false)
    discard rt.pumpAnimations(5000)
    check rt.radiusAt == 20.0
    discard rt.pumpAnimations(5050)
    check rt.radiusAt == 30.0
    let reduced = newRuntime(componentApplication(component(TransitionDot, ()), "reduced")
      .withMotionPolicy(MotionPolicy.reduced))
    defer: reduced.closeRuntime()
    discard reduced.dispatch("grow", Event(kind: click))
    check reduced.radiusAt == 30.0
    check not reduced.animationPumpPending

component RichTransition:
  state:
    changed = false
    identity = "original"
  view:
    column:
      canvas:
        key: "rich"
        viewBox: (200, 200)
        group:
          key: "group"
          translate: (if changed: (20, 30) else: (0, 0))
          rotate: (if changed: 360 else: 0).deg
          scale: (if changed: (2, 3) else: (1, 1))
          transition:
            duration: 100.ms
            easing: linear
          rect:
            key: "box"
            position: (if changed: (100, 20) else: (0, 0))
            size: (if changed: (30, 40) else: (10, 20))
            radius: (if changed: 6 else: 2)
            fill: (if changed: "#FFFFFF" else: "#000000")
            stroke: (if changed: "#00FF00" else: "#FF0000")
            strokeWidth: (if changed: 3 else: 1)
            transition:
              duration: 100.ms
              easing: linear
          circle:
            key: identity
            center: (if changed: (30, 30) else: (10, 10))
            radius: (if changed: 30 else: 10)
            transition:
              duration: 100.ms
              easing: linear
      button "change":
        key: "change"
        onClick: changed = true
      button "replace":
        key: "replace"
        onClick: identity = "replacement"

proc routedTransition(): tuple[runtime: Runtime, navigation: ComponentRouter] =
  var navigation: ComponentRouter
  let navigator = defineComponent[int, int]("TransitionNavigator",
    proc(ctx: MountContext, props: int): int =
      navigation = newComponentRouter(ctx, @[
        Route(name: "A", path: "/A", page: "A", view: "main"),
        Route(name: "B", path: "/B", page: "B", view: "main")], @[
        ComponentPageDefinition(name: "A", views: @["main"], build: proc(view: string): UiDescription = component(TransitionDot, ())),
        ComponentPageDefinition(name: "B", views: @["main"], build: proc(view: string): UiDescription = host(text("other", key="other")))], "A")
      0,
    proc(ctx: ComponentContext, props, model: int): UiDescription = renderPage(ctx, navigation))
  result.runtime = newRuntime(componentApplication(component(navigator, 0), "routes"))
  result.navigation = navigation

suite "Canvas transition typed properties and lifetime":
  test "one frame interpolates geometry, paint and raw angle consistently":
    let rt = newRuntime(componentApplication(component(RichTransition, ()), "rich"))
    defer: rt.closeRuntime()
    discard rt.dispatch("change", Event(kind: click))
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(50)
    let frame = rt.find("rich").node.canvasFrame.get
    let transform = frame.commandAt(0).transform
    check abs(transform.xx + 1.5) < 0.000001
    check abs(transform.yy + 2.0) < 0.000001
    check transform.dx == 10
    check transform.dy == 15
    let box = frame.commandAt(1)
    check box.position == vec2(50, 10)
    check box.size == vec2(20, 30)
    check box.radius == 4
    check box.paint.strokeWidth == 2
    check abs(box.paint.fill.get.r - 0.735357) < 0.00001
    check abs(box.paint.stroke.get.r - 0.735357) < 0.00001
    check abs(box.paint.stroke.get.g - 0.735357) < 0.00001
    check frame.commandAt(2).center == vec2(20, 20)
    check frame.commandAt(2).radius == 20

  test "replacement key starts directly at its new value without resetting other tracks":
    let rt = newRuntime(componentApplication(component(RichTransition, ()), "rich"))
    defer: rt.closeRuntime()
    discard rt.dispatch("change", Event(kind: click))
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(50)
    discard rt.dispatch("replace", Event(kind: click))
    let frame = rt.find("rich").node.canvasFrame.get
    check frame.commandAt(2).radius == 30
    check frame.commandAt(1).radius == 4
    discard rt.pumpAnimations(75)
    check rt.find("rich").node.canvasFrame.get.commandAt(1).radius == 5

  test "retained owner freezes even if no frame occurs while it is hidden":
    let (rt, navigation) = routedTransition()
    defer: rt.closeRuntime()
    discard rt.dispatch("grow", Event(kind: click))
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(50)
    rt.uiTask(proc() = discard navigation.navigate("B"))
    check not rt.animationPumpPending
    rt.uiTask(proc() = discard navigation.navigate("A"))
    discard rt.pumpAnimations(5000)
    check rt.radiusAt == 20
    discard rt.pumpAnimations(5050)
    check rt.radiusAt == 30
    rt.closeRuntime()
    check not rt.animationPumpPending

proc opaqueDrawing(value: float64): UiDescription =
  let drawing = canvas:
    key: "opaque"
    circle:
      center: (50, 50)
      radius: value
      transition:
        properties: [radius]
        duration: 100.ms
  host(drawing)
component OpaqueTweenDriver:
  animation:
    r = tween(10.0, 30.0, duration=100.ms, autoplay=true)
  view:
    opaqueDrawing(r)

suite "Canvas transition driver boundary":
  test "an opaque numeric helper cannot silently retarget transitions on every tween frame":
    let rt = newRuntime(componentApplication(component(OpaqueTweenDriver, ()), "opaque"))
    defer: rt.closeRuntime()
    discard rt.pumpAnimations(0)
    expect GraphicsError: discard rt.pumpAnimations(50)
    check rt.find("opaque").node.canvasFrame.get.commandAt(0).radius == 10

component MixedDrivers:
  state:
    radius = 10.0
  animation:
    x = tween(40.0, 160.0, duration=100.ms, autoplay=true)
  view:
    column:
      canvas:
        key: "mixed"
        circle:
          center: (x, 50)
          radius: radius
          transition:
            properties: [radius]
            duration: 100.ms
            easing: linear
      button "grow":
        key: "mixed-grow"
        onClick: radius = 30.0

suite "Canvas transition existing backend transaction":
  test "prepare and partial apply rejection preserve both presentation and accepted anchor":
    let rt = newRuntime(componentApplication(component(TransitionDot, ()), "backend"))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend,
      HostContext(sessionId: 79, mountGeneration: 1, contentWidth: 400, contentHeight: 300, scale: 1))
    defer:
      session.dispose()
      rt.closeRuntime()
    let handle = session.handleFor(rt.find("drawing").id)
    discard rt.dispatch("grow", Event(kind: click))
    discard rt.pumpAnimations(0)
    recording.failPrepare = true
    expect UiError: discard rt.pumpAnimations(50)
    recording.failPrepare = false
    check rt.radiusAt == 10
    check recording.entities[handle].canvas.get.commandAt(0).radius == 10
    recording.failApplyAt = 1
    expect UiError: discard rt.pumpAnimations(75)
    recording.failApplyAt = 0
    check rt.radiusAt == 10
    check recording.entities[handle].canvas.get.commandAt(0).radius == 10
    discard rt.pumpAnimations(100)
    check rt.radiusAt == 30
    check recording.entities[handle].canvas.get.commandAt(0).radius == 30
    check not session.faulted

  test "a tween and a different transitioned property share exactly one accepted host batch":
    let rt = newRuntime(componentApplication(component(MixedDrivers, ()), "mixed"))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend,
      HostContext(sessionId: 80, mountGeneration: 1, contentWidth: 400, contentHeight: 300, scale: 1))
    defer:
      session.dispose()
      rt.closeRuntime()
    discard rt.dispatch("mixed-grow", Event(kind: click))
    discard rt.pumpAnimations(0)
    let applied = recording.applyCalls
    discard rt.pumpAnimations(50)
    check recording.applyCalls == applied + 1
    let frame = rt.find("mixed").node.canvasFrame.get
    check frame.commandAt(0).center == vec2(100, 50)
    check frame.commandAt(0).radius == 20
    let handle = session.handleFor(rt.find("mixed").id)
    check recording.entities[handle].canvas.get == frame
