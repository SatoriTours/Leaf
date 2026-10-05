## Retain test directories until C atexit runs, after module globals finalize.
import std/[os, exitprocs]

proc removeDirectoryOnExit*(directory: string) =
  # Capturing this argument owns its string; referring to a module global
  # from an exit hook would read that global after ORC has released it.
  addExitProc(proc() = removeDir(directory))
