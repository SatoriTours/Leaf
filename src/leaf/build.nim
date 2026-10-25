## A build can be polled while the previous desktop process continues running.
import std/[os, strutils, options]
import ./[core, project, process_io, sdk]
import ./orm_config
import ./[android_build, android_job]
when defined(windows): import ./[windows_paths, windows_manifest]

const SourceRoot = currentSourcePath().parentDir.parentDir
type BuildJob* = ref object
  binary*: string
  android: AndroidJob
  process*: ManagedProcess

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

proc compilerBase(sources, cache, binary: string, isolatedConfig: bool): seq[string] =
  ## Compiler/library/ORM switches shared by application and headless builds.
  result = @["c", "-d:release", "--mm:orc", "--path:" & sources.replace("$", "$$"),
    "--nimcache:" & cache.replace("$", "$$"),
    "--out:" & binary.replace("$", "$$")]
  if isolatedConfig: result.add(@["--skipParentCfg:on", "--skipUserCfg:on"])
  when defined(windows): result.add(WindowsHeaderCompilerArgs)
  for argument in ormCompilerArgs(sources): result.add(argument.replace("$", "$$"))

proc startBuild*(project: Project, output = "", cacheDirectory = "", isolatedConfig = false,
                 selection: Option[BuildSelection] = none(BuildSelection)): BuildJob =
  let selected = selection.get(resolveBuild(project.backend))
  selected.validateHost()
  if selected.target == "android":
    let mobile=startAndroidBuild(project,libraryPath(),compiler(),output)
    return BuildJob(binary:mobile.binary,android:mobile)
  let directory = if cacheDirectory.len == 0: project.root / "target" / "nim" else: absolutePath(cacheDirectory)
  createDir(directory)
  result = BuildJob(binary: if output.len == 0: directory / "app".addFileExt(ExeExt)
    else: absolutePath(output.addFileExt(ExeExt)))
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
  var args = compilerBase(sources, cache, binary, isolatedConfig)
  if selected.headlessOnly: args.add("-d:leafHeadlessOnly")
  else: args.add("-d:leafNativeWin32")
  when defined(windows):
    let bundledGcc = sdkGcc()
    var gcc=bundledGcc
    if bundledGcc.len > 0:
      let path=compilerPath(gcc).replace("$", "$$")
      args.add(@["--cc:gcc", "--gcc.exe:" & path, "--gcc.linkerexe:" & path])
    else:
      # Ask Nim to generate its real project commands with its existing configs.
      # This does not compile/link C or replace the project's chosen toolchain.
      var discoverArgs=args
      discoverArgs.add(@["--compileOnly",entry])
      let discover=startManaged(executable,discoverArgs,project.root)
      var retained = false
      try:
        while not discover.poll():
          if wasInterrupted():raise newException(ProcessInterruptedError,"compiler discovery interrupted")
          sleep(10)
        if discover.code != 0:
          # Semantic errors are build results on Windows too. Retain the
          # completed child so callers can poll, inspect and close the job.
          result.process = discover
          retained = true
          return
        gcc=gccFromBuildScript(cache / binary.extractFilename.changeFileExt("json"))
      finally:
        if not retained: discover.close()
    let objectPath = compileWindowsManifest(sources, cache, gcc)
    # --passL is opaque to Nim; unlike path switches it does not expand dollars.
    args.add("--passL:" & quoteShell(compilerPath(objectPath)))
  args.add(entry)
  result.process = startManaged(executable, args, project.root)

proc startHeadlessBuild*(project: Project, entry, output, cacheDirectory: string): BuildJob =
  ## Compile a maintenance program without the graphical manifest or GUI backend.
  let directory = if cacheDirectory.len == 0: project.root / "target" / "leaf-db"
    else: absolutePath(cacheDirectory)
  createDir(directory)
  result = BuildJob(binary: absolutePath(output))
  var executable = compiler()
  var sources = libraryPath()
  var cache = directory / "cache"
  var binary = result.binary
  var target = entry
  when defined(windows):
    createDir(cache)
    executable = compilerPath(executable)
    sources = compilerPath(sources)
    cache = compilerPath(cache)
    binary = compilerPath(binary)
    target = compilerPath(target)
  var args = compilerBase(sources, cache, binary, false)
  when defined(windows):
    let bundledGcc = sdkGcc()
    if bundledGcc.len > 0:
      let path = compilerPath(bundledGcc).replace("$", "$$")
      args.add(@["--cc:gcc", "--gcc.exe:" & path, "--gcc.linkerexe:" & path])
  args.add(target)
  result.process = startManaged(executable, args, project.root)

proc pollBuild*(job: BuildJob): bool =
  if job.android != nil: job.android.pollAndroid() else: job.process.poll()
proc code*(job: BuildJob): int =
  if job.android != nil: job.android.code else: job.process.code
proc output*(job: BuildJob): string =
  if job.android != nil: job.android.output.diagnosticText() else: job.process.output.diagnosticText()
proc close*(job: BuildJob) =
  if job != nil:
    if job.android != nil: job.android.close() else: job.process.close()

proc build*(project: Project, output = "", selection: Option[BuildSelection] = none(BuildSelection)): string =
  beginInterruptHandling()
  defer: endInterruptHandling()
  let job = startBuild(project, output, selection = selection)
  defer: job.close()
  while not job.pollBuild():
    if wasInterrupted(): raise newException(ProcessInterruptedError, "build interrupted")
    sleep(10)
  if job.code != 0: fail("Nim application build failed (exit " & $job.code & ")\n" & job.output)
  job.binary
