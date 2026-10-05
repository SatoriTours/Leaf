import std/[os, unittest, dynlib, tempfiles, strutils]
import leaf/native_library

proc systemLibrarySource(name: string, folders: openArray[string]): string =
  for folder in folders:
    if fileExists(folder / name): return folder / name
  # Debian-family architectures place libc libraries in a triplet subdirectory;
  # discover it without hardcoding the build machine's CPU or ABI spelling.
  for folder in folders:
    if not dirExists(folder): continue
    for kind, path in walkDir(folder):
      if kind notin {pcDir, pcLinkToDir}: continue
      if "-linux-gnu" in path.extractFilename and fileExists(path / name):
        return path / name

suite "Unicode native library loading":
  test "missing libraries return no handle":
    check openNativeLibrary("/missing/leaf-native-library") == nil

  when defined(linux):
    test "system library fixtures are discovered in distribution multiarch directories":
      let root = createTempDir("leaf-multiarch-", "")
      defer: removeDir(root)
      let folder = root / "aarch64-linux-gnu"
      createDir(folder)
      let target = folder / "libm.so.6"
      writeFile(target, "fixture: lookup only, never loaded")
      check systemLibrarySource("libm.so.6", [root]) == target

  test "a system library loads from a Unicode directory with spaces":
    when defined(windows):
      let name = "version.dll"
      let source = getEnv("WINDIR", "C:\\Windows") / "System32" / name
      let symbol = "GetFileVersionInfoW"
    elif defined(macosx):
      # Apple system libraries may exist only in the shared cache.
      let name = "libSystem.B.dylib"
      let source = "/usr/lib" / name
      let symbol = "getpid"
    else:
      let name = "libm.so.6"
      let source = systemLibrarySource(name, ["/usr/lib", "/lib", "/usr/lib64", "/lib64"])
      let symbol = "cos"
    if fileExists(source):
      let root = createTempDir("leaf-native-", "")
      defer: removeDir(root)
      let folder = root / "中文 library"
      createDir(folder)
      let target = folder / name
      copyFile(source, target)
      check openNativeLibrary(target & "\0ignored") == nil
      let handle = openNativeLibrary(target)
      check handle != nil
      if handle != nil:
        defer: unloadLib(handle)
        check handle.symAddr(symbol) != nil
    else:
      # A shared-cache-only macOS library still verifies the native loader;
      # the GPUI bridge path regression provides the copied-file evidence.
      when defined(macosx):
        let handle = openNativeLibrary(source)
        check handle != nil
        if handle != nil:
          defer: unloadLib(handle)
          check handle.symAddr(symbol) != nil
      else:
        raise newException(IOError, "System test library unavailable: " & name)
