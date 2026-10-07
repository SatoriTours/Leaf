import std/[unittest, os, strutils, json, xmlparser, xmltree, tempfiles]
import leaf/windows_manifest
import ./cleanup_support
when defined(windows):
  import std/winlean
  import leaf/[build, project, process_io]
  proc freeLibrary(module: Handle): int32 {.stdcall, importc: "FreeLibrary", dynlib: "kernel32".}
  proc loadData(path: WideCString, file: Handle, flags: uint32): Handle {.stdcall, importc: "LoadLibraryExW", dynlib: "kernel32".}
  proc findManifest(module: Handle, name, kind: pointer): Handle {.stdcall, importc: "FindResourceW", dynlib: "kernel32".}
  proc loadResource(module, resource: Handle): Handle {.stdcall, importc: "LoadResource", dynlib: "kernel32".}
  proc lockResource(resource: Handle): pointer {.stdcall, importc: "LockResource", dynlib: "kernel32".}
  proc resourceSize(module, resource: Handle): uint32 {.stdcall, importc: "SizeofResource", dynlib: "kernel32".}
let base = createTempDir("leaf manifest 中文 $ ", "")
removeDirectoryOnExit(base)
let sources = base / "moved SDK" / "src"
createDir(sources / "leaf" / "resources" / "windows")
let templatePath = "src/leaf/resources/windows/leaf_app.manifest"

proc verifyManifest(xml: string) =
  let root = parseXml(xml)
  check root.tag == "assembly"
  check root.attr("xmlns") == "urn:schemas-microsoft-com:asm.v1"
  check root.attr("manifestVersion") == "1.0"
  let app = root.child("application")
  check app != nil
  if app != nil:
    check app.attr("xmlns") == "urn:schemas-microsoft-com:asm.v3"
    let settings = app.child("windowsSettings")
    check settings.child("dpiAware").attr("xmlns") == "http://schemas.microsoft.com/SMI/2005/WindowsSettings"
    check settings.child("dpiAware").innerText == "true/pm"
    check settings.child("dpiAwareness").attr("xmlns") == "http://schemas.microsoft.com/SMI/2016/WindowsSettings"
    check settings.child("dpiAwareness").innerText == "PerMonitorV2"
  check root.child("trustInfo") == nil
  check root.child("dependency").child("dependentAssembly").child("assemblyIdentity").attr("name") == "Microsoft.Windows.Common-Controls"

