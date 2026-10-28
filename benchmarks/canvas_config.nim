## Bounded, shell-free standalone producer parameters. Durations in milliseconds.
import std/[strutils,sets,math]

type CanvasConfig* = object
  objects*,warmupMs*,sampleMs*,capacity*:int
  loadName*,output*,environment*:string
  formal*:bool
const CanvasCadenceMs* = 1000.0/60.0

proc parseCanvasArgs*(args:seq[string]):CanvasConfig =
  result=CanvasConfig(objects:1000,loadName:"properties",warmupMs:5000,sampleMs:30000)
  var seen=initHashSet[string]()
  var i=0
  while i<args.len:
    if i+1>=args.len:raise newException(ValueError,"missing argument value")
    let key=args[i];let value=args[i+1];i+=2
    if key in seen:raise newException(ValueError,"duplicate producer option: " & key)
    seen.incl(key)
    case key
    of "--objects":result.objects=parseInt(value)
    of "--load":result.loadName=value
    of "--warmup-ms":result.warmupMs=parseInt(value)
    of "--sample-ms":result.sampleMs=parseInt(value)
    of "--output":result.output=value
    of "--environment":result.environment=value
    else:raise newException(ValueError,"unknown producer option: " & key)
  if result.objects notin [100,1000,10000] or result.loadName notin ["staticFrame","properties","geometry"] or
      result.warmupMs notin 0..60000 or result.sampleMs notin 100..120000 or
      result.output.len notin 1..2048 or result.environment.len notin 1..2048:
    raise newException(ValueError,"invalid frozen producer parameters")
  result.capacity=int(ceil(float64(result.sampleMs)/CanvasCadenceMs))+4
  result.formal=result.warmupMs>=5000 and result.sampleMs>=30000
