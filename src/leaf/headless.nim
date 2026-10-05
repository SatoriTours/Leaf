## Native application harness shared by examples and compiled user projects.
## Event commands execute in order, then emit the last successful snapshot.
import std/[os, strutils, json]
import ./[core, diagnostics, developer_options]

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

proc runHeadless*(app: Application, args: seq[string]): int =
  try:
    let options = parseDeveloperOptions(args)
    if options.watching: fail("--watch is only supported by the developer CLI for desktop applications")
    let args = options.remaining
    let diagnostics = options.diagnostics()
    defer: diagnostics.close()
    var i = 0
    var includeStats = false
    var checkOnly = false
    let runtime = newRuntime(app, diagnostics = diagnostics)
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
  except CatchableError as error:
    stderr.writeLine("leaf: " & error.msg)
    result = 1

proc runHeadless*(app: Application): int =
  runHeadless(app, commandLineParams())
