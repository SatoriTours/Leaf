## Native application harness shared by examples and compiled user projects.
## Event commands execute in order, then emit the last successful snapshot.
import std/[os, strutils, json, options]
import ./[core, diagnostics, developer_options, styles,backend,managed_runtime]

proc helpText*(): string =
  """Leaf Nim application
  --check                       Validate the initial component tree
  --headless                    Execute events and output JSON
  --click KEY                   Click a button
  --change KEY VALUE            Change an input
  --toggle KEY true|false       Change a checkbox or switch
  --submit KEY VALUE            Submit an input
  --list KEY FIRST FINISH       Materialize a half-open list range
  --dump-tree FILE              Write the successful snapshot
  --trace                       Write structured diagnostics to stderr
  --log-file FILE               Append structured JSONL diagnostics
  --stats                       Include runtime counters in JSON
"""

proc runHeadless*(app: Application, args: seq[string], cleanupOwner: ptr Runtime = nil): int =
  if cleanupOwner != nil and cleanupOwner[] != nil:
    fail("headless cleanup owner slot must be empty")
  var runtime: Runtime
  var diagnostics: Diagnostics
  var primary, cleanup: ref CatchableError
  var status = none(int)
  try:
    let options = parseDeveloperOptions(args)
    if options.watching: fail("--watch is only supported by the developer CLI for desktop applications")
    let args = options.remaining
    diagnostics = options.diagnostics()
    runtime = newRuntime(app, diagnostics=diagnostics)
    proc execute(): int =
      var i = 0
      var includeStats = false
      var checkOnly = false
      if runtime.managed:discard runtime.useNativePolicy(fullCapabilities())
      else:runtime.setValidator(proc(snapshot:Snapshot)=validateProps(snapshot.root))
      proc next(): string =
        inc i
        if i >= args.len: fail("missing argument for " & args[i - 1])
        args[i]
      while i < args.len:
        case args[i]
        of "--help", "-h":
          stdout.write(helpText())
          return 0
        of "--headless": discard
        of "--check": checkOnly = true
        of "--stats": includeStats = true
        of "--click":
          discard runtime.dispatch(next(), Event(kind: click))
        of "--change", "--submit", "--toggle":
          let flag = args[i]
          let key = next()
          let value = next()
          let kind = if flag == "--submit": submit else: change
          if flag == "--toggle" and value notin ["true", "false"]:
            fail("toggle value must be true or false")
          discard runtime.dispatch(key, Event(kind: kind, value: value, checked: value == "true"))
        of "--list":
          let key = next()
          let first = parseInt(next())
          let finish = parseInt(next())
          discard runtime.materialize(key, first, finish)
        else: fail("unknown application option: " & args[i])
        inc i
      var tree = runtime.snapshot.toJson()
      if includeStats: tree["performance"] = %runtime.stats
      diagnostics.snapshot(tree)
      if not checkOnly: stdout.write($tree & "\n")
    status = some(execute())
  except CatchableError as error:
    primary = error

  # Construction has already attempted cleanup. Preserve its owner and error;
  # neither diagnostics teardown nor an outer finally may repeat that attempt.
  if primary of RuntimeCleanupError and cast[ref RuntimeCleanupError](primary).cleanupRuntime != nil:
    if cleanupOwner != nil: cleanupOwner[] = cast[ref RuntimeCleanupError](primary).cleanupRuntime
    try: diagnostics.close()
    except CatchableError: discard
    raise primary
  if runtime != nil:
    try: runtime.closeRuntime()
    except CatchableError as error: cleanup = error
  try: diagnostics.close()
  except CatchableError as error:
    if primary == nil and cleanup == nil: primary = error
  if cleanup != nil:
    if cleanupOwner != nil: cleanupOwner[] = runtime
    if primary == nil and status.isSome and cleanupOwner != nil: return status.get()
    let failure = newException(RuntimeCleanupError, (if primary != nil: primary.msg else: cleanup.msg))
    failure.parent = (if primary != nil: primary else: cleanup)
    failure.cleanupRuntime = runtime
    failure.exitStatus = (if primary != nil: none(int) else: status)
    raise failure
  if primary != nil:
    stderr.writeLine("leaf: " & primary.msg)
    return 1
  status.get()

proc runHeadless*(app: Application, cleanupOwner: ptr Runtime = nil): int =
  runHeadless(app, commandLineParams(), cleanupOwner)
