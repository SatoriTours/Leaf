import std/[unittest, options]
import leaf
from leaf/animation import AnimationError

proc staticOnly(): Node =
  canvas:
    viewBox: (200, 200)
    group:
      key: "group"
      translate: (20, 20)
      rotate: 45.deg
      scale: (2, 2)
      transition:
        duration: 120.ms
      rect:
        position: (0, 0)
        size: (40, 20)
        transition:
          properties: [position, size, radius, fill, strokeWidth]
          easing: easeInOut
      text "文字":
        position: (0, 30)
        transition:
          properties: [position, fill]

proc separateSources() =
  component SeparateTweenAndTransition:
    animation:
      size = tween(10.0, 30.0, 100.ms)
    view:
      canvas:
        circle:
          center: (50, 50)
          radius: size
          transition:
            properties: [fill]
  discard componentApplication(component(SeparateTweenAndTransition, ()), "separate")

static:
  doAssert compiles(staticOnly())
  doAssert compiles(separateSources())
  doAssert not compiles(block:
    let drawing = canvas:
      circle:
        center: (20, 20)
        radius: 10
        transition:
          properties: [fontSize])
  doAssert not compiles(block:
    let drawing = canvas:
      circle:
        center: (20, 20)
        radius: 10
        transition:
          properties: [radius, radius])
  doAssert not compiles(block:
    let drawing = canvas:
      circle:
        center: (20, 20)
        radius: 10
        transition:
          mystery: 5)
  doAssert not compiles(block:
    let drawing = canvas:
      for i in 0..<2:
        circle:
          center: (i * 20, 20)
          radius: 10
          transition:
            duration: 100.ms)
  doAssert compiles(block:
    let drawing = canvas:
      for i in 0..<2:
        circle:
          key: $i
          center: (i * 20, 20)
          radius: 10
          transition:
            duration: 100.ms)

template explicitConflict() {.dirty.} =
  component ExplicitConflict:
    animation:
      r = tween(10.0, 30.0, 100.ms)
    view:
      canvas:
        circle:
          center: (50, 50)
          radius: r
          transition:
            properties: [radius]
template aliasConflict() {.dirty.} =
  component AliasConflict:
    animation:
      r = tween(10.0, 30.0, 100.ms)
    view:
      canvas:
        let local = r
        let twice = local * 2
        circle:
          center: (50, 50)
          radius: twice
          transition:
            properties: [radius]
proc shadowIsNotConflict() =
  component ShadowIsNotConflict:
    animation:
      r = tween(10.0, 30.0, 100.ms)
    view:
      canvas:
        let r = 20.0
        circle:
          center: (50, 50)
          radius: r
          transition:
            properties: [radius]
static:
  doAssert not compiles(explicitConflict())
  doAssert not compiles(aliasConflict())
  doAssert compiles(shadowIsNotConflict())

suite "Canvas transition declarations":
  test "metadata records component group targets without matrix decomposition":
    let frame = staticOnly().canvasFrame.get
    var definitions: seq[CanvasTransitionDefinition]
    for entry in frame.transitionDefinitionsInternal: definitions.add(entry)
    check definitions.len == 3
    check definitions[0].translation == vec2(20, 20)
    check definitions[0].rotation == 45.deg
    check definitions[0].scaling == vec2(2, 2)
    check definitions[0].durationMs == 120
    check definitions[1].easingId == ord(easeInOut)
    check definitions[2].properties == {CanvasProperty.position, CanvasProperty.fill}

  test "invalid finite duration is rejected while evaluating a real declaration":
    expect AnimationError:
      discard canvas:
        circle:
          center: (10, 10)
          radius: 5
          transition:
            duration: (-1).ms

template aliasLoopShadow() {.dirty.} =
  component AliasLoopShadow:
    animation:
      r = tween(10.0, 30.0, 100.ms)
    view:
      canvas:
        let local = r
        for local in [20.0]:
          circle:
            key: $local
            center: (50, 50)
            radius: local
            transition:
              properties: [radius]
static: doAssert compiles(aliasLoopShadow())

proc properties(value: float64): float64 = value * 2

template propertiesHelperIsOrdinary() {.dirty.} =
  component PropertiesHelperIsOrdinary:
    animation:
      r = tween(10.0, 30.0, 100.ms)
    view:
      canvas:
        circle:
          center: (50, 50)
          radius: properties(r)
          transition:
            properties: [fill]
static: doAssert compiles(propertiesHelperIsOrdinary())
