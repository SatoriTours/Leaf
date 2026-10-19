import std/[unittest,json]
import leaf/performance_report
proc validReport(mode="managed-typed"):JsonNode=
  result= %*{"schema":"leaf-components-1","metadata":{"mode":mode,"abi":2,"cache":false,"commit":"abcdef012345","hardware":"fixture cpu","compiler":"Nim 2.2.6","platform":"linux","scope":"runtime-and-encoding","allocation_unit":"count"},"cases":[]}
  for size in [100,1000,5000]:
    var samples=newJArray()
    for i in 0..<6:
      samples.add(%*{"latency_ms":0.1,"compute_ms":0.08,"encoding_ms":0.02,"allocations":120,
        "counters":{"componentRenders":1,"visitedHosts":3,"normalizedHosts":1,"indexEdits":1,"ops":1,"ffiBytes":600,"snapshotExports":0}})
    result["cases"].add(%*{"static":size,"iterations":2,"rounds":3,"warmup":50,"checks_passed":true,"samples":samples})
suite "strict structural performance acceptance":
  test "complete report passes":check verifyComponentReport(validReport()).len==0
  test "snapshot export extra render and linear allocation fail":
    for fault in ["snapshotExports","componentRenders","allocations"]:
      let report=validReport()
      if fault=="allocations":report["cases"][2]["samples"][0]["allocations"] = %5000
      else:report["cases"][2]["samples"][0]["counters"][fault] = %2
      check verifyComponentReport(report).len>0
  test "missing fields samples metadata and duplicate sizes fail":
    for mode in 0..4:
      let report=validReport()
      case mode
      of 0:report["metadata"].delete("commit")
      of 1:report["cases"][0]["samples"][0]["counters"].delete("snapshotExports")
      of 2:report["cases"][0]["samples"] = newJArray()
      of 3:report["cases"][1]["static"] = %100
      else:report["cases"][0]["checks_passed"] = %false
      check verifyComponentReport(report).len>0
  test "removed legacy modes are rejected":
    for mode in ["legacy-json","legacy-typed"]:
      let report=validReport(mode)
      check verifyComponentReport(report).len>0
