import std/[unittest, os, json, strutils, tempfiles]
import ../../src/leaf/[licenses, checksum]

const root = currentSourcePath().parentDir.parentDir.parentDir

suite "offline ORM dependencies":
  test "each vendored source matches its upstream or declared library patch hash":
    let vendor = root / "src/leaf/vendor/orm"
    let lock = parseFile(vendor / "lock.json")
    check lock["dependencies"].len == 3
    for dependency in lock["dependencies"]:
      let package = dependency["name"].getStr
      for path, hash in dependency["files"]:
        var expected = hash.getStr
        for patch in lock["patches"]:
          if patch["package"].getStr == package and patch["file"].getStr == path:
            check patch["original_sha256"].getStr == expected
            expected = patch["patched_sha256"].getStr
            let source = readFile(vendor / package / path)
            let original = source.replace("\n\nconst leafOrmSqliteLibrary {.strdefine.} = DefaultLib\nconst Lib = leafOrmSqliteLibrary\n", "").replace("DefaultLib", "Lib")
            let temporary = createTempFile("leaf-upstream-", ".nim")
            temporary.cfile.close()
            writeFile(temporary.path, original)
            check sha256File(temporary.path) == patch["original_sha256"].getStr
            removeFile(temporary.path)
        check sha256File(vendor / package / path) == expected

  test "license collection includes all ORM provenance and MIT notices":
    let destination = createTempDir("leaf-orm-licenses-", "")
    defer: removeDir(destination)
    collectLicenses(destination)
    let inventory = parseFile(destination / "inventory.json")
    for package in ["norm", "lowdb", "db_connector"]:
      check fileExists(destination / "orm" / (package & "-LICENSE.txt"))
      require "orm" in inventory
      check inventory["orm"][package]["license"].getStr == "MIT"
      check inventory["orm"][package]["commit"].getStr.len == 40
    check fileExists(destination / "orm/lock.json")

  test "packaging rejects altered sources before creating an SDK":
    let temporary = createTempDir("leaf-orm-check-", "")
    defer: removeDir(temporary)
    copyDir(root / "src/leaf/vendor/orm", temporary / "leaf/vendor/orm")
    verifyOrmSources(temporary)
    let altered = temporary / "leaf/vendor/orm/norm/src/norm/model.nim"
    writeFile(altered, readFile(altered) & "\n# changed\n")
    expect ValueError: verifyOrmSources(temporary)
