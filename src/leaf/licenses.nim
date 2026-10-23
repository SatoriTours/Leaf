## Embedded license texts make the installed packager independent of its checkout.
import std/[os, json]
import ./checksum
const
  LeafLicense = staticRead("../../LICENSE")
  NimLicense = staticRead("vendor/Nim-LICENSE.txt")
  ZippyLicense = staticRead("vendor/zippy/LICENSE")
  ChecksumsLicense = staticRead("vendor/checksums/LICENSE")
  GpuiNotices = staticRead("vendor/GPUI-NOTICES.json")
  OrmLock = staticRead("vendor/orm/lock.json")
  NormLicense = staticRead("vendor/orm/norm/LICENSE")
  LowdbLicense = staticRead("vendor/orm/lowdb/LICENSE.MIT")
  ConnectorLicense = staticRead("vendor/orm/db_connector/LICENSE")
  SqliteLicense = staticRead("vendor/sqlite/LICENSE.txt")
  SqliteManifest = staticRead("vendor/sqlite/manifest.json")
  Provenance = staticRead("vendor/provenance.json")

proc collectLicenses*(destination: string) =
  createDir(destination / "tools")
  writeFile(destination / "Leaf-LICENSE.txt", LeafLicense)
  writeFile(destination / "Nim-LICENSE.txt", NimLicense)
  writeFile(destination / "tools/Zippy-LICENSE.txt", ZippyLicense)
  writeFile(destination / "tools/Checksums-LICENSE.txt", ChecksumsLicense)
  writeFile(destination / "GPUI-NOTICES.json", GpuiNotices)
  createDir(destination / "orm")
  writeFile(destination / "orm/norm-LICENSE.txt", NormLicense)
  writeFile(destination / "orm/lowdb-LICENSE.txt", LowdbLicense)
  writeFile(destination / "orm/db_connector-LICENSE.txt", ConnectorLicense)
  writeFile(destination / "orm/lock.json", OrmLock)
  createDir(destination / "sqlite")
  writeFile(destination / "sqlite/LICENSE.txt", SqliteLicense)
  writeFile(destination / "sqlite/manifest.json", SqliteManifest)
  var inventory = parseJson(Provenance)
  let sqlite = parseJson(SqliteManifest)
  inventory["sqlite"] = %*{"version": sqlite["version"], "source": sqlite["source"],
    "archive_sha256": sqlite["archiveSha256"], "license": sqlite["license"],
    "license_file": "sqlite/LICENSE.txt"}
  inventory["orm"] = newJObject()
  for dependency in parseJson(OrmLock)["dependencies"]:
    let name = dependency["name"].getStr
    inventory["orm"][name] = %*{"version": dependency["version"],
      "commit": dependency["commit"], "source": dependency["source"],
      "license": dependency["license"], "license_file": "orm/" & name & "-LICENSE.txt"}
  inventory["leaf"] = %*{"license": "MIT", "source": "https://github.com/SatoriTours/Leaf", "license_file": "Leaf-LICENSE.txt"}
  inventory["system_dependencies"] = %*["GPUI + GPUI Kit bridge (bundled; see GPUI-NOTICES.json)",
    "System graphics drivers, fonts and platform dependencies (not bundled)"]
  writeFile(destination / "inventory.json", inventory.pretty() & "\n")

proc verifyOrmSources*(sourceRoot: string) =
  ## Packaging uses the embedded lock, so editing the input lock cannot repin it.
  let vendor = sourceRoot / "leaf/vendor/orm"
  let lock = parseJson(OrmLock)
  if not fileExists(vendor / "lock.json") or readFile(vendor / "lock.json") != OrmLock:
    raise newException(ValueError, "ORM dependency lock differs from the packager")
  for dependency in lock["dependencies"]:
    let package = dependency["name"].getStr
    for path, hash in dependency["files"]:
      var expected = hash.getStr
      for patch in lock["patches"]:
        if patch["package"].getStr == package and patch["file"].getStr == path:
          expected = patch["patched_sha256"].getStr
      let file = vendor / package / path
      if not fileExists(file) or sha256File(file) != expected:
        raise newException(ValueError, "ORM source checksum mismatch: " & package & "/" & path)
  for patch in lock["patches"]:
    let file = vendor / patch["patch"].getStr
    if not fileExists(file) or sha256File(file) != patch["patch_sha256"].getStr:
      raise newException(ValueError, "ORM patch checksum mismatch: " & patch["patch"].getStr)

proc verifySqliteSources*(sourceRoot: string) =
  ## The embedded manifest pins upstream bytes and the application build wrapper.
  let vendor = sourceRoot / "leaf/vendor/sqlite"
  if not fileExists(vendor / "manifest.json") or
      readFile(vendor / "manifest.json") != SqliteManifest:
    raise newException(ValueError, "SQLite source manifest differs from the packager")
  for entry in parseJson(SqliteManifest)["files"]:
    let file = vendor / entry["path"].getStr
    if not fileExists(file) or sha256File(file) != entry["sha256"].getStr:
      raise newException(ValueError, "SQLite source checksum mismatch: " & entry["path"].getStr)
