import std/[unittest, json, strutils]
import ../../benchmarks/canvas_report

import ./support/canvas_performance_fixture

suite "Canvas duration performance reports":
  test "raw CPU stages produce nearest-rank intervals and escaped CSV, not display FPS":
    let report = fixture()
    let summary = summarizeCanvas(report)
    check summary["frames"].getInt == 3
    check summary["interval_p50_ms"].getFloat == 34.0
    check summary["interval_p95_ms"].getFloat == 40.0
    check summary["over_budget_ratio"].getFloat == 2.0/3.0
    let csv = canvasCsv(report)
    check csv.startsWith("machine,load,objects,")
    check "\"fixture,not-real\"" in csv
    check csv.splitLines.len == 5 # header + three records + final newline
    check "display_fps" notin csv

  test "CSV refuses incomplete samples rather than publishing a success-looking artifact":
    for empty in [true,false]:
      let report = fixture()
      if empty: report["samples"] = newJArray()
      else: report.delete("samples")
      expect CanvasPerfError: discard canvasCsv(report)

  test "cleanup failure or native resource imbalance blocks report publication":
    for mode in 0..2:
      let report = fixture()
      case mode
      of 0: report["cleanup"]["successful"] = %false
      of 1: report["cleanup"]["window_destroyed"] = %false
      else: report["cleanup"]["native_after"].elems[2] = %1
      expect CanvasPerfError: discard canvasCsv(report)

  test "minimizing or environment changes invalidate a duration run":
    let report = fixture()
    report["environment_unchanged"] = %false
    expect CanvasPerfError: discard canvasCsv(report)

  test "shortened duration or unfinished warmup cannot pass as the requested run":
    for mode in 0..1:
      let report = fixture()
      if mode == 0: report["sampled_elapsed_ms"] = %99.0
      else: report["metadata"]["warmup_ms"] = %5000
      expect CanvasPerfError: discard canvasCsv(report)

  test "request accounting and frozen primitive counts cannot be invented":
    for key in ["requests","coalesced","builds","commands","path_segments"]:
      let report = fixture()
      if key in ["commands","path_segments"]: report["metadata"][key] = %0
      else: report[key] = %0
      expect CanvasPerfError: discard canvasCsv(report)

  test "negative nonfinite and overlapping CPU phases are rejected":
    for mode in 0..2:
      let report = fixture()
      case mode
      of 0: report["samples"][0]["cpu_draw_submit_ms"] = %(-1.0)
      of 1: report["samples"][0]["timeline_ms"] = %NaN
      else: report["samples"][0]["timeline_ms"] = %10.0
      expect CanvasPerfError: discard canvasCsv(report)

  test "frame interval observations must agree with monotonic start timestamps":
    let report = fixture()
    report["samples"][1]["interval_ms"] = %33.0
    expect CanvasPerfError: discard canvasCsv(report)

  test "GPU time and displayed FPS remain unknown for HWND EndDraw":
    for field in ["gpu_ms","display_fps"]:
      let report = fixture()
      report[field] = %60.0
      expect CanvasPerfError: discard canvasCsv(report)

  test "debug builds unbounded buffers and unknown renderers are not baselines":
    for mode in 0..2:
      let report = fixture()
      case mode
      of 0: report["metadata"]["release"] = %false
      of 1:
        let item = report["samples"][0]
        report["samples"] = newJArray()
        for i in 0..20000: report["samples"].add(item)
      else: report["metadata"]["renderer"] = %"automatic-fallback"
      expect CanvasPerfError: discard canvasCsv(report)

  test "a complete-looking report still needs an actual successful process exit":
    for timedOut in [true,false]:
      expect CanvasPerfError:
        validateCanvasReport(fixture(),exitCode=(if timedOut:0 else:7),timedOut=timedOut)

  test "nominal requests cover the full requested duration and raw tail is bounded":
    let report = fixture()
    report["metadata"]["sample_ms"] = %30000
    report["sampled_elapsed_ms"] = %30000.0
    expect CanvasPerfError: discard canvasCsv(report)

  test "primitive mix alpha bindings and dynamic ratio are frozen, not UI defaults":
    for key in ["circles","rectangles","triangles","opacity","size_scale","interactive_bindings","dynamic_ratio"]:
      let report=fixture()
      report["metadata"][key]= %(-1)
      expect CanvasPerfError: discard canvasCsv(report)

suite "Canvas independent-process comparison":
  test "three independent formal processes compare across code hashes, not environments":
    let compared=compareCanvasRuns(group(),group('c','d'))
    check compared["interval_p95_growth"].getFloat==0
    check compared["processes"].getInt==3
  test "cycles or short smoke windows do not stand in for three processes":
    var runs=group()
    expect CanvasPerfError: discard compareCanvasRuns(runs[0..1],group())
    runs[2]=runs[0]
    expect CanvasPerfError: discard compareCanvasRuns(runs,group())
    expect CanvasPerfError: discard compareCanvasRuns(@[fixture(),fixture(),fixture()],group())
  test "viewport renderer environment and parameters are compatibility boundaries":
    for mode in 0..3:
      let baseline=group('c','d')
      for report in baseline:
        case mode
        of 0:report["metadata"]["width_px"]= %961
        of 1:report["metadata"]["renderer"]= %"hardware"
        of 2:report["metadata"]["environment"]["vm"]= %false
        else:report["metadata"]["warmup_ms"]= %4999
      expect CanvasPerfError: discard compareCanvasRuns(group(),baseline)

  test "raw reports are bound to the observed runner PID and exact binary/source":
    let report=fixture()
    verifyCanvasProcess(report,0,false,123,repeat('a',64),repeat('b',64))
    expect CanvasPerfError: verifyCanvasProcess(report,0,false,124,repeat('a',64),repeat('b',64))
    expect CanvasPerfError: verifyCanvasProcess(report,0,false,123,repeat('c',64),repeat('b',64))
    expect CanvasPerfError: verifyCanvasProcess(report,0,false,123,repeat('a',64),repeat('d',64))

  test "CPU memory and native observer windows must be present even when RSS is unknown":
    for key in ["cpu_ms","heap_bytes","rss_bytes","gdi_objects"]:
      let report=fixture()
      report["resources"]["at_measure_end"].delete(key)
      expect CanvasPerfError:discard canvasCsv(report)

  test "missing or unverified compiler/toolchain identity cannot be a baseline":
    let report=fixture()
    report["metadata"].delete("toolchain_sha256")
    expect CanvasPerfError:discard canvasCsv(report)
    let runs=group()
    for r in runs:r["metadata"].delete("toolchain_sha256")
    expect CanvasPerfError:discard canvasProcessGroup(runs)
