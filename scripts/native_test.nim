## Run real Nim + GPUI regression in a desktop session; Linux can launch private Xvfb.
import std/[os, osproc, strtabs, times]

proc exists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    result = true
  except OSError: discard

proc main(): int =
  let root = currentSourcePath().parentDir.parentDir
  let compiler = getEnv("NIM", findExe("nim"))
  if compiler.len == 0:
    stderr.writeLine("Nim compiler not found")
    return 1
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  var server: Process
  try:
    when defined(linux):
      if getEnv("DISPLAY").len == 0:
        let xvfb = getEnv("LEAF_TEST_XVFB", findExe("Xvfb"))
        if xvfb.len == 0:
          stderr.writeLine("Native GPUI tests need DISPLAY or Xvfb; set LEAF_TEST_XVFB if needed")
          return 1
        var display = 90
        while display < 150 and (exists("/tmp/.X" & $display & "-lock") or
            exists("/tmp/.X11-unix/X" & $display)):
          inc display
        if display == 150: raise newException(IOError, "No free test display")
        env["DISPLAY"] = ":" & $display
        server = startProcess(xvfb, env = env,
          args = @[env["DISPLAY"], "-screen", "0", "1280x900x24", "-nolisten", "tcp", "-ac"],
          options = {poUsePath, poParentStreams})
        let deadline = epochTime() + 10
        while not exists("/tmp/.X11-unix/X" & $display):
          if not server.running: raise newException(IOError, "Xvfb exited before opening display")
          if epochTime() > deadline: raise newException(IOError, "Xvfb display startup timed out")
          sleep(50)
    let process = startProcess(compiler, workingDir = root, env = env,
      args = @["c", "-r", "--out:" & root / "target/nim" / "native_suites".addFileExt(ExeExt), root / "tests/nim/gpui_native.nim"],
      options = {poUsePath, poParentStreams})
    try: result = process.waitForExit()
    finally: process.close()
  except CatchableError as error:
    stderr.writeLine(error.msg)
    result = 1
  finally:
    if server != nil:
      if server.running:
        server.terminate()
        discard server.waitForExit(5000)
        if server.running: server.kill()
      server.close()

when isMainModule: quit(main())
