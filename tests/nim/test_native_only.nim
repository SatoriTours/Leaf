## Native-only defaults must be enforced before probing tools or creating output.
import std/[unittest, os, tempfiles, json, options, strutils]
import leaf/[core, project, targets, doctor, pack]
import ../../src/leaf/vendor/zippy/zippy/ziparchives

suite "native-only product contract":
  test "an omitted backend selects native":
    let root = createTempDir("leaf-native-default-", "")
    defer: removeDir(root)
    writeFile(root / "main.nim", "discard")
    writeFile(root / "leaf.json", $(%*{"name":"NativeDefault",
      "identifier":"org.leaf.default", "version":"0.1.0", "entry":"main.nim",
      "include":["main.nim"]}))
    let project = readProject(root)
    check project.backend == backendNative
    check resolveBuild(project.backend, target="windows").backend == backendNative

  test "the removed backend cannot be selected explicitly":
    expect UiError: discard parseBackend("gpui")
    expect UiError: discard resolveBuild(backendNative, backend="gpui")
    check parseBackend("native") == backendNative

  test "default doctor never probes a graphics bridge or Rust tools":
    let report = doctorReport()
    check report["desktop_backend"].getStr == "native"
    check not report.hasKey("gpui")
    check not report.hasKey("gpui_kit")
    check not report["tools"].hasKey("cargo")
    check not report["tools"].hasKey("rustc")

  test "unimplemented desktop targets are explicit, with headless still available":
    when not defined(windows):
      var refused = false
      try: resolveBuild(backendNative).validateHost()
      except UiError as error:
        refused = true
        check "not implemented" in error.msg
      check refused
    resolveBuild(backendNative, headlessOnly=true).validateHost()

  test "Windows packaging needs only its executable, not a rendering bridge":
    let root = createTempDir("leaf-native-package-", "")
    defer: removeDir(root)
    writeFile(root / "main.nim", "discard")
    writeFile(root / "leaf.json", $(%*{"name":"NativePackage",
      "identifier":"org.leaf.package", "version":"0.1.0", "entry":"main.nim",
      "include":["main.nim"]}))
    # A structural PE fixture proves archive contents, not Windows execution.
    var pe = newString(392)
    pe[0..1] = "MZ"; pe[60] = '\x80'; pe[128..131] = "PE\0\0"
    pe[132] = '\x64'; pe[133] = '\x86'; pe[148] = '\xf0'; pe[150] = '\x02'
    pe[152] = '\x0b'; pe[153] = '\x02'
    writeFile(root / "application.exe", pe)
    let artifacts = pack(readProject(root), "windows", root / "dist", root / "application.exe")
    check artifacts.len == 1
    let archive = openZipArchive(artifacts[0])
    defer: archive.close()
    check archive.extractFile("package/bin/package.exe") == pe
    check "native" in archive.extractFile("package/app/leaf.json")
    let inventory = archive.extractFile("package/licenses/inventory.json")
    check "GPUI" notin inventory
    for name in archive.walkFiles:
      check "gpui" notin name.toLowerAscii

  test "unimplemented packaging targets fail before creating output":
    let root = createTempDir("leaf-native-pack-reject-", "")
    defer: removeDir(root)
    let project = Project(root: root, backend: backendNative)
    for target in ["linux", "macos", "all"]:
      expect UiError: discard pack(project, target, root / "dist")
      check not dirExists(root / "dist")

  test "Android remains native and still refuses desktop headless execution":
    check resolveBuild(backendNative, target="android").backend == backendNative
    expect UiError:
      discard resolveBuild(backendNative, target="android", headlessOnly=true)
