import ./cleanup_support
import std/[unittest, os, osproc, tempfiles, json, strutils, tables]
when defined(posix): import std/posix
import leaf/[core, project, pack, package_files, checksum]
import ../../src/leaf/vendor/zippy/zippy/ziparchives

import ./archive_reader

let root = createTempDir("leaf-packaging-", "")
removeDirectoryOnExit(root)
proc fixture(label: string): Project =
  let p = root / label
  createDir(p / "src"); createDir(p / "assets")
  writeFile(p / "src/main.nim", "discard")
  writeFile(p / "assets/message.txt", "relocatable content")
  writeFile(p / "LICENSE", "application license")
  writeFile(p / "third-party-licenses.json", "{\"application_dependencies\": []}")
  var elf = newString(64)
  elf[0..6] = "\x7fELF\x02\x01\x01"; elf[16] = '\x02'; elf[18] = '\x3e'; elf[52] = '\x40'
  writeFile(p / "linux", elf)
  var elfLibrary=elf
  elfLibrary[16]='\x03'
  writeFile(p / "libleaf_gpui.so", elfLibrary)
  var mac = newString(32)
  mac[0..3] = "\xcf\xfa\xed\xfe"; mac[4] = '\x07'; mac[7] = '\x01'; mac[12] = '\x02'
  writeFile(p / "macos", mac)
  var macLibrary=mac
  macLibrary[12]='\x06'
  writeFile(p / "libleaf_gpui.dylib", macLibrary)
  var pe = newString(392)
  pe[0..1] = "MZ"; pe[60] = '\x80'; pe[128..131] = "PE\0\0"
  pe[132] = '\x64'; pe[133] = '\x86'; pe[148] = '\xf0'; pe[150] = '\x02'
  pe[152] = '\x0b'; pe[153] = '\x02'; writeFile(p / "windows", pe)
  var peLibrary=pe
  peLibrary[151]='\x20'
  writeFile(p / "leaf_gpui.dll", peLibrary)
  writeFile(p / "leaf.json", $(%*{"name": "My App", "identifier": "org.example.app", "version": "1.2.3",
    "entry": "src/main.nim", "include": ["src", "assets"],
    "platforms": {"linux": {"binary": "linux"}, "macos": {"binary": "macos"}, "windows": {"binary": "windows"}}}))
  readProject(p)

