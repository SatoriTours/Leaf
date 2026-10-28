## Canvas duration reports are distinct from iteration-based runtime reports.
## These functions run after measurement/cleanup; never in a paint callback.
import std/[json, strutils, math, sets]
import leaf/performance_report

const CanvasSampleFields* = ["at_ms", "interval_ms", "timeline_ms", "scene_sample_ms",
  "frame_build_validate_ms", "framework_commit_ms", "native_resource_ms",
  "cpu_draw_submit_ms", "total_ms", "record_ms"]

type CanvasPerfError* = object of ValueError

proc reject(message: string) {.noreturn.} =
  raise newException(CanvasPerfError, "Canvas performance: " & message)

proc field(node: JsonNode, key: string, kind: JsonNodeKind): JsonNode =
  if node == nil or node.kind != JObject or not node.hasKey(key) or node[key].kind != kind:
    reject("missing or invalid " & key)
  node[key]

proc number(node: JsonNode, key: string): float64 =
  if node == nil or node.kind != JObject or not node.hasKey(key) or node[key].kind notin {JInt,JFloat}:
    reject("missing number " & key)
  result = node[key].getFloat
  if classify(result) in {fcNan,fcInf,fcNegInf} or result < 0 or result > 3_600_000:
    reject("out of bounds " & key)

proc integer(node: JsonNode, key: string, maximum=1_000_000): int =
  let n = field(node,key,JInt).getBiggestInt
  if n < 0 or n > BiggestInt(maximum): reject("out of bounds " & key)
  int(n)

proc text(node: JsonNode, key: string): string =
  result = field(node,key,JString).getStr
  if result.len == 0 or result.len > 2048 or '\0' in result: reject("invalid " & key)

proc truth(node: JsonNode, key: string) =
  if not field(node,key,JBool).getBool: reject(key & " must be true")

proc hash(node: JsonNode, key: string) =
  let value = text(node,key)
  if value.len != 64: reject("invalid hash " & key)
  for c in value:
    if c notin {'0'..'9','a'..'f'}: reject("invalid hash " & key)

