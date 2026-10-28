## Backend-neutral, value-semantic animation primitives.
## Time is milliseconds of monotonic *active* time, never a frame count.
## Copies are isolated candidates; this module performs no callbacks or I/O.
import std/[math, options]
import ./graphics

type
  MotionPolicy* {.pure.} = enum system, full, reduced
  AnimationError* = object of CatchableError
  AnimationDuration* = distinct float64
  Easing* = enum linear, easeIn, easeOut, easeInOut
  RepeatKind = enum finite, looping, alternating
  AnimationRepeat* = object
    kind: RepeatKind
    count: int
  Tween*[T] = object
    first, last: T
    duration: float64
    easing: Easing
    repeat: AnimationRepeat
    autoplay: bool
  Timeline*[T] = object
    spec: Tween[T]
    elapsed, seekProgress: float64
    hasSeek: bool
    revision: uint64
    running, ended, retired, finishIssued, finishPending: bool
  Transition*[T] = object
    first, target: T
    elapsed, duration: float64
    easing: Easing
    moving, reduced: bool
  AnimationFrame* = object
    activeMs*, deltaMs*: float64
  AnimationClock* = object
    initialized, visible: bool
    previous, active: float64
  AnimationDemand* = object
    requested: bool

const
  once* = AnimationRepeat(kind: finite, count: 1)
  forever* = AnimationRepeat(kind: looping)
  pingPong* = AnimationRepeat(kind: alternating)

proc bad(message: string) {.noreturn.} =
  raise newException(AnimationError, message)

proc finiteNumber(value: float64): bool =
  classify(value) notin {fcNan, fcInf, fcNegInf}

proc nonnegative(value: float64) =
  if not finiteNumber(value) or value < 0:
    bad("animation time must be finite and nonnegative")

proc ms*[T: SomeNumber](value: T): AnimationDuration =
  nonnegative(float64(value))
  AnimationDuration(value)

proc milliseconds*(value: AnimationDuration): float64 = float64(value)

proc times*(count: int): AnimationRepeat =
  if count <= 0: bad("repeat count must be positive")
  AnimationRepeat(kind: finite, count: count)

proc validValue[T: SomeFloat](value: T) =
  if not finiteNumber(float64(value)): bad("animation endpoint must be finite")

proc validValue(value: Vec2) =
  validValue(value.x)
  validValue(value.y)

proc validValue(value: Color) =
  for channel in [value.r, value.g, value.b, value.a]:
    if not finiteNumber(float64(channel)) or channel < 0 or channel > 1:
      bad("animation color channels must be finite and in 0..1")

proc tween*[T: SomeFloat | Vec2 | Color](first, last: T,
    duration: AnimationDuration, easing=linear, repeat=once, autoplay=false): Tween[T] =
  validValue(first)
  validValue(last)
  let length = float64(duration)
  nonnegative(length)
  if repeat.kind == finite:
    if repeat.count <= 0: bad("repeat count must be positive")
    if not finiteNumber(length * float64(repeat.count)):
      bad("total animation duration must be finite")
  else:
    if length == 0: bad("infinite animation requires positive duration")
    if repeat.kind == alternating and not finiteNumber(length * 2):
      bad("pingPong period must be finite")
  Tween[T](first: first, last: last, duration: length,
    easing: easing, repeat: repeat, autoplay: autoplay)

proc eased(progress: float64, easing: Easing): float64 =
  case easing
  of linear: progress
  of easeIn: progress * progress
  of easeOut: 1 - (1-progress) * (1-progress)
  of easeInOut:
    if progress < 0.5: 2 * progress * progress
    else: 1 - 2 * (1-progress) * (1-progress)

proc blend[T: SomeFloat](first, last: T, progress: float64): T =
  if progress <= 0: return first
  if progress >= 1: return last
  T(float64(first) * (1-progress) + float64(last) * progress)

proc blend(first, last: Vec2, progress: float64): Vec2 =
  vec2(blend(first.x, last.x, progress), blend(first.y, last.y, progress))

proc toLinear(value: float64): float64 =
  if value <= 0.04045: value / 12.92
  else: pow((value + 0.055) / 1.055, 2.4)

proc toSrgb(value: float64): float32 =
  let value = clamp(value, 0.0, 1.0)
  float32(if value <= 0.0031308: value * 12.92
    else: 1.055 * pow(value, 1.0/2.4) - 0.055)

proc blend(first, last: Color, progress: float64): Color =
  if progress <= 0: return first
  if progress >= 1: return last
  let alpha = blend(float64(first.a), float64(last.a), progress)
  if alpha == 0: return Color()
  result.a = float32(alpha)
  result.r = toSrgb(blend(toLinear(first.r) * first.a,
    toLinear(last.r) * last.a, progress) / alpha)
  result.g = toSrgb(blend(toLinear(first.g) * first.a,
    toLinear(last.g) * last.a, progress) / alpha)
  result.b = toSrgb(blend(toLinear(first.b) * first.a,
    toLinear(last.b) * last.a, progress) / alpha)

proc newTimeline*[T](spec: Tween[T], reduced=false): Timeline[T] =
  Timeline[T](spec: spec, revision: 1, running: spec.autoplay and not reduced)

proc playing*[T](state: Timeline[T]): bool = state.running
proc generation*[T](state: Timeline[T]): uint64 = state.revision

