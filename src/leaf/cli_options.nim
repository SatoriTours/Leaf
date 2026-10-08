## Pure command-line parsing for the Leaf developer CLI. Nothing here resolves a
## project or touches the filesystem: `parseCli` only classifies arguments and
## validates their shape, so callers can prove parsing never builds or opens a
## database. Project resolution and IO happen in the entry point afterwards.
import std/[options, strutils]
import ./core
import ./scaffold
import ./scaffold_types
import ./migrations/types

type
  CliCommandKind* = enum
    ccHelp, ccVersion, ccVerifySdk, ccInit, ccScaffoldApp, ccScaffoldResource,
    ccMigrationGenerate, ccBuild, ccPack, ccDoctor, ccRun, ccDeveloper, ccDatabase
  CliCommand* = object
    kind*: CliCommandKind
    scaffold*: ScaffoldOptions
    request*: MigrationRequest
    dryRun*, jsonOutput*: bool
    output*, binary*, target*, initDirectory*, migrationName*: string
    runArgs*, sdkArgs*: seq[string]
    ## `db init` is not a migration direction, so it is tracked separately.
    databaseInit*: bool
    watching*: bool

proc parseDecimal(raw, option: string): int64 =
  if raw.len == 0: fail("missing value for " & option)
  var value: int64
  for character in raw:
    if character notin {'0'..'9'}: fail("invalid value for " & option & ": " & raw)
    let digit = int64(ord(character) - ord('0'))
    if value > (high(int64) - digit) div 10: fail("value out of range for " & option & ": " & raw)
    value = value * 10 + digit
  value

proc parseSteps(raw: string): int =
  let value = parseDecimal(raw, "--steps")
  if value <= 0 or value > int64(high(int)): fail("--steps must be a positive integer")
  int(value)

proc parseRunArgs(args: seq[string], forWatch = false): seq[string] =
  ## Validate event arity before interpreting flags, so event text that happens
  ## to look like an option is preserved in order instead of being parsed.
  var events = 0
  var headless = false
  var stats = false
  var seen: seq[string]
  var i = 0
  while i < args.len:
    let flag = args[i]
    case flag
    of "--headless", "--check":
      if forWatch: fail("--watch cannot be combined with headless or event commands")
      if flag in seen: fail("duplicated option: " & flag)
      seen.add(flag)
      headless = true
      result.add(flag)
    of "--stats":
      if forWatch: fail("--stats requires --headless or --check")
      if flag in seen: fail("duplicated option: " & flag)
      seen.add(flag)
      stats = true
      result.add(flag)
    of "--trace":
      if flag in seen: fail("duplicated option: " & flag)
      seen.add(flag)
      result.add(flag)
    of "--log-file", "--dump-tree":
      if flag in seen: fail("duplicated option: " & flag)
      if i + 1 >= args.len: fail("missing argument for " & flag)
      seen.add(flag)
      result.add(flag)
      result.add(args[i + 1])
      inc i
    of "--click", "--change", "--submit", "--toggle", "--list":
      if forWatch: fail("--watch cannot be combined with headless or event commands")
      let count = case flag
        of "--click": 1
        of "--change", "--submit", "--toggle": 2
        else: 3
      if i + count >= args.len: fail("missing argument for " & flag)
      result.add(flag)
      for offset in 1 .. count: result.add(args[i + offset])
      i += count
      inc events
    else:
      if flag.startsWith("--"): fail("unknown option: " & flag)
      fail("unexpected argument: " & flag & "; commands operate on the current directory")
    inc i
  if events > 0 and not headless:
    fail("event commands require --headless or --check")
  if stats and not headless:
    fail("--stats requires --headless or --check")

proc parsePack(args: seq[string]): CliCommand =
  result.kind = ccPack
  if args.len < 3: fail("usage: leaf pack --target TARGET [--binary EXE] [--output DIR]")
  var seen: seq[string]
  var i = 1
  while i < args.len:
    let flag = args[i]
    if flag notin ["--target", "--binary", "--output"] or flag in seen:
      fail("unknown or duplicated pack option: " & flag)
    if i + 1 >= args.len or args[i + 1].len == 0 or args[i + 1].startsWith("--"):
      fail("missing value for " & flag)
    seen.add(flag)
    case flag
    of "--target": result.target = args[i + 1]
    of "--binary": result.binary = args[i + 1]
    else: result.output = args[i + 1]
    i += 2
  if result.target notin ["linux", "macos", "windows", "all"]:
    fail("--target must be linux, macos, windows or all")
  if result.target == "all" and result.binary.len > 0: fail("--binary requires a single target")

