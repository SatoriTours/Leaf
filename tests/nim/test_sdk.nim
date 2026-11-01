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
    writeFile(root / "sdk.json", $ %*{"schema": 2, "backend": "native", "version": "v1.2.3", "channel": "release", "commit": "abcdef123"})
    check sdkRoot(root / "bin" / "leaf".addFileExt(ExeExt)) == root
    check sdkRoot(base / "uninstalled" / "leaf") == ""

  test "unrelated or malformed marker does not identify an SDK":
    let root = base / "bad"
    createDir(root / "bin")
    writeFile(root / "sdk.json", "not json")
    check sdkRoot(root / "bin/leaf") == ""
    writeFile(root / "sdk.json", $ %*{"schema": 99})
    check sdkRoot(root / "bin/leaf") == ""
    createDir(root / "src")
    writeFile(root / "src/leaf.nim", "discard")
    writeFile(root / "sdk.json", $ %*{"schema": 1})
    check sdkRoot(root / "bin/leaf") == ""
    expect ValueError: verifySdk("release", "windows-x86_64", root=root)

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
    writeFile(root / "sdk.json", $ %*{"schema": 2, "backend": "native", "version": "v1.2.3",
      "channel": "release", "target": "linux-x86_64"})
    verifySdk("release", "linux-x86_64", "v1.2.3", root)
    expect ValueError: verifySdk("beta", "linux-x86_64", "", root)
    expect ValueError: verifySdk("release", "windows-x86_64", "", root)
    expect ValueError: verifySdk("release", "linux-x86_64", "v9.0.0", root)

  test "relative overrides remain valid after the build changes directory":
    let previous = getCurrentDir()
    let hadLibrary = existsEnv("LEAF_LIBRARY")
    let hadNim = existsEnv("NIM")
    let oldLibrary = getEnv("LEAF_LIBRARY")
    let oldNim = getEnv("NIM")
    let root = base / "relative SDK 中文 $ paths"
    createDir(root / "tools")
    createDir(root / "src")
    createDir(root / "project/subdir")
    writeFile(root / "tools" / "nim".addFileExt(ExeExt), "compiler fixture")
    writeFile(root / "src/leaf.nim", "discard")
    defer:
      setCurrentDir(previous)
      if hadLibrary: putEnv("LEAF_LIBRARY", oldLibrary)
      else: delEnv("LEAF_LIBRARY")
      if hadNim: putEnv("NIM", oldNim)
      else: delEnv("NIM")
    setCurrentDir(root / "project/subdir")
    putEnv("LEAF_LIBRARY", "../../src")
    putEnv("NIM", "../../tools" / "nim".addFileExt(ExeExt))
    let sources = libraryPath()
    let nim = compiler()
    check isAbsolute(sources)
    check isAbsolute(nim)
    setCurrentDir(root / "project")
    check fileExists(sources / "leaf.nim")
    check fileExists(nim)