proc validateCanvasReport*(report: JsonNode, exitCode=0, timedOut=false) =
  if timedOut or exitCode != 0: reject("measurement process did not finish successfully")
  if integer(report,"schema") != 1 or text(report,"kind") != "leaf-canvas-performance" or
      text(report,"status") != "complete": reject("unsupported or incomplete report")
  let meta = field(report,"metadata",JObject)
  truth(meta,"release")
  if text(meta,"memory_manager") != "orc" or text(meta,"instrumentation") != "leafCanvasMeasure-v1":
    reject("unsupported build mode")
  discard text(meta,"compiler")
  hash(meta,"source_sha256"); hash(meta,"executable_sha256"); hash(meta,"toolchain_sha256")
  if text(meta,"scene_version") != "leaf-canvas-lab-v1" or integer(meta,"seed",high(int32).int) != 514834654:
    reject("unknown frozen workload")
  let count = integer(meta,"objects")
  if count notin [100,1000,10000] or integer(meta,"commands") != 3*count or
      integer(meta,"path_segments") != 4*(count div 3): reject("frozen geometry counts differ")
  for (key,expected) in [("circles",(count+2) div 3),("rectangles",(count+1) div 3),("triangles",count div 3)]:
    if integer(meta,key)!=expected: reject("frozen primitive mix differs")
  if number(meta,"opacity")!=0.85 or number(meta,"size_scale")!=1 or integer(meta,"interactive_bindings")!=0:
    reject("frozen paint/size/binding count differs")
  let load = text(meta,"load")
  if load notin ["staticFrame","properties","geometry"]: reject("unknown load")
  if number(meta,"dynamic_ratio") != (if load=="staticFrame":0.0 else:1.0): reject("frozen dynamic ratio differs")
  if text(meta,"renderer") notin ["software","hardware"]: reject("unknown actual renderer")
  let width = integer(meta,"width_px",16384);let height = integer(meta,"height_px",16384)
  if width == 0 or height == 0 or int64(width)*int64(height)>32_000_000 or integer(meta,"dpi",960)==0:
    reject("invalid physical surface")
  let environment = field(meta,"environment",JObject)
  for key in ["machine","os","cpu"]: discard text(environment,key)
  for key in ["gpu","driver"]:
    if environment.hasKey(key) and environment[key].kind != JNull: discard text(environment,key)
    elif not environment.hasKey(key): reject("missing " & key)
  discard field(environment,"vm",JBool);discard field(environment,"remote_desktop",JBool)
  if not environment.hasKey("refresh_hz"): reject("missing refresh rate")
  if environment["refresh_hz"].kind != JNull: discard number(environment,"refresh_hz")
  let warmup = integer(meta,"warmup_ms",60000);let duration = integer(meta,"sample_ms",120000)
  let cadence = number(meta,"cadence_ms")
  if duration < 100 or cadence < 1 or cadence > 1000 or float64(duration)/cadence > 19990:
    reject("duration/cadence exceeds preallocated capacity")
  if number(report,"warmup_elapsed_ms") < float64(warmup) or
      number(report,"sampled_elapsed_ms") < float64(duration): reject("incomplete requested duration")
  let samples = field(report,"samples",JArray)
  if samples.len < 2 or samples.len > 20000: reject("empty or excessive raw samples")
  let requests = integer(report,"requests")
  if requests != int(ceil(float64(duration)/cadence)):
    reject("nominal requests do not cover the requested duration")
  if integer(report,"cutoff_dropped") > requests: reject("invalid cutoff requests")
  if requests != samples.len + integer(report,"coalesced") + integer(report,"cutoff_dropped"): reject("request/coalescing accounting differs")
  if integer(report,"builds") != (if load=="staticFrame":0 else:samples.len): reject("frame build count differs")
  if integer(report,"successful_draws") < samples.len or
      integer(report,"draw_attempts") < integer(report,"successful_draws"): reject("draw accounting differs")
  truth(report,"environment_unchanged")
  let cleanup = field(report,"cleanup",JObject)
  truth(cleanup,"successful");truth(cleanup,"window_destroyed")
  let before = field(cleanup,"native_before",JArray);let after = field(cleanup,"native_after",JArray)
  if before.len != 8 or before != after: reject("native resources did not return to baseline")
  for n in before:
    if n.kind!=JInt or n.getBiggestInt<0: reject("invalid native resource count")
  let process = field(report,"process",JObject)
  if integer(process,"pid",high(int32).int)==0: reject("missing process identity")
  discard text(process,"start_id")
  let resources = field(report,"resources",JObject)
  var cpuPrevious = -1.0
  for key in ["before","after_warmup","at_measure_end","after_cleanup"]:
    let window=field(resources,key,JObject)
    let cpu=number(window,"cpu_ms")
    if cpu<cpuPrevious:reject("process CPU counter went backwards")
    cpuPrevious=cpu
    for name in ["heap_bytes","reserved_heap_bytes"]:discard integer(window,name,16_000_000_000_000)
    for name in ["rss_bytes","peak_rss_bytes","gdi_objects","user_objects"]:
      if not window.hasKey(name):reject("missing process observation " & name)
      if window[name].kind!=JNull:discard integer(window,name,16_000_000_000_000)
  discard number(field(report,"observer",JObject),"clock_pair_ms")
  for key in ["gpu_ms","display_fps"]: discard field(report,key,JNull)
  var previous = -1.0
  for sample in samples:
    for key in CanvasSampleFields: discard number(sample,key)
    let at = number(sample,"at_ms")
    if at <= previous or at > number(report,"sampled_elapsed_ms"): reject("nonmonotonic sample timestamps")
    if previous>=0 and abs((at-previous)-number(sample,"interval_ms")) > 0.1:
      reject("interval differs from actual start timestamps")
    previous=at
    var stages=0.0
    for key in ["timeline_ms","scene_sample_ms","frame_build_validate_ms","framework_commit_ms",
        "native_resource_ms","cpu_draw_submit_ms"]: stages+=number(sample,key)
    if stages > number(sample,"total_ms")+0.00001: reject("CPU stages overlap or exceed whole operation")


  let last = samples[samples.len-1]
  let tail = number(report,"sampled_elapsed_ms")-number(last,"at_ms")
  if tail > number(last,"total_ms") + max(3*cadence,2*number(last,"total_ms")):
    reject("unobserved terminal frame gap exceeds coverage policy")

