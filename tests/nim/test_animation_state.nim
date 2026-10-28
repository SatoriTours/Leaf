import std/[unittest, options]
import leaf/[core, animation, animation_state, component_state, component_description]

proc make(store: StateStore, owner: uint64): Animation[float64] =
  store.setPhase(StatePhase.initializing)
  result = newAnimationInternal(newMountContext(store, owner),
    tween(0.0, 100.0, duration=100.ms))
  store.setPhase(StatePhase.idle)

suite "owner-bound animation control transactions":
  test "ordered controls share a draft but failed acceptance preserves playback":
    let store = newStateStore(1)
    let a = store.make(10)
    a.play()
    a.seek(0.25)
    a.pause()
    check a.readDraft == 25
    check a.sample == 0
    let rejected = store.beginAttempt()
    store.setPhase(StatePhase.rendering)
    check newComponentContext(store, rejected, 10).value(a) == 25
    store.setPhase(StatePhase.idle)
    store.reject(rejected)
    check a.sample == 0
    check a.readDraft == 0
    a.play()
    a.seek(0.5)
    let accepted = store.beginAttempt()
    store.accept(accepted)
    check a.sample == 50
    a.advanceAnimationInternal(10.ms)
    let frame = store.beginAttempt()
    store.accept(frame)
    check a.sample == 60

  test "frame failure cannot consume a natural Finish":
    let store = newStateStore(1)
    let a = store.make(10)
    a.play()
    store.accept(store.beginAttempt())
    a.advanceAnimationInternal(100.ms)
    check a.takeAnimationFinishInternal == some(1'u64)
    let rejected = store.beginAttempt()
    store.reject(rejected)
    check a.sample == 0
    a.advanceAnimationInternal(100.ms)
    check a.takeAnimationFinishInternal == some(1'u64)
    store.accept(store.beginAttempt())
    check a.sample == 100
    check a.takeAnimationFinishInternal.isNone

  test "owner teardown retires controls and frames without affecting another owner":
    let store = newStateStore(1)
    let a = store.make(10)
    let b = store.make(20)
    a.play()
    b.seek(0.5)
    store.disposeOwner(10)
    a.restart()
    a.advanceAnimationInternal(100.ms)
    check a.takeAnimationFinishInternal.isNone
    store.accept(store.beginAttempt())
    check b.sample == 50

  test "render cannot mutate controls or consume finish and foreign context cannot read":
    let store = newStateStore(1)
    let a = store.make(10)
    let attempt = store.beginAttempt()
    store.setPhase(StatePhase.rendering)
    let ctx = newComponentContext(store, attempt, 20)
    expect UiError: a.play()
    expect UiError: a.seek(0.5)
    expect UiError: a.advanceAnimationInternal(1.ms)
    expect UiError: discard a.takeAnimationFinishInternal()
    expect UiError: discard ctx.value(a)
    store.setPhase(StatePhase.idle)
    store.reject(attempt)

  test "idle frames and already paused controls never queue owners":
    let store = newStateStore(1)
    let a = store.make(10)
    a.advanceAnimationInternal(100.ms)
    a.pause()
    check store.pendingOwners.len == 0
    a.play()
    a.advanceAnimationInternal(100.ms)
    discard a.takeAnimationFinishInternal()
    store.accept(store.beginAttempt())
    a.advanceAnimationInternal(100.ms)
    a.play() # play after natural end is not restart.
    check store.pendingOwners.len == 0

  test "invalid control does not overwrite earlier valid draft":
    let store = newStateStore(1)
    let a = store.make(10)
    a.seek(0.25)
    expect AnimationError: a.seek(2)
    check a.readDraft == 25
    store.clearQueued()
    check a.readDraft == 0
