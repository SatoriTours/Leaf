## Developer CLI: native Nim applications are compiled before execution.
import std/[os, json, strutils, strtabs]
import leaf/[core, project, build, doctor, developer_options, diagnostics, watch, process_io, pack, scaffold]
export build

proc execute(exe: string, args: seq[string], workingDir: string): int =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  env["LEAF_PROJECT_ROOT"] = workingDir
  beginInterruptHandling()
  defer: endInterruptHandling()
  let process = startManaged(exe, args, workingDir, env, parentStreams = true)
  defer: process.close()
  while not process.poll():
    if wasInterrupted(): raise newException(ProcessInterruptedError, "application interrupted")
    sleep(10)
  process.code

proc main*(args: seq[string]): int =
  try:
    if args.len == 0 or args[0] in ["--help", "-h"]:
      stdout.writeLine("""Leaf Nim developer tools
  leaf init DIRECTORY              Create a native Nim application
  leaf g scaffold DIRECTORY [--dry-run] Create a full page-group application
  leaf g scaffold MODEL FIELD:TYPE... --project DIRECTORY [--dry-run]
                                   Add a resource with CRUD pages, routes and SQL
  leaf generate scaffold ...       Alias for leaf g scaffold
  leaf build PROJECT [--output EXE] Compile a release application
  leaf pack PROJECT --target TARGET [--binary EXE] [--output DIR]
  leaf doctor [--json]              Show the local build environment
  leaf --check PROJECT             Compile and validate the application
  leaf --headless [EVENTS] PROJECT  Compile and run ordered events
  leaf PROJECT                     Compile and open a GPUI + GPUI Kit desktop window
  leaf --watch [DIAGNOSTICS] PROJECT Rebuild and replace ready desktop windows
  DIAGNOSTICS: --trace, --log-file FILE, --dump-tree FILE

Applications are native executables. GPUI + GPUI Kit provides native windows.
Release TARGET: linux, macos, windows or all. Foreign targets need native binaries.
""")
      return 0
    case args[0]
    of "g", "generate":
      if args.len < 3 or args[1] != "scaffold":
        fail("usage: leaf g scaffold DIRECTORY | MODEL FIELD:TYPE... --project DIRECTORY [--dry-run]")
      for action in generateScaffold(parseScaffoldOptions(args[2..^1])):
        stdout.writeLine(action)
    of "init":
      if args.len != 2: fail("usage: leaf init DIRECTORY")
      initProject(args[1])
    of "pack":
      if args.len < 4: fail("usage: leaf pack PROJECT --target TARGET [--binary EXE] [--output DIR]")
      var target, binary: string
      var output = "dist"
      var seen: seq[string]
      var i = 2
      while i < args.len:
        let flag = args[i]
        if flag notin ["--target", "--binary", "--output"] or flag in seen:
          fail("unknown or duplicated pack option: " & flag)
        if i + 1 >= args.len or args[i + 1].len == 0 or args[i + 1].startsWith("--"):
          fail("missing value for " & flag)
        seen.add(flag)
        case flag
        of "--target": target = args[i + 1]
        of "--binary": binary = absolutePath(args[i + 1])
        else: output = args[i + 1]
        i += 2
      if target notin ["linux", "macos", "windows", "all"]: fail("--target must be linux, macos, windows or all")
      if target == "all" and binary.len > 0: fail("--binary requires a single target")
      for artifact in pack.pack(readProject(args[1]), target, output, binary): stdout.writeLine(artifact)
    of "doctor":
      if args.len > 2 or (args.len == 2 and args[1] != "--json"):
        fail("usage: leaf doctor [--json]")
      stdout.writeLine(doctorReport().pretty())
    of "build":
      if args.len notin [2, 4] or (args.len == 4 and args[2] != "--output"):
        fail("usage: leaf build PROJECT [--output EXE]")
      let output = if args.len == 4: args[3] else: ""
      stdout.writeLine(build(readProject(args[1]), output))
    else:
      if args[^1].startsWith("--"): fail("missing project path")
      let project = readProject(args[^1])
      let rawArgs: seq[string] = if args.len == 1: @[] else: args[0..^2]
      let options = parseDeveloperOptions(rawArgs, project.root)
      if options.watching:
        if options.remaining.len > 0: fail("--watch cannot be combined with headless or event commands")
        let d = options.diagnostics()
        defer: d.close()
        return runWatch(project, d)
      let binary = build(project)
      result = execute(binary, options.launchArgs(), project.root)
  except ProcessInterruptedError:
    result = 130
  except CatchableError as error:
    stderr.writeLine("leaf: " & error.msg)
    result = 1

proc exitCli*(code: int) {.noreturn.} =
  # Nim quit saturates POSIX integers to int8; preserve conventional 130 and
  # the full 8-bit exit status returned by a supervised application.
  when defined(posix): quit(if code in 128..255: code - 256 else: code)
  else: quit(code)

when isMainModule: exitCli(main(commandLineParams()))
