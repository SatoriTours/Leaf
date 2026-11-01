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
    writeFile(root / "main.nim", "import leaf\nlet Root = defineComponent[int, int](\"NativeCliRoot\",\n  proc(ctx: MountContext, p: int): int = p,\n  proc(ctx: ComponentContext, p, m: int): UiDescription = host(text(\"CLI native headless\")))\nquit run(componentApplication(component(Root, 0), \"native\", 320, 200))\n")
    writeFile(root / "leaf.json", $(%*{"name":"NativeCli", "identifier":"org.leaf.nativecli",
      "version":"0.1.0", "entry":"main.nim", "include":["main.nim"], "backend":"native"}))
    setCurrentDir(root)
    check cli.main(@["--check"]) == 0
    check cli.main(@["--watch"]) == 1
    check not fileExists(root / "target/nim/leaf_gpui.dll")
    check not fileExists(root / "target/nim/libleaf_gpui.so")

  test "default native backend cannot be overridden by a removed backend":
    check resolveBuild(backendNative).backend == backendNative
    check resolveBuild(backendNative, backend="native").backend == backendNative
    expect UiError: discard resolveBuild(backendNative, backend="gpui")
    expect UiError: discard resolveBuild(backendNative, backend="unknown")
    check resolveBuild(backendNative, target="android").backend == backendNative
    expect UiError: discard resolveBuild(backendNative, target="android", backend="gpui")
    expect UiError: discard resolveBuild(backendNative, target="android", headlessOnly=true)
    expect UiError: discard resolveBuild(backendNative, target="unknown")

  test "subdirectory CLI and maintenance builds accept relative toolchain overrides":
    let nim = compiler().absolutePath
    let sources = libraryPath().absolutePath
    let root = createTempDir("leaf-relative 中文 $ tools-", "")
    let previous = getCurrentDir()
    let hadNim = existsEnv("NIM")
    let hadLibrary = existsEnv("LEAF_LIBRARY")
    let oldNim = getEnv("NIM")
    let oldLibrary = getEnv("LEAF_LIBRARY")
    defer:
      setCurrentDir(previous)
      if hadNim: putEnv("NIM", oldNim)
      else: delEnv("NIM")
      if hadLibrary: putEnv("LEAF_LIBRARY", oldLibrary)
      else: delEnv("LEAF_LIBRARY")
      removeDir(root)
    createDir(root / "nested")
    # Keep sources below the fixture root: paths that traverse all the way to
    # the filesystem root can accidentally work from either cwd.
    copyDir(sources, root / "sdk/src")
    writeFile(root / "main.nim", "import leaf\nlet Root = defineComponent[int, int](\"RelativeTools\",\n  proc(ctx: MountContext, p: int): int = p,\n  proc(ctx: ComponentContext, p, m: int): UiDescription = host(text(\"relative paths\")))\nquit run(componentApplication(component(Root, 0), \"relative\", 320, 200))\n")
    writeFile(root / "leaf.json", $(%*{"name":"RelativeTools", "identifier":"org.leaf.relative",
      "version":"0.1.0", "entry":"main.nim", "include":["main.nim"], "backend":"native"}))
    setCurrentDir(root / "nested")
    putEnv("NIM", relativePath(nim, getCurrentDir()))
    putEnv("LEAF_LIBRARY", "../sdk/src")
    check cli.main(@["--check"]) == 0
    # Database commands use this separate build entry, with the same cwd change.
    writeFile(root / "maintenance.nim", "import leaf/core\necho \"maintenance ok\"\n")
    let job = startHeadlessBuild(readProject(root), root / "maintenance.nim",
      root / "maintenance".addFileExt(ExeExt), root / "target/maintenance-cache")
    defer: job.close()
    while not job.pollBuild(): sleep(10)
    checkpoint job.output
    require job.code == 0
    let run = execCmdEx(quoteShell(job.binary))
    check run.exitCode == 0
    check run.output.strip == "maintenance ok"
  test "native configuration is strict and unsupported packaging rejects before staging":
    let root = createTempDir("leaf-native-config-", "")
    defer: removeDir(root)
    writeFile(root / "main.nim", "discard")
    let config = %*{"name":"NativeTest", "identifier":"org.leaf.native", "version":"0.1.0",
      "entry":"main.nim", "include":["main.nim"], "backend":"native"}
    writeFile(root / "leaf.json", $config)
    check readProject(root).backend == backendNative
    expect UiError: discard pack(readProject(root), "macos", root / "dist")
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
    writeFile(root / "main.nim", "import leaf\nlet Root = defineComponent[int, int](\"NativeHeadlessRoot\",\n  proc(ctx: MountContext, p: int): int = p,\n  proc(ctx: ComponentContext, p, m: int): UiDescription = host(text(\"native headless\")))\nquit run(componentApplication(component(Root, 0), \"native\", 320, 200))\n")
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
