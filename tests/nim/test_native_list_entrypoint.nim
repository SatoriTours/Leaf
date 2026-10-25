## Exercise the shipped main, not only application.nim: catches swallowed Leaf
## flags and application parameters leaking back into the framework's argv.
import ./[cleanup_support, migration_compile_support]
import std/[unittest, os, tempfiles, strtabs, strutils]
import ../../examples/native_list/store

const root = currentSourcePath().parentDir.parentDir.parentDir
let base = createTempDir("leaf-native-list-entry-", "")
removeDirectoryOnExit(base)
let binary = base / "native-list".changeFileExt(ExeExt)
let compiler = getEnv("NIM", findExe("nim"))
let compiled = runManagedBounded(compiler, @[
  "c", "-d:leafHeadlessOnly", "--hints:off", "--path:" & root / "src",
  "--nimcache:" & base / "cache", "--out:" & binary,
  root / "examples/native_list/main.nim"], root, seconds = 120)
var env = newStringTable(modeCaseSensitive)
for key, value in envPairs(): env[key] = value
# --check (as used by default pack) must never touch the user's real data.
for key in ["XDG_DATA_HOME", "APPDATA", "LOCALAPPDATA"]:
  env[key] = base / "user-data"
createDir(base / "user-data")

suite "real native list executable argument boundary":
  setup:
    if compiled.code != 0: checkpoint compiled.output
    require compiled.code == 0

  test "default pack's standalone --check reaches the framework":
    let ran = runCli(binary, base, @["--check"], env, seconds = 10)
    checkpoint ran.stderrText
    check ran.code == 0
    check ran.stderrText == ""

  test "database option is consumed while explicit framework check is forwarded":
    let database = base / "中文 空格" / "check.sqlite3"
    let ran = runCli(binary, base, @["--database", database, "--check"], env, seconds = 10)
    checkpoint ran.stderrText
    check ran.code == 0
    check ran.stderrText == ""
    check fileExists(database)

  test "real entrypoint saves and reopens the chosen database with Leaf events":
    let database = base / "saved.sqlite3"
    let saved = runCli(binary, base, @[
      "--database", database, "--headless", "--list", "items", "0", "1",
      "--change", "edit-0", "--database", "--toggle", "done-0", "true",
      "--click", "save-0"], env, seconds = 10)
    checkpoint saved.stderrText
    check saved.code == 0
    check saved.stderrText == ""
    if fileExists(database):
      let storage = openListStore(database)
      try:
        check storage.loadItem(0) == ListItem(id: 0, note: "--database", done: true)
        check storage.loadItem(1) == ListItem(id: 1)
      finally: storage.close()
    else:
      check fileExists(database)
    let reopened = runCli(binary, base, @[
      "--database", database, "--headless", "--list", "items", "0", "1"],
      env, seconds = 10)
    checkpoint reopened.stderrText
    check reopened.code == 0
    check reopened.stderrText == ""
    check "--database" in reopened.stdoutText

  test "missing and empty database paths fail before opening storage":
    for args in [@["--database"], @["--database", ""], @["--database", "--check"]]:
      let ran = runCli(binary, base, args, env, seconds = 10)
      check ran.code == 2
      check "SQLite:" notin ran.stdoutText
    check not fileExists(base / "--check")

  test "unknown framework options still fail rather than being discarded":
    let ran = runCli(binary, base, @[
      "--database", base / "unknown.sqlite3", "--headless", "--not-a-leaf-option"],
      env, seconds = 10)
    check ran.code != 0
