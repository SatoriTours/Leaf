## Test-only helper: compile (and optionally run) real Nim migration sources.
## Migration files use numbered names that Nim cannot import as modules, so the
## generated probe programs include them textually, like the real catalog must.
import ./cleanup_support
import leaf/process_io
import std/[monotimes, os, osproc, streams, tempfiles, times]

const leafSourceRoot = currentSourcePath().parentDir.parentDir.parentDir / "src"

let probeCache = createTempDir("leaf-migration-probe-cache-", "")
removeDirectoryOnExit(probeCache)

proc runManagedBounded*(exe: string, args: seq[string], cwd: string,
    seconds = 900): tuple[code: int, output: string] =
  ## Test-local bounded child: literal argv, monotonic deadline, finally reap.
  let child = startManaged(exe, args, cwd)
  try:
    let deadline = getMonoTime() + initDuration(seconds = seconds)
    while not child.poll():
      if getMonoTime() > deadline:
        result.code = 124
        break
      sleep(10)
    if result.code != 124: result.code = child.code
    result.output = child.output.diagnosticText()
  finally:
    child.close()


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
  let ran = runManagedBounded(compiler, args, root)
  result.code = ran.code
  result.output = ran.output

proc createProbeRoot*(): string =
  ## A probe root the caller owns and removes (unlike compileProbe's temporary).
  createTempDir("leaf-migration-probe-", "")

proc writeProbeFiles*(root: string, files: seq[tuple[path, content: string]]) =
  for file in files:
    let target = root / file.path
    createDir(target.parentDir)
    writeFile(target, file.content)

proc buildProbe*(root, mainPath, nimcache: string, outName = "probe",
    outPath = "", extraArgs: seq[string] = @[]): tuple[code: int, output: string, binary: string] =
  ## Compile an existing root with an explicit nimcache, keeping the binary.
  ## `outPath` keeps `--out` away from fixture paths that contain `$`.
  let compiler = getEnv("NIM", findExe("nim"))
  if compiler.len == 0: return (1, "Nim compiler not found", "")
  result.binary = if outPath.len > 0: outPath
    else: root / (outName & (when defined(windows): ".exe" else: ""))
  var args = @["c", "--hints:off", "--path:" & leafSourceRoot,
    "--nimcache:" & nimcache, "--out:" & result.binary]
  args.add extraArgs
  args.add mainPath
  let ran = runManagedBounded(compiler, args, root)
  result.code = ran.code
  result.output = ran.output

proc runBinary*(binary, workingDir: string): tuple[code: int, output: string] =
  let ran = runManagedBounded(binary, @[], workingDir)
  result.code = ran.code
  result.output = ran.output

proc startBuild*(root, mainPath, nimcache, outName: string): Process =
  ## Start a real compile without waiting, for concurrency tests.
  let compiler = getEnv("NIM", findExe("nim"))
  let binary = root / (outName & (when defined(windows): ".exe" else: ""))
  startProcess(compiler, workingDir = root,
    args = @["c", "--hints:off", "--path:" & leafSourceRoot, "--nimcache:" & nimcache,
      "--out:" & binary, mainPath],
    options = {poUsePath, poStdErrToStdOut})
