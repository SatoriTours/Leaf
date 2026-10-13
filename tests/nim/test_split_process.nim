## Exercises the same POSIX group backend on Linux with -d:leafPortableSplit.
import ./cleanup_support
import std/[monotimes, os, strutils, tempfiles, times, unittest]
import leaf/process_io
when defined(posix): import std/posix
# The fault and Darwin-waitid wrappers live in one test-only C translation unit;
# each build enables only the link injections it declared.
when defined(leafSplitFaultTest) and defined(linux):
  {.passC: "-DLEAF_SPLIT_FAULT_TEST".}
  {.passL: "-Wl,--wrap=waitpid -Wl,--wrap=read".}
when defined(leafSplitDarwinWaitid) and defined(linux):
  {.passC: "-DLEAF_SPLIT_DARWIN_WAITID".}
  {.passL: "-Wl,--wrap=waitid".}
when defined(linux) and (defined(leafSplitFaultTest) or defined(leafSplitDarwinWaitid)):
  {.compile: "split_process_faults.c".}

let args = commandLineParams()
if args == @["--burst"]:
  for _ in 0 ..< 80:
    stdout.write(repeat('O', 8192))
    stderr.write(repeat('E', 8192))
  stdout.write("stdout-tail")
  stderr.write("stderr-tail")
  quit(23)
if args == @["--sleep"]:
  sleep(60_000)
  quit(0)
if args == @["--negative-exit"]:
  # Mirrors leaf_cli.exitCli's POSIX convention: the conventional 130 status is
  # emitted through Nim's int8-saturating quit as quit(-126). Darwin's waitid
  # reports that whole 32-bit value in si_status, while Linux encodes the low
  # eight bits, so the owner must normalize both to 130.
  quit(130 - 256)
if args.len == 2 and args[0] == "--nested":
  let child = startSplitManaged(getAppFilename(), @["--sleep"], getCurrentDir())
  writeFile(args[1], $child.splitPid())
  while true: sleep(10)

let root = createTempDir("leaf-split-", "")
removeDirectoryOnExit(root)

proc finish(child: SplitProcess) =
  let deadline = getMonoTime() + initDuration(seconds = 15)
  while not child.pollSplit():
    if getMonoTime() > deadline: raise newException(IOError, "split process timed out")
    sleep(5)

