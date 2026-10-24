import std/os
import leaf
import ./[application, store]

proc main(): int =
  var path = getDataDir() / "leaf-native-list" / "items.sqlite3"
  let args = commandLineParams()
  if args.len > 0:
    if args.len != 2 or args[0] != "--database":
      stderr.writeLine("Usage: LeafNativeList [--database <writable SQLite path>]")
      return 2
    path = args[1]
  try:
    let storage = openListStore(path)
    try:
      echo "SQLite: ", absolutePath(path)
      result = run(nativeListApp(storage))
    finally:
      storage.close()
  except CatchableError as error:
    stderr.writeLine(error.msg)
    result = 1

when isMainModule: quit(main())
