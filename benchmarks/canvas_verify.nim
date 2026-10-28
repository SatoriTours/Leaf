## Offline verification; never runs on the measured frame path.
import std/[json,os,tables,strutils,sets]
import leaf/checksum
import leaf/vendor/checksums/sha2
import ./canvas_report

type VerifiedCanvasIndex* = object
  summary*:JsonNode
  groups*:OrderedTable[string,seq[JsonNode]]
proc require(condition:bool,message:string) =
  if not condition:raise newException(CanvasPerfError,message)
proc boundedJson(path:string):JsonNode =
  require(getFileInfo(path,followSymlink=false).kind==pcFile,"report must be a regular file")
  require(getFileSize(path) in 1..16*1024*1024,"report size is out of bounds")
  parseFile(path)

proc verifyCanvasIndex*(path:string,requireFormal=false):VerifiedCanvasIndex =
  let index=boundedJson(path)
  require(index.kind==JObject and index["kind"].getStr=="leaf-canvas-run-index" and
    index["schema"].getInt==1 and index["stage"].getStr=="complete","run index is incomplete")
  require(index["environment_before"]==index["environment_after"],"runner environment changed")
  let entries=index["entries"]
  require(entries.kind==JArray and entries.len in 1..27,"run index length is invalid")
  let directory=absolutePath(path).parentDir
  require(index.hasKey("toolchain_sha256") and index["toolchain_sha256"].kind==JString and
    index.hasKey("toolchain_json") and index["toolchain_json"].kind==JString,"missing toolchain provenance")
  let toolchain=index["toolchain_sha256"].getStr
  let toolchainText=index["toolchain_json"].getStr
  require(toolchainText.len in 1..65536,"invalid toolchain document size")
  var toolchainDigest=initSha_256()
  toolchainDigest.update(toolchainText)
  require($toolchainDigest.digest()==toolchain,"toolchain document differs from its hash")
  let toolchainDoc=parseJson(toolchainText)
  require(toolchainDoc.kind==JObject and toolchainDoc["schema"].kind==JInt and toolchainDoc["schema"].getInt==1,"unsupported toolchain document")
  for key in ["nim_version","cc_version"]:
    require(toolchainDoc.hasKey(key) and toolchainDoc[key].kind==JString and toolchainDoc[key].getStr.len in 1..2048,"missing compiler version")
  for key in ["nim_binary_sha256","cc_binary_sha256","resource_manifest_sha256"]:
    require(toolchainDoc.hasKey(key) and toolchainDoc[key].kind==JString and toolchainDoc[key].getStr.len==64,"missing build input hash")
    for c in toolchainDoc[key].getStr:require(c in {'0'..'9','a'..'f'},"invalid build input hash")
  require(toolchainDoc.hasKey("flags") and toolchainDoc["flags"].kind==JArray and toolchainDoc["flags"].len in 1..64,"missing build flags")
  for flag in toolchainDoc["flags"]:require(flag.kind==JString and flag.getStr.len in 1..2048,"invalid build flag")
  let executable=index["executable_sha256"].getStr
  let source=index["source_sha256"].getStr
  var cases=initHashSet[string]()
  var summaryRuns=newJArray()
  var allFormal=true
  for entry in entries:
    require(entry.kind==JObject,"run entry must be an object")
    for key in ["exit_code","pid","objects","repetition"]:
      require(entry.hasKey(key) and entry[key].kind==JInt,"invalid integer entry field " & key)
    for key in ["timed_out","cleanup_confirmed"]:
      require(entry.hasKey(key) and entry[key].kind==JBool,"invalid Boolean entry field " & key)
    let objects=entry["objects"].getInt
    let load=entry["load"].getStr
    let repetition=entry["repetition"].getInt
    require(objects in [100,1000,10000] and load in ["staticFrame","properties","geometry"] and
      repetition in 1..3,"unknown run index case")
    let caseId=load & "-" & $objects & "-r" & $repetition
    require(caseId notin cases,"duplicate run index case")
    cases.incl(caseId)
    require(entry["case"].getStr==caseId,"run label differs from arguments")
    require(entry["cleanup_confirmed"].getBool,"child process termination is unconfirmed")
    let reportPath=directory/(caseId & ".json")
    let report=boundedJson(reportPath)
    require(sha256File(reportPath)==entry["report_sha256"].getStr,"collected report bytes changed")
    verifyCanvasProcess(report,entry["exit_code"].getInt,entry["timed_out"].getBool,
      entry["pid"].getInt,source,executable)
    let meta=report["metadata"]
    require(meta["toolchain_sha256"].getStr==toolchain and meta["compiler"]==toolchainDoc["nim_version"],"compiled toolchain identity differs from runner")
    require(meta["objects"].getInt==objects and meta["load"].getStr==load,"report workload differs from runner case")
    require(meta["warmup_ms"]==index["warmup_ms"] and meta["sample_ms"]==index["sample_ms"],"duration differs from runner arguments")
    require(meta["environment"]==index["environment_before"],"report public environment differs")
    let expected=summarizeCanvas(report)
    require(report["summary"]==expected,"stored summary differs from raw samples")
    let csvPath=directory/(caseId & ".csv")
    require(getFileInfo(csvPath,followSymlink=false).kind==pcFile and getFileSize(csvPath)<=16*1024*1024,"invalid CSV file")
    require(readFile(csvPath)==canvasCsv(report),"stored CSV differs from validated raw samples")
    let groupId=load & "-" & $objects
    result.groups.mgetOrPut(groupId,@[]).add(report)
    summaryRuns.add(%*{"case":caseId,"pid":entry["pid"],"summary":expected,"resources":report["resources"]})
    allFormal=allFormal and meta["warmup_ms"].getInt>=5000 and meta["sample_ms"].getInt>=30000
  allFormal=allFormal and entries.len==27 and result.groups.len==9
  var groups=newJObject()
  if allFormal:
    for name,reports in result.groups:groups[name]=canvasProcessGroup(reports)
  if requireFormal:require(allFormal,"all nine workloads need three independent formal processes")
  result.summary= %*{"kind":"leaf-canvas-verified-index","schema":1,
    "status":(if allFormal:"validated-baseline" else:"validated-smoke"),
    "source_sha256":source,"executable_sha256":executable,"toolchain_sha256":toolchain,
    "toolchain":toolchainDoc,"runs":summaryRuns,"groups":groups,
    "gpu_ms":newJNull(),"display_fps":newJNull()}

proc compareCanvasIndices*(current,baseline:VerifiedCanvasIndex):JsonNode =
  require(current.summary["status"].getStr=="validated-baseline" and
    baseline.summary["status"].getStr=="validated-baseline","only full formal indices can be compared")
  result=newJObject()
  for name,reports in current.groups:
    require(baseline.groups.hasKey(name),"baseline workload missing")
    result[name]=compareCanvasRuns(reports,baseline.groups[name])