suite "Split subprocess lifecycle":
  test "fair bounded streams preserve both tails and the exact exit":
    let child = startSplitManaged(getAppFilename(), @["--burst"], root)
    defer: child.closeSplit()
    child.finish()
    child.closeSplit()
    check child.code == 23
    check child.stdoutText.endsWith("stdout-tail")
    check child.stderrText.endsWith("stderr-tail")
    check child.stdoutText.len <= SplitOutputCap
    check child.stderrText.len <= SplitOutputCap
    check not child.protocolError
    check not child.cleanupUnconfirmed

  test "a launch failure stays a failure through close":
    when defined(windows):
      # CreateProcessW reports a missing executable synchronously; no child is
      # returned. POSIX reports exec failure through its guardian status pipe.
      expect OSError:
        discard startSplitManaged(root / "missing-executable", @[], root)
    else:
      let child = startSplitManaged(root / "missing-executable", @[], root)
      defer: child.closeSplit()
      child.finish()
      child.closeSplit()
      check child.code == 127
      check not child.cleanupUnconfirmed

  test "a full width POSIX exit keeps its conventional eight bit status":
    when defined(posix):
      # leaf_cli.exitCli reports conventional 130 through Nim's int8-saturating
      # quit as quit(-126). Darwin's waitid returns the whole 32-bit value, so
      # the owner sees either -126 (p_xhighbits still set) or, after the kernel
      # clears them even under WNOWAIT, 0x00FFFF82. Both must normalize to 130.
      # LEAF_SPLIT_WAITID_FORM only steers the test-only Darwin replay wrapper,
      # so both forms are asserted independently with real guardian processes.
      for form in ["sign", "cleared"]:
        block:
          let previousForm = getEnv("LEAF_SPLIT_WAITID_FORM")
          if form == "cleared": putEnv("LEAF_SPLIT_WAITID_FORM", "cleared")
          else: delEnv("LEAF_SPLIT_WAITID_FORM")
          defer:
            if previousForm.len > 0: putEnv("LEAF_SPLIT_WAITID_FORM", previousForm)
            else: delEnv("LEAF_SPLIT_WAITID_FORM")
          let child = startSplitManaged(getAppFilename(), @["--negative-exit"], root)
          # A timeout in finish must never leak the owner or the replay mode.
          defer: child.closeSplit()
          child.finish()
          child.closeSplit()
          checkpoint "form=" & form
          check child.code == 130
          check not child.protocolError
          check not child.cleanupUnconfirmed

  test "closing one split leaves its sibling usable":
    let one = startSplitManaged(getAppFilename(), @["--sleep"], root)
    let two = startSplitManaged(getAppFilename(), @["--burst"], root)
    defer: one.closeSplit()
    defer: two.closeSplit()
    one.closeSplit()
    two.finish()
    two.closeSplit()
    check not one.cleanupUnconfirmed
    check not two.cleanupUnconfirmed
    check two.code == 23
    check two.stdoutText.endsWith("stdout-tail")

  when defined(posix):
    test "guardians close unrelated inherited descriptors above 1023":
      var original: RLimit
      require getrlimit(RLIMIT_NOFILE, original) == 0
      if original.rlim_cur <= 2048:
        var raised = original
        raised.rlim_cur = 2049
        require setrlimit(RLIMIT_NOFILE, raised) == 0
      defer: discard setrlimit(RLIMIT_NOFILE, original)
      var channel: array[2, cint]
      require pipe(channel) == 0
      let highFd = fcntl(channel[1], F_DUPFD, 2048)
      require highFd >= 2048
      discard close(channel[1])
      defer: discard close(channel[0])
      let child = startSplitManaged(getAppFilename(), @["--sleep"], root)
      defer: child.closeSplit()
      discard close(highFd)
      let flags = fcntl(channel[0], F_GETFL, 0)
      discard fcntl(channel[0], F_SETFL, flags or O_NONBLOCK)
      var data: char
      check posix.read(channel[0], addr data, 1) == 0
      child.closeSplit()
      check not child.cleanupUnconfirmed

    test "closing a parent also stops its nested Leaf command":
      let marker = root / "nested.pid"
      let parent = startSplitManaged(getAppFilename(), @["--nested", marker], root)
      defer: parent.closeSplit()
      let ready = getMonoTime() + initDuration(seconds = 5)
      while not fileExists(marker):
        if parent.pollSplit() or getMonoTime() > ready:
          raise newException(IOError, "nested command not ready")
        sleep(5)
      let pid = Pid(parseInt(readFile(marker)))
      parent.closeSplit()
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while kill(pid, 0) == 0 and getMonoTime() < deadline: sleep(10)
      check kill(pid, 0) != 0
      check not parent.cleanupUnconfirmed

  when defined(leafSplitFaultTest) and defined(linux):
    test "finite owner wait errors still reap the tree and report failure":
      let marker = root / "fault-nested.pid"
      putEnv("LEAF_SPLIT_FAULT_WAIT", marker)
      defer: delEnv("LEAF_SPLIT_FAULT_WAIT")
      let parent = startSplitManaged(getAppFilename(), @["--nested", marker], root)
      defer: parent.closeSplit()
      parent.finish()
      parent.closeSplit()
      check parent.protocolError
      check parent.cleanupUnconfirmed
      let pid = Pid(parseInt(readFile(marker)))
      check kill(pid, 0) != 0

    test "an output read failure stops polling and preserves cleanup":
      putEnv("LEAF_SPLIT_FAULT_READ", "1")
      defer: delEnv("LEAF_SPLIT_FAULT_READ")
      let child = startSplitManaged(getAppFilename(), @["--burst"], root)
      defer: child.closeSplit()
      child.finish()
      child.closeSplit()
      check child.protocolError
      check not child.cleanupUnconfirmed
