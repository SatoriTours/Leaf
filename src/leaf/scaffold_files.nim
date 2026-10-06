## Preflight every write, then roll back ordinary failures without touching user files.
import std/[os, strutils]
import ./[core, project, scaffold_types]

proc guardedPath*(root, relative: string): string =
  discard portableRelative(relative)
  var path = root
  var ancestor = absolutePath(root)
  while true:
    if symlinkExists(ancestor): fail("scaffold path cannot be a symbolic link: " & ancestor)
    let parent = ancestor.parentDir
    if parent == ancestor or parent.len == 0: break
    ancestor = parent
  for part in relative.split('/'):
    path = path / part
    if symlinkExists(path): fail("scaffold path cannot be a symbolic link: " & path)
    if path != root / relative and fileExists(path): fail("scaffold parent is a file: " & path)
  path

proc checkPlan*(root: string, plan: seq[ScaffoldFile], newProject: bool) =
  if newProject and (fileExists(root) or dirExists(root) or symlinkExists(root)):
    fail("refusing to overwrite existing project: " & root)
  for file in plan:
    let path = guardedPath(root, file.path)
    if file.update:
      if not fileExists(path) or readFile(path) != file.previous:
        fail("generated file was modified; preserve it and resolve the conflict: " & file.path)
    elif fileExists(path) or dirExists(path):
      fail("scaffold file already exists: " & file.path)

proc writePlan*(root: string, plan: seq[ScaffoldFile], newProject: bool) =
  checkPlan(root, plan, newProject)
  var attempted: seq[ScaffoldFile]
  var directories: seq[string]
  proc ensureDirectory(path: string) =
    if dirExists(path): return
    if path.parentDir != path: ensureDirectory(path.parentDir)
    createDir(path)
    directories.add(path)
  try:
    for file in plan:
      let path = guardedPath(root, file.path)
      ensureDirectory(path.parentDir)
      # Record before writing so a partially written file is also restored.
      attempted.add(file)
      writeFile(path, file.content)
  except CatchableError as failure:
    var recoveryErrors: seq[string]
    for i in countdown(attempted.high, 0):
      let file = attempted[i]
      let path = root / file.path
      try:
        if file.update:
          # A failed open may leave an unwritable original untouched.
          if not fileExists(path) or readFile(path) != file.previous:
            writeFile(path, file.previous)
        elif fileExists(path): removeFile(path)
      except CatchableError as recovery:
        recoveryErrors.add(file.path & ": " & recovery.msg)
    for i in countdown(directories.high, 0):
      try:
        if dirExists(directories[i]):
          var empty = true
          for kind, path in walkDir(directories[i]): empty = false
          if empty: removeDir(directories[i])
      except CatchableError as recovery:
        recoveryErrors.add(directories[i] & ": " & recovery.msg)
    if recoveryErrors.len > 0:
      fail(failure.msg & "; rollback incomplete: " & recoveryErrors.join("; "))
    raise failure
