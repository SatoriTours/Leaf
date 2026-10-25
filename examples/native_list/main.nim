import std/[os, strutils]
import leaf
import ./[application, store]

proc main(): int =
  var path = getDataDir() / "leaf-native-list" / "items.sqlite3"
  var args = commandLineParams()
  # Only the leading pair belongs to this example. Keep Leaf options and their
  # values intact (even a --change value that literally equals --database).
  if args.len > 0 and args[0] == "--database":
    if args.len < 2 or args[1].len == 0 or args[1].startsWith("--"):
      stderr.writeLine("Usage: LeafNativeList [--database <writable SQLite path>] [Leaf options...]")
      return 2
    path = args[1]
    args = args[2 .. ^1]
  try:
    let storage = openListStore(path)
    try:
      echo "SQLite: ", absolutePath(path)
      result = run(nativeListApp(storage), args)
    finally:
      storage.close()
  except CatchableError as error:
    stderr.writeLine(error.msg)
    result = 1

when isMainModule: quit(main())
