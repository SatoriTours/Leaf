import std/[os, osproc, tempfiles, streams]
import leaf/orm_config

proc compileModelFailure*(declaration: string): tuple[code: int, output: string] =
  let root = createTempDir("leaf-model-compile-", "")
  defer: removeDir(root)
  let source = currentSourcePath().parentDir.parentDir.parentDir / "src"
  let path = root / "invalid.nim"
  writeFile(path, "import leaf/model\n" & declaration & "\n")
  var args = @["c", "--hints:off", "--path:" & source,
    "--nimcache:" & root / "cache", "--out:" & root / "invalid"]
  args.add(ormCompilerArgs(source))
  args.add(path)
  const Compiler = getCurrentCompilerExe()
  let process = startProcess(Compiler, args=args, options={poUsePath, poStdErrToStdOut})
  result.output = process.outputStream.readAll()
  result.code = process.waitForExit()
  process.close()
