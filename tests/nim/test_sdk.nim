import ./cleanup_support
import std/[unittest, os, tempfiles, json]
import leaf/[sdk, build]

let base = createTempDir("leaf-sdk-", "")
removeDirectoryOnExit(base)

suite "SDK discovery":
  test "relocated SDK is discovered beside the executable":
    let root = base / "SDK with spaces"
    createDir(root / "bin")
    createDir(root / "src")
    writeFile(root / "src/leaf.nim", "discard")
    writeFile(root / "sdk.json", $ %*{"schema": 1, "version": "v1.2.3", "channel": "release", "commit": "abcdef123"})
    check sdkRoot(root / "bin" / "leaf".addFileExt(ExeExt)) == root
    check sdkRoot(base / "uninstalled" / "leaf") == ""

  test "unrelated or malformed marker does not identify an SDK":
    let root = base / "bad"
    createDir(root / "bin")
    writeFile(root / "sdk.json", "not json")
    check sdkRoot(root / "bin/leaf") == ""
    writeFile(root / "sdk.json", $ %*{"schema": 99})
    check sdkRoot(root / "bin/leaf") == ""

  test "explicit library and compiler overrides keep priority":
    let oldLibrary = getEnv("LEAF_LIBRARY")
    let oldNim = getEnv("NIM")
    defer:
      putEnv("LEAF_LIBRARY", oldLibrary)
      putEnv("NIM", oldNim)
    createDir(base / "override")
    writeFile(base / "override/leaf.nim", "discard")
    putEnv("LEAF_LIBRARY", base / "override")
    putEnv("NIM", getAppFilename())
    check libraryPath() == base / "override"
    check compiler() == getAppFilename()

  test "installer checks requested channel target and exact version":
    let root = base / "verified"
    createDir(root)
    writeFile(root / "sdk.json", $ %*{"schema": 1, "version": "v1.2.3",
      "channel": "release", "target": "linux-x86_64"})
    verifySdk("release", "linux-x86_64", "v1.2.3", root)
    expect ValueError: verifySdk("beta", "linux-x86_64", "", root)
    expect ValueError: verifySdk("release", "windows-x86_64", "", root)
    expect ValueError: verifySdk("release", "linux-x86_64", "v9.0.0", root)
