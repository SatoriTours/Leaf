import std/[os, tempfiles]
import leaf/orm_config
import ./migration_compile_support

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
  # Windows pipe reads may be short before EOF. Keep polling the owned child
  # through exit and its final output drain instead of using Stream.readAll.
  result = runManagedBounded(Compiler, args, root, seconds = 120)