proc sample*[T](state: Timeline[T]): T =
  let spec = state.spec
  var progress = 0.0
  if state.hasSeek:
    progress = state.seekProgress
  elif spec.duration == 0:
    if state.running or state.ended: progress = 1
  elif spec.repeat.kind == finite and
      state.elapsed >= spec.duration * float64(spec.repeat.count):
    progress = 1
  elif spec.repeat.kind == alternating:
    let phase = state.elapsed / spec.duration
    progress = (if phase <= 1: phase else: 2-phase)
  else:
    progress = (state.elapsed mod spec.duration) / spec.duration
  blend(spec.first, spec.last, eased(progress, spec.easing))

proc nextRevision[T](state: Timeline[T]): uint64 =
  if state.revision == high(uint64): bad("animation generation exhausted")
  state.revision + 1

proc play*[T](state: var Timeline[T]) =
  if not state.retired and not state.ended: state.running = true

proc pause*[T](state: var Timeline[T]) =
  state.running = false

proc restart*[T](state: var Timeline[T]) =
  if state.retired: return
  state.revision = state.nextRevision()
  state.elapsed = 0
  state.hasSeek = false
  state.running = true
  state.ended = false
  state.finishIssued = false
  state.finishPending = false

proc reset*[T](state: var Timeline[T]) =
  if state.retired: return
  state.restart()
  state.running = false

proc cancel*[T](state: var Timeline[T]) =
  if state.retired: return
  state.revision = state.nextRevision()
  state.retired = true
  state.running = false
  state.finishPending = false

proc seek*[T](state: var Timeline[T], progress: float64) =
  if not finiteNumber(progress) or progress < 0 or progress > 1:
    bad("seek position must be finite and in 0..1")
  if state.retired: return
  let spec = state.spec
  var leg = 0.0
  if spec.duration > 0:
    leg = floor(state.elapsed / spec.duration)
    if spec.repeat.kind == finite: leg = min(leg, float64(spec.repeat.count-1))
    elif spec.repeat.kind == alternating: leg = min(leg, 1.0)
  state.elapsed = (leg + progress) * spec.duration
  state.hasSeek = true
  state.seekProgress = (if spec.repeat.kind == alternating and leg == 1: 1-progress else: progress)
  state.ended = false
  state.finishPending = false

proc advance*[T](state: var Timeline[T], elapsed: AnimationDuration) =
  let delta = float64(elapsed)
  nonnegative(delta)
  if not state.running or state.retired: return
  # A zero-time presentation of seek must show the requested endpoint before
  # the next positive time step wraps a repeated leg or naturally finishes.
  if state.hasSeek and delta == 0: return
  state.hasSeek = false
  let spec = state.spec
  if spec.repeat.kind == finite:
    let total = spec.duration * float64(spec.repeat.count)
    if delta >= total - state.elapsed:
      state.elapsed = total
      state.running = false
      state.ended = true
      if not state.finishIssued:
        state.finishIssued = true
        state.finishPending = true
    else:
      state.elapsed += delta
  else:
    let period = spec.duration * (if spec.repeat.kind == alternating: 2.0 else: 1.0)
    let step = delta mod period
    # Do not overflow even when a legal period is close to float64.high.
    let remaining = period-state.elapsed
    state.elapsed = (if step >= remaining: step-remaining else: state.elapsed+step)

proc finishValidInternal*[T](state:Timeline[T],generation:uint64):bool=
  not state.retired and state.ended and state.finishIssued and
    not state.finishPending and state.revision==generation

proc takeFinish*[T](state: var Timeline[T]): Option[uint64] =
  ## A token, not a callback. A runtime must validate owner and generation and
  ## deliver it in an ordinary UI turn only after this candidate is accepted.
  if state.finishPending and not state.retired:
    state.finishPending = false
    result = some(state.revision)

proc newTransition*[T: SomeFloat | Vec2 | Color](initial: T,
    duration=180.ms, easing=easeOut, reduced=false): Transition[T] =
  validValue(initial)
  nonnegative(float64(duration))
  Transition[T](first: initial, target: initial, duration: float64(duration),
    easing: easing, reduced: reduced)

proc active*[T](state: Transition[T]): bool = state.moving

proc sample*[T](state: Transition[T]): T =
  if not state.moving or state.duration == 0: return state.target
  blend(state.first, state.target, eased(state.elapsed/state.duration, state.easing))

proc retarget*[T](state: var Transition[T], target: T) =
  validValue(target)
  if target == state.target: return
  let current = state.sample
  state.first = current
  state.target = target
  state.elapsed = 0
  state.moving = state.duration > 0 and not state.reduced

proc advance*[T](state: var Transition[T], elapsed: AnimationDuration) =
  let delta = float64(elapsed)
  nonnegative(delta)
  if not state.moving: return
  if delta >= state.duration-state.elapsed:
    state.elapsed = state.duration
    state.moving = false
  else:
    state.elapsed += delta

proc tick*(clock: var AnimationClock, monotonicMs: float64,
    visible=true): AnimationFrame =
  nonnegative(monotonicMs)
  if clock.initialized and monotonicMs < clock.previous:
    bad("animation clock must be monotonic")
  let delta = (if clock.initialized and clock.visible: monotonicMs-clock.previous else: 0.0)
  let active = clock.active + delta
  nonnegative(active)
  clock.previous = monotonicMs
  clock.active = active
  clock.visible = visible
  clock.initialized = true
  AnimationFrame(activeMs: active, deltaMs: delta)

proc needsFrame*(demand: AnimationDemand): bool = demand.requested

proc update*(demand: var AnimationDemand, active: bool, visible=true): bool =
  let requested = active and visible
  result = requested and not demand.requested
  demand.requested = requested
