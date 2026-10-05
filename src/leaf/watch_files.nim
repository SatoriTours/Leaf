## Bounded project scan. Symlink directories are never followed.
import std/[os, times, tables, strutils]

type
  FileStamp* = object
    size*: BiggestInt
    modified*: Time
  FileSnapshot* = Table[string, FileStamp]

proc scanFiles*(root: string, maxEntries = 10_000): FileSnapshot =
  var entries = 0
  # Nim closure capture cannot capture an implicit result safely under ORC.
  var snapshot: FileSnapshot
  proc collect(directory: string, assets: bool) =
    for kind, path in walkDir(directory):
      inc entries
      if entries > maxEntries: raise newException(ValueError, "watch project exceeds " & $maxEntries & " directory entries")
      case kind
      of pcDir:
        if path.extractFilename notin ["target", "dist", "vendor", ".git", ".superpowers", ".agents", ".codex"]:
          collect(path, assets or path == root / "assets")
      of pcFile:
        if assets or path.endsWith(".nim") or path.endsWith(".nims") or path.endsWith(".cfg") or path.extractFilename == "leaf.json":
          let info = getFileInfo(path)
          snapshot[path] = FileStamp(size: info.size, modified: info.lastWriteTime)
      of pcLinkToFile, pcLinkToDir: discard
  collect(root, false)
  result = move(snapshot)
