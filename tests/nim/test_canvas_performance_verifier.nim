import std/[unittest,json,os,tempfiles,strutils]
import leaf/checksum
import ../../benchmarks/[canvas_report,canvas_verify]
import ./support/canvas_performance_fixture

proc input(directory:string):JsonNode =
  let report=fixture()
  report["summary"]=summarizeCanvas(report)
  let prefix=directory/"properties-100-r1"
  writeFile(prefix & ".json",$report)
  writeFile(prefix & ".csv",canvasCsv(report))
  result= %*{"kind":"leaf-canvas-run-index","schema":1,"stage":"complete",
    "source_sha256":repeat('a',64),"executable_sha256":repeat('b',64),
    "toolchain_sha256":FixtureToolchainHash,"toolchain_json":FixtureToolchainJson,
    "warmup_ms":0,"sample_ms":100,"environment_before":report["metadata"]["environment"],
    "environment_after":report["metadata"]["environment"].copy(),
    "entries":[{"case":"properties-100-r1","objects":100,"load":"properties","repetition":1,
      "cleanup_confirmed":true,"exit_code":0,"timed_out":false,"pid":123,
      "report_sha256":sha256File(prefix & ".json")}]}

suite "offline Canvas collection adjudication":
  test "actual file/hash/CSV validation distinguishes smoke from a baseline":
    let dir=createTempDir("leaf-canvas-index-","")
    defer:removeDir(dir)
    let index=input(dir)
    writeFile(dir/"run-index.json",$index)
    check verifyCanvasIndex(dir/"run-index.json").summary["status"].getStr=="validated-smoke"
    expect CanvasPerfError:discard verifyCanvasIndex(dir/"run-index.json",true)

  test "bad exit timeout PID cleanup or changed environment cannot be waived by complete":
    for mode in 0..4:
      let dir=createTempDir("leaf-canvas-index-","")
      defer:removeDir(dir)
      let index=input(dir)
      let entry=index["entries"][0]
      case mode
      of 0:entry["exit_code"]= %7
      of 1:entry["timed_out"]= %true
      of 2:entry["pid"]= %124
      of 3:entry["cleanup_confirmed"]= %false
      else:index["environment_after"]["vm"]= %false
      writeFile(dir/"run-index.json",$index)
      expect CanvasPerfError:discard verifyCanvasIndex(dir/"run-index.json")

  test "wrongly typed success fields are not silently defaulted to zero or false":
    for key in ["exit_code","timed_out","pid"]:
      let dir=createTempDir("leaf-canvas-index-","")
      defer:removeDir(dir)
      let index=input(dir)
      index["entries"][0][key]= %(if key=="timed_out":"false" elif key=="pid":"123" else:"0")
      writeFile(dir/"run-index.json",$index)
      expect CanvasPerfError:discard verifyCanvasIndex(dir/"run-index.json")

  test "altered raw bytes CSV summaries and traversal labels are rejected":
    for mode in 0..3:
      let dir=createTempDir("leaf-canvas-index-","")
      defer:removeDir(dir)
      let index=input(dir)
      let path=dir/"properties-100-r1.json"
      case mode
      of 0:writeFile(path,readFile(path) & " ")
      of 1:writeFile(dir/"properties-100-r1.csv","invented data")
      of 2:
        let report=parseFile(path)
        report["summary"]["interval_p95_ms"]= %1.0
        writeFile(path,$report)
        index["entries"][0]["report_sha256"]= %sha256File(path)
      else:index["entries"][0]["case"]= %"../unrelated"
      writeFile(dir/"run-index.json",$index)
      expect CanvasPerfError:discard verifyCanvasIndex(dir/"run-index.json")

  test "toolchain content and compiled identity must be bound, not just Nim version":
    for mode in 0..2:
      let dir=createTempDir("leaf-canvas-index-","")
      defer:removeDir(dir)
      let index=input(dir)
      case mode
      of 0:index.delete("toolchain_sha256")
      of 1:index["toolchain_sha256"]= %repeat('f',64)
      else:index["toolchain_json"]= %"different compiler flags"
      writeFile(dir/"run-index.json",$index)
      expect CanvasPerfError:discard verifyCanvasIndex(dir/"run-index.json")
