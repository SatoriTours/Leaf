## Self-contained Nim test entry; also works in source archives without Git.
import std/[os, osproc, algorithm]

proc main(): int =
  let root = currentSourcePath().parentDir.parentDir
  let compiler = getEnv("NIM", findExe("nim"))
  if compiler.len == 0:
    stderr.writeLine("Nim compiler not found; put nim on PATH or set NIM")
    return 1
  createDir(root / "target" / "nim")
  var tests: seq[string]
  for path in walkFiles(root / "tests" / "nim" / "test_*.nim"):
    tests.add(path)
  tests.sort()
  if tests.len == 0:
    stderr.writeLine("No Nim test suites found")
    return 1
  for test in tests:
    let output = root / "target" / "nim" / test.extractFilename.changeFileExt(ExeExt)
    var args = @["c", "-r", "--path:" & root / "src", "--out:" & output]
    args.add(test)
    let process = startProcess(compiler, workingDir = root,
      args = args,
      options = {poUsePath, poParentStreams})
    let code = process.waitForExit()
    process.close()
    if code != 0: return code
  stdout.writeLine("Passed all " & $tests.len & " Nim test suites")


when isMainModule: quit(main())
