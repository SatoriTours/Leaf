when not defined(windows): {.error: "native toolchain tests require Windows".}
import std/[unittest, os, tempfiles, options, osproc, strutils, json, monotimes, times]
from std/winlean import nil
import leaf/[project, build, targets]
import leaf/backends/win32/api

type WindowSearch = object
  process: DWORD
  window: HWND
proc processOf(window: HWND, process: ptr DWORD): DWORD {.stdcall, dynlib: "user32.dll", importc: "GetWindowThreadProcessId", raises: [].}
proc enumerate(callback: proc(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].},
               data: LPARAM): BOOL {.stdcall, dynlib: "user32.dll", importc: "EnumWindows", raises: [].}
proc matchWindow(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  let state = cast[ptr WindowSearch](data)
  var process: DWORD
  discard processOf(window, addr process)
  if process == state.process and IsWindowVisible(window) != 0:
    state.window = window
    return 0
  1
proc loadData(path: WideCString, file: winlean.Handle, flags: DWORD): winlean.Handle {.stdcall, dynlib: "kernel32.dll", importc: "LoadLibraryExW".}
proc freeData(module: winlean.Handle): BOOL {.stdcall, dynlib: "kernel32.dll", importc: "FreeLibrary".}
proc findResource(module: winlean.Handle, name, kind: pointer): winlean.Handle {.stdcall, dynlib: "kernel32.dll", importc: "FindResourceW".}
proc loadResource(module, resource: winlean.Handle): winlean.Handle {.stdcall, dynlib: "kernel32.dll", importc: "LoadResource".}
proc lockResource(resource: winlean.Handle): pointer {.stdcall, dynlib: "kernel32.dll", importc: "LockResource".}
proc resourceSize(module, resource: winlean.Handle): DWORD {.stdcall, dynlib: "kernel32.dll", importc: "SizeofResource".}

proc manifestOf(path: string): string =
  let module = loadData(newWideCString(path), 0, 0x22)
  doAssert module != 0
  defer: discard freeData(module)
  let resource = findResource(module, cast[pointer](1), cast[pointer](24))
  doAssert resource != 0
  let data = lockResource(loadResource(module, resource))
  let length = int(resourceSize(module, resource))
  doAssert data != nil and length > 0
  result = newString(length)
  copyMem(addr result[0], data, length)

proc readProcess(access: DWORD, inherited: BOOL, process: DWORD): winlean.Handle {.stdcall, dynlib: "kernel32.dll", importc: "OpenProcess".}
proc enumerateModules(process: winlean.Handle, modules: ptr winlean.Handle, size: DWORD,
                      needed: ptr DWORD): BOOL {.stdcall, dynlib: "kernel32.dll", importc: "K32EnumProcessModules".}
proc moduleName(process, module: winlean.Handle, path: WideCString, size: DWORD): DWORD {.stdcall, dynlib: "kernel32.dll", importc: "K32GetModuleFileNameExW".}
proc loadedModules(processId: DWORD): seq[string] =
  let process = readProcess(0x410, 0, processId) # query/read our own child only
  doAssert process != 0
  defer: discard winlean.closeHandle(process)
  var modules: array[1024, winlean.Handle]
  var needed: DWORD
  doAssert enumerateModules(process, addr modules[0], DWORD(sizeof(modules)), addr needed) != 0
  doAssert needed <= DWORD(sizeof(modules))
  for i in 0..<int(needed) div sizeof(winlean.Handle):
    let wide = newWideCString(32768)
    let count = moduleName(process, modules[i], wide, 32768)
    doAssert count > 0 and count < 32768
    result.add(($wide).extractFilename.toLowerAscii)

proc launchAndClose(binary: string) =
  let child = startProcess(binary, options = {poParentStreams})
  defer:
    if child.running: child.terminate()
    child.close()
  var search = WindowSearch(process: DWORD(child.processID))
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while search.window == nil and child.running and getMonoTime() < deadline:
    discard enumerate(matchWindow, cast[LPARAM](addr search))
    sleep(10)
  check search.window != nil
  if search.window != nil:
    check GetDpiForWindow(search.window) > 0
    let modules = loadedModules(search.process)
    check modules.len > 0
    echo "NATIVE_LOADED_MODULES=", modules.join(",")
    for name in modules:
      check "leaf_gpui" notin name and "vulkan" notin name
    check PostMessageW(search.window, WM_CLOSE, 0, 0) != 0
  check child.waitForExit(5000) == 0


suite "real Cargo-free Win32 application builds":
  test "native and headless applications compile from a Unicode space dollar path":
    let root = createTempDir("leaf 原生 $ tools-", "")
    defer: removeDir(root)
    let previousPath = getEnv("PATH")
    let nimDirectory = getEnv("NIM", findExe("nim")).parentDir
    let gccDirectory = findExe("gcc").parentDir
    putEnv("PATH", [nimDirectory, gccDirectory, getEnv("SystemRoot") / "System32",
      getEnv("SystemRoot")].join($PathSep))
    defer: putEnv("PATH", previousPath)
    check findExe("cargo").len == 0 and findExe("rustc").len == 0
    let previousLibrary = getEnv("LEAF_LIBRARY")
    let sources = libraryPath()
    let movedSources = root / "moved SDK 中文 $" / "src"
    copyDir(sources, movedSources)
    putEnv("LEAF_LIBRARY", movedSources)
    defer:
      if previousLibrary.len == 0: delEnv("LEAF_LIBRARY")
      else: putEnv("LEAF_LIBRARY", previousLibrary)
    writeFile(root / "main.nim", "import leaf\nproc render(c: BuildContext): Node = column(@[text(\"中文 😀\"), input(\"hello\")])\nquit run(Application(title: \"native\", width: 320, height: 200, render: render))\n")
    let project = Project(root: root, entry: root / "main.nim", backend: backendNative)
    let binary = build(project)
    check fileExists(binary)
    let checked = execCmdEx(quoteShell(binary) & " --check")
    check checked.exitCode == 0
    check not fileExists(binary.parentDir / "leaf_gpui.dll")
    let manifest = manifestOf(binary)
    check "PerMonitorV2" in manifest
    check "Microsoft.Windows.Common-Controls" in manifest
    check "trustInfo" notin manifest
    # MinGW objdump accepts a narrow filename and loses Unicode absolute paths.
    # Inspect the same EXE in its Unicode directory using its ASCII basename.
    let imports = execCmdEx("objdump -p " & quoteShell(binary.extractFilename),
      workingDir = binary.parentDir)
    checkpoint imports.output
    check imports.exitCode == 0
    check "leaf_gpui" notin imports.output.toLowerAscii
    check "vulkan" notin imports.output.toLowerAscii
    launchAndClose(binary)
    let instructions = parseFile(binary.parentDir / "cache" / "app.json")
    let command = instructions["linkcmd"].getStr.toLowerAscii
    check "leaf_gpui" notin command and "vulkan" notin command
    var generated = ""
    for c in walkFiles(binary.parentDir / "cache" / "*.c"):
      generated.add(readFile(c))
    check "leaf_gpui_abi_version" notin generated
    check "gpui_bridge.nim" notin generated
    let headless = build(project, root / "headless.exe",
      some(resolveBuild(backendNative, headlessOnly=true)))
    check execCmdEx(quoteShell(headless) & " --check").exitCode == 0

  test "the acceptance form compiles and opens using its native project setting":
    let directory = createTempDir("leaf-form-sample-", "")
    defer: removeDir(directory)
    let sample = currentSourcePath().parentDir.parentDir.parentDir / "examples" / "native_forms"
    let binary = build(readProject(sample), directory / "sample.exe")
    check execCmdEx(quoteShell(binary) & " --check").exitCode == 0
    launchAndClose(binary)
