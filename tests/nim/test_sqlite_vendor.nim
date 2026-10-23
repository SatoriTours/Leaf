import std/[unittest, os, json, tempfiles]
import leaf/licenses
import ./cleanup_support
const sourceRoot = currentSourcePath().parentDir.parentDir.parentDir / "src"
let temporary = createTempDir("leaf-sqlite-vendor-", "")
removeDirectoryOnExit(temporary)
suite "bundled SQLite source and notices":
  test "frozen upstream and build wrapper pass packaging checks":
    verifySqliteSources(sourceRoot)
    verifyOrmSources(sourceRoot)
  test "changed amalgamation is refused":
    let root = temporary / "changed"
    copyDir(sourceRoot / "leaf/vendor/sqlite", root / "leaf/vendor/sqlite")
    let path = root / "leaf/vendor/sqlite/sqlite3.c"
    writeFile(path, readFile(path) & "\n/* changed */\n")
    expect ValueError: verifySqliteSources(root)
  test "editing source manifest cannot repin the packager":
    let root = temporary / "repinned"
    copyDir(sourceRoot / "leaf/vendor/sqlite", root / "leaf/vendor/sqlite")
    writeFile(root / "leaf/vendor/sqlite/manifest.json", "{}\n")
    expect ValueError: verifySqliteSources(root)
  test "bundled engine notices and immutable provenance ship with licenses":
    let destination = temporary / "licenses"
    collectLicenses(destination)
    let inventory = parseFile(destination / "inventory.json")
    check inventory["sqlite"]["version"].getStr == "3.54.1"
    check inventory["sqlite"]["license"].getStr == "Public domain"
    check fileExists(destination / "sqlite/LICENSE.txt")
    check readFile(destination / "sqlite/manifest.json") == readFile(sourceRoot / "leaf/vendor/sqlite/manifest.json")
