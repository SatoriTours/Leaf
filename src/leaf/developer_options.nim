import std/os
import ./diagnostics

type DeveloperOptions* = object
  trace*, watching*: bool
  logFile*, dumpFile*: string
  remaining*: seq[string]

proc parseDeveloperOptions*(args: seq[string], projectRoot = ""): DeveloperOptions =
  var i = 0
  while i < args.len:
    let flag = args[i]
    case flag
    of "--trace": result.trace = true
    of "--watch": result.watching = true
    of "--log-file", "--dump-tree":
      inc i
      if i >= args.len: raise newException(ValueError, "missing argument for " & flag)
      if args[i].len == 0: raise newException(ValueError, "empty diagnostic output path")
      if flag == "--log-file": result.logFile = absolutePath(args[i])
      else: result.dumpFile = absolutePath(args[i])
    else:
      result.remaining.add(flag)
      # Event values can contain flags literally; preserve their positions.
      let count = case flag
        of "--click": 1
        of "--change", "--submit", "--toggle": 2
        of "--list": 3
        else: 0
      for argument in 0..<count:
        inc i
        if i >= args.len: raise newException(ValueError, "missing argument for " & flag)
        result.remaining.add(args[i])
    inc i
  validateOutputs(result.logFile, result.dumpFile, projectRoot, result.watching)

proc diagnostics*(options: DeveloperOptions): Diagnostics =
  if options.trace or options.logFile.len > 0 or options.dumpFile.len > 0:
    result = newDiagnostics(options.trace, options.logFile, options.dumpFile)

proc launchArgs*(options: DeveloperOptions): seq[string] =
  result = options.remaining
  if options.trace: result.add("--trace")
  if options.logFile.len > 0: result.add(@["--log-file", options.logFile])
  if options.dumpFile.len > 0: result.add(@["--dump-tree", options.dumpFile])
