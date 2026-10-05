import ./cleanup_support
import std/[unittest, os, tempfiles, strutils]
import leaf/[project]
import leaf_cli

let root = createTempDir("leaf-pack-cli-", "")
removeDirectoryOnExit(root)
suite "Nim release CLI and template":
  test "pack rejects missing duplicated unknown and incompatible options before compiling":
    for args in [@["pack"], @["pack", root], @["pack", root, "--target"],
        @["pack", root, "--target", "linux", "--unknown", "x"],
        @["pack", root, "--target", "linux", "--target", "linux"],
        @["pack", root, "--target", "all", "--binary", "app"],
        @["pack", root, "--runtime", "old"], @["pack", root, "--target", "android"]]:
      check leaf_cli.main(args) == 1
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
    var elf = newString(64)
    elf[0..6] = "\x7fELF\x02\x01\x01"; elf[16] = '\x02'; elf[18] = '\x3e'; elf[52] = '\x40'
    writeFile(root / "application", elf)
    elf[16]='\x03'
    writeFile(root / "libleaf_gpui.so", elf)
    let output = root / "dist"
    check leaf_cli.main(@["pack", path, "--target", "linux", "--binary", root / "application", "--output", output]) == 0
    check fileExists(output / "provided-0.1.0-linux-x86_64.tar.gz")
    check fileExists(output / "provided-0.1.0-linux-x86_64.tar.gz.sha256")
