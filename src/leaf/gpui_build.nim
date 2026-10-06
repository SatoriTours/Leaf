## Build one GPUI bridge and copy it beside each application executable.
import std/os
import ./[core,gpui_api,process_io,sdk]
proc gpuiLibraryName*(target:string):string =
  case target
  of "windows":"leaf_gpui.dll"
  of "macos":"libleaf_gpui.dylib"
  of "linux":"libleaf_gpui.so"
  else:fail("unsupported GPUI target: " & target)
proc ensureGpui*():string =
  let override=getEnv("LEAF_GPUI_LIBRARY")
  if override.len>0:
    if not fileExists(override):fail("LEAF_GPUI_LIBRARY does not exist")
    return absolutePath(override)
  let bundled = sdkFile("lib" / GpuiLibraryName)
  if bundled.len > 0 and getEnv("LEAF_GPUI_ROOT").len == 0: return bundled
  let root=getEnv("LEAF_GPUI_ROOT",FrameworkRoot)
  if not fileExists(root/"Cargo.toml"):fail("GPUI bridge sources not found; set LEAF_GPUI_ROOT or LEAF_GPUI_LIBRARY")
  # Rustup selects Cargo by argv[0]; retain the cargo symlink name.
  let cargo=getEnv("CARGO",findExe("cargo",followSymlinks=false))
  if cargo.len==0:fail("Rust/Cargo is required to build the GPUI bridge")
  let release=getEnv("LEAF_GPUI_PROFILE")=="release"
  var args = @["build","--locked","-p","leaf-gpui"]
  if release:args.add("--release")
  let process=startManaged(cargo,args,root)
  defer:process.close()
  while not process.poll():
    if wasInterrupted():raise newException(ProcessInterruptedError,"GPUI build interrupted")
    sleep(10)
  if process.code!=0:fail("GPUI bridge build failed\n" & process.output.diagnosticText())
  let target=absolutePath(getEnv("CARGO_TARGET_DIR",root/"target"),root)
  result=target/(if release:"release" else:"debug")/GpuiLibraryName
  if not fileExists(result):fail("Cargo did not produce the GPUI bridge: " & result)
proc stageGpui*(library,binary:string) =
  let destination=binary.parentDir/GpuiLibraryName
  createDir(binary.parentDir)
  if absolutePath(library)!=absolutePath(destination):copyFile(library,destination)
