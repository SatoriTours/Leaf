import std/[unittest, os, tempfiles, json, strutils]
import leaf/doctor

# Real subprocesses expose which fixture tool doctor selected; no compiler is
# needed to exercise version discovery. Copies keep this portable to Windows.
if commandLineParams() == @["--version"]:
  echo "tool fixture: " & getAppFilename().parentDir.extractFilename
  quit(0)

proc tool(directory, name: string) =
  createDir(directory)
  let path = directory / name.addFileExt(ExeExt)
  copyFile(getAppFilename(), path)
  when defined(posix):
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc withTools(body: proc(root: string)) =
  let root = createTempDir("leaf doctor 中文 $ ", "")
  let oldPath = getEnv("PATH")
  let oldNim = getEnv("NIM")
  let hadNim = existsEnv("NIM")
  defer:
    putEnv("PATH", oldPath)
    if hadNim: putEnv("NIM", oldNim)
    else: delEnv("NIM")
    removeDir(root)
  tool(root / "compiler", "gcc")
  putEnv("NIM", getAppFilename())
  putEnv("PATH", root / "compiler" & PathSep & root / "resources")
  body(root)

suite "doctor resource compiler discovery":
  test "windres on PATH is reported when GCC has no sibling tool":
    withTools(proc(root: string) =
      tool(root / "resources", "windres")
      let report = doctorReport()
      check report["cc"].getStr == root / "compiler" / "gcc".addFileExt(ExeExt)
      check report["tools"]["windres"].getStr.strip == "tool fixture: resources"
    )

  test "a sibling windres takes precedence over another PATH tool":
    withTools(proc(root: string) =
      tool(root / "resources", "windres")
      tool(root / "compiler", "windres")
      # Put the unrelated tool first so a PATH-first lookup would fail here.
      putEnv("PATH", root / "resources" & PathSep & root / "compiler")
      let report = doctorReport()
      check report["tools"]["windres"].getStr.strip == "tool fixture: compiler"
    )

  test "missing windres stays explicitly absent":
    withTools(proc(root: string) =
      let report = doctorReport()
      check report["tools"]["windres"].kind == JNull
    )
