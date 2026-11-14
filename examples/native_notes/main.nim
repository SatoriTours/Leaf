import std/[os, strutils]
import leaf
import ./[store, application]

proc main(): int =
  var database = getDataDir() / "leaf-notes" / "notes.sqlite3"
  var theme = matsuLight
  var args = commandLineParams()
  while args.len > 0 and args[0] in ["--database", "--theme"]:
    if args.len < 2 or args[1].len == 0 or args[1].startsWith("--"):
      stderr.writeLine("Usage: LeafNotes [--database <path>] [--theme light|dark|system] [Leaf options]")
      return 2
    if args[0] == "--database": database = args[1]
    else:
      case args[1]
      of "light": theme = matsuLight
      of "dark": theme = matsuDark
      of "system": theme = systemTheme
      else:
        stderr.writeLine("Theme must be light, dark or system")
        return 2
    args = args[2 .. ^1]
  try:
    let storage = openNotesStore(database)
    defer: storage.close()
    echo "SQLite: ", absolutePath(database)
    result = run(notesApp(storage, theme), args)
  except CatchableError as error:
    stderr.writeLine(error.msg)
    result = 1

when isMainModule: quit main()
