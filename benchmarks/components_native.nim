## Native GPUI frame benchmark for the unique managed runtime. draw_ms is
## explicit layout+paint, not pure layout.
import std/[os,osproc,json,strutils,monotimes,times]
import leaf/[core,components,gpui_session,gpui_ffi_v2,gpui_api,process_metrics,checksum]
import ./components as workload
proc main():int=
  when not defined(release):fail("native benchmark needs -d:release")
  let size=parseInt(getEnv("LEAF_BENCH_STATIC","1000"))
  let iterations=parseInt(getEnv("LEAF_BENCH_ITERATIONS","200"))
  let warmup=parseInt(getEnv("LEAF_BENCH_WARMUP","50"))
  let rounds=parseInt(getEnv("LEAF_BENCH_ROUNDS","3"))
  if iterations notin 1..10000 or warmup notin 1..100000 or rounds notin 1..100 or size notin [100,1000,5000]:fail("invalid native parameters")
  let api=loadGpui(getEnv("LEAF_GPUI_LIBRARY"))
  type Observation=object
    frame:LeafFrameSample
    dispatchMs:float64
  var samples=newSeqOfCap[Observation](iterations*rounds)
  var performed=0
  var pending=false
  var closed=false
  var lastDispatchMs=0.0
  let before=observeProcess()
  let rt=newRuntime(componentApplication(workload.makeBenchmarkDescription(size),"components"))
  let session=openGpuiSession(rt,api)
  session.onFrame=proc(sample:LeafFrameSample):bool=
    if pending:
      if rt.find("counter").node.text!= $performed:fail("native update lost")
      if performed>warmup:samples.add(Observation(frame:sample,dispatchMs:lastDispatchMs))
    if performed==warmup+iterations*rounds:closed=true;return true
    let start=getMonoTime()
    discard rt.dispatch("counter",Event(kind:click))
    lastDispatchMs=float64((getMonoTime()-start).inNanoseconds)/1_000_000
    inc performed;pending=true
    false
  result=session.run()
  let after=observeProcess()
  if result!=0 or not closed or samples.len!=iterations*rounds:fail("native benchmark incomplete")
  var raw=newJArray()
  for observation in samples:
    let s=observation.frame
    raw.add(%*{"frame_ms":s.elapsed_ms,"dispatch_including_ffi_ms":observation.dispatchMs,
      "rust_prepare_ms":s.rust_prepare_ms,"rust_apply_ms":s.rust_apply_ms,
      "gpui_draw_layout_and_paint_ms":s.draw_ms,"pure_layout_ms":newJNull(),
      "host_renders":s.host_renders})
  let output=getEnv("LEAF_BENCH_OUTPUT","/tmp/leaf-native-components.json")
  writeFile(output,(%*{"schema":"leaf-native-components-1","mode":"managed-typed","static":size,
    "iterations":iterations,"warmup":warmup,"rounds":rounds,"abi":2,
    "cache":getEnv("LEAF_GPUI_CACHE","1"),"compiler":"Nim " & NimVersion,
    "commit":execProcess("git",args= @["rev-parse","HEAD"],options={poUsePath}).strip(),
    "source_dirty":true,"binary_sha256":sha256File(getAppFilename()),
    "resources":resourceRecord(before,after),"samples":raw}).pretty & "\n")
  echo "native components benchmark: ", output
  result=0
when isMainModule: quit(main())