proc summarizeCanvas*(report: JsonNode): JsonNode =
  validateCanvasReport(report)
  var intervals, totals: seq[float64]
  var over = 0
  let budget = report["metadata"]["cadence_ms"].getFloat
  for sample in report["samples"]:
    let interval = sample["interval_ms"].getFloat
    intervals.add(interval)
    totals.add(sample["total_ms"].getFloat)
    if interval > budget: inc over
  result = %*{"frames": intervals.len,
    "interval_p50_ms": percentile(intervals,0.5),
    "interval_p95_ms": percentile(intervals,0.95),
    "interval_p99_ms": percentile(intervals,0.99),
    "cpu_total_p50_ms": percentile(totals,0.5),
    "cpu_total_p95_ms": percentile(totals,0.95),
    "cpu_total_p99_ms": percentile(totals,0.99),
    "over_budget_ratio": float64(over)/float64(intervals.len)}

  result["terminal_gap_ms"] = %(report["sampled_elapsed_ms"].getFloat-report["samples"][report["samples"].len-1]["at_ms"].getFloat)
  var stages=newJObject()
  for key in CanvasSampleFields[2..^1]:
    var values:seq[float64]
    for sample in report["samples"]:values.add(sample[key].getFloat)
    stages[key]= %*{"p50":percentile(values,0.5),"p95":percentile(values,0.95),"p99":percentile(values,0.99)}
  result["cpu_stages_ms"]=stages

proc csvCell(value: string): string =
  if value.find({',','"','\r','\n'}) >= 0: "\"" & value.replace("\"","\"\"") & "\""
  else: value

proc canvasCsv*(report: JsonNode): string =
  validateCanvasReport(report)
  result = "machine,load,objects,source_sha256,pid,start_id," & CanvasSampleFields.join(",") & "\n"
  let meta = report["metadata"]
  for sample in report["samples"]:
    var cells = @[csvCell(meta["environment"]["machine"].getStr), csvCell(meta["load"].getStr),
      $meta["objects"].getInt, meta["source_sha256"].getStr,
      $report["process"]["pid"].getInt, csvCell(report["process"]["start_id"].getStr)]
    for field in CanvasSampleFields: cells.add($sample[field].getFloat)
    result.add(cells.join(",") & "\n")

proc comparisonIdentity(meta:JsonNode):JsonNode =
  result=meta.copy()
  result.delete("source_sha256");result.delete("executable_sha256")

proc canvasProcessGroup*(runs:seq[JsonNode]):JsonNode =
  if runs.len!=3:reject("exactly three independent processes are required")
  var identities=initHashSet[string]()
  var intervals,totals:seq[float64]
  for report in runs:
    validateCanvasReport(report)
    let meta=report["metadata"]
    if integer(meta,"warmup_ms")<5000 or integer(meta,"sample_ms")<30000:
      reject("smoke windows are not a formal performance baseline")
    if meta!=runs[0]["metadata"]:reject("process group uses different inputs/builds/environments")
    let identity= $report["process"]["pid"].getInt & ":" & report["process"]["start_id"].getStr
    if identity in identities:reject("same process was counted twice")
    identities.incl(identity)
    let summary=summarizeCanvas(report)
    intervals.add(summary["interval_p95_ms"].getFloat)
    totals.add(summary["cpu_total_p95_ms"].getFloat)
  result= %*{"processes":3,"interval_p95_median_ms":percentile(intervals,0.5),
    "cpu_total_p95_median_ms":percentile(totals,0.5),"metadata":runs[0]["metadata"]}

proc compareCanvasRuns*(current,baseline:seq[JsonNode]):JsonNode =
  let now=canvasProcessGroup(current);let previous=canvasProcessGroup(baseline)
  if comparisonIdentity(now["metadata"])!=comparisonIdentity(previous["metadata"]):
    reject("baseline workload/build parameters or environment are incompatible")
  let oldInterval=previous["interval_p95_median_ms"].getFloat
  let oldCpu=previous["cpu_total_p95_median_ms"].getFloat
  if oldInterval<=0 or oldCpu<=0:reject("zero baseline cannot be a regression denominator")
  result= %*{"processes":3,"current":now,"baseline":previous,
    "interval_p95_growth":now["interval_p95_median_ms"].getFloat/oldInterval-1,
    "cpu_total_p95_growth":now["cpu_total_p95_median_ms"].getFloat/oldCpu-1}

proc verifyCanvasProcess*(report:JsonNode,exitCode:int,timedOut:bool,pid:int,sourceHash,executableHash:string) =
  validateCanvasReport(report,exitCode,timedOut)
  if report["process"]["pid"].getInt!=pid or report["metadata"]["source_sha256"].getStr!=sourceHash or
      report["metadata"]["executable_sha256"].getStr!=executableHash:
    reject("report differs from the actual runner process/build")
