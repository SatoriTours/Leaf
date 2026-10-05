## Optional JSONL diagnostics. Failed renders never replace the last good dump.
import std/[os, json, times, strutils, tempfiles]
when defined(windows): import ./windows_paths

type Diagnostics* = ref object
  log: File
  trace*: bool
  dumpFile*: string
  closed: bool

proc canonical(path: string): string =
  let full = normalizedPath(absolutePath(path))
  if fileExists(full) or dirExists(full) or symlinkExists(full):
    when defined(windows): result = realPath(full)
    else: result = expandFilename(full)
  else:
    if not dirExists(full.parentDir): raise newException(ValueError, "diagnostic output directory does not exist: " & full.parentDir)
    when defined(windows): result = realPath(full.parentDir) / full.extractFilename
    else: result = expandFilename(full.parentDir) / full.extractFilename
  when defined(windows): result = result.toLowerAscii()

proc validateOutputs*(logFile, dumpFile, projectRoot: string, watching: bool) =
  var paths: seq[string]
  for path in [logFile, dumpFile]:
    if path.len == 0: continue
    let resolved = canonical(path)
    if fileExists(resolved) and getFileInfo(resolved).linkCount > 1:
      raise newException(ValueError, "diagnostic output cannot use a hard linked file: " & path)
    for candidate in [normalizedPath(absolutePath(path)), resolved]:
      if candidate.toLowerAscii.endsWith(".nim") or candidate.toLowerAscii.endsWith(".nims") or
          candidate.toLowerAscii.endsWith(".cfg") or candidate.extractFilename.toLowerAscii == "leaf.json":
        raise newException(ValueError, "diagnostic output cannot overwrite source or configuration: " & path)
    if resolved in paths: raise newException(ValueError, "log and tree outputs must use different files")
    paths.add(resolved)
    if watching and projectRoot.len > 0:
      let assets = canonical(projectRoot) / "assets"
      let realAssets = if dirExists(assets): canonical(assets) else: assets
      if resolved == realAssets or resolved.startsWith(realAssets & DirSep):
        raise newException(ValueError, "watch diagnostic output cannot be inside assets: " & path)

proc atomicWrite*(path, contents: string) =
  let (file, temporary) = createTempFile(".leaf-", ".tmp", path.parentDir)
  var closed = false
  try:
    file.write(contents)
    file.close()
    closed = true
    moveFile(temporary, path)
  finally:
    if not closed: file.close()
    if fileExists(temporary): removeFile(temporary)

proc newDiagnostics*(trace = false, logFile = "", dumpFile = "",
                     projectRoot = "", watching = false): Diagnostics =
  validateOutputs(logFile, dumpFile, projectRoot, watching)
  result = Diagnostics(trace: trace, dumpFile: dumpFile)
  if logFile.len > 0:
    result.log = open(logFile, fmAppend, bufSize = 0)

proc forwardRecord*(d: Diagnostics, record: JsonNode) =
  if d == nil or d.closed: return
  try:
    let line = $record & "\n"
    if d.log != nil: d.log.write(line)
    elif d.trace: stderr.write(line)
  except CatchableError as error: stderr.writeLine("leaf: diagnostic log failed: " & error.msg)

proc record*(d: Diagnostics, phase, status: string, details = newJObject()) =
  if d == nil or d.closed: return
  d.forwardRecord(%*{"time_ms": int64(epochTime() * 1000), "pid": getCurrentProcessId(),
    "phase": phase, "status": status, "details": details})

proc snapshot*(d: Diagnostics, tree: JsonNode) =
  if d == nil or d.closed or d.dumpFile.len == 0: return
  try: atomicWrite(d.dumpFile, tree.pretty() & "\n")
  except CatchableError as error: stderr.writeLine("leaf: tree dump failed: " & error.msg)

proc close*(d: Diagnostics) =
  if d == nil or d.closed: return
  if d.log != nil: d.log.close()
  d.closed = true
