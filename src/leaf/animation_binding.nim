## Internal owner-owned hooks. Registrations travel with accepted component
## instances, never a process-global registry or an independently committed map.
import std/options

type
  AnimationBinding* = ref object
    playing*: proc(): bool {.closure.}
    step*: proc(activeMs: float64, activation: uint64) {.closure.}
    finish*: proc(): Option[uint64] {.closure.}
    validFinish*: proc(generation: uint64): bool {.closure.}
    onFinish*: proc() {.closure.}
  AnimationPumpReport* = object
    sampledAnimations*, deliveredFinishes*, droppedFinishes*: int
    needsFrame*: bool

proc retireAnimationBindingInternal*(binding: AnimationBinding) {.raises: [].} =
  if binding == nil: return
  binding.onFinish = nil
  binding.playing = nil
  binding.step = nil
  binding.finish = nil
  binding.validFinish = nil
