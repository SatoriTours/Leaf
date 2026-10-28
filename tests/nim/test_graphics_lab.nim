import std/[unittest, options, strutils]
import leaf
import ../../examples/graphics_lab/[lab, scene]

proc mounted(): Runtime =
  newRuntime(componentApplication(labDescription(),"graphics-lab"))

proc click(runtime: Runtime, key: string) =
  discard runtime.dispatch(key,Event(kind:EventKind.click))

suite "graphics laboratory actual component":
  test "paused single steps and seeking control the accepted timeline":
    let runtime = mounted()
    check not runtime.animationPumpPending
    runtime.click("step")
    check runtime.find("cursor").node.text == "0.83%"
    check not runtime.animationPumpPending
    runtime.click("seek-half")
    check runtime.find("cursor").node.text == "50.00%"
    runtime.click("play")
    discard runtime.pumpAnimations(0)
    discard runtime.pumpAnimations(1000)
    check runtime.find("cursor").node.text == "75.00%"
    runtime.click("pause")
    discard runtime.pumpAnimations(5000)
    check runtime.find("cursor").node.text == "75.00%"
    runtime.click("reset")
    check runtime.find("cursor").node.text == "0.00%"
    check not runtime.animationPumpPending
    runtime.closeRuntime()

  test "invalid percentage edits never change the accepted cursor":
    let runtime = mounted()
    runtime.click("seek-half")
    for value in ["-1","101","nan","inf","abc",""]:
      discard runtime.dispatch("seek-input",Event(kind:EventKind.change,value:value))
      discard runtime.dispatch("seek-input",Event(kind:EventKind.submit))
      check runtime.find("cursor").node.text == "50.00%"
      check runtime.find("status").node.text.contains("0–100")
    discard runtime.dispatch("seek-input",Event(kind:EventKind.change,value:" 25 "))
    discard runtime.dispatch("seek-input",Event(kind:EventKind.submit))
    check runtime.find("cursor").node.text == "25.00%"
    runtime.closeRuntime()

  test "all stress tiers submit the same real commands as the shared frozen scene":
    let runtime = mounted()
    runtime.click("seek-half")
    for count in [100,1000,10000]:
      runtime.click("count-" & $count)
      for (key,load) in [("static",LabLoad.staticFrame),("properties",LabLoad.properties),("geometry",LabLoad.geometry)]:
        runtime.click("load-" & key)
        let actual = runtime.find("drawing").node.canvasFrame.get
        let wanted = newLabScene(count=count,load=load).frameAt(0.5)
        check actual.commandCount == 3*count
        for index in 0..<actual.commandCount:
          check actual.commandAt(index) == wanted.commandAt(index)
        check runtime.find("objects").node.text == $count
        check runtime.find("commands").node.text == $(3*count)
        check runtime.find("segments").node.text == $(4*(count div 3))
    runtime.closeRuntime()

  test "parameter edits alter real geometry and reset restores demonstration":
    let runtime = mounted()
    let before = runtime.find("drawing").node.canvasFrame.get.commandAt(1).radius
    runtime.click("size-up")
    check runtime.find("drawing").node.canvasFrame.get.commandAt(1).radius > before
    runtime.click("opacity-down")
    check runtime.find("drawing").node.canvasFrame.get.commandAt(1).paint.fill.get.a == 0.75
    runtime.click("count-100")
    runtime.click("demo")
    check runtime.find("objects").node.text == "17"
    check runtime.find("commands").node.text == "49"
    runtime.closeRuntime()

  test "rejected scene replacement preserves accepted scene and cursor":
    let runtime = mounted()
    var reject = false
    runtime.setValidator(proc(snapshot:Snapshot) =
      if reject: raise newException(UiError,"reject lab candidate"))
    reject = true
    expect UiError: runtime.click("count-100")
    check runtime.find("objects").node.text == "17"
    check runtime.find("cursor").node.text == "0.00%"
    reject = false
    runtime.click("step")
    check runtime.find("objects").node.text == "17"
    check runtime.find("cursor").node.text == "0.83%"
    runtime.closeRuntime()

  test "demo transition and running tween share accepted frames and retire on close":
    let runtime = mounted()
    runtime.click("play")
    runtime.click("move-dot")
    discard runtime.pumpAnimations(0)
    discard runtime.pumpAnimations(90)
    let middle = runtime.find("drawing").node.canvasFrame.get.commandAt(48).center.x
    check middle > 100
    check middle < 860
    discard runtime.pumpAnimations(200)
    check runtime.find("drawing").node.canvasFrame.get.commandAt(48).center.x == 100
    runtime.closeRuntime()
    check not runtime.animationPumpPending
