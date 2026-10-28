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
  import ../src/leaf/[windows_manifest, windows_paths, orm_config]

  proc execute(compiler, root: string, args: seq[string]): int =
    let process = startProcess(compiler, workingDir = root, args = args,
      options = {poUsePath, poParentStreams})
    defer: process.close()
    process.waitForExit()

proc windowsSuiteDefinesInternal*(filename: string): seq[string] =
  ## Keep optional Canvas CPU instrumentation out of ordinary native suites.
  result = @["-d:leafProtocolProbes"]
  if filename == "test_canvas_performance.nim":
    result.add("-d:leafCanvasMeasure")

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
    let outputDirectory = getEnv("LEAF_WIN32_TEST_OUT",
      root / "target" / "nim" / "a2" / "windows")
    createDir(outputDirectory)
    for test in tests:
      let name = test.extractFilename.changeFileExt(ExeExt)
      let output = outputDirectory / name
      let cache = compilerPath(outputDirectory / (name & "-cache"))
      var args = @["c", "--threads:on", "--forceBuild:on"] &
        windowsSuiteDefinesInternal(test.extractFilename) & @[
        "--skipParentCfg:on", "--skipUserCfg:on",
        "--nimcache:" & cache.replace("$", "$$"),
        "--passC:-I" & quoteShell(compilerPath(directory)),
        "--path:" & compilerPath(root / "src").replace("$", "$$"),
        "--out:" & compilerPath(output).replace("$", "$$")]
      args.add(WindowsHeaderCompilerArgs)
      for argument in ormCompilerArgs(compilerPath(root / "src")):
        args.add(argument.replace("$", "$$"))
      let entry = compilerPath(test)
      # Use Nim's selected compiler, then link the same v6/PMv2 resource as apps.
      # No generated object in the source checkout is a prerequisite.
      let discovery = execute(compiler, root, args & @["--compileOnly", entry])
      if discovery != 0: return discovery
      try:
        let gcc = gccFromBuildScript(cache / name.changeFileExt("json"))
        let resource = compileWindowsManifest(root / "src", cache, gcc)
        args.add("--passL:" & quoteShell(compilerPath(resource)))
      except CatchableError as error:
        stderr.writeLine(error.msg)
        return 1
      let code = execute(compiler, root, args & @["-r", entry])
      if code != 0: return code
    stdout.writeLine("Passed all " & $tests.len & " Windows host test suites")
    return 0
  else:
    stderr.writeLine("NotRun: Win32 host tests require Windows; " &
      "no host validation was executed.")
    return 2

when isMainModule: quit(main())
