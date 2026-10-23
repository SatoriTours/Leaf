## Android tool discovery uses installed tools; it never downloads or accepts licenses.
import std/[os, strutils, algorithm, json, monotimes, times]
import ./[core, process_io]

type AndroidTools* = object
  sdk*, ndk*, java*, jar*, gradleJar*, clang*, readelf*, aapt2*, adb*: string

proc androidNdkHost*(): string =
  when defined(linux) and defined(amd64): "linux-x86_64"
  elif defined(macosx): "darwin-x86_64"
  elif defined(windows) and defined(amd64): "windows-x86_64"
  else: fail("no Android NDK host configured for this platform")

proc resolveAndroidSdk*(home, legacy: string): string =
  let selected=if home.len>0:home else:legacy
  if selected.len==0 or not dirExists(selected): fail("Android SDK missing; set ANDROID_HOME")
  result=expandFilename(selected)
  if home.len>0 and legacy.len>0 and
      (not dirExists(legacy) or expandFilename(legacy)!=result):
    fail("ANDROID_HOME and ANDROID_SDK_ROOT disagree")

proc required(path, description:string):string =
  if not fileExists(path): fail("missing Android " & description & ": " & path)
  absolutePath(path)

proc inspectAndroidTools*(sdk, ndk, jdk, gradle:string, targetSdk:int):AndroidTools =
  result.sdk=resolveAndroidSdk(sdk,"")
  if not dirExists(ndk):fail("Android NDK missing; set ANDROID_NDK_HOME")
  result.ndk=expandFilename(ndk)
  let bin=result.ndk / "toolchains/llvm/prebuilt" / androidNdkHost() / "bin"
  result.clang=required(bin / "clang".addFileExt(ExeExt),"NDK clang")
  result.readelf=required(bin / "llvm-readelf".addFileExt(ExeExt),"NDK readelf")
  discard required(result.sdk / "platforms" / ("android-" & $targetSdk) / "android.jar","platform")
  result.aapt2=required(result.sdk / "build-tools/36.0.0/aapt2".addFileExt(ExeExt),"Build Tools 36.0.0")
  # adb is required by run, not by build or pack.
  result.adb=result.sdk / "platform-tools/adb".addFileExt(ExeExt)
  result.java=required(jdk / "bin/java".addFileExt(ExeExt),"JDK java")
  result.jar=required(jdk / "bin/jar".addFileExt(ExeExt),"JDK jar")
  result.gradleJar=required(gradle / "lib/gradle-gradle-cli-main-9.1.0.jar","Gradle 9.1.0")

proc latestNdk(sdk:string):string =
  var versions:seq[(tuple[major,minor,patch:int],string)]
  if dirExists(sdk / "ndk"):
    for kind,path in walkDir(sdk / "ndk"):
      if kind!=pcDir:continue
      let parts=path.extractFilename.split('.')
      if parts.len!=3:continue
      try: versions.add(((parseInt(parts[0]),parseInt(parts[1]),parseInt(parts[2])),path))
      except ValueError:discard
  versions.sort(proc(a,b:(tuple[major,minor,patch:int],string)):int=cmp(a[0],b[0]))
  if versions.len==0:fail("Android NDK missing; set ANDROID_NDK_HOME")
  versions[^1][1]

proc discoverAndroidTools*(targetSdk=36):AndroidTools =
  let sdk=resolveAndroidSdk(getEnv("ANDROID_HOME"),getEnv("ANDROID_SDK_ROOT"))
  var ndk=getEnv("ANDROID_NDK_HOME")
  if ndk.len==0:ndk=latestNdk(sdk)
  var jdk=getEnv("JAVA_HOME")
  if jdk.len==0:
    let java=findExe("java")
    if java.len>0:jdk=expandFilename(java).parentDir.parentDir
  var gradle=getEnv("GRADLE_HOME")
  if gradle.len==0:
    let command=findExe("gradle")
    if command.len>0:gradle=expandFilename(command).parentDir.parentDir
  if gradle.len==0:
    let cache=getHomeDir() / ".gradle/wrapper/dists/gradle-9.1.0-bin"
    var installations:seq[string]
    if dirExists(cache):
      for kind,path in walkDir(cache):
        if kind==pcDir and fileExists(path / "gradle-9.1.0/lib/gradle-gradle-cli-main-9.1.0.jar"):
          installations.add(path / "gradle-9.1.0")
    installations.sort()
    if installations.len>0:gradle=installations[0]
  inspectAndroidTools(sdk,ndk,jdk,gradle,targetSdk)

proc androidToolOutput*(exe:string,args:seq[string],cwd:string,seconds=10):string =
  let child=startManaged(exe,args,cwd)
  defer:child.close()
  let deadline=getMonoTime()+initDuration(seconds=seconds)
  while not child.poll():
    if wasInterrupted():raise newException(ProcessInterruptedError,"Android command interrupted")
    if getMonoTime()>deadline:fail("Android command timed out: " & exe)
    sleep(10)
  if child.code!=0:fail("Android command failed (exit " & $child.code & "): " & exe & "\n" & child.output.diagnosticText())
  child.output.diagnosticText()

proc androidDoctorReport*(targetSdk=36):JsonNode =
  result= %*{"implementation":"nim","target":"android","backend":"native","host_available":false}
  try:
    let tools=discoverAndroidTools(targetSdk)
    result["sdk"]= %tools.sdk;result["ndk"]= %tools.ndk
    result["java"]= %tools.java;result["gradleJar"]= %tools.gradleJar
    result["java_version"]= %androidToolOutput(tools.java,@["-version"],getCurrentDir())
    result["gradle_version"]= %androidToolOutput(tools.java,@["-jar",tools.gradleJar,"--version","--offline","--no-daemon"],getCurrentDir(),30)
    result["clang_version"]= %androidToolOutput(tools.clang,@["--version"],getCurrentDir())
    result["host_available"]= %true
  except ProcessInterruptedError:raise
  except CatchableError as error:result["host_error"]= %error.msg
