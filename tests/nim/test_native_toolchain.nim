import std/[unittest, os, tempfiles, json, options, osproc, strutils]
import leaf/[core, project, targets, build, doctor, pack]
import leaf_cli as cli

suite "explicit backend and headless toolchain selection":
  test "current-directory CLI builds native headless and rejects native watch":
    let root = createTempDir("leaf-native-cli-", "")
    let previous = getCurrentDir()
    defer:
      setCurrentDir(previous)
      removeDir(root)
    writeFile(root / "main.nim", "import leaf\nproc render(c: BuildContext): Node = text(\"CLI native headless\")\nquit run(Application(title: \"native\", width: 320, height: 200, render: render))\n")
    writeFile(root / "leaf.json", $(%*{"name":"NativeCli", "identifier":"org.leaf.nativecli",
      "version":"0.1.0", "entry":"main.nim", "include":["main.nim"], "backend":"native"}))
    setCurrentDir(root)
    check cli.main(@["--check"]) == 0
    check cli.main(@["--watch"]) == 1
    check not fileExists(root / "target/nim/leaf_gpui.dll")
    check not fileExists(root / "target/nim/libleaf_gpui.so")

  test "default and explicit backend precedence remain strict":
    check resolveBuild(backendGpui).backend == backendGpui
    check resolveBuild(backendNative).backend == backendNative
    check resolveBuild(backendNative, backend="gpui").backend == backendGpui
    check resolveBuild(backendGpui, backend="native").backend == backendNative
    expect UiError: discard resolveBuild(backendGpui, backend="unknown")
    expect UiError: discard resolveBuild(backendGpui, target="android")
  test "native configuration is strict and native packaging rejects before staging":
    let root = createTempDir("leaf-native-config-", "")
    defer: removeDir(root)
    writeFile(root / "main.nim", "discard")
    let config = %*{"name":"NativeTest", "identifier":"org.leaf.native", "version":"0.1.0",
      "entry":"main.nim", "include":["main.nim"], "backend":"native"}
    writeFile(root / "leaf.json", $config)
    check readProject(root).backend == backendNative
    expect UiError: discard pack(readProject(root), "windows", root / "dist")
    check not dirExists(root / "dist")
    config["backend"] = %false
    writeFile(root / "leaf.json", $config)
    expect UiError: discard readProject(root)
  test "native doctor does not probe or load the GPUI bridge":
    let old = getEnv("LEAF_GPUI_LIBRARY")
    putEnv("LEAF_GPUI_LIBRARY", "/nonexistent/native-must-not-load-gpui")
    defer:
      if old.len > 0: putEnv("LEAF_GPUI_LIBRARY", old)
      else: delEnv("LEAF_GPUI_LIBRARY")
    let report = doctorReport(some(resolveBuild(backendNative)))
    check report["desktop_backend"].getStr == "native"
    check "gpui" notin report
    check "cargo" notin report["tools"]
    check "rustc" notin report["tools"]
  test "unsupported native host is refused before starting build":
    when not defined(windows):
      expect UiError: resolveBuild(backendNative).validateHost()
    else:
      resolveBuild(backendNative).validateHost()
  test "native project headless build runs without GPUI or Cargo":
    let root = createTempDir("leaf-native-headless-", "")
    defer: removeDir(root)
    writeFile(root / "main.nim", "import leaf\nproc render(c: BuildContext): Node = text(\"native headless\")\nquit run(Application(title: \"native\", width: 320, height: 200, render: render))\n")
    let project = Project(root: root, entry: root / "main.nim", backend: backendNative)
    let binary = build(project, selection=some(resolveBuild(backendNative, headlessOnly=true)))
    let result = execCmdEx(quoteShell(binary) & " --check")
    check result.exitCode == 0
    check not fileExists(binary.parentDir / "leaf_gpui.dll")
    check not fileExists(binary.parentDir / "libleaf_gpui.so")
    when defined(linux):
      let libraries = execCmdEx("ldd " & quoteShell(binary))
      checkpoint libraries.output
      check libraries.exitCode == 0
      let symbols = execCmdEx("nm -u " & quoteShell(binary))
      checkpoint symbols.output
      check symbols.exitCode == 0
      for forbidden in ["leaf_gpui", "vulkan", "user32", "gdi32", "comctl32"]:
        check forbidden notin libraries.output.toLowerAscii
        check forbidden notin symbols.output.toLowerAscii
      let instructions = parseFile(binary.parentDir / "cache" / "app.json")
      let link = instructions["linkcmd"].getStr.toLowerAscii
      check "leaf_gpui" notin link and "vulkan" notin link
      var generated = ""
      for file in walkFiles(binary.parentDir / "cache" / "*.c"):
        generated.add(readFile(file))
      check "leaf_gpui_abi_version" notin generated
      check "gpui_bridge.nim" notin generated
      check "backends/win32/host.nim" notin generated
