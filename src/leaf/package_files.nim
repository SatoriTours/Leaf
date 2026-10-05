## Portable resource collection, with the same rules for explicit and implicit files.
import std/[os, algorithm, tables, unicode, strutils]
import ./[core, project, process_io]

type PackageFile* = object
  source*, relative*: string
  directory*: bool

proc checkCancelled*() =
  if wasInterrupted(): raise newException(ProcessInterruptedError, "packaging interrupted")

proc checkSource*(root, relative: string): string =
  discard portableRelative(relative)
  var current = root
  for part in relative.split('/'):
    current = current / part
    if symlinkExists(current): fail("release files cannot be symbolic links or reparse points: " & relative)
  let info = getFileInfo(current, followSymlink = false)
  if info.isSpecial or info.kind notin {pcFile, pcDir}: fail("release requires regular files or directories: " & relative)
  result = resolve(root, relative)

proc collectFiles*(project: Project): seq[PackageFile] =
  if project.configFile.len == 0: fail("release packaging requires leaf.json")
  discard checkSource(project.root, "leaf.json")
  var names: Table[string, PackageFile]
  proc add(relative: string, directory: bool, source: string, allowParent = false) =
    discard portableRelative(relative)
    if relative.split('/').len > 64: fail("release path exceeds depth 64")
    if unicode.toLower(relative) == "leaf.json": fail("leaf.json is generated; do not include it")
    let key = unicode.toLower(relative)
    if key in names:
      if allowParent and names[key].relative == relative and names[key].directory: return
      fail("overlapping include or case-insensitive path collision: " & relative)
    if names.len >= 10_000: fail("release exceeds 10000 files/directories")
    names[key] = PackageFile(source: source, relative: relative, directory: directory)
  proc visit(relative: string) =
    checkCancelled()
    let source = checkSource(project.root, relative)
    let directory = dirExists(source)
    add(relative, directory, source)
    if directory:
      var children: seq[string]
      for kind, path in walkDir(source):
        if children.len + names.len >= 10_000: fail("release exceeds 10000 files/directories")
        children.add(path.extractFilename)
      children.sort()
      for child in children: visit(relative & "/" & child)
  for relative in project.includedPaths:
    discard checkSource(project.root, relative)
    # Implicit parent directories are shared; explicit overlaps are rejected.
    let parts = relative.split('/')
    for index in 1..<parts.len:
      let parent = parts[0..<index].join("/")
      add(parent, true, checkSource(project.root, parent), allowParent = true)
    visit(relative)
  let entry = unicode.toLower(project.entryRelative)
  if entry notin names or names[entry].directory or names[entry].relative != project.entryRelative:
    fail("entry is missing from collected release files")
  for value in names.values: result.add(value)
  result.sort(proc(a, b: PackageFile): int = cmp(a.relative, b.relative))

proc implicitLicensePaths*(project: Project): seq[string] =
  for name in ["LICENSE", "NOTICE", "third-party-licenses", "third-party-licenses.json"]:
    let path = project.root / name
    var present = false
    try:
      discard getFileInfo(path, followSymlink = false)
      present = true
    except OSError as error:
      when defined(windows):
        if error.errorCode notin [2, 3]: raise
      else:
        if error.errorCode != 2: raise
    if present:
      discard checkSource(project.root, name)
      result.add(name)

proc prospectiveRealPath(path: string): string =
  var existing = normalizedPath(absolutePath(path))
  var suffix: seq[string]
  while not fileExists(existing) and not dirExists(existing):
    if symlinkExists(existing): fail("output path contains a dangling symlink")
    suffix.add(existing.extractFilename)
    let parent = existing.parentDir
    if parent == existing: fail("cannot resolve output path")
    existing = parent
  result = realPath(existing)
  for i in countdown(suffix.high, 0): result = result / suffix[i]

proc validateOutput*(project: Project, output: string) =
  let canonical = prospectiveRealPath(output)
  if fileExists(canonical): fail("release output must be a directory")
  for relative in project.includedPaths & implicitLicensePaths(project):
    let source = checkSource(project.root, relative)
    if within(source, canonical): fail("release output is inside included files or licenses: " & relative)

proc checkBinarySource*(project: Project, path: string): string =
  var full = normalizedPath(absolutePath(path))
  var anchor = ""
  if within(project.root, full):
    anchor = project.root
  elif within(getTempDir(), full):
    # OS temp roots (notably /var on macOS) may themselves be aliases. Treat
    # that configured root like the already-canonical project root; every
    # component below it still receives the no-link check.
    let relative = relativePath(full, getTempDir())
    anchor = realPath(getTempDir())
    full = normalizedPath(anchor / relative)
  var current = full
  while current.len > 0:
    if symlinkExists(current): fail("application binary path contains a symbolic link or reparse point: " & path)
    if anchor.len > 0 and within(anchor, current) and within(current, anchor): break
    let parent = current.parentDir
    if parent.len == 0 or parent == current: break
    current = parent
  let info = getFileInfo(full, followSymlink = false)
  if info.isSpecial or info.kind != pcFile: fail("application binary must be a regular file: " & path)
  result = realPath(full)

proc copyRegular*(source, destination: string) =
  checkCancelled()
  if symlinkExists(source): fail("refusing to copy release symlink: " & source)
  let before = getFileInfo(source, followSymlink = false)
  if before.isSpecial or before.kind != pcFile: fail("release requires a regular file: " & source)
  createDir(destination.parentDir)
  let input = open(source, fmRead)
  defer: input.close()
  let output = open(destination, fmWrite)
  defer: output.close()
  var buffer = newString(65_536)
  var total: int64
  while true:
    checkCancelled()
    let count = input.readBuffer(addr buffer[0], buffer.len)
    if count == 0: break
    if output.writeBuffer(addr buffer[0], count) != count: raise newException(IOError, "release copy failed")
    total += int64(count)
  let after = getFileInfo(source, followSymlink = false)
  if after.kind != pcFile or before.id != after.id or total != before.size or before.size != after.size or before.lastWriteTime != after.lastWriteTime:
    fail("release source changed while copying: " & source)

proc copyFiles*(project: Project, files: seq[PackageFile], destination: string) =
  createDir(destination)
  for file in files:
    let source = checkSource(project.root, file.relative)
    if file.directory: createDir(destination / file.relative)
    else: copyRegular(source, destination / file.relative)

proc copyLicenseTree*(project: Project, relative, destination: string) =
  var count = 0
  var names: Table[string, string]
  proc visit(name: string, depth: int) =
    checkCancelled()
    if depth > 64: fail("license path exceeds depth 64")
    inc count
    if count > 10_000: fail("license tree exceeds 10000 entries")
    let source = checkSource(project.root, name)
    let key = unicode.toLower(name)
    if key in names: fail("case-insensitive license path collision: " & name)
    names[key] = name
    let suffix = if name == relative: "" else: name[relative.len + 1..^1]
    let target = if suffix.len == 0: destination else: destination / suffix
    if dirExists(source):
      createDir(target)
      for kind, child in walkDir(source): visit(name & "/" & child.extractFilename, depth + 1)
    else: copyRegular(source, target)
  visit(relative, 1)
