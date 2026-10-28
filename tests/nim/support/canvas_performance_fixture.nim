const FixtureToolchainJson* = "{\"schema\":1,\"nim_version\":\"2.2.6\",\"nim_binary_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"cc_version\":\"fixture GCC\",\"cc_binary_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"flags\":[\"fixture-release-orc\"],\"resource_manifest_sha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"}"
const FixtureToolchainHash* = "899a67f5356091b6532bebb16b66c2114d5d9ccd5ceb29973947c241f458702e"
import std/[json,strutils]
# Synthetic report fixtures test policies only, never performance evidence.
proc fixture*(): JsonNode =
  result = %*{
    "schema": 1, "kind": "leaf-canvas-performance", "status": "complete",
    "metadata": {"scene_version": "leaf-canvas-lab-v1", "seed": 514834654,
      "objects": 100, "commands": 300, "path_segments": 132, "load": "properties",
      "circles":34,"rectangles":33,"triangles":33,"opacity":0.85,"size_scale":1.0,
      "interactive_bindings":0,"dynamic_ratio":1.0,
      "source_sha256": repeat('a',64), "executable_sha256": repeat('b',64),
      "compiler": "2.2.6", "toolchain_sha256":"899a67f5356091b6532bebb16b66c2114d5d9ccd5ceb29973947c241f458702e", "release": true, "memory_manager": "orc",
      "instrumentation": "leafCanvasMeasure-v1", "renderer": "software",
      "width_px": 960, "height_px": 540, "dpi": 96,
      "warmup_ms": 0, "sample_ms": 100, "cadence_ms": 16.6666666667,
      "environment": {"machine": "fixture,not-real", "os": "Windows fixture",
        "cpu": "fixture", "gpu": "fixture", "driver": "fixture", "vm": true,
        "remote_desktop": false, "refresh_hz": 60}},
    "process": {"pid": 123, "start_id": "fixture-1"},
    "warmup_elapsed_ms": 0.0, "sampled_elapsed_ms": 100.0,
    "requests": 6, "builds": 3, "coalesced": 3, "cutoff_dropped": 0,
    "draw_attempts": 3, "successful_draws": 3, "environment_unchanged": true,
    "cleanup": {"successful": true, "window_destroyed": true,
      "native_before": [0,0,0,0,0,0,0,0], "native_after": [0,0,0,0,0,0,0,0]},
    "resources": {
      "before":{"cpu_ms":1.0,"heap_bytes":65536,"reserved_heap_bytes":131072,"rss_bytes":newJNull(),"peak_rss_bytes":newJNull(),"gdi_objects":0,"user_objects":0},
      "after_warmup":{"cpu_ms":2.0,"heap_bytes":65536,"reserved_heap_bytes":131072,"rss_bytes":newJNull(),"peak_rss_bytes":newJNull(),"gdi_objects":1,"user_objects":1},
      "at_measure_end":{"cpu_ms":3.0,"heap_bytes":65536,"reserved_heap_bytes":131072,"rss_bytes":newJNull(),"peak_rss_bytes":newJNull(),"gdi_objects":1,"user_objects":1},
      "after_cleanup":{"cpu_ms":4.0,"heap_bytes":65536,"reserved_heap_bytes":131072,"rss_bytes":newJNull(),"peak_rss_bytes":newJNull(),"gdi_objects":0,"user_objects":0}},
    "observer": {"clock_pair_ms": 0.001},
    "gpu_ms": newJNull(), "display_fps": newJNull(),
    "samples": [
      {"at_ms":16.0,"interval_ms":16.0,"timeline_ms":1.0,"scene_sample_ms":1.0,
       "frame_build_validate_ms":3.0,"framework_commit_ms":2.0,
       "native_resource_ms":3.0,"cpu_draw_submit_ms":5.0,"total_ms":15.0,"record_ms":0.001},
      {"at_ms":50.0,"interval_ms":34.0,"timeline_ms":1.0,"scene_sample_ms":1.0,
       "frame_build_validate_ms":3.0,"framework_commit_ms":2.0,
       "native_resource_ms":3.0,"cpu_draw_submit_ms":5.0,"total_ms":15.0,"record_ms":0.001},
      {"at_ms":90.0,"interval_ms":40.0,"timeline_ms":1.0,"scene_sample_ms":1.0,
       "frame_build_validate_ms":3.0,"framework_commit_ms":2.0,
       "native_resource_ms":3.0,"cpu_draw_submit_ms":5.0,"total_ms":15.0,"record_ms":0.001}]}

proc group*(source='a',executable='b'):seq[JsonNode] =
  for i in 0..<3:
    let report=fixture()
    report["metadata"]["warmup_ms"]= %5000
    report["metadata"]["sample_ms"]= %30000
    report["metadata"]["source_sha256"]= %repeat(source,64)
    report["metadata"]["executable_sha256"]= %repeat(executable,64)
    report["warmup_elapsed_ms"]= %5000.0
    report["sampled_elapsed_ms"]= %30000.0
    report["requests"]= %1800
    report["coalesced"]= %1797
    report["process"]["pid"]= %(123+i)
    report["process"]["start_id"]= %("fixture-" & $i)
    report["samples"][1]["at_ms"]= %15000.0
    report["samples"][1]["interval_ms"]= %14984.0
    report["samples"][2]["at_ms"]= %29990.0
    report["samples"][2]["interval_ms"]= %14990.0
    result.add(report)
