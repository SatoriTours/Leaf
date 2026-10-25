## CPU managed-runtime and host-batch preparation only; no native drawing.
import std/[os,osproc,json,strutils,monotimes,times]
import leaf/[core,widgets,components,host_session,managed_runtime,process_metrics,checksum]
var counter:State[int]
let Counter* = defineComponent[int,State[int]]("BenchCounter",
  proc(ctx:MountContext,p:int):State[int]=
    result=ctx.state(0);counter=result,
  proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription=
    let n=ctx.value(s)
    host(button($n,key="counter",onClick=(proc(e:Event)=s.update(proc(n:int):int=n+1)),styles=style({"width":"200","height":"36"}))))
let Static=defineComponent[int,int]("BenchStatic",
  proc(ctx:MountContext,p:int):int=p,
  proc(ctx:ComponentContext,p,m:int):UiDescription=host(text($m,key="static-leaf",styles=style({"width":"100","height":"20"}))))
let MemoStatic* = memo(Static,proc(a,b:int):bool=a==b)
proc milliseconds(start:MonoTime):float64=float64((getMonoTime()-start).inNanoseconds)/1_000_000
proc difference(a,b:UpdateStats):UpdateStats=
  result=UpdateStats(componentRenders:a.componentRenders-b.componentRenders,visitedHosts:a.visitedHosts-b.visitedHosts,
    normalizedHosts:a.normalizedHosts-b.normalizedHosts,indexEdits:a.indexEdits-b.indexEdits,
    ops:a.ops-b.ops,ffiBytes:a.ffiBytes-b.ffiBytes,snapshotExports:a.snapshotExports-b.snapshotExports)
proc allocations(stats:AllocStats):int=
  for name,value in fieldPairs(stats):
    when name=="allocCount":result=value
proc makeBenchmarkDescription*(size:int):UiDescription=
  var children:seq[UiDescription]
  children.add(component(Counter,0,key="local"))
  for j in 0..<size:children.add(component(MemoStatic,j,key= $j))
  hostShell(column(@[]),children)
## The benchmark only measures the unique managed runtime.
proc main()=
  when not defined(release) or not defined(gcOrc) or not defined(nimAllocStats):
    raise newException(ValueError,"compile -d:release --mm:orc -d:nimAllocStats")
  let mode="managed-typed"
  var size=100
  var iterations=200
  var warmup=50
  var rounds=3
  var output=""
  let args=commandLineParams()
  var i=0
  while i<args.len:
    if i+1>=args.len:raise newException(ValueError,"missing argument value")
    let key=args[i];let value=args[i+1];i+=2
    case key
    of "--mode":
      if value!="managed-typed":raise newException(ValueError,"only managed-typed is supported")
      discard value
    of "--static":size=parseInt(value)
    of "--iterations":iterations=parseInt(value)
    of "--warmup":warmup=parseInt(value)
    of "--rounds":rounds=parseInt(value)
    of "--output":output=value
    else:raise newException(ValueError,"unknown option: " & key)
  if size notin [100,1000,5000] or iterations notin 1..10000 or rounds notin 1..100 or warmup notin 1..100000 or output.len==0:
    raise newException(ValueError,"invalid benchmark parameters")
  var rt:Runtime
  var session:HostSession
  var latest:UpdateStats
  var encodingMs=0.0
  var sinkRevision:uint64
  proc consume(batch:HostBatch)=
    discard
  rt=newRuntime(componentApplication(makeBenchmarkDescription(size),"components"))
  session=attachHostSession(rt,HostConsumer(sessionId:91,prepare:consume,apply:proc()=discard,
    accept:proc(r:uint64) {.raises:[].}=sinkRevision=r,discardPrepared:proc() {.raises:[].}=discard))
  var operations=0
  proc operation()=
    encodingMs=0;latest=default(UpdateStats)
    discard rt.dispatch("counter",Event(kind:click))
    inc operations
    if sinkRevision!=rt.acceptedRevision:raise newException(ValueError,"consumer revision mismatch")
  proc verify()=
    if rt.find("counter").node.text!= $operations:raise newException(ValueError,"lost business update")
    if counter.read()!=operations:raise newException(ValueError,"lost State update")
  for j in 0..<warmup:operation();verify()
  let before=collectObservation()
  type Sample=object
    latency,compute,encoding:float64
    allocations:int
    counters:UpdateStats
  var samples=newSeqOfCap[Sample](iterations*rounds)
  for round in 0..<rounds:
    for j in 0..<iterations:
      let statsBefore=rt.updateStats()
      let allocBefore=getAllocStats()
      let start=getMonoTime()
      operation()
      let elapsed=milliseconds(start)
      let allocAfter=getAllocStats()
      let counts=difference(rt.updateStats(),statsBefore)
      samples.add(Sample(latency:elapsed,compute:max(0.0,elapsed-encodingMs),encoding:encodingMs,
        allocations:allocations(allocAfter-allocBefore),counters:counts))
      verify()
  let after=collectObservation()
  if session!=nil:session.close()
  var raw=newJArray()
  for sample in samples:
    raw.add(%*{"latency_ms":sample.latency,"compute_ms":sample.compute,"encoding_ms":sample.encoding,
      "native_apply_ms":newJNull(),"native_layout_ms":newJNull(),"frame_ms":newJNull(),
      "allocations":sample.allocations,"counters": %sample.counters})
  var hardware=hostCPU
  when defined(linux):
    for line in readFile("/proc/cpuinfo").splitLines:
      if line.startsWith("model name"):hardware=line.split(':',1)[1].strip();break
  let commit=execProcess("git",args= @["rev-parse","HEAD"],options={poUsePath}).strip()
  let report= %*{"schema":"leaf-components-1","metadata":{"mode":mode,"abi":2,"cache":false,
    "commit":commit,"source_dirty":execProcess("git",args= @["status","--porcelain"],options={poUsePath}).strip().len>0,"binary_sha256":sha256File(getAppFilename()),"hardware":hardware,"compiler":"Nim " & NimVersion,"platform":hostOS,"scope":"runtime-and-encoding","allocation_unit":"count"},
    "cases":[{"static":size,"iterations":iterations,"warmup":warmup,"rounds":rounds,"checks_passed":true,"samples":raw,"resources":resourceRecord(before,after)}]}
  createDir(output.parentDir)
  writeFile(output,report.pretty & "\n")
when isMainModule:
  try:main()
  except CatchableError as error:stderr.writeLine(error.msg);quit(1)
