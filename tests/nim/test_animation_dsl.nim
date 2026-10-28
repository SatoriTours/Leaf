import std/[unittest, options]
import leaf

var starts = 0
proc first(): float64 =
  inc starts
  10.0
proc twice(x: float64): float64 = x * 2

component AnimatedControls:
  state:
    seen = 0.0
  animation:
    x = tween(first(), 110.0, duration=100.ms)
  view:
    column:
      text twice(x):
        key: "value"
      text seen:
        key: "seen"
      button "seek":
        key: "seek"
        onClick:
          x.play()
          x.seek(0.25)
          x.pause()
          seen = x
      button "reset":
        key: "reset"
        onClick:
          x.reset()
      button "throw":
        key: "throw"
        onClick:
          x.seek(1)
          seen = x
          raise newException(UiError, "reject")
      button "shadow":
        key: "shadow"
        onClick:
          let x = 42.0
          seen = twice(x)
      for x in 0..<2:
        text x:
          key: "loop-" & $x

# Removing except-alias scope from lower() must make this compile assertion fail.
template exceptionAliasScenario() {.dirty.} =
  component ExceptionAliases:
    state:
      message = "model"
      caught = 0
    animation:
      x = tween(0.0, 1.0, duration=100.ms)
    view:
      column:
        text caught:
          key: "caught"
        text message:
          key: "message"
        text x:
          key: "x"
        button "state alias":
          key: "state-alias"
          onClick:
            try:
              raise newException(ValueError, "boom")
            except ValueError as message:
              caught += message.msg.len
        button "animation alias":
          key: "animation-alias"
          onClick:
            try:
              raise newException(ValueError, "boom")
            except ValueError as x:
              caught += x.msg.len
  let aliasRuntime = newRuntime(componentApplication(component(ExceptionAliases, ()), "aliases"))
  defer: aliasRuntime.closeRuntime()
  doAssert aliasRuntime.dispatch("state-alias", Event(kind:click))
  doAssert aliasRuntime.find("caught").node.text == "4"
  doAssert aliasRuntime.dispatch("animation-alias", Event(kind:click))
  doAssert aliasRuntime.find("caught").node.text == "8"
  doAssert aliasRuntime.find("message").node.text == "model"
  doAssert aliasRuntime.find("x").node.text == "0.0"

suite "component animation lexical bindings":
  test "view samples numbers and ordered controls publish in the same transaction":
    starts = 0
    let runtime = newRuntime(componentApplication(component(AnimatedControls, ()), "animations"))
    check starts == 1
    check runtime.find("value").node.text == "20.0"
    check runtime.dispatch("seek", Event(kind: click))
    check runtime.find("value").node.text == "70.0"
    check runtime.find("seen").node.text == "35.0"
    check starts == 1
    check runtime.dispatch("reset", Event(kind: click))
    check runtime.find("value").node.text == "20.0"

  test "handler failure rolls animation and State back together":
    let runtime = newRuntime(componentApplication(component(AnimatedControls, ()), "animations"))
    expect UiError: discard runtime.dispatch("throw", Event(kind: click))
    check runtime.find("value").node.text == "20.0"
    check runtime.find("seen").node.text == "0.0"
    check runtime.dispatch("seek", Event(kind: click))
    check runtime.find("value").node.text == "70.0"

  test "local and loop names shadow animations without global conversion":
    let runtime = newRuntime(componentApplication(component(AnimatedControls, ()), "animations"))
    check runtime.find("loop-0").node.text == "0"
    check runtime.find("loop-1").node.text == "1"
    check runtime.dispatch("shadow", Event(kind: click))
    check runtime.find("seen").node.text == "84.0"
    check runtime.find("value").node.text == "20.0"

  test "animation slots are initialized per owner and never shared across instances":
    let page = defineComponent[tuple[], int]("TwoAnimatedControls",
      proc(ctx: MountContext, props: tuple[]): int = 0,
      proc(ctx: ComponentContext, props: tuple[], model: int): UiDescription =
        componentView:
          column:
            component AnimatedControls, (), key="one"
            component AnimatedControls, (), key="two")
    let runtime = newRuntime(componentApplication(component(page, ()), "animations"))
    let firstSeek = runtime.snapshot.root.children[0].children[2].id
    check runtime.dispatch(firstSeek, Event(kind: click))
    let one = runtime.snapshot.root.children[0]
    let two = runtime.snapshot.root.children[1]
    check one.children[0].node.text == "70.0"
    check two.children[0].node.text == "20.0"

  test "except aliases shadow State and animation names only inside their branch":
    check compiles(exceptionAliasScenario())
    when compiles(exceptionAliasScenario()):
      exceptionAliasScenario()

static:
  doAssert not compiles(block:
    component BadAnimationAssignment:
      animation:
        x = tween(0.0, 1.0, duration=100.ms)
      view:
        button "bad":
          onClick: x = 1.0)
  doAssert not compiles(block:
    component BadAnimationViewControl:
      animation:
        x = tween(0.0, 1.0, duration=100.ms)
      view:
        column:
          x.play()
          text x)
  doAssert not compiles(block:
    component DuplicateAnimation:
      state:
        x = 0
      animation:
        x = tween(0.0, 1.0, duration=100.ms)
      view:
        text x)
