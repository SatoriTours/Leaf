import std/[unittest, os, json, tempfiles]
import leaf
import leaf/runner
import ../fixture_app

suite "Application launch dispatch":
  test "headless check needs no display":
    let app = fixtureApplication(proc(): Node = text("OK"), title = "No GUI", width = 320, height = 240)
    check run(app, @["--check"]) == 0

  when not defined(windows):
    test "unimplemented native desktop launch fails explicitly":
      let app = fixtureApplication(proc(): Node = text("OK"), title = "Unsupported", width = 320, height = 240)
      check run(app, @[]) == 1

  test "unknown desktop parameters fail instead of silently launching":
    let app = fixtureApplication(proc(): Node = text("OK"), title = "Bad flag", width = 320, height = 240)
    check run(app, @["--unknown"]) == 1

  test "headless diagnostics have no desktop DPI initialization":
    let (file, path) = createTempFile("leaf-headless-dpi-", ".jsonl")
    file.close()
    defer: removeFile(path)
    let app = fixtureApplication(proc(): Node = text("OK"), title = "Headless DPI", width = 320, height = 240)
    check run(app, @["--check", "--log-file", path]) == 0
    for line in lines(path):
      check parseJson(line)["phase"].getStr != "dpi"
