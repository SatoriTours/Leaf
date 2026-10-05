## Collect pinned Nim/Leaf license texts without network access.
import std/[os, tempfiles]
import leaf/[project, licenses, core]

proc main(): int =
  try:
    let args = commandLineParams()
    if args.len != 1: fail("usage: collect_licenses PROJECT")
    let project = readProject(args[0])
    let destination = project.root / "third-party-licenses"
    if symlinkExists(destination) or fileExists(destination) or dirExists(destination):
      fail("refusing to overwrite existing third-party-licenses")
    let stage = createTempDir(".leaf-licenses-", "", project.root)
    defer:
      if dirExists(stage): removeDir(stage)
    collectLicenses(stage)
    moveDir(stage, destination)
    stdout.writeLine(destination)
  except CatchableError as error:
    stderr.writeLine("leaf licenses: " & error.msg)
    result = 1

when isMainModule: quit(main())
