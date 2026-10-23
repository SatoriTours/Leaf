## Exercise the real archive path with tiny toolchain inputs. This checks source
## and notice distribution, not whether a fake compiler is a usable SDK.
import std/[unittest, os, tempfiles, json]
import ../../scripts/package_sdk
import ../../src/leaf/checksum
import ../nim/archive_reader

const root = currentSourcePath().parentDir.parentDir.parentDir

suite "bundled SQLite SDK inputs":
  setup:
    let temporary = createTempDir("leaf-sqlite-sdk-", "")
    let nimRoot = temporary / "nim"
    for directory in ["bin", "lib", "config"]: createDir(nimRoot / directory)
    # These inputs target the Linux archive below, regardless of the test host.
    writeFile(nimRoot / "bin/nim", "fixture compiler")
    writeFile(nimRoot / "lib/system.nim", "discard")
    writeFile(nimRoot / "config/nim.cfg", "# fixture")
    let cli = temporary / "leaf"
    let bridge = temporary / "bridge"
    writeFile(cli, "fixture CLI")
    writeFile(bridge, "fixture bridge")
    var options = PackageOptions(root: root, nimRoot: nimRoot, cli: cli,
      bridge: bridge, output: temporary / "output", target: "linux-x86_64",
      channel: "release", version: "v1.2.3", commit: "abcdef")
  teardown:
    removeDir(temporary)

  test "real SDK archive contains pinned SQLite source and notices":
    let archive = packageSdk(options)
    let unpacked = temporary / "unpacked"
    extractTar(archive, unpacked)
    let sdk = unpacked / "leaf-sdk"
    for name in ["sqlite3.c", "sqlite3.h", "sqlite3ext.h", "leaf_sqlite.c", "manifest.json", "LICENSE.txt"]:
      check sha256File(sdk / "src/leaf/vendor/sqlite" / name) ==
        sha256File(root / "src/leaf/vendor/sqlite" / name)
    check fileExists(sdk / "src/leaf/sqlite_link.nim")
    for name in ["c/leaf_jni.c", "c/leaf_android_jni.c", "java/dev/leaf/runtime/LeafActivity.kt",
        "java/dev/leaf/runtime/LeafRuntime.kt"]:
      check sha256File(sdk / "native/android/src/main" / name) ==
        sha256File(root / "native/android/src/main" / name)
    check fileExists(sdk / "src/leaf/mobile.nim")
    check fileExists(sdk / "licenses/sqlite/LICENSE.txt")
    check parseFile(sdk / "licenses/inventory.json")["sqlite"]["version"].getStr == "3.54.1"

  test "SQLite checksum gate runs before the SDK output is created":
    let changed = temporary / "changed"
    for name in ["orm", "sqlite"]:
      copyDir(root / "src/leaf/vendor" / name, changed / "src/leaf/vendor" / name)
    writeFile(changed / "src/leaf/vendor/sqlite/leaf_sqlite.c", "/* altered */\n")
    options.root = changed
    expect ValueError: discard packageSdk(options)
    check not dirExists(options.output)
