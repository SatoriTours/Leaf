import std/unittest
import leaf

component FiniteAnimation:
  state:
    finishes = 0
  animation:
    x = tween(0.0, 100.0, duration=100.ms, autoplay=true,
      onFinish=proc() = finishes += 1)
  view:
    column:
      text x:
        key: "x"
      text finishes:
        key: "finishes"
      button "restart":
        key: "restart"
        onClick: x.restart()
      button "seek":
        key: "seek"
        onClick: x.seek(0.5)

var finishAttempts = 0
var throwFromFinish = false
component RejectedFinish:
  state:
    finishes = 0
  animation:
    x = tween(0.0, 100.0, duration=100.ms, autoplay=true,
      onFinish=proc() =
        inc finishAttempts # Real nontransactional side effect, not a mock.
        finishes += 1
        if throwFromFinish: raise newException(UiError, "callback failed"))
  view:
    column:
      text x:
        key: "x"
      text finishes:
        key: "finishes"

suite "ordinary turn animation finish delivery":
  test "Finish follows accepted frame and is delivered once in a later turn":
    let rt = newRuntime(componentApplication(component(FiniteAnimation, ()), "finish"))
    discard rt.pumpAnimations(0)
    let done = rt.pumpAnimations(100)
    check done.deliveredFinishes == 0
    check rt.find("x").node.text == "100.0"
    check rt.find("finishes").node.text == "0"
    check rt.animationPumpPending
    check rt.pumpAnimations(100).deliveredFinishes == 1
    check rt.find("finishes").node.text == "1"
    check not rt.animationPumpPending
    check rt.pumpAnimations(200).deliveredFinishes == 0

  test "restart and seek retire a previously queued Finish":
    for action in ["restart", "seek"]:
      let rt = newRuntime(componentApplication(component(FiniteAnimation, ()), "finish"))
      discard rt.pumpAnimations(0)
      discard rt.pumpAnimations(100)
      discard rt.dispatch(action, Event(kind: click))
      check rt.pumpAnimations(101).droppedFinishes == 1
      check rt.find("finishes").node.text == "0"
      if action == "restart":
        discard rt.pumpAnimations(201)
        discard rt.pumpAnimations(202)
        check rt.find("finishes").node.text == "1"

  test "failed completed frame cannot deliver its candidate token":
    let rt = newRuntime(componentApplication(component(FiniteAnimation, ()), "finish"))
    discard rt.pumpAnimations(0)
    var reject = true
    rt.setValidator(proc(snapshot: Snapshot) =
      if reject and snapshot.root.children[0].node.text == "100.0":
        raise newException(UiError, "reject frame"))
    expect UiError: discard rt.pumpAnimations(100)
    check rt.find("finishes").node.text == "0"
    reject = false
    check rt.pumpAnimations(101).deliveredFinishes == 0
    check rt.pumpAnimations(102).deliveredFinishes == 1
    check rt.find("finishes").node.text == "1"

  test "close retires queued Finish before any callback":
    let rt = newRuntime(componentApplication(component(FiniteAnimation, ()), "finish"))
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(100)
    rt.closeRuntime()
    check rt.pumpAnimations(101).deliveredFinishes == 0

  test "rejected or throwing Finish callbacks roll State back but never replay external effects":
    for throwing in [false, true]:
      finishAttempts = 0
      throwFromFinish = throwing
      let rt = newRuntime(componentApplication(component(RejectedFinish, ()), "finish"))
      defer: rt.closeRuntime()
      discard rt.pumpAnimations(0)
      discard rt.pumpAnimations(100)
      var reject = not throwing
      rt.setValidator(proc(snapshot:Snapshot) =
        if reject and snapshot.root.children[1].node.text == "1":
          raise newException(UiError, "reject delivery turn"))
      expect UiError: discard rt.pumpAnimations(116)
      check finishAttempts == 1
      check rt.find("finishes").node.text == "0"
      reject = false
      throwFromFinish = false
      check rt.pumpAnimations(132).deliveredFinishes == 0
      check rt.pumpAnimations(148).deliveredFinishes == 0
      check finishAttempts == 1
      check rt.find("finishes").node.text == "0"
      check not rt.animationPumpPending
