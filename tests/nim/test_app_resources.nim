import ./cleanup_support
import std/[unittest, os, tempfiles]
import leaf/[app_resources, core]

let root = createTempDir("leaf-resources-", "")
removeDirectoryOnExit(root)
for name in ["assets", "data", "cache", "outside"]: createDir(root / name)
writeFile(root / "assets/内容.bin", "中文😀\0tail")
writeFile(root / "assets/empty", "")
writeFile(root / "assets/large", newString(MaxStringBytes + 1))
writeFile(root / "outside/secret", "outside")

suite "host resources":
  test "binary resource read owns bytes and preserves Unicode NUL":
    let host = directoryResources(root / "assets", root / "data", root / "cache")
    let first = host.readAsset("内容.bin")
    check first == "中文😀\0tail"
    writeFile(root / "assets/内容.bin", "changed")
    check first == "中文😀\0tail"
    check host.readAsset("内容.bin") == "changed"
    writeFile(root / "assets/内容.bin", first)
    check host.readAsset("empty", 0) == ""
    host.close()
  test "rejects missing resources and invalid names before reader runs":
    var calls = 0
    let host = newHostResources(proc(path: string, limit: int): string =
      inc calls
      "value", root / "data", root / "cache")
    for path in ["", "../secret", "/absolute", "a/../secret", "a\\secret", "a\0b", "a//b", "a/./b", "C:/secret", "\xff"]:
      expect UiError: discard host.readAsset(path)
    check calls == 0
    host.close()
    let disk = directoryResources(root / "assets", root / "data", root / "cache")
    expect CatchableError: discard disk.readAsset("missing")
    disk.close()
  test "budget is checked before allocation and after reader return":
    let disk = directoryResources(root / "assets", root / "data", root / "cache")
    expect UiError: discard disk.readAsset("large")
    expect UiError: discard disk.readAsset("内容.bin", -1)
    expect UiError: discard disk.readAsset("内容.bin", MaxStringBytes + 1)
    expect UiError: discard disk.readAsset("内容.bin", 1)
    disk.close()
    let bad = newHostResources(proc(path: string, limit: int): string = "too large",
      root / "data", root / "cache")
    expect UiError: discard bad.readAsset("bad", 2)
    bad.close()
  test "data paths are absolute and remain beneath private root":
    let host = directoryResources(root / "assets", root / "data", root / "cache")
    check host.dataPath("数据/notes.sqlite3") == root / "data/数据/notes.sqlite3"
    check not fileExists(host.dataPath("数据/notes.sqlite3"))
    for path in ["../secret", "/tmp/escape", "a\\b", "a\0b"]:
      expect UiError: discard host.dataPath(path)
    host.close()
  test "asset extraction reuses equal bytes and changes path with content":
    let host = directoryResources(root / "assets", root / "data", root / "cache")
    let first = host.asset("内容.bin")
    check readFile(first) == "中文😀\0tail"
    check host.asset("内容.bin") == first
    writeFile(root / "assets/内容.bin", "next")
    let second = host.asset("内容.bin")
    check first != second
    check readFile(first) == "中文😀\0tail"
    check readFile(second) == "next"
    writeFile(root / "assets/内容.bin", "中文😀\0tail")
    host.close()
  test "extraction refuses corrupt preexisting file":
    let host = directoryResources(root / "assets", root / "data", root / "cache")
    let path = host.asset("empty")
    setFilePermissions(path, {fpUserRead, fpUserWrite})
    writeFile(path, "corrupt")
    expect UiError: discard host.asset("empty")
    check readFile(path) == "corrupt"
    removeFile(path)
    host.close()
  test "existing aliases cannot escape asset data or extraction roots":
    when not defined(windows):
      createSymlink(root / "outside", root / "assets/escape")
      createSymlink(root / "outside", root / "data/escape")
      let host = directoryResources(root / "assets", root / "data", root / "cache")
      expect UiError: discard host.readAsset("escape/secret")
      expect UiError: discard host.dataPath("escape/new.db")
      let extracted = host.asset("内容.bin")
      let parent = extracted.parentDir
      setFilePermissions(extracted, {fpUserRead, fpUserWrite})
      removeDir(parent)
      createSymlink(root / "outside", parent)
      expect UiError: discard host.asset("内容.bin")
      check not fileExists(root / "outside/内容.bin")
      removeFile(parent)
      host.close()
  test "constructor rejects missing relative malformed and nil service inputs":
    expect UiError: discard directoryResources(root / "missing", root / "data", root / "cache")
    expect UiError: discard directoryResources(root / "assets", "relative", root / "cache")
    expect UiError: discard directoryResources(root / "assets", root / "data\0bad", root / "cache")
    expect UiError: discard newHostResources(nil, root / "data", root / "cache")
  test "close is idempotent and prevents all subsequent service calls":
    var calls = 0
    let host = newHostResources(proc(path: string, limit: int): string =
      inc calls
      "data", root / "data", root / "cache")
    host.close()
    host.close()
    expect UiError: discard host.readAsset("x")
    expect UiError: discard host.asset("x")
    expect UiError: discard host.dataPath("x")
    check calls == 0
  test "owner thread gate runs before any reader or path work":
    var threadId = 10'u64
    var calls = 0
    let host = newHostResources(proc(path: string, limit: int): string =
      inc calls
      "data", root / "data", root / "cache",
      currentThread = proc(): uint64 {.raises: [].} = threadId)
    threadId = 11
    expect UiError: discard host.readAsset("x")
    expect UiError: discard host.asset("x")
    expect UiError: discard host.dataPath("x")
    expect UiError: host.close()
    check calls == 0
    threadId = 10
    check host.readAsset("x") == "data"
    host.close()
