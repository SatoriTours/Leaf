import std/[os, strutils, unittest]

let root = currentSourcePath().parentDir.parentDir.parentDir

proc referencedTestFiles(content: string): seq[string] =
  for line in content.splitLines:
    var rest = line
    while true:
      let marker = rest.find("tests/nim/test_")
      if marker < 0: break
      rest = rest[marker .. ^1]
      var finish = 0
      while finish < rest.len and
          (rest[finish].isAlphaNumeric or rest[finish] in {'_', '.', '/'}):
        inc finish
      if finish > 0:
        let candidate = rest[0 ..< finish]
        if candidate.endsWith(".nim") and '*' notin candidate: result.add(candidate)
      rest = rest[min(finish + 1, rest.len) .. ^1]

proc allowlistedTests(content: string): seq[string] =
  for line in content.splitLines:
    var rest = line
    while true:
      let marker = rest.find("\"test_")
      if marker < 0: break
      rest = rest[marker + 1 .. ^1]
      let finish = rest.find('"')
      if finish < 0: break
      let candidate = rest[0 ..< finish]
      if candidate.endsWith(".nim") and '*' notin candidate: result.add(candidate)
      rest = rest[min(finish + 1, rest.len) .. ^1]

suite "workflow test references":
  test "release workflow and model-only allowlist point at existing Nim tests":
    for relative in referencedTestFiles(readFile(root / ".github/workflows/release.yml")):
      check fileExists(root / relative)
    for name in allowlistedTests(readFile(root / "scripts/test.nim")):
      check fileExists(root / "tests/nim" / name)
