import std/[unittest, options, math]
import leaf/[animation, graphics]

proc close(a, b: float64): bool = abs(a-b) < 0.000001

suite "deterministic animation sampling":
  test "sampling is pure and endpoints use elapsed time not read count":
    var t = newTimeline(tween(10.0, 30.0, duration=100.ms, autoplay=true))
    check t.sample == 10
    t.advance(25.ms)
    for i in 0..<10: check t.sample == 15
    t.advance(75.ms)
    check t.sample == 30
    check not t.playing
    check t.takeFinish == some(1'u64)
    check t.takeFinish.isNone

  test "vector size and scalar rotation share explicit easing":
    var t = newTimeline(tween(vec2(10, 20), vec2(30, 60), duration=100.ms, easing=easeInOut, autoplay=true))
    t.advance(50.ms)
    check t.sample == vec2(20, 40)
    var angle = newTimeline(tween(350.0, 10.0, duration=100.ms, autoplay=true))
    angle.advance(50.ms)
    check angle.sample == 180 # Scalar angles do not take a shortest-path shortcut.

  test "linear light premultiplied color avoids transparent dark halos":
    var t = newTimeline(tween(color("#000000"), color("#FFFFFF"), duration=100.ms, autoplay=true))
    t.advance(50.ms)
    check abs(float64(t.sample.r)-0.73535698) < 0.00001
    var alpha = newTimeline(tween(color("#FF000000"), color("#0000FFFF"), duration=100.ms, autoplay=true))
    alpha.advance(50.ms)
    check abs(float64(alpha.sample.a)-0.5) < 0.00001
    check alpha.sample.r == 0
    check alpha.sample.b == 1

  test "finite repeats count one way legs and issue Finish once":
    var t = newTimeline(tween(0.0, 10.0, duration=100.ms, repeat=times(3), autoplay=true))
    t.advance(100.ms)
    check t.sample == 0
    t.advance(150.ms)
    check t.sample == 5
    t.advance(900.ms)
    check t.sample == 10
    check t.takeFinish == some(1'u64)
    t.play()
    t.advance(100.ms)
    check t.takeFinish.isNone
    check t.sample == 10
    t.restart()
    t.advance(300.ms)
    check t.takeFinish == some(2'u64)

  test "forever and pingPong stay bounded across large skipped intervals":
    var a = newTimeline(tween(0.0, 10.0, duration=100.ms, repeat=forever, autoplay=true))
    var b = newTimeline(tween(0.0, 10.0, duration=100.ms, repeat=pingPong, autoplay=true))
    a.advance(1000000150.0.ms)
    b.advance(1000000150.0.ms)
    check a.sample == 5
    check b.sample == 5
    check a.playing and b.playing
    check a.takeFinish.isNone and b.takeFinish.isNone

  test "controls preserve order and seek neither starts nor finishes":
    var t = newTimeline(tween(0.0, 10.0, duration=100.ms))
    t.seek(0.5)
    check t.sample == 5
    check not t.playing
    t.play()
    t.advance(25.ms)
    t.pause()
    t.advance(500.ms)
    check t.sample == 7.5
    t.reset()
    check t.sample == 0
    check not t.playing
    t.seek(1)
    check t.sample == 10
    check t.takeFinish.isNone

  test "seek one exposes the leg endpoint even for repeats and zero duration":
    for mode in [times(3), forever, pingPong]:
      var t = newTimeline(tween(0.0, 10.0, duration=100.ms, repeat=mode, autoplay=true))
      t.seek(1)
      check t.sample == 10
      t.advance(0.ms)
      check t.sample == 10
      check t.takeFinish.isNone
      t.advance(10.ms)
      check t.sample.close(if mode == pingPong: 9.0 else: 1.0)
    var zero = newTimeline(tween(1.0, 2.0, duration=0.ms))
    zero.seek(1)
    check zero.sample == 2
    check not zero.playing
    check zero.takeFinish.isNone
    zero.seek(0)
    check zero.sample == 1

  test "seek suppresses stale Finish without allowing repeat delivery":
    var t = newTimeline(tween(0.0, 10.0, duration=100.ms, autoplay=true))
    t.advance(100.ms)
    t.seek(0.5)
    check t.takeFinish.isNone
    t.play()
    t.advance(50.ms)
    check t.takeFinish.isNone # Same playback generation has already ended.
    t.restart()
    t.advance(100.ms)
    check t.takeFinish == some(t.generation)

  test "zero duration is finite and cancel retires all future work":
    var t = newTimeline(tween(1.0, 2.0, duration=0.ms))
    check t.sample == 1
    t.play()
    t.advance(0.ms)
    check t.sample == 2
    check t.takeFinish == some(1'u64)
    t.cancel()
    t.restart()
    t.advance(1.ms)
    check not t.playing
    check t.takeFinish.isNone

  test "invalid inputs reject without changing the accepted value":
    expect AnimationError: discard tween(0.0, 1.0, duration=(-1).ms)
    expect AnimationError: discard tween(0.0, Inf, duration=1.ms)
    expect AnimationError: discard tween(vec2(0, 0), vec2(NaN, 1), duration=1.ms)
    expect AnimationError: discard times(0)
    expect AnimationError: discard tween(0.0, 1.0, duration=0.ms, repeat=forever)
    var t = newTimeline(tween(0.0, 1.0, duration=1.ms))
    expect AnimationError: t.seek(1.01)
    expect AnimationError: t.advance((-1).ms)
    check t.sample == 0

suite "accepted transition and shared frame clock":
  test "retarget begins at the current sample and candidate copies are isolated":
    var accepted = newTransition(0.0, duration=100.ms, easing=linear)
    check accepted.sample == 0
    accepted.retarget(10.0)
    accepted.advance(50.ms)
    check accepted.sample == 5
    var rejected = accepted
    rejected.retarget(100.0)
    rejected.advance(50.ms)
    check accepted.sample == 5
    accepted.retarget(15.0)
    check accepted.sample == 5
    accepted.advance(50.ms)
    check accepted.sample == 10
    accepted.retarget(15.0) # The same accepted target must not restart.
    accepted.advance(50.ms)
    check accepted.sample == 15
    check not accepted.active

  test "reduced motion snaps transitions and disables only automatic playback":
    var t = newTimeline(tween(0.0, 10.0, duration=100.ms, autoplay=true), reduced=true)
    check not t.playing
    t.play()
    t.advance(50.ms)
    check t.sample == 5
    var change = newTransition(0.0, duration=100.ms, reduced=true)
    change.retarget(10.0)
    check change.sample == 10
    check not change.active

  test "one shared clock freezes hidden time and rejects backwards ticks":
    var clock: AnimationClock
    check clock.tick(1000).activeMs == 0
    check clock.tick(1050).activeMs == 50
    check clock.tick(1060, visible=false).activeMs == 60
    check clock.tick(9999, visible=false).activeMs == 60
    let resumed = clock.tick(10000)
    check resumed.activeMs == 60
    check resumed.deltaMs == 0
    check clock.tick(10025).activeMs == 85
    expect AnimationError: discard clock.tick(9999)
    check clock.tick(10025).deltaMs == 0

  test "frame demand coalesces and goes idle when hidden or finished":
    var demand: AnimationDemand
    check not demand.needsFrame
    check demand.update(true)
    check demand.needsFrame
    check not demand.update(true)
    check not demand.update(true, visible=false)
    check not demand.needsFrame
    check demand.update(true, visible=true)
    check not demand.update(false)
    check not demand.needsFrame
