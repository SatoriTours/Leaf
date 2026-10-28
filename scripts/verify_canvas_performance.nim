## nim c -d:release --path:src scripts/verify_canvas_performance.nim
import std/[os,json,sets]
import ../benchmarks/canvas_verify
proc main() =
  var input,output,baseline:string
  var formal=false
  var seen=initHashSet[string]()
  let args=commandLineParams()
  var i=0
  while i<args.len:
    let key=args[i];inc i
    if key in seen:raise newException(ValueError,"duplicate option")
    seen.incl(key)
    if key=="--require-formal":formal=true;continue
    if i>=args.len:raise newException(ValueError,"missing argument value")
    let value=args[i];inc i
    case key
    of "--index":input=value
    of "--output":output=value
    of "--baseline":baseline=value
    else:raise newException(ValueError,"unknown verifier option")
  if input.len==0 or output.len==0 or fileExists(output):
    raise newException(ValueError,"provide --index and a new --output file")
  let verified=verifyCanvasIndex(input,formal)
  var summary=verified.summary
  if baseline.len>0:summary["comparison"]=compareCanvasIndices(verified,verifyCanvasIndex(baseline,true))
  writeFile(output,pretty(summary) & "\n")
  echo summary["status"].getStr
when isMainModule:
  try:main()
  except CatchableError as error:stderr.writeLine(error.msg);quit(1)
