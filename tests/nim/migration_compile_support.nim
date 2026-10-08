## Test-only helper: compile (and optionally run) real Nim migration sources.
## Migration files use numbered names that Nim cannot import as modules, so the
## generated probe programs include them textually, like the real catalog must.
import ./cleanup_support
import std/[os, osproc, streams, tempfiles]

const leafSourceRoot = currentSourcePath().parentDir.parentDir.parentDir / "src"

let probeCache = createTempDir("leaf-migration-probe-cache-", "")
removeDirectoryOnExit(probeCache)

proc compileProbe*(files: seq[tuple[path, content: string]], mainPath: string,
    run = false): tuple[code: int, output: string] =
  let compiler = getEnv("NIM", findExe("nim"))
  if compiler.len == 0: return (1, "Nim compiler not found")
  let root = createTempDir("leaf-migration-probe-", "")
  removeDirectoryOnExit(root)
  for file in files:
    let target = root / file.path
    createDir(target.parentDir)
    writeFile(target, file.content)
  let binary = root / ("probe" & (when defined(windows): ".exe" else: ""))
  var args = @["c", "--hints:off", "--path:" & leafSourceRoot,
    "--nimcache:" & probeCache, "--out:" & binary]
  if run: args.add "-r"
  args.add mainPath
  let process = startProcess(compiler, workingDir = root, args = args,
    options = {poUsePath, poStdErrToStdOut})
  result.output = process.outputStream.readAll()
  result.code = process.waitForExit()
  process.close()
