import std/unittest
import leaf

component TwoClocks:
  animation:
    x = tween(0.0, 100.0, duration=100.ms, autoplay=true)
    y = tween(0.0, 200.0, duration=100.ms, autoplay=true)
  view:
    column:
      text x:
        key: "x"
      text y:
        key: "y"
      button "pause":
        key: "pause"
        onClick:
          x.pause()
          y.pause()
      button "play":
        key: "play"
        onClick:
          x.play()
          y.play()
      button "seek":
        key: "seek"
        onClick:
          x.seek(0.25)
          y.seek(0.25)

proc routed():tuple[runtime:Runtime,navigation:ComponentRouter]=
  var navigation:ComponentRouter
  let navigator=defineComponent[int,int]("AnimatedNavigator",
    proc(ctx:MountContext,props:int):int=
      navigation=newComponentRouter(ctx,@[
        Route(name:"A",path:"/A",page:"A",view:"main"),
        Route(name:"B",path:"/B",page:"B",view:"main")],@[
        ComponentPageDefinition(name:"A",views: @["main"],build:proc(view:string):UiDescription=component(TwoClocks,())),
        ComponentPageDefinition(name:"B",views: @["main"],build:proc(view:string):UiDescription=host(text("other",key="other")))],"A")
      0,
    proc(ctx:ComponentContext,props,model:int):UiDescription=renderPage(ctx,navigation))
  result.runtime=newRuntime(componentApplication(component(navigator,0),"routes"))
  result.navigation=navigation

suite "accepted shared animation frames":
  test "all animations sample one time and completed owners go idle":
    let runtime = newRuntime(componentApplication(component(TwoClocks, ()), "clocks"))
    check runtime.animationPumpPending
    check runtime.pumpAnimations(1000).sampledAnimations == 2
    discard runtime.pumpAnimations(1025)
    check runtime.find("x").node.text == "25.0"
    check runtime.find("y").node.text == "50.0"
    discard runtime.pumpAnimations(1200)
    check runtime.find("x").node.text == "100.0"
    check runtime.find("y").node.text == "200.0"
    check not runtime.animationPumpPending

  test "paused idle time is not charged when explicitly resumed":
    let runtime = newRuntime(componentApplication(component(TwoClocks, ()), "clocks"))
    discard runtime.pumpAnimations(0)
    discard runtime.pumpAnimations(25)
    discard runtime.dispatch("pause", Event(kind: click))
    check not runtime.animationPumpPending
    discard runtime.pumpAnimations(5000)
    discard runtime.dispatch("play", Event(kind: click))
    discard runtime.pumpAnimations(6000)
    check runtime.find("x").node.text == "25.0"
    discard runtime.pumpAnimations(6010)
    check runtime.find("x").node.text == "35.0"

  test "hidden window freezes at its visibility boundary without replay":
    let runtime = newRuntime(componentApplication(component(TwoClocks, ()), "clocks"))
    discard runtime.pumpAnimations(0)
    discard runtime.pumpAnimations(20)
    discard runtime.pumpAnimations(30, visible=false)
    discard runtime.pumpAnimations(5000, visible=false)
    check runtime.find("x").node.text == "20.0"
    discard runtime.pumpAnimations(6000)
    check runtime.find("x").node.text == "30.0"
    discard runtime.pumpAnimations(6010)
    check runtime.find("x").node.text == "40.0"

  test "failed frame preserves accepted anchors and catches up on next successful time":
    let runtime = newRuntime(componentApplication(component(TwoClocks, ()), "clocks"))
    discard runtime.pumpAnimations(0)
    runtime.setValidator(proc(snapshot: Snapshot) =
      if snapshot.root.children[0].node.text == "25.0":
        raise newException(UiError, "reject frame"))
    expect UiError: discard runtime.pumpAnimations(25)
    check runtime.find("x").node.text == "0.0"
    discard runtime.pumpAnimations(50)
    check runtime.find("x").node.text == "50.0"

  test "seek displays requested position and the next frame does not eat paused time":
    let runtime = newRuntime(componentApplication(component(TwoClocks, ()), "clocks"))
    discard runtime.pumpAnimations(0)
    discard runtime.pumpAnimations(25)
    discard runtime.dispatch("seek", Event(kind: click))
    check runtime.find("x").node.text == "25.0"
    discard runtime.pumpAnimations(90)
    check runtime.find("x").node.text == "25.0"
    discard runtime.pumpAnimations(100)
    check runtime.find("x").node.text == "35.0"

  test "closed runtime cannot request frames or pump callbacks":
    let runtime = newRuntime(componentApplication(component(TwoClocks, ()), "clocks"))
    runtime.closeRuntime()
    check not runtime.animationPumpPending
    check runtime.pumpAnimations(100).sampledAnimations == 0

  test "retained hidden owners resume without charging another page's time":
    let (rt, navigation)=routed()
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(25)
    rt.uiTask(proc()=discard navigation.navigate("B"))
    check not rt.animationPumpPending
    discard rt.pumpAnimations(5000)
    rt.uiTask(proc()=discard navigation.navigate("A"))
    discard rt.pumpAnimations(6000)
    check rt.find("x").node.text=="25.0"
    discard rt.pumpAnimations(6010)
    check rt.find("x").node.text=="35.0"

  test "a hide and reactivate with no intermediate frame still changes activation epoch":
    let (rt, navigation)=routed()
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(25)
    rt.uiTask(proc()=discard navigation.navigate("B"))
    rt.uiTask(proc()=discard navigation.navigate("A"))
    discard rt.pumpAnimations(5000)
    check rt.find("x").node.text=="25.0"

  test "rejected pause keeps the previous accepted cursor for subsequent elapsed time":
    let rt=newRuntime(componentApplication(component(TwoClocks,()),"reject pause"))
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(25)
    var reject=false
    rt.setValidator(proc(snapshot:Snapshot)=
      if reject:raise newException(UiError,"reject pause"))
    reject=true
    expect UiError:discard rt.dispatch("pause",Event(kind:click))
    reject=false
    discard rt.pumpAnimations(50)
    check rt.find("x").node.text=="50.0"

  test "reduced policy prevents automatic start but preserves explicit play":
    let app=componentApplication(component(TwoClocks,()),"reduced").withMotionPolicy(MotionPolicy.reduced)
    let rt=newRuntime(app)
    check not rt.animationPumpPending
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(50)
    check rt.find("x").node.text=="0.0"
    discard rt.dispatch("play",Event(kind:click))
    discard rt.pumpAnimations(100)
    discard rt.pumpAnimations(125)
    check rt.find("x").node.text=="25.0"
