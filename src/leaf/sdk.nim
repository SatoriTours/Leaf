## Installed SDK paths are relative to the running CLI, never its build checkout.
import std/[os, json]

proc sdkRoot*(executable = getAppFilename()): string =
  let resolved = if fileExists(executable): expandFilename(executable) else: executable.absolutePath
  let root = resolved.parentDir.parentDir
  if not fileExists(root / "sdk.json") or not fileExists(root / "src/leaf.nim"):
    return ""
  try:
    let metadata = parseFile(root / "sdk.json")
    if metadata{"schema"}.getInt == 1: return root
  except CatchableError: discard

proc sdkFile*(relative: string): string =
  let root = sdkRoot()
  if root.len > 0 and fileExists(root / relative): result = root / relative

proc sdkVersion*(): string =
  let root = sdkRoot()
  if root.len == 0: return "Leaf 0.1.0 (source)"
  let metadata = parseFile(root / "sdk.json")
  "Leaf " & metadata{"version"}.getStr & " (" & metadata{"channel"}.getStr &
    ", " & metadata{"commit"}.getStr & ")"

proc verifySdk*(channel, target: string; version = ""; root = sdkRoot()) =
  if root.len == 0: raise newException(ValueError, "not an installed Leaf SDK")
  let metadata = parseFile(root / "sdk.json")
  if metadata{"schema"}.getInt != 1 or metadata{"channel"}.getStr != channel or
      metadata{"target"}.getStr != target or
      (version.len > 0 and metadata{"version"}.getStr != version):
    raise newException(ValueError, "SDK metadata does not match requested channel, target or version")

proc sdkCompiler*(): string = sdkFile("toolchain/nim/bin" / "nim".addFileExt(ExeExt))
proc sdkGcc*(): string = sdkFile("toolchain/mingw/bin" / "gcc".addFileExt(ExeExt))
