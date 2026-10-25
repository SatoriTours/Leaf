## Bounded process observation shared by native test tooling.
import std/[os, monotimes]
import leaf/process_io

proc probeWindowGone*(exe: string, args: seq[string], root: string, deadline: MonoTime): bool =
  if getMonoTime() >= deadline: raise newException(IOError, "window close observation timeout")
  let probe = startManaged(exe, args, root)
  defer: probe.close()
  while true:
    if getMonoTime() >= deadline: raise newException(IOError, "window close observation timeout")
    if probe.poll(): return probe.code != 0
    sleep(1)