suite "Atomic relocatable native releases":
  test "three formats preserve resource layout licenses architecture and checksums":
    let p = fixture("three")
    let output = root / "releases"
    let artifacts = pack(p, "all", output)
    check artifacts.len == 3
    for artifact in artifacts:
      check readFile(artifact & ".sha256") == sha256File(artifact) & "  " & artifact.extractFilename & "\n"
    extractTar(output / "app-1.2.3-linux-x86_64.tar.gz", root / "linux-out")
    check readFile(root / "linux-out/app/app/assets/message.txt") == "relocatable content"
    check fileExists(root / "linux-out/app/app/src/main.nim")
    check not parseFile(root / "linux-out/app/app/leaf.json").hasKey("platforms")
    check readFile(root / "linux-out/app/licenses/application/LICENSE") == "application license"
    check fileExists(root / "linux-out/app/licenses/Nim-LICENSE.txt")
    check fileExists(root / "linux-out/app/licenses/GPUI-NOTICES.json")
    check fileExists(root / "linux-out/app/bin/libleaf_gpui.so")
    check fileExists(root / "linux-out/app/licenses/application/third-party-licenses.json")
    when defined(posix): check fpUserExec in getFilePermissions(root / "linux-out/app/bin/app")
    let windows = openZipArchive(output / "app-1.2.3-windows-x86_64.zip")
    check windows.extractFile("app/app/assets/message.txt") == "relocatable content"
    check windows.extractFile("app/bin/app.exe")[0..1] == "MZ"
    windows.close()
    let mac = openZipArchive(output / "app-1.2.3-macos-x86_64.zip")
    check mac.extractFile("My App.app/Contents/Resources/app/assets/message.txt") == "relocatable content"
    check "org.example.app" in mac.extractFile("My App.app/Contents/Info.plist")
    mac.close()
  test "missing and mismatched GPUI bridges are rejected":
    let p=fixture("bridge-check")
    removeFile(p.root / "libleaf_gpui.so")
    expect UiError: discard pack(p, "linux", root / "missing-bridge")
    var bridge=readFile(p.root / "linux")
    bridge[16]='\x03'
    bridge[18]='\xb7'
    writeFile(p.root / "libleaf_gpui.so", bridge)
    expect UiError: discard pack(p, "linux", root / "wrong-bridge")
  test "overlapping includes and generated manifest collisions fail before output":
    var p = fixture("overlap")
    p.includedPaths.add("src/main.nim")
    expect UiError: discard pack(p, "linux", root / "overlap-out")
    p = fixture("manifest"); p.includedPaths.add("leaf.json")
    expect UiError: discard pack(p, "linux", root / "manifest-out")
  test "case and Unicode case collisions cannot produce ambiguous portable payloads":
    var p = fixture("collision")
    writeFile(p.root / "assets/Ä.txt", "a"); writeFile(p.root / "assets/ä.txt", "b")
    # Case-insensitive filesystems expose one file for these two writes.
    # Directory collisions are possible only when both files actually exist.
    if not sameFile(p.root / "assets/Ä.txt", p.root / "assets/ä.txt"):
      expect UiError: discard pack(p, "linux", root / "collision-directory-out")
    # Explicit portable names must remain unambiguous on either filesystem.
    p.includedPaths = @["src", "assets/Ä.txt", "assets/ä.txt"]
    expect UiError: discard pack(p, "linux", root / "collision-out")
  test "output inside included or implicit license directories is rejected":
    let p = fixture("output")
    for output in [p.root / "assets/releases", p.root / "src/releases"]:
      expect UiError: discard pack(p, "linux", output)
      check not dirExists(output)
    createDir(p.root / "third-party-licenses")
    writeFile(p.root / "third-party-licenses/NOTICE", "required notice")
    expect UiError: discard pack(p, "linux", p.root / "third-party-licenses/releases")
  test "republishing leaves every existing release byte unchanged":
    let p = fixture("existing")
    let output = root / "existing-out"
    let artifacts = pack(p, "all", output)
    let previous = sha256File(artifacts[0])
    expect UiError: discard pack(p, "all", output)
    check sha256File(artifacts[0]) == previous
    var count = 0
    for kind, path in walkDir(output):
      check kind == pcFile
      inc count
    check count == 6
  test "partial hardlink commit removes only artifacts published by this operation":
    let p = root / "publish"
    createDir(p); writeFile(p / "source", "new"); writeFile(p / "existing", "old")
    expect OSError:
      publishArtifacts(@[(p / "source", p / "created"), (p / "source", p / "existing")])
    check not fileExists(p / "created")
    check readFile(p / "existing") == "old"
  test "wrong native target and unknown target do not leave staging artifacts":
    let p = fixture("wrong")
    expect UiError: discard pack(p, "windows", root / "wrong-out", p.root / "linux")
    expect UiError: discard pack(p, "android", root / "wrong-out")
    if dirExists(root / "wrong-out"):
      for kind, path in walkDir(root / "wrong-out"): check false
  when defined(posix):
    test "source links parent aliases and implicit license links are all refused":
      for location in ["assets/link", "LICENSE", "third-party-licenses"]:
        let p = fixture("links-" & location.replace('/', '-'))
        if fileExists(p.root / location): removeFile(p.root / location)
        let target = if location == "third-party-licenses": p.root / "assets" else: p.root / "linux"
        createSymlink(target, p.root / location)
        expect UiError: discard pack(p, "linux", root / ("links-out-" & location.replace('/', '-')))
      var p = fixture("parent-alias")
      createSymlink(p.root / "src", p.root / "alias")
      p.includedPaths = @["alias/main.nim", "assets"]
      p.entryRelative = "alias/main.nim"
      expect UiError: discard pack(p, "linux", root / "parent-alias-out")

  test "native compilation cannot silently use modules excluded from the staged payload":
    let path = root / "excluded-module"
    initProject(path)
    var p = readProject(path)
    p.includedPaths = @["src/main.nim", "assets"]
    let output = root / "excluded-module-out"
    expect UiError: discard pack(p, nativeTarget(), output)
    check not dirExists(path / "target")
    if dirExists(output):
      for kind, file in walkDir(output): check false

  test "ancestor Nim configs cannot expose excluded modules during staged release builds":
    let path = root / "ancestor-config"
    initProject(path)
    writeFile(path / "src/main.nim", "import leaf\nimport hidden\nwhen isMainModule: quit(run(hidden.app()))\n")
    writeFile(path / "src/hidden.nim", "import leaf\nproc app*(): Application = Application(title: \"hidden\", width: 480, height: 320, render: proc(c: BuildContext): Node = text(\"hidden\"))\n")
    writeFile(path / "nim.cfg", "--path:src\n")
    var p = readProject(path)
    p.includedPaths = @["src/main.nim", "assets"]
    expect UiError: discard pack(p, nativeTarget(), path / "dist")
    check not dirExists(path / "target")
    if dirExists(path / "dist"):
      for kind, file in walkDir(path / "dist"): check false

  test "included entry-local build configuration is retained in release compilation":
    let path = root / "entry-config"
    initProject(path)
    writeFile(path / "src/main.nim.cfg", "--define:releaseConfigPresent\n")
    writeFile(path / "src/main.nim", "when not defined(releaseConfigPresent):\n  {.error: \"missing included entry config\".}\n" & readFile(path / "src/main.nim"))
    let artifacts = pack(readProject(path), nativeTarget(), root / "entry-config-out")
    check artifacts.len == 1 and fileExists(artifacts[0])
    check not dirExists(path / "target")

  test "a relative output directory supports real compilation and packaged self-check":
    let path = root / "relative-native"
    initProject(path)
    let previous = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(previous)
    let artifacts = pack(readProject(path), nativeTarget(), "relative output")
    check artifacts.len == 1
    check isAbsolute(artifacts[0]) and fileExists(artifacts[0])
    check artifacts[0].parentDir == root / "relative output"
    check not dirExists(path / "target")
    var entries = 0
    for kind, file in walkDir(root / "relative output"):
      check kind == pcFile
      inc entries
    check entries == 2 # archive and checksum; temporary stage is gone

  when defined(posix):
    test "special implicit license files cannot be silently omitted":
      for name in ["LICENSE", "NOTICE", "third-party-licenses", "third-party-licenses.json"]:
        let p = fixture("fifo-" & name)
        if fileExists(p.root / name): removeFile(p.root / name)
        check posix.mkfifo(cstring(p.root / name), posix.Mode(0o600)) == 0
        expect UiError: discard pack(p, "linux", root / ("fifo-out-" & name))
    test "external native application binary parent aliases are rejected":
      let p = fixture("binary-parent")
      createDir(root / "native-parent")
      copyFile(p.root / "linux", root / "native-parent/app")
      createSymlink(root / "native-parent", root / "native-alias")
      expect UiError: discard pack(p, "linux", root / "binary-parent-out", root / "native-alias/app")
