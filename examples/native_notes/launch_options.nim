## Leaf Notes launch options and the isolated demo dataset location.
##
## Parsing and path resolution only: this module never removes or overwrites a
## database, a sidecar file or a directory that already exists. `--demo` always
## picks a fresh dataset directory; reopen one explicitly with `--database PATH`.
import std/[os, strutils, times]
import leaf/native_theme

type
  LaunchOptionError* = object of CatchableError ## Usage error; exit code 2.

  LaunchOptions* = object
    demo*: bool             ## --demo: start from a fresh isolated dataset
    help*: bool
    database*: string       ## --database value; "" when the flag is absent
    theme*: NativeTheme
    remaining*: seq[string] ## Leaf's own flags (--check/--headless/events/trace)

const
  NotebookFileName* = "notes.sqlite3"
  DemoDirectoryName* = "leaf-notes-demo"
  UsageText* = "Usage: LeafNotes [--demo | --database PATH] " &
    "[--theme light|dark|system] [--help] [Leaf options]"

proc userDatabasePath*(dataDir: string): string =
  ## Default notebook next to the user's other application data.
  dataDir / "leaf-notes" / NotebookFileName

proc demoRoot*(tempDir: string): string =
  ## Dedicated directory that holds only demo datasets.
  tempDir / DemoDirectoryName

proc demoDatabasePath*(tempDir, batch: string): string =
  ## Deterministic location for one named demo dataset.
  demoRoot(tempDir) / ("demo-" & batch) / NotebookFileName

proc themeNamed*(name: string): NativeTheme =
  case name
  of "light": matsuLight
  of "dark": matsuDark
  of "system": systemTheme
  else:
    raise newException(LaunchOptionError,
      "Theme must be light, dark or system: " & name)

proc parseLaunchOptions*(args: seq[string]): LaunchOptions =
  ## Single validation point: no branch returns unvalidated options.
  result = LaunchOptions(theme: matsuLight)
  var index = 0
  var passthrough = false
  while index < args.len:
    let flag = args[index]
    case flag
    of "--help", "-h":
      result.help = true
      inc index
    of "--demo":
      result.demo = true
      inc index
    of "--reset":
      raise newException(LaunchOptionError,
        "--reset was removed: --demo starts a fresh dataset each launch; " &
        "reopen one with --database PATH")
    of "--database", "--theme":
      if index + 1 >= args.len or args[index + 1].len == 0 or
          args[index + 1].startsWith("--"):
        raise newException(LaunchOptionError, flag & " needs a value")
      let value = args[index + 1]
      if flag == "--database": result.database = value
      else: result.theme = themeNamed(value)
      index += 2
    else:
      # Everything from Leaf's first own flag on belongs to Leaf. Application
      # options are documented as coming first so this split stays unambiguous.
      passthrough = true
      break
  if passthrough: result.remaining = args[index .. ^1]
  # Checked after the loop so a trailing Leaf flag cannot skip the invariant.
  if result.demo and result.database.len > 0:
    raise newException(LaunchOptionError,
      "--demo and --database cannot be combined")

proc newDemoDatabase*(tempDir: string): string =
  ## Create (but do not open) a fresh, uniquely named demo dataset directory.
  let root = demoRoot(tempDir)
  if symlinkExists(root):
    raise newException(LaunchOptionError,
      "Refusing a symlinked demo directory: " & root)
  try:
    createDir(root)
  except OSError as error:
    raise newException(LaunchOptionError,
      "Cannot create the demo directory: " & error.msg)
  let stamp = now().utc.format("yyyyMMdd-HHmmss") & "-" & $getCurrentProcessId()
  var suffix = 0
  while true:
    let batch = if suffix == 0: stamp else: stamp & "-" & $suffix
    let candidate = demoDatabasePath(tempDir, batch)
    let directory = candidate.parentDir
    if not (dirExists(directory) or symlinkExists(directory) or
        fileExists(candidate) or symlinkExists(candidate)):
      try:
        createDir(directory)
      except OSError as error:
        raise newException(LaunchOptionError,
          "Cannot create the demo dataset: " & error.msg)
      return candidate
    inc suffix

proc prepareDatabase*(options: LaunchOptions, dataDir, tempDir: string): string =
  ## Resolve the notebook to open. Never clears or overwrites an existing file:
  ## demo runs create a new dataset directory, explicit paths are used as-is.
  if options.demo and options.database.len > 0:
    raise newException(LaunchOptionError,
      "--demo and --database cannot be combined")
  if options.demo:
    return absolutePath(newDemoDatabase(tempDir))
  let requested = if options.database.len > 0: options.database
    else: userDatabasePath(dataDir)
  result = absolutePath(requested)
  if dirExists(result):
    raise newException(LaunchOptionError, "Database path is a directory: " & result)
