import ./cleanup_support
import std/[os, osproc, strutils, unittest, tempfiles, times, strtabs]
import leaf/process_io
import leaf_cli
when defined(posix): import std/posix
when defined(windows): import std/winlean

let args = commandLineParams()
if args.len == 2 and args[0] == "--cli-build":
  leaf_cli.exitCli(leaf_cli.main(@["build", args[1]]))
if args.len == 2 and args[0] == "--child":
  when defined(posix): discard posix.signal(SIGTERM, SIG_IGN)
  writeFile(args[1], $getCurrentProcessId())
  while true: sleep(25)
if args.len == 3 and args[0] == "--leader":
  discard startProcess(getAppFilename(), args = @["--child", args[1]], options = {poParentStreams})
  while not fileExists(args[1]): sleep(5)
  if args[2] == "exit": quit(0)
  while true: sleep(25)
if args.len > 0 and args[0] == "c" and getEnv("LEAF_TEST_COMPILER_MARKER").len > 0:
  let marker = getEnv("LEAF_TEST_COMPILER_MARKER")
  discard startProcess(getAppFilename(), args = @["--child", marker], options = {poParentStreams})
  while true: sleep(25)

let root = createTempDir("leaf-process-", "")
removeDirectoryOnExit(root)
proc alive(pid: int): bool =
  when defined(linux):
    try:
      let stat = readFile("/proc/" & $pid & "/stat")
      result = stat[stat.rfind(')') + 2] notin {'Z', 'X'}
    except IOError: discard
  elif defined(posix): result = posix.kill(Pid(pid), 0) == 0
  elif defined(windows):
    let handle = openProcess(0x1000, 0, int32(pid))
    if handle != 0:
      result = waitForSingleObject(handle, 0) == WAIT_TIMEOUT
      discard closeHandle(handle)

suite "Owned subprocess trees":
  for mode in ["running", "exit"]:
    test "close stops resistant children with leader " & mode:
      let marker = root / mode
      let p = startManaged(getAppFilename(), @["--leader", marker, mode], root)
      defer: p.close()
      let deadline = epochTime() + 10
      while not fileExists(marker):
        if epochTime() > deadline: raise newException(IOError, "child startup timed out")
        sleep(10)
      let child = parseInt(readFile(marker))
      defer:
        if alive(child):
          when defined(posix): discard posix.kill(Pid(child), SIGKILL)
          elif defined(windows):
            let h = openProcess(1, 0, int32(child))
            if h != 0:
              discard terminateProcess(h, 1)
              discard closeHandle(h)
      if mode == "exit":
        while not p.poll(): sleep(5)
      p.close()
      let stopped = epochTime() + 2
      while alive(child) and epochTime() < stopped: sleep(5)
      check not alive(child)
  when defined(posix):
    test "Ctrl+C during a real CLI build cleans compiler and resistant descendants":
      let source = root / "app.nim"
      writeFile(source, "discard")
      let marker = root / "compiler-child"
      var env = newStringTable(modeCaseSensitive)
      for key, value in envPairs(): env[key] = value
      env["NIM"] = getAppFilename()
      env["LEAF_TEST_COMPILER_MARKER"] = marker
      let p = startManaged(getAppFilename(), @["--cli-build", source], root, env)
      defer: p.close()
      let deadline = epochTime() + 10
      while not fileExists(marker):
        if epochTime() > deadline: raise newException(IOError, "compiler startup timed out")
        sleep(10)
      let child = parseInt(readFile(marker))
      defer:
        if alive(child): discard posix.kill(Pid(child), SIGKILL)
      discard posix.kill(Pid(p.pid), SIGINT)
      while not p.poll():
        if epochTime() > deadline: raise newException(IOError, "CLI interruption timed out")
        sleep(10)
      checkpoint(p.output)
      check p.code == 130
      check not alive(child)
