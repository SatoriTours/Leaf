import ./cleanup_support
import std/[unittest, os, tempfiles, strutils]
import leaf/[project]
import leaf_cli

let root = createTempDir("leaf-pack-cli-", "")
removeDirectoryOnExit(root)

proc runCliIn(directory: string, args: seq[string]): int =
  createDir(directory)
  let previous = getCurrentDir()
  setCurrentDir(directory)
  try: return leaf_cli.main(args)
  finally: setCurrentDir(previous)
suite "Nim release CLI and template":
  test "pack rejects missing duplicated unknown and incompatible options before compiling":
    for args in [@["pack"], @["pack", "--target"],
        @["pack", "--target", "linux", "--unknown", "x"],
        @["pack", "--target", "linux", "--target", "linux"],
        @["pack", "--target", "all", "--binary", "app"],
        @["pack", "--runtime", "old"], @["pack", "--target", "android"]]:
      check runCliIn(root, args) == 1
    # The removed PROJECT position form is rejected, not reinterpreted.
    check runCliIn(root, @["pack", root, "--target", "linux"]) == 1
  test "generated template contains shared Nim state and relocatable assets":
    let path = root / "generated"
    initProject(path)
    let p = readProject(path)
    check fileExists(path / "src/app.nim")
    check fileExists(path / "assets/message.txt")
    check "import ./app" in readFile(p.entry)
    check "asset(\"message.txt\")" in readFile(path / "src/app.nim")

  test "CLI packs an explicitly provided application and reports archive paths":
    let path = root / "provided"
    initProject(path)
    var pe = newString(392)
    pe[0..1] = "MZ"; pe[60] = '\x80'; pe[128..131] = "PE\0\0"
    pe[132] = '\x64'; pe[133] = '\x86'; pe[148] = '\xf0'; pe[150] = '\x02'
    pe[152] = '\x0b'; pe[153] = '\x02'
    writeFile(root / "application.exe", pe)
    let output = root / "dist"
    check runCliIn(path, @["pack", "--target", "windows", "--binary", root / "application.exe", "--output", output]) == 0
    check fileExists(output / "provided-0.1.0-windows-x86_64.zip")
    check fileExists(output / "provided-0.1.0-windows-x86_64.zip.sha256")
