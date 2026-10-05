import ./cleanup_support
import std/[unittest, os, tempfiles, json, tables, strutils]
import leaf/[core, project, native_binary]

let root = createTempDir("leaf-package-project-", "")
removeDirectoryOnExit(root)
proc config(): JsonNode = %*{"name": "My App", "identifier": "org.example.my-app",
  "version": "1.2.3", "entry": "src/main.nim", "include": ["src", "assets"],
  "platforms": {"linux": {"binary": "../linux-app"}, "macos": {"icon": "assets/App.icns"}}}
proc open(value: JsonNode): Project =
  writeFile(root / "leaf.json", $value)
  readProject(root)
createDir(root / "src"); createDir(root / "assets")
writeFile(root / "src/main.nim", "discard")
writeFile(root / "assets/App.icns", "icns")

suite "Portable Nim release projects":
  test "strict manifest retains native build inputs and portable source includes":
    let p = open(config())
    check p.slug == "my-app"
    check p.entryRelative == "src/main.nim"
    check p.platforms["linux"].binary == "../linux-app"
    check p.platforms["macos"].icon == "assets/App.icns"
  test "unknown fields and incompatible interpreter manifests are rejected":
    for name in ["unknown", "runtime"]:
      let c = config(); c[name] = %"value"
      expect UiError: discard open(c)
    let c = config(); c["platforms"]["linux"]["runtime"] = %"host"
    expect UiError: discard open(c)
    c["platforms"] = %*{"android": {}}
    expect UiError: discard open(c)
  test "names reverse DNS and bounded semantic versions are validated":
    for (field, value) in [("name", "bad/name"), ("name", ""),
        ("identifier", "single"), ("identifier", "org.1app"),
        ("version", "1.2"), ("version", "1.-2.3"), ("version", "1.2.4294967296")]:
      let c = config(); c[field] = %value
      expect UiError: discard open(c)
  test "entry must be included and paths must be portable":
    let c = config(); c["include"] = %*["assets"]
    expect UiError: discard open(c)
    for path in ["../out", "a/../out", "./src", "src//file", "src\\file", "/absolute",
        "assets/CON.txt", "assets/LPT1", "assets/abc.", "assets/abc ", "assets/a:b", "assets/a?b", "assets/a\n", "assets/a\u0085"]:
      expect UiError: discard portableRelative(path)
    check portableRelative("assets/中文 image.png") == "assets/中文 image.png"
  test "init handles numeric spaced names with valid identifiers and includes modules":
    let directory = root / "123 Demo App"
    initProject(directory)
    let p = readProject(directory)
    check p.slug == "app-123-demo-app"
    check "src" in p.includedPaths
  when defined(posix):
    test "entry aliases cannot escape through a parent directory":
      let outside = root / "outside"
      createDir(outside); writeFile(outside / "main.nim", "discard")
      createSymlink(outside, root / "linked")
      let c = config(); c["entry"] = %"linked/main.nim"; c["include"] = %*["linked"]
      # The alias is within root here, so a link inside the project is valid for
      # dev resolution, but an actual external target must be rejected.
      let external = createTempDir("leaf-external-", "")
      defer: removeDir(external)
      writeFile(external / "main.nim", "discard")
      removeFile(root / "linked"); createSymlink(external, root / "linked")
      expect UiError: discard open(c)

suite "Native executable header validation":
  test "ELF64 Mach-O64 and PE64 identify actual CPU architecture":
    var elf = newString(64)
    elf[0..6] = "\x7fELF\x02\x01\x01"
    elf[16] = '\x02'; elf[18] = '\x3e'; elf[52] = '\x40'
    writeFile(root / "elf", elf)
    check nativeBinary(root / "elf", "linux") == "x86_64"
    elf[18] = '\xb7'; writeFile(root / "elf", elf)
    check nativeBinary(root / "elf", "linux") == "aarch64"
    var mac = newString(32)
    mac[0..3] = "\xcf\xfa\xed\xfe"; mac[4] = '\x0c'; mac[7] = '\x01'; mac[12] = '\x02'
    writeFile(root / "mac", mac)
    check nativeBinary(root / "mac", "macos") == "aarch64"
    var pe = newString(392)
    pe[0..1] = "MZ"; pe[60] = '\x80'; pe[128..131] = "PE\0\0"
    pe[132] = '\x64'; pe[133] = '\x86'; pe[148] = '\xf0'; pe[150] = '\x02'
    pe[152] = '\x0b'; pe[153] = '\x02'
    writeFile(root / "pe", pe)
    check nativeBinary(root / "pe", "windows") == "x86_64"
    expect UiError: discard nativeBinary(root / "pe", "linux")
    pe[153] = '\x01'; writeFile(root / "pe", pe)
    expect UiError: discard nativeBinary(root / "pe", "windows")
  test "truncated arbitrary and unsupported executable headers are rejected":
    for content in ["", "hello", "\x7fELF", "MZ", "\xca\xfe\xba\xbe", "\xcf\xfa\xed\xfe"]:
      writeFile(root / "invalid", content)
      for target in ["linux", "macos", "windows"]:
        expect UiError: discard nativeBinary(root / "invalid", target)
