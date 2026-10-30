## Diagnostic only: identical ordered work, never an elapsed-time FPS baseline.
import std/[strutils, sets]
import leaf/vendor/checksums/sha2
import ./canvas_config

type
  FixedCanvasSchedule* = object
    warmupFrames*, sampleFrames*, cycleFrames*: int
  FixedCanvasConfig* = object
    schedule*: FixedCanvasSchedule
    producer*: CanvasConfig

proc fixedSchedule*(warmupFrames=60, sampleFrames=240, cycleFrames=120): FixedCanvasSchedule =
  if warmupFrames notin 0..600 or sampleFrames notin 1..1200 or cycleFrames notin 2..1200:
    raise newException(ValueError, "invalid bounded fixed Canvas schedule")
  FixedCanvasSchedule(warmupFrames:warmupFrames, sampleFrames:sampleFrames, cycleFrames:cycleFrames)

proc phase*(plan:FixedCanvasSchedule, index:int):float64 =
  if index<0:raise newException(ValueError,"negative fixed frame index")
  float64(index mod plan.cycleFrames)/float64(plan.cycleFrames)

proc warmupPhase*(plan:FixedCanvasSchedule, index:int):float64 =
  if index<0:raise newException(ValueError,"negative warmup frame index")
  plan.phase((plan.cycleFrames-plan.warmupFrames mod plan.cycleFrames+index mod plan.cycleFrames) mod plan.cycleFrames)

proc initialPhase*(plan:FixedCanvasSchedule):float64 =
  plan.phase((2*plan.cycleFrames-plan.warmupFrames mod plan.cycleFrames-1) mod plan.cycleFrames)

proc warmingUp*(plan:FixedCanvasSchedule, completed:int):bool = completed<plan.warmupFrames
proc complete*(plan:FixedCanvasSchedule, completed:int):bool = completed>=plan.sampleFrames

proc fingerprint*(plan:FixedCanvasSchedule):string =
  var hash=initSha_256()
  hash.update("leaf-canvas-fixed-v1\n" & $plan.cycleFrames & "\n")
  for index in 0..<plan.sampleFrames:hash.update($(index mod plan.cycleFrames) & "\n")
  $hash.digest()

proc parseFixedCanvasArgs*(args:seq[string]):FixedCanvasConfig =
  var warmup=60;var count=240;var cycle=120
  var producerArgs:seq[string]
  var seen=initHashSet[string]()
  var index=0
  while index<args.len:
    if index+1>=args.len:raise newException(ValueError,"missing diagnostic argument value")
    let key=args[index];let value=args[index+1];index+=2
    if key in seen:raise newException(ValueError,"duplicate diagnostic option: " & key)
    seen.incl(key)
    case key
    of "--warmup-frames":warmup=parseInt(value)
    of "--frames":count=parseInt(value)
    of "--cycle-frames":cycle=parseInt(value)
    of "--objects","--load","--output","--environment":producerArgs.add(@[key,value])
    else:raise newException(ValueError,"unknown diagnostic option: " & key)
  result.schedule=fixedSchedule(warmup,count,cycle)
  result.producer=parseCanvasArgs(producerArgs)
  result.producer.capacity=count
  result.producer.formal=false
