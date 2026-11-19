import std/os
import leaf
import ./[store, application, launch_options]

proc main(): int =
  var options: LaunchOptions
  try:
    options = parseLaunchOptions(commandLineParams())
  except LaunchOptionError as error:
    stderr.writeLine(error.msg)
    stderr.writeLine(UsageText)
    return 2
  if options.help:
    stdout.writeLine(UsageText)
    return 0
  var database: string
  try:
    database = prepareDatabase(options, getDataDir(), getTempDir())
  except LaunchOptionError as error:
    stderr.writeLine(error.msg)
    return 2
  try:
    stdout.writeLine((if options.demo: "Demo database: " else: "Database: ") & database)
    if options.demo:
      stdout.writeLine("Reopen: --database \"" & database & "\"")
    flushFile(stdout)
    let storage = openNotesStore(database)
    defer: storage.close()
    stdout.writeLine("Seed: " & (if storage.seeded: "created" else: "existing"))
    flushFile(stdout)
    result = run(notesApp(storage, options.theme), options.remaining)
  except CatchableError as error:
    stderr.writeLine(error.msg)
    result = 1

when isMainModule: quit main()
