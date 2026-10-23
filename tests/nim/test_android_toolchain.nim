import std/[unittest, os, tempfiles, strutils]
import leaf/[android_tools, core]

proc file(path:string) =
  createDir(path.parentDir)
  writeFile(path,"fixture")

suite "Android toolchain preflight":
  test "explicit roots resolve only required Android tools":
    let root=createTempDir("leaf-android-tools-","")
    defer: removeDir(root)
    let sdk=root / "Android SDK"
    let ndk=sdk / "ndk/28.2.13676358"
    let jdk=root / "jdk"
    let gradle=root / "gradle"
    let host=androidNdkHost()
    for path in [sdk / "platforms/android-36/android.jar",sdk / "build-tools/36.0.0/aapt2".addFileExt(ExeExt),
        sdk / "platform-tools/adb".addFileExt(ExeExt),ndk / "toolchains/llvm/prebuilt" / host / "bin/clang".addFileExt(ExeExt),
        ndk / "toolchains/llvm/prebuilt" / host / "bin/llvm-readelf".addFileExt(ExeExt),
        jdk / "bin/java".addFileExt(ExeExt),jdk / "bin/jar".addFileExt(ExeExt),
        gradle / "lib/gradle-gradle-cli-main-9.1.0.jar"]:file(path)
    let tools=inspectAndroidTools(sdk,ndk,jdk,gradle,36)
    check tools.sdk == sdk
    check tools.clang.endsWith("clang".addFileExt(ExeExt))
    check tools.gradleJar.endsWith("gradle-gradle-cli-main-9.1.0.jar")
    check tools.java.startsWith(jdk)
    expect UiError: discard inspectAndroidTools(sdk,ndk,jdk,gradle,37)
    removeFile(jdk / "bin/jar".addFileExt(ExeExt))
    expect UiError: discard inspectAndroidTools(sdk,ndk,jdk,gradle,36)

  test "SDK environment aliases agree canonically and missing roots fail early":
    let root=createTempDir("leaf-android-sdk-","")
    defer: removeDir(root)
    check resolveAndroidSdk(root,root) == expandFilename(root)
    expect UiError: discard resolveAndroidSdk(root,root / "different")
    expect UiError: discard resolveAndroidSdk(root / "missing","")
