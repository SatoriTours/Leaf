## Main executable resource, relative to the selected (possibly moved) SDK.
import std/[os, json, strutils]
import ./process_io
when defined(windows): import ./windows_paths

proc gccFromBuildScript*(path:string):string =
  let script=parseFile(path)
  proc executable(command:string):string =
    let argv=parseCmdLine(command)
    if argv.len==0:raise newException(IOError,"Nim produced an empty compiler command")
    let name=argv[0].extractFilename.toLowerAscii
    if name != "gcc" and name != "gcc.exe" and not name.endsWith("-gcc") and not name.endsWith("-gcc.exe"):
      raise newException(IOError,"DPI manifest requires MinGW GCC; incompatible Nim toolchain: " & argv[0])
    if isAbsolute(argv[0]):result=argv[0]
    elif argv[0].parentDir.len>0:
      result=absolutePath(argv[0],script.getOrDefault("currentDir").getStr(path.parentDir))
    else:result=findExe(argv[0])
    if result.len==0 or not fileExists(result):
      raise newException(IOError,"Nim selected GCC does not exist: " & argv[0])
    result=absolutePath(result)
  result=executable(script["linkcmd"].getStr)
  for compilation in script["compile"]:
    if executable(compilation[1].getStr) != result:
      raise newException(IOError,"DPI manifest requires the same GCC for compilation and linking")

proc compileWindowsManifest*(sources, cacheDirectory, gccPath: string): string =
  if gccPath.len == 0 or not fileExists(gccPath):
    raise newException(IOError, "DPI manifest requires an existing MinGW GCC: " & gccPath)
  let gcc = absolutePath(gccPath)
  var windres = gcc.parentDir / "windres".addFileExt(ExeExt)
  if not fileExists(windres): windres = findExe("windres".addFileExt(ExeExt))
  if windres.len == 0 or not fileExists(windres):
    raise newException(IOError, "DPI manifest resource compiler windres not found for " & gcc)
  let directory = absolutePath(cacheDirectory)
  createDir(directory)
  result = directory / "leaf_app_manifest.o"
  # Refuse an earlier object's contents even if the new tool claims success.
  if fileExists(result): removeFile(result)
  let manifest = sources / "leaf/resources/windows/leaf_app.manifest"
  if not fileExists(manifest):
    raise newException(IOError, "Leaf application manifest missing: " & manifest)
  copyFile(manifest, directory / "leaf_app.manifest")
  # A local ASCII basename avoids RC filename encoding and quote ambiguities.
  writeFile(directory / "leaf_app.rc", "1 24 \"leaf_app.manifest\"\n")
  var tool = absolutePath(windres)
  var preprocessor = gcc
  var working = directory
  when defined(windows):
    tool = compilerPath(tool)
    preprocessor = compilerPath(preprocessor)
    working = compilerPath(working)
  # windres parses its preprocessor command itself; quote that path once.
  let args = @["-J", "rc", "-O", "coff", "--preprocessor", quoteShell(preprocessor),
    "--preprocessor-arg=-E", "--preprocessor-arg=-xc", "--preprocessor-arg=-DRC_INVOKED",
    "-i", "leaf_app.rc", "-o", "leaf_app_manifest.o"]
  let process = startManaged(tool, args, working)
  defer: process.close()
  while not process.poll():
    if wasInterrupted(): raise newException(ProcessInterruptedError, "manifest compilation interrupted")
    sleep(10)
  if process.code != 0:
    raise newException(IOError, "DPI manifest resource compilation failed (exit " & $process.code & ")\n" & process.output.diagnosticText())
  if not fileExists(result) or getFileSize(result) == 0:
    raise newException(IOError, "DPI manifest resource compiler produced no object\n" & process.output.diagnosticText())