proc parseDatabase(args: seq[string]): CliCommand =
  result.kind = ccDatabase
  if args.len < 2:
    fail("usage: leaf db <init|migrate|rollback|forward|up|down|status> ...")
  let action = args[1]
  let rest = args[2 .. ^1]
  case action
  of "init":
    case rest.len
    of 0: result.databaseInit = true
    of 1:
      if rest[0] != "--dry-run": fail("usage: leaf db init [--dry-run]")
      result.databaseInit = true
      result.dryRun = true
    else: fail("usage: leaf db init [--dry-run]")
    return
  of "status":
    result.request = MigrationRequest(kind: mrStatus)
    case rest.len
    of 0: return
    of 1:
      if rest[0] != "--json": fail("usage: leaf db status [--json]")
      result.jsonOutput = true
      return
    else: fail("usage: leaf db status [--json]")
  of "migrate", "rollback", "forward", "up", "down": discard
  else: fail("unknown db command: " & action)
  var target: Option[int64]
  var steps = 1
  var positional = ""
  var seenTo, seenSteps, seenDry, seenJson = false
  var i = 0
  while i < rest.len:
    let flag = rest[i]
    case flag
    of "--dry-run":
      if seenDry: fail("duplicated option: --dry-run")
      seenDry = true
      result.dryRun = true
    of "--json":
      if seenJson: fail("duplicated option: --json")
      seenJson = true
      result.jsonOutput = true
    of "--to":
      if action != "migrate": fail("--to is only valid for leaf db migrate")
      if seenTo: fail("duplicated option: --to")
      if i + 1 >= rest.len: fail("missing value for --to")
      seenTo = true
      target = some(parseDecimal(rest[i + 1], "--to"))
      inc i
    of "--steps":
      if action notin ["rollback", "forward"]: fail("--steps is only valid for rollback and forward")
      if seenSteps: fail("duplicated option: --steps")
      if i + 1 >= rest.len: fail("missing value for --steps")
      seenSteps = true
      steps = parseSteps(rest[i + 1])
      inc i
    else:
      if flag.startsWith("--"): fail("unknown option for leaf db " & action & ": " & flag)
      if positional.len > 0: fail("unexpected argument for leaf db " & action & ": " & flag)
      positional = flag
    inc i
  case action
  of "migrate":
    if positional.len > 0: fail("leaf db migrate does not take a positional argument")
    result.request = MigrationRequest(kind: mrMigrate, target: target)
  of "rollback", "forward":
    if positional.len > 0: fail("leaf db " & action & " takes only --steps")
    result.request = MigrationRequest(kind: (if action == "rollback": mrRollback else: mrForward),
      steps: steps)
  of "up", "down":
    if target.isSome: fail("leaf db " & action & " takes a positional version")
    if positional.len == 0: fail("usage: leaf db " & action & " VERSION")
    let version = parseDecimal(positional, action)
    if version <= 0: fail("version must be positive for leaf db " & action)
    result.request = MigrationRequest(kind: (if action == "up": mrUp else: mrDown),
      target: some(version))
  else: discard

proc parseCli*(args: seq[string]): CliCommand =
  ## Classify the whole command line without resolving any project.
  if args.len == 0: return CliCommand(kind: ccRun)
  case args[0]
  of "--help", "-h":
    if args.len != 1: fail("usage: leaf --help")
    result.kind = ccHelp
  of "--version", "-v":
    if args.len != 1: fail("usage: leaf --version")
    result.kind = ccVersion
  of "--verify-sdk":
    if args.len notin [3, 4]: fail("usage: leaf --verify-sdk CHANNEL TARGET [VERSION]")
    result.kind = ccVerifySdk
    result.sdkArgs = args[1 .. ^1]
  of "init":
    if args.len != 2: fail("usage: leaf init DIRECTORY")
    result.kind = ccInit
    result.initDirectory = args[1]
  of "g", "generate":
    if args.len < 2: fail("usage: leaf g scaffold|migration ...")
    case args[1]
    of "scaffold":
      let options = parseScaffoldOptions(args[2 .. ^1])
      result.scaffold = options
      result.dryRun = options.dryRun
      result.kind = if options.mode == smApplication: ccScaffoldApp else: ccScaffoldResource
    of "migration":
      if args.len notin [3, 4] or (args.len == 4 and args[3] != "--dry-run"):
        fail("usage: leaf g migration NAME [--dry-run]")
      result.kind = ccMigrationGenerate
      result.migrationName = args[2]
      result.dryRun = args.len == 4
    else: fail("usage: leaf g scaffold|migration ...")
  of "build":
    result.kind = ccBuild
    if args.len == 1: discard
    elif args.len == 3 and args[1] == "--output": result.output = args[2]
    else: fail("usage: leaf build [--output EXE]")
  of "pack":
    result = parsePack(args)
  of "doctor":
    result.kind = ccDoctor
    if args.len == 2:
      if args[1] != "--json": fail("usage: leaf doctor [--json]")
      result.jsonOutput = true
    elif args.len != 1: fail("usage: leaf doctor [--json]")
  of "db":
    result = parseDatabase(args)
  of "--watch":
    result.kind = ccDeveloper
    result.watching = true
    result.runArgs = parseRunArgs(args[1 .. ^1], forWatch = true)
  else:
    if not args[0].startsWith("--"):
      fail("unknown command: " & args[0] & "; commands operate on the current directory")
    result.kind = ccRun
    result.runArgs = parseRunArgs(args)
