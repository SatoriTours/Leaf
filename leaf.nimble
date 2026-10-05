import std/os

version = "0.1.0"
author = "Leaf contributors"
description = "Nim desktop application framework powered by GPUI and GPUI Kit"
license = "MIT"
srcDir = "src"
requires "nim >= 2.2.6"

task cli, "Build the native Nim developer CLI":
  exec "nim c -d:release --out:" & "target/nim/leaf".addFileExt(ExeExt) & " src/leaf_cli.nim"

task test, "Run Nim runtime regression tests":
  exec "nim c -r --out:" & "target/nim/test_runner".addFileExt(ExeExt) & " scripts/test.nim"

task nativeTest, "Run real GPUI desktop tests (DISPLAY or Xvfb)":
  exec "nim c -r --out:" & "target/nim/native_test".addFileExt(ExeExt) & " scripts/native_test.nim"

task benchmark, "Measure native runtime and virtual list costs":
  exec "nim c -d:release -r --path:src --out:" & "target/nim/benchmark".addFileExt(ExeExt) & " benchmarks/runtime.nim"

task performance, "Run verified Release Nim performance workloads":
  exec "nim c -d:release -r --out:" & "target/nim/leaf-performance".addFileExt(ExeExt) & " scripts/performance.nim"
