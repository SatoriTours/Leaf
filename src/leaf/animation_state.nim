## Runtime-internal animation cells. Reuses StateStore's owner identity,
## event drafts and prepare/reject/publication; no second commit protocol.
## Scheduling and Finish callback delivery are intentionally not owned here.
import std/options
import ./[core, animation, component_state, component_description, animation_binding]

type
  AnimationAnchor = object
    activeMs: float64
    activation: uint64
    valid: bool
  Animation*[T] = object
    cell: State[Timeline[T]]
    anchor: State[AnimationAnchor]
    binding: AnimationBinding
  Control = enum start, stop, rewindPlay, rewindStop, position

proc sample*[T](animation: Animation[T]): T =
  animation.cell.requireStateExecution()
  animation.cell.readAccepted().sample

proc readDraft*[T](animation: Animation[T]): T =
  animation.cell.readDraft().sample

proc value*[T](ctx: ComponentContext, animation: Animation[T]): T =
  if not ctx.ownsState(animation.cell): fail("animation belongs to another component owner")
  ctx.value(animation.cell).sample

proc control[T](animation: Animation[T], kind: Control, progress=0.0) =
  animation.cell.requireStateExecution()
  if not animation.cell.stateAlive: return
  let previous = animation.cell.readDraft()
  var next = previous
  case kind
  of start: next.play()
  of stop: next.pause()
  of rewindPlay: next.restart()
  of rewindStop: next.reset()
  of position: next.seek(progress)
  if next != previous:
    animation.cell.writeDraft(next)
    # Cursor changes share the same State attempt. Rejecting a control cannot
    # reset its accepted clock, and resuming never charges paused idle time.
    animation.anchor.writeDraft(AnimationAnchor())

proc play*[T](animation: Animation[T]) = animation.control(start)
proc pause*[T](animation: Animation[T]) = animation.control(stop)
proc restart*[T](animation: Animation[T]) = animation.control(rewindPlay)
proc reset*[T](animation: Animation[T]) = animation.control(rewindStop)
proc seek*[T](animation: Animation[T], progress: float64) =
  animation.control(position, progress)

proc advanceAnimationInternal*[T](animation: Animation[T], delta: AnimationDuration) =
  animation.cell.requireStateExecution()
  if not animation.cell.stateAlive: return
  let previous = animation.cell.readDraft()
  var next = previous
  next.advance(delta)
  if next != previous: animation.cell.writeDraft(next)

proc takeAnimationFinishInternal*[T](animation: Animation[T]): Option[uint64] =
  ## Token is only a candidate fact until its State attempt has been accepted.
  ## The scheduler must discard it on failure, revalidate owner/generation,
  ## and invoke onFinish in a later ordinary UI turn, never in publication.
  animation.cell.requireStateExecution()
  if not animation.cell.stateAlive: return
  var next = animation.cell.readDraft()
  result = next.takeFinish()
  if result.isSome: animation.cell.writeDraft(next)

proc stepAnimationInternal[T](animation:Animation[T],activeMs:float64,activation:uint64)=
  if not animation.cell.stateAlive:return
  let previous=animation.cell.readDraft()
  if not previous.playing:return
  let cursor=animation.anchor.readDraft()
  let delta=if cursor.valid and cursor.activation==activation:activeMs-cursor.activeMs else:0.0
  var next=previous
  next.advance(delta.ms)
  if next!=previous:animation.cell.writeDraft(next)
  let anchor=AnimationAnchor(activeMs:activeMs,activation:activation,valid:true)
  if anchor!=cursor:animation.anchor.writeDraft(anchor)

proc newAnimationInternal*[T](ctx:MountContext,spec:Tween[T],reduced=false):Animation[T]=
  let cell=ctx.managedStateInternal(newTimeline(spec,reduced or ctx.reducedMotionInternal))
  let anchor=ctx.managedStateInternal(AnimationAnchor())
  let controller=Animation[T](cell:cell,anchor:anchor)
  let binding=AnimationBinding(
    playing:proc():bool=cell.stateAlive and cell.readAccepted().playing,
    step:proc(activeMs:float64,activation:uint64)=controller.stepAnimationInternal(activeMs,activation),
    finish:proc():Option[uint64]=controller.takeAnimationFinishInternal(),
    validFinish:proc(generation:uint64):bool=
      cell.stateAlive and cell.readAccepted().finishValidInternal(generation))
  ctx.registerAnimationInternal(binding)
  Animation[T](cell:cell,anchor:anchor,binding:binding)

proc setAnimationFinishInternal*[T](ctx:MountContext,animation:Animation[T],callback:proc() {.closure.})=
  ctx.accountOwnedDescriptionBytes(0)
  if not ctx.ownsAnimationStateInternal(animation.cell):fail("animation belongs to another owner")
  if animation.binding==nil:fail("missing animation binding")
  animation.binding.onFinish=callback
