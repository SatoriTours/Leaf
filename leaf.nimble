import std/os

version = "0.1.0"
author = "Leaf contributors"
description = "Nim application framework using system-native controls"
license = "MIT"
srcDir = "src"
requires "nim >= 2.2.6"

task cli, "Build the native Nim developer CLI":
  exec "nim c -d:release --out:" & "target/nim/leaf".addFileExt(ExeExt) & " src/leaf_cli.nim"

task test, "Run Nim runtime regression tests":
  exec "nim c -r --out:" & "target/nim/test_runner".addFileExt(ExeExt) & " scripts/test.nim"

task nativeTest, "Run real Windows native controls tests (Windows required)":
  exec "nim c -r --out:" & "target/nim/native_test".addFileExt(ExeExt) & " scripts/test_win32.nim"

task benchmark, "Measure native runtime and virtual list costs":
  exec "nim c -d:release -r --path:src --out:" & "target/nim/benchmark".addFileExt(ExeExt) & " benchmarks/runtime.nim"

task performance, "Run verified Release Nim performance workloads":
  exec "nim c -d:release -r --out:" & "target/nim/leaf-performance".addFileExt(ExeExt) & " scripts/performance.nim"
