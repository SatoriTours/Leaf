## Actual window frames. draw_ms is explicit GPUI layout+paint, not pure layout.
import std/[os,osproc,json,strutils,monotimes,times]
import leaf/[core,components,gpui_session,gpui_ffi_v2,gpui_api,gpui_bridge,process_metrics,checksum]
import ./components as workload
type NativeDriver=ref object
  host:DesktopBridge
  next:proc(sample:LeafFrameSample):bool {.closure.}
  response,error:string
proc legacyFrame(context:pointer,data:ptr uint8,len:csize_t):cstring {.cdecl,raises:[].}=
  let driver=cast[NativeDriver](context)
  try:
    var raw=newString(int(len))
    if len>0:copyMem(addr raw[0],data,int(len))
    let request=parseJson(raw)
    if request["op"].getStr!="frame":return desktopCallback(cast[pointer](driver.host),data,len)
    var sample:LeafFrameSample
    if request["elapsed_ms"].kind!=JNull:sample.elapsed_ms=request["elapsed_ms"].getFloat
    let close=driver.next(sample)
    driver.response= $(%*{"snapshot":driver.host.runtime.snapshot.toJson(),"rows":[],"close":close})
    driver.response.cstring
  except Exception as failure:
    driver.error=failure.msg
    nil
proc main():int=
  when not defined(release):fail("native benchmark needs -d:release")
  let mode=getEnv("LEAF_BENCH_MODE","managed-typed")
  let size=parseInt(getEnv("LEAF_BENCH_STATIC","1000"))
  let iterations=parseInt(getEnv("LEAF_BENCH_ITERATIONS","200"))
  let warmup=parseInt(getEnv("LEAF_BENCH_WARMUP","50"))
  let rounds=parseInt(getEnv("LEAF_BENCH_ROUNDS","3"))
  if mode notin ["legacy-json","legacy-typed","managed-typed"] or iterations notin 1..10000 or warmup notin 1..100000 or rounds notin 1..100 or size notin [100,1000,5000]:fail("invalid native parameters")
  let library=getEnv("LEAF_GPUI_LIBRARY")
  let api=loadGpui(library)
  type Observation=object
    frame:LeafFrameSample
    dispatchMs:float64
  var samples=newSeqOfCap[Observation](iterations*rounds)
  var rt:Runtime
  var performed=0
  var pending=false
  var closed=false
  var lastDispatchMs=0.0
  var error:string
  let before=observeProcess()
  proc next(sample:LeafFrameSample):bool=
    if pending:
      if rt.find("counter").node.text!= $performed:fail("native update lost")
      if performed>warmup:samples.add(Observation(frame:sample,dispatchMs:lastDispatchMs))
    if performed==warmup+iterations*rounds:closed=true;return true
    let start=getMonoTime()
    discard rt.dispatch("counter",Event(kind:click))
    lastDispatchMs=float64((getMonoTime()-start).inNanoseconds)/1_000_000
    inc performed;pending=true
  if mode=="legacy-json":
    let host=newDesktopBridge(workload.makeLegacyBenchmarkApplication(size))
    rt=host.runtime
    let driver=NativeDriver(host:host,next:next)
    let tree= $rt.snapshot.toJson()
    result=api.frames(cast[ptr uint8](tree.cstring),csize_t(tree.len),legacyFrame,cast[pointer](driver))
    error=driver.error
  else:
    let app=if mode=="managed-typed":componentApplication(workload.makeBenchmarkDescription(size),"components") else:workload.makeLegacyBenchmarkApplication(size)
    rt=newRuntime(app)
    let session=openGpuiSession(rt,api)
    session.onFrame=proc(sample:LeafFrameSample):bool=next(sample)
    result=session.run()
  let after=observeProcess()
  if result!=0 or not closed or samples.len!=iterations*rounds:fail("native benchmark incomplete: " & error)
  var raw=newJArray()
  for observation in samples:
    let s=observation.frame
    raw.add(%*{"frame_ms":s.elapsed_ms,"dispatch_including_ffi_ms":observation.dispatchMs,
      "rust_prepare_ms":(if mode=="legacy-json":newJNull() else: %s.rust_prepare_ms),
      "rust_apply_ms":(if mode=="legacy-json":newJNull() else: %s.rust_apply_ms),
      "gpui_draw_layout_and_paint_ms":(if mode=="legacy-json":newJNull() else: %s.draw_ms),
      "pure_layout_ms":newJNull(),"host_renders":(if mode=="legacy-json":newJNull() else: %s.host_renders)})
  let output=getEnv("LEAF_BENCH_OUTPUT","/tmp/leaf-native-components.json")
  writeFile(output,(%*{"schema":"leaf-native-components-1","mode":mode,"static":size,"iterations":iterations,"warmup":warmup,"rounds":rounds,
    "abi":(if mode=="legacy-json":1 else:2),"cache":getEnv("LEAF_GPUI_CACHE","1"),"compiler":"Nim " & NimVersion,
    "commit":execProcess("git",args= @["rev-parse","HEAD"],options={poUsePath}).strip(),"source_dirty":true,"binary_sha256":sha256File(getAppFilename()),
    "rust_profile":getEnv("LEAF_BENCH_RUST_PROFILE","debug"),"library_sha256":sha256File(library),"platform":hostOS,
    "scope":"actual software-rendered window event-to-frame; typed draw samples explicitly draw layout+paint together; pure layout unavailable",
    "checks_passed":true,"samples":raw,"resources":resourceRecord(before,after)}).pretty & "\n")
when isMainModule:
  try:quit(main())
  except CatchableError as error:stderr.writeLine(error.msg);quit(1)
