import ./cleanup_support
import std/[unittest, os, json, strutils, tempfiles]
import leaf/[core, project, headless, build, process_io]
import ../../examples/counter
when defined(windows) or defined(macosx): import std/strtabs

let base = createTempDir("leaf-nim-tooling-", "")
removeDirectoryOnExit(base)

proc checkBuiltExecutable(binary: string) =
  check fileExists(binary)
  if fileExists(binary):
    let child = startManaged(binary, @[], base)
    defer: child.close()
    while not child.poll(): sleep(10)
    check child.code == 0
    check child.output.diagnosticText().strip() == "native executable ready"

suite "Nim project and headless tooling":
  test "default build returns the executable actually produced by Nim":
    let directory = base / "default build"
    createDir(directory)
    let source = directory / "main.nim"
    writeFile(source, "echo \"native executable ready\"\n")
    let binary = build(readProject(source))
    check binary.extractFilename == (when defined(windows): "app.exe" else: "app")
    checkBuiltExecutable(binary)

  test "extensionless build output returns the executable actually produced by Nim":
    let directory = base / "named build"
    createDir(directory)
    let source = directory / "main.nim"
    writeFile(source, "echo \"native executable ready\"\n")
    let binary = build(readProject(source), directory / "published name")
    check binary.extractFilename == (when defined(windows): "published name.exe" else: "published name")
    checkBuiltExecutable(binary)

  test "build preserves a caller supplied executable extension":
    let directory = base / "custom build"
    createDir(directory)
    let source = directory / "main.nim"
    writeFile(source, "echo \"native executable ready\"\n")
    let binary = build(readProject(source), directory / "published.bin")
    check binary.extractFilename == "published.bin"
    checkBuiltExecutable(binary)

  test "project init produces a compilable Nim entry":
    let path = base / "application"
    initProject(path)
    let project = readProject(path)
    check project.entry.endsWith("src" / "main.nim")
    check project.name == "application"
    check project.includedPaths == @["src", "assets"]
    check "import leaf" in readFile(project.entry)
    expect UiError: initProject(path)

  test "seven page project uses a multi-file Nim entry":
    let root = currentSourcePath().parentDir.parentDir.parentDir
    let project = readProject(root / "example")
    check project.entry.endsWith("example" / "main.nim")
    check "ui.nim" in project.includedPaths
    for entry in ["stocks.nim", "reports.nim", "chat.nim"]:
      check readProject(root / "example" / entry).entry.endsWith(entry)

  test "standalone Nim examples resolve without JSON manifests":
    let file = base / "app.nim"
    writeFile(file, "discard")
    let project = readProject(file)
    check project.entry == file
    check project.root == base

  test "project traversal and invalid configuration are rejected":
    let path = base / "bad"
    createDir(path)
    writeFile(base / "external.nim", "discard")
    writeFile(path / "leaf.json", $ %*{"name": "bad", "identifier": "org.bad",
      "version": "1", "entry": "../external.nim"})
    expect UiError: discard readProject(path)
    expect UiError: discard resolve(path, "../external.nim")
    expect UiError: discard resolve(path, base / "external.nim")
    writeFile(path / "leaf.json", $ %*{"name": "bad"})
    expect UiError: discard readProject(path)

  when defined(posix):
    test "existing symlinks cannot escape the project":
      let path = base / "links"
      createDir(path)
      createSymlink(base / "external.nim", path / "alias.nim")
      expect UiError: discard resolve(path, "alias.nim")

  test "ordered headless events and tree dump":
    let dump = base / "snapshot.json"
    check runHeadless(counterApp(), @["--headless", "--click", "add",
      "--click", "add", "--stats", "--dump-tree", dump, "--check"]) == 0
    let tree = parseFile(dump)
    check tree["root"]["children"][1]["text"].getStr == "2"
    check tree["performance"]["dispatches"].getInt == 2
    check tree["performance"]["renders"].getInt == 3

  test "malformed commands return a failing status":
    check runHeadless(counterApp(), @["--click"]) == 1
    check runHeadless(counterApp(), @["--toggle", "add", "maybe"]) == 1
    check runHeadless(counterApp(), @["--unknown"]) == 1

  test "headless diagnostics log ordered events without overwriting source":
    let log = base / "headless.jsonl"
    let dump = base / "headless.json"
    check runHeadless(counterApp(), @["--headless", "--trace", "--click", "add",
      "--log-file", log, "--dump-tree", dump, "--check"]) == 0
    check "\"phase\":\"event\"" in readFile(log)
    check parseFile(dump)["root"]["children"][1]["text"].getStr == "1"
    let source = base / "safe.nim"
    writeFile(source, "original")
    check runHeadless(counterApp(), @["--headless", "--dump-tree", source]) == 1
    check readFile(source) == "original"
