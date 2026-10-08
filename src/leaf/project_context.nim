## Resolve the Leaf project that owns a directory by walking its ancestors.
## This protocol is independent of databases and migrations: it only consults
## the nearest `leaf.json` and never scans subdirectories for a project.
import std/[options, os]
import ./core
import ./project

proc configPresent(directory: string): bool =
  ## A manifest is present whenever the name exists at all. Directories and
  ## broken symlinks still occupy `leaf.json`, so they must be validated (and
  ## rejected) rather than silently skipped in favour of an ancestor project.
  let config = directory / "leaf.json"
  fileExists(config) or dirExists(config) or symlinkExists(config)

proc loadProject(directory: string): Project =
  ## The nearest manifest is authoritative: any problem with it fails here and
  ## never falls back to an ancestor project.
  try:
    readProject(directory)
  except UiError:
    raise
  except CatchableError as error:
    raise newException(UiError,
      "invalid project configuration " & (directory / "leaf.json") & ": " & error.msg)

proc findCurrentProject*(start = getCurrentDir()): Option[Project] =
  ## Return the nearest project containing `start`, or none when no ancestor
  ## has a `leaf.json`. A corrupt nearest manifest raises UiError.
  var directory = normalizedPath(absolutePath(start))
  if not dirExists(directory): directory = directory.parentDir
  while true:
    if configPresent(directory): return some(loadProject(directory))
    let parent = directory.parentDir
    if parent == directory: break
    directory = parent
  none(Project)

proc requireCurrentProject*(start = getCurrentDir()): Project =
  ## Like findCurrentProject, but an absent project asks the caller to enter one.
  let project = findCurrentProject(start)
  if project.isSome: return project.get()
  raise newException(UiError, "no Leaf project found for " & absolutePath(start) &
    "; cd into a project directory containing leaf.json")