suite "Main EXE DPI resource":
  test "resource compiler follows actual Nim GCC and rejects incompatible toolchains":
    let script=base/"selected.json"
    createDir(base/"selected compiler $ space")
    let gcc=base/"selected compiler $ space"/"gcc.exe"
    writeFile(gcc, "fixture compiler")
    writeFile(script, $(%*{"compile":[["main.c",quoteShell(gcc) & " -c main.c"]],
      "linkcmd":quoteShell(gcc) & " -o app main.o"}))
    check gccFromBuildScript(script)==absolutePath(gcc)
    writeFile(script, $(%*{"compile":[["main.c","clang -c main.c"]],"linkcmd":"clang -o app main.o"}))
    expect CatchableError:discard gccFromBuildScript(script)
    writeFile(script, $(%*{"compile":[["main.c",quoteShell(gcc) & " -c main.c"]],"linkcmd":"cl.exe /Fe:app main.obj"}))
    expect CatchableError:discard gccFromBuildScript(script)

  test "manifest declares PMv2 in correct namespaces":
    verifyManifest(readFile(templatePath))
  when not defined(windows):
    test "resource tool uses argv and relocated sources and refuses stale objects":
      copyFile(templatePath, sources / "leaf/resources/windows/leaf_app.manifest")
      let tools = base / "tools space $"
      createDir(tools)
      let gcc = tools / "gcc"
      writeFile(gcc, "#!/bin/sh\nexit 0\n")
      setFilePermissions(gcc, {fpUserRead, fpUserWrite, fpUserExec})
      let windres = tools / "windres"
      writeFile(windres, "#!/bin/sh\nprintf 'original tool diagnostic'\nexit 7\n")
      setFilePermissions(windres, {fpUserRead, fpUserWrite, fpUserExec})
      let cache = base / "output cache 中文 $"
      createDir(cache)
      writeFile(cache / "leaf_app_manifest.o", "stale")
      try:
        discard compileWindowsManifest(sources, cache, gcc)
        check false
      except CatchableError as e:
        check e.msg.contains("original tool diagnostic")
        check e.msg.contains("7")
      check not fileExists(cache / "leaf_app_manifest.o")
      writeFile(windres, "#!/bin/sh\nexit 0\n")
      expect CatchableError:
        discard compileWindowsManifest(sources, cache, gcc)
      # Validate actual argv/working directory, not a shell-joined command.
      writeFile(windres, "#!/bin/sh\n[ \"$1\" = '-J' ] && [ \"$2\" = 'rc' ] && [ \"$3\" = '-O' ] && [ \"$4\" = 'coff' ] || exit 9\n[ -f leaf_app.manifest ] || exit 10\nfor last do :; done\nprintf 'fresh object' > \"$last\"\n")
      let obj = compileWindowsManifest(sources, cache, gcc)
      check isAbsolute(obj)
      check readFile(obj) == "fresh object"
      check readFile(cache / "leaf_app.rc") == "1 24 \"leaf_app.manifest\"\n"
    test "missing resource compiler fails explicitly":
      expect CatchableError:
        discard compileWindowsManifest(sources, base / "missing", base / "absent-gcc")

  when defined(windows):
    test "actual built PE resource survives moved sources and complex paths":
      copyFile(templatePath, sources / "leaf/resources/windows/leaf_app.manifest")
      writeFile(sources / "leaf.nim", "# relocated SDK source marker\n")
      let old = getEnv("LEAF_LIBRARY")
      putEnv("LEAF_LIBRARY", sources)
      defer:
        if old.len == 0: delEnv("LEAF_LIBRARY")
        else: putEnv("LEAF_LIBRARY", old)
      createDir(base / "产物 $ space")
      let source = base / "main.nim"
      # Minimal EXE compiled through the CLI's shared startBuild.
      writeFile(source, """import std/dynlib
proc main() =
  type GetContext=proc():pointer {.stdcall.}
  type EqualContexts=proc(a,b:pointer):int32 {.stdcall.}
  let lib=loadLib("user32.dll")
  doAssert lib != nil
  defer:unloadLib(lib)
  let current=cast[GetContext](lib.symAddr("GetThreadDpiAwarenessContext"))
  let equal=cast[EqualContexts](lib.symAddr("AreDpiAwarenessContextsEqual"))
  doAssert current != nil and equal != nil
  doAssert equal(current(),cast[pointer](-4)) != 0
  echo "manifest_per_monitor_v2"
main()
""")
      let job = startBuild(readProject(source), output=base / "产物 $ space" / "probe",
        cacheDirectory=base / "cache 中文 $ space", isolatedConfig=true)
      defer: job.close()
      while not job.pollBuild(): sleep(10)
      checkpoint job.output
      check job.code == 0
      check fileExists(job.binary)
      let child=startManaged(job.binary,@[],base)
      defer:child.close()
      while not child.poll():sleep(10)
      checkpoint child.output
      check child.code==0
      check child.output.strip()=="manifest_per_monitor_v2"
      let module = loadData(newWideCString(job.binary), 0, 0x22)
      check module != 0
      if module != 0:
        defer: discard freeLibrary(module)
        let resource = findManifest(module, cast[pointer](1), cast[pointer](24))
        check resource != 0
        let loaded = loadResource(module, resource)
        let data = lockResource(loaded)
        let length = int(resourceSize(module, resource))
        check data != nil and length > 0
        if data != nil and length > 0:
          var xml = newString(length)
          copyMem(addr xml[0], data, length)
          verifyManifest(xml)
