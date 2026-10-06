## A build can be polled while the previous desktop process continues running.
import std/[os, strutils]
import ./[core, project, process_io, gpui_build, sdk]
when defined(windows): import ./windows_paths

const SourceRoot = currentSourcePath().parentDir.parentDir
type BuildJob* = ref object
  binary*: string
  process*: ManagedProcess
  bridge: string

proc libraryPath*(): string =
  let installed = sdkRoot()
  result = getEnv("LEAF_LIBRARY", if installed.len > 0: installed / "src" else: SourceRoot)
  if not fileExists(result / "leaf.nim"):
    fail("Leaf sources not found; set LEAF_LIBRARY to the installed src directory")

proc compiler*(): string =
  let bundled = sdkCompiler()
  result = getEnv("NIM", if bundled.len > 0: bundled else: findExe("nim"))
  if result.len == 0 or not fileExists(result):
    fail("Nim compiler not found; install Nim 2.2.6+ or set NIM")

proc startBuild*(project: Project, output = "", cacheDirectory = "", isolatedConfig = false): BuildJob =
  let directory = if cacheDirectory.len == 0: project.root / "target" / "nim" else: absolutePath(cacheDirectory)
  createDir(directory)
  result = BuildJob(binary: if output.len == 0: directory / "app".addFileExt(ExeExt)
    else: absolutePath(output.addFileExt(ExeExt)))
  result.bridge = ensureGpui()
  stageGpui(result.bridge, result.binary)
  var executable = compiler()
  var sources = libraryPath()
  var cache = directory / "cache"
  var binary = result.binary
  var entry = project.entry
  when defined(windows):
    createDir(cache)
    executable = compilerPath(executable)
    sources = compilerPath(sources)
    cache = compilerPath(cache)
    binary = compilerPath(binary)
    entry = compilerPath(entry)
  # Nim expands dollar variables in path switches independently of the shell.
  var args = @["c", "-d:release", "--mm:orc", "--path:" & sources.replace("$", "$$"),
    "--nimcache:" & cache.replace("$", "$$"),
    "--out:" & binary.replace("$", "$$")]
  if isolatedConfig: args.add(@["--skipParentCfg:on", "--skipUserCfg:on"])
  when defined(windows):
    let gcc = sdkGcc()
    if gcc.len > 0:
      let path = compilerPath(gcc).replace("$", "$$")
      args.add(@["--cc:gcc", "--gcc.exe:" & path, "--gcc.linkerexe:" & path])
  args.add(entry)
  result.process = startManaged(executable, args, project.root)

proc pollBuild*(job: BuildJob): bool = job.process.poll()
proc code*(job: BuildJob): int = job.process.code
proc output*(job: BuildJob): string = job.process.output.diagnosticText()
proc close*(job: BuildJob) =
  if job != nil: job.process.close()

proc build*(project: Project, output = ""): string =
  beginInterruptHandling()
  defer: endInterruptHandling()
  let job = startBuild(project, output)
  defer: job.close()
  while not job.pollBuild():
    if wasInterrupted(): raise newException(ProcessInterruptedError, "build interrupted")
    sleep(10)
  if job.code != 0: fail("Nim application build failed (exit " & $job.code & ")\n" & job.output)
  job.binary
