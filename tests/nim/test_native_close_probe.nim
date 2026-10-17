## A hung observation tool must not hang the native suite or retain children.
import std/[unittest, os, monotimes, times, tempfiles, strutils]
import ./gpui_native
when defined(linux):
  suite "native close observation deadline":
    test "a late nonzero observer cannot bypass the shared deadline":
      let started = getMonoTime()
      var timedOut = false
      try:
        discard probeWindowGone("/bin/sh", @["-c", "sleep 0.3; exit 1"], getCurrentDir(),
          started + initDuration(milliseconds = 40))
      except IOError: timedOut = true
      check timedOut
      check getMonoTime() - started < initDuration(seconds = 1)
    test "nonzero failure observes gone and closes immediately within the same deadline":
      let deadline = getMonoTime() + initDuration(seconds = 1)
      check probeWindowGone("/bin/sh", @["-c", "exit 7"], getCurrentDir(), deadline)
      check not probeWindowGone("/bin/sh", @["-c", "exit 0"], getCurrentDir(), deadline)

    test "timeout closes the observer process group and all managed descriptors":
      let directory = createTempDir("leaf-native-probe-", "")
      defer: removeDir(directory)
      proc descriptorCount(): int =
        for kind, path in walkDir("/proc/self/fd"): inc result
      proc alive(pid: string): bool =
        let path = "/proc/" & pid & "/stat"
        if not fileExists(path): return false
        let stat = readFile(path)
        stat[stat.rfind(')')+2] != 'Z'
      let before = descriptorCount()
      let started = getMonoTime()
      var timedOut = false
      try:
        discard probeWindowGone("/bin/sh", @["-c",
          "echo $$ > leader; sleep 60 & echo $! > child; wait"], directory,
          started + initDuration(milliseconds = 100))
      except IOError: timedOut = true
      check timedOut
      # ManagedProcess.close has an existing <=500ms TERM grace before KILL;
      # the shared polling deadline is not a claim of preemptive cleanup.
      check getMonoTime() - started < initDuration(seconds = 2)
      for name in ["leader", "child"]:
        check fileExists(directory / name)
        if fileExists(directory / name): check not alive(readFile(directory / name).strip())
      check descriptorCount() == before
      expect IOError:
        discard probeWindowGone("/bin/sh", @["-c", "touch should-not-start"], directory, started)
      check not fileExists(directory / "should-not-start")
