import std/[unittest, os, json, tempfiles]
import leaf
import leaf/runner

suite "Application launch dispatch":
  test "headless check does not need a GPUI library or display":
    let oldLibrary = getEnv("LEAF_GPUI_LIBRARY")
    putEnv("LEAF_GPUI_LIBRARY", "/missing/gpui")
    defer:
      if oldLibrary.len == 0: delEnv("LEAF_GPUI_LIBRARY")
      else: putEnv("LEAF_GPUI_LIBRARY", oldLibrary)
    let app = Application(title: "No GUI", width: 320, height: 240,
      render: proc(ctx: BuildContext): Node = text("OK"))
    check run(app, @["--check"]) == 0

  test "default launch reports a missing graphics dependency":
    let oldLibrary = getEnv("LEAF_GPUI_LIBRARY")
    putEnv("LEAF_GPUI_LIBRARY", "/missing/gpui")
    defer:
      if oldLibrary.len == 0: delEnv("LEAF_GPUI_LIBRARY")
      else: putEnv("LEAF_GPUI_LIBRARY", oldLibrary)
    let app = Application(title: "No GPUI", width: 320, height: 240,
      render: proc(ctx: BuildContext): Node = text("OK"))
    check run(app, @[]) == 1

  test "unknown desktop parameters fail instead of silently launching":
    let app = Application(title: "Bad flag", width: 320, height: 240,
      render: proc(ctx: BuildContext): Node = text("OK"))
    check run(app, @["--unknown"]) == 1

  test "headless diagnostics have no desktop DPI initialization":
    let (file, path) = createTempFile("leaf-headless-dpi-", ".jsonl")
    file.close()
    defer: removeFile(path)
    let app = Application(title: "Headless DPI", width: 320, height: 240,
      render: proc(ctx: BuildContext): Node = text("OK"))
    check run(app, @["--check", "--log-file", path]) == 0
    for line in lines(path):
      check parseJson(line)["phase"].getStr != "dpi"
