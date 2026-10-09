## Win32 host test runner.
##
## On Windows it scans `tests/windows/test_*.nim`, compiles and runs each suite
## and requires exit 0. It never reports success without actually running a
## Windows host test: an empty directory is a failure, not a pass.
##
## On non-Windows it reports NotRun and exits 2 -- the refusal is explicit and
## is not evidence that any Windows host behavior passed.
when defined(windows):
  import std/[os, osproc, strutils, algorithm]

proc main(): int =
  when defined(windows):
    let root = currentSourcePath().parentDir.parentDir
    let directory = root / "tests" / "windows"
    var tests: seq[string]
    if dirExists(directory):
      for path in walkFiles(directory / "test_*.nim"):
        tests.add(path)
    if tests.len == 0:
      stderr.writeLine("No Windows host tests found in tests/windows; " &
        "refusing to report success.")
      return 1
    tests.sort()
    let compiler = getEnv("NIM", findExe("nim"))
    if compiler.len == 0:
      stderr.writeLine("Nim compiler not found; put nim on PATH or set NIM")
      return 1
    let outputDirectory = root / "target" / "nim" / "a2" / "windows"
    createDir(outputDirectory)
    for test in tests:
      let name = test.extractFilename.changeFileExt(ExeExt)
      let output = outputDirectory / name
      let process = startProcess(compiler, workingDir = root,
        args = @["c", "-r", "--path:" & root / "src", "--out:" & output, test],
        options = {poUsePath, poParentStreams})
      let code = process.waitForExit()
      process.close()
      if code != 0: return code
    stdout.writeLine("Passed all " & $tests.len & " Windows host test suites")
    return 0
  else:
    stderr.writeLine("NotRun: Win32 host tests require Windows; " &
      "no host validation was executed.")
    return 2

when isMainModule: quit(main())