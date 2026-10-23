import std/[unittest, os, json, tempfiles]
import leaf/[project, core]

proc fixture(root: string, android: JsonNode): JsonNode =
  createDir(root / "src")
  writeFile(root / "src/main.nim", "discard\n")
  writeFile(root / "src/mobile.nim", "discard\n")
  result = %*{"name":"Example", "identifier":"dev.example.app", "version":"1.2.3",
    "entry":"src/main.nim", "include":["src"], "platforms":{"android":android}}

proc read(root: string, value: JsonNode): Project =
  writeFile(root / "leaf.json", value.pretty())
  readProject(root)

suite "Android project selection":
  test "explicit mobile entry and defaults preserve desktop entry":
    let root = createTempDir("leaf-android-project-", "")
    defer: removeDir(root)
    let p = read(root, fixture(root, %*{"entry":"src/mobile.nim"}))
    check p.entry == realPath(root / "src/main.nim")
    check p.android.enabled
    check p.android.entry == realPath(root / "src/mobile.nim")
    check p.android.entryRelative == "src/mobile.nim"
    check p.android.minSdk == 26
    check p.android.targetSdk == 36
    check p.android.versionCode == 1
    check p.android.abis == @["arm64-v8a", "x86_64"]

  test "mobile settings use strict bounded types and known ABI sets":
    let root = createTempDir("leaf-android-project-", "")
    defer: removeDir(root)
    let p = read(root, fixture(root, %*{"entry":"src/mobile.nim", "minSdk":28,
      "targetSdk":36, "versionCode":42, "abis":["x86_64"]}))
    check p.android.minSdk == 28
    check p.android.versionCode == 42
    check p.android.abis == @["x86_64"]
    for settings in [newJNull(), %*{}, %*{"entry":17}, %*{"entry":"src/mobile.nim","minSdk":25},
      %*{"entry":"src/mobile.nim","minSdk":37,"targetSdk":36},
      %*{"entry":"src/mobile.nim","versionCode":0}, %*{"entry":"src/mobile.nim","versionCode":2100000001'i64},
      %*{"entry":"src/mobile.nim","targetSdk":36.5}, %*{"entry":"src/mobile.nim","abis":[]},
      %*{"entry":"src/mobile.nim","abis":["x86_64","x86_64"]},
      %*{"entry":"src/mobile.nim","abis":["armeabi-v7a"]},
      %*{"entry":"src/mobile.nim","unknown":true}]:
      expect UiError: discard read(root, fixture(root, settings))

  test "mobile entry must be included regular Nim source within the project":
    let root = createTempDir("leaf-android-project-", "")
    defer: removeDir(root)
    createDir(root / "other")
    writeFile(root / "other/mobile.nim", "discard\n")
    for name in ["../mobile.nim", "src/missing.nim", "src", "src/main.txt", "other/mobile.nim"]:
      expect UiError: discard read(root, fixture(root, %*{"entry":name}))
    when defined(posix):
      let outside = createTempDir("leaf-outside-", "")
      defer: removeDir(outside)
      writeFile(outside / "mobile.nim", "discard\n")
      createSymlink(outside / "mobile.nim", root / "src/escape.nim")
      expect UiError: discard read(root, fixture(root, %*{"entry":"src/escape.nim"}))

  test "Android package identity rejects Kotlin keywords and desktop-only dashes":
    let root = createTempDir("leaf-android-project-", "")
    defer: removeDir(root)
    for id in ["dev.example.app-name", "dev.class.app", "dev.object.app", "dev.when.app"]:
      let value=fixture(root, %*{"entry":"src/mobile.nim"});value["identifier"] = %id
      expect UiError: discard read(root, value)
    var desktop=fixture(root, %*{"entry":"src/mobile.nim"})
    desktop.delete("platforms");desktop["identifier"] = %"dev.example.app-name"
    check not read(root, desktop).android.enabled

  test "Android always selects native and rejects desktop-only execution modes":
    let chosen=resolveBuild(backendGpui, "android")
    check chosen.backend == backendNative
    check chosen.target == "android"
    chosen.validateHost()
    check resolveBuild(backendNative, "android", "native").backend == backendNative
    expect UiError: discard resolveBuild(backendGpui, "android", "gpui")
    expect UiError: discard resolveBuild(backendGpui, "android", headlessOnly=true)
