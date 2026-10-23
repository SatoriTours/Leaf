## Source projects build through finite NDK, Gradle and artifact inspection stages.
import std/[os, strutils, tempfiles, json, sequtils]
import ./[core, project, package_files, licenses, orm_config, android_tools, android_job, android_apk]

proc xml(value:string):string =
  value.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace("\"","&quot;").replace("'","&apos;")

proc androidInputs*(project:Project):seq[AndroidAssetInput] =
  for file in collectFiles(project):
    if not file.directory and file.relative.startsWith("assets/"):
      if file.relative=="assets/leaf/licenses" or file.relative.startsWith("assets/leaf/licenses/"):
        fail("assets/leaf/licenses is reserved for Android package notices")
      result.add((file.relative,file.source))

proc androidNotices*(project:Project,directory:string):seq[AndroidAssetInput] =
  let noticeRoot=directory / "assets/leaf/licenses"
  collectLicenses(noticeRoot)
  for relative in implicitLicensePaths(project):
    copyLicenseTree(project,relative,noticeRoot / "application" / relative)
  for file in walkDirRec(noticeRoot):
    result.add(("assets/leaf/licenses/" & relativePath(file,noticeRoot).replace('\\','/'),file))

proc startAndroidBuild*(project:Project,sources,compiler:string,output=""):AndroidJob =
  if not project.android.enabled:fail("leaf.json requires platforms.android.entry")
  let tools=discoverAndroidTools(project.android.targetSdk)
  let limits=parseFile(tools.ndk / "meta/platforms.json")
  if project.android.minSdk<limits["min"].getInt or project.android.minSdk>limits["max"].getInt:
    fail("selected NDK does not provide the configured Android minSdk")
  let runtime=sources.parentDir / "native/android/src/main"
  let headers=sources.parentDir / "include"
  for path in [runtime / "c/leaf_jni.c",runtime / "c/leaf_android_jni.c",headers / "leaf_android.h"]:
    if not fileExists(path):fail("Android runtime source missing from Leaf SDK: " & path)
  let files=collectFiles(project)
  let assets=androidInputs(project)
  let base=project.root / "target/android"
  validateOutput(project,base)
  let binary=absolutePath(if output.len==0:base / (project.slug & ".apk") else:output)
  if not binary.endsWith(".apk"):fail("Android output must end in .apk")
  validateOutput(project,binary.parentDir)
  if symlinkExists(binary) or dirExists(binary):fail("Android output is not a regular file")
  createDir(base)
  let directory=createTempDir(".build-","",base)
  let app=directory / "application"
  copyFiles(project,files,app)
  let entry=app / project.android.entryRelative
  let main=directory / "src/main"
  createDir(main / "java")
  copyDir(runtime / "java",main / "java")
  for item in assets:copyRegular(item.source,main / item.name)
  var requiredAssets:seq[AndroidAssetInput]
  for item in assets:requiredAssets.add((item.name,main / item.name))
  requiredAssets.add(androidNotices(project,main))
  let activity=main / "java" / project.identifier.replace('.',DirSep) / "MainActivity.kt"
  createDir(activity.parentDir)
  writeFile(activity,"package " & project.identifier & "\nimport dev.leaf.runtime.LeafActivity\nclass MainActivity: LeafActivity() { override val leafLibrary = \"leaf_android\" }\n")
  writeFile(main / "AndroidManifest.xml","<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"><application android:enableOnBackInvokedCallback=\"true\" android:label=\"@string/app_name\" android:theme=\"@android:style/Theme.Material.Light.NoActionBar\"><activity android:name=\"" & project.identifier & ".MainActivity\" android:exported=\"true\" android:windowSoftInputMode=\"adjustNothing\"><intent-filter><action android:name=\"android.intent.action.MAIN\"/><category android:name=\"android.intent.category.LAUNCHER\"/></intent-filter></activity></application></manifest>\n")
  createDir(main / "res/values")
  writeFile(main / "res/values/strings.xml","<resources><string name=\"app_name\" translatable=\"false\">\"" & xml(project.name).replace("&apos;","\\'") & "\"</string></resources>\n")
  writeFile(directory / "settings.gradle","pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }\ndependencyResolutionManagement { repositories { google(); mavenCentral() } }\nrootProject.name = 'leaf-android-application'\n")
  writeFile(directory / "local.properties","sdk.dir=" & tools.sdk.replace("\\","\\\\").replace("\n","\\n").replace("\r","\\r") & "\n")
  writeFile(directory / "build.gradle","""buildscript {
  repositories { google(); mavenCentral() }
  dependencies {
    classpath 'com.android.tools.build:gradle:9.0.1'
    classpath 'org.jetbrains.kotlin:kotlin-gradle-plugin:2.3.20'
  }
}
apply plugin: 'com.android.application'
android {
  namespace '""" & project.identifier & "'\n  compileSdk " & $project.android.targetSdk & "\n  buildToolsVersion '36.0.0'\n  defaultConfig {\n    applicationId '" & project.identifier & "'\n    minSdk " & $project.android.minSdk & "\n    targetSdk " & $project.android.targetSdk & "\n    versionCode " & $project.android.versionCode & "\n    versionName '" & project.version & "'\n  }\n  sourceSets.main {\n    kotlin.directories.add('src/main/java')\n    jniLibs.directories.add('src/main/jniLibs')\n  }\n}\ndependencies { implementation 'androidx.recyclerview:recyclerview:1.4.0' }\n")
  var steps:seq[AndroidStep]
  for abi in project.android.abis:
    let triple=if abi=="x86_64":"x86_64-linux-android" else:"aarch64-linux-android"
    let target=triple & $project.android.minSdk
    let lib=main / "jniLibs" / abi / "libleaf_android.so"
    createDir(lib.parentDir)
    proc nimPath(path:string):string=path.replace("$","$$")
    var args= @["c","--cc:clang","--os:android","--cpu:" & (if abi=="x86_64":"amd64" else:"arm64"),
      "--app:lib","--noMain:on","--threads:on","--mm:orc","--deepcopy:on","-d:release",
      "--skipParentCfg:on","--skipProjCfg:on","--skipUserCfg:on","--path:" & nimPath(sources),
      "--path:" & nimPath(app / "src"),"--clang.exe:" & nimPath(tools.clang),"--clang.linkerexe:" & nimPath(tools.clang),
      "--passC:--target=" & target,"--passL:--target=" & target,
      "--passC:-I" & quoteShell(headers),"--passC:-I" & quoteShell(runtime / "c"),
      "--passL:-Wl,-z,max-page-size=16384","--nimcache:" & nimPath(directory / "cache" / abi),
      "--out:" & nimPath(lib)]
    for flag in ormCompilerArgs(sources,"android"):args.add(nimPath(flag))
    for file in ["leaf_jni.c","leaf_android_jni.c"]:args.add("--compile:" & nimPath(runtime / "c" / file))
    args.add(nimPath(entry))
    steps.add(AndroidStep(executable:compiler,arguments:args,workingDirectory:app,timeoutMilliseconds:120_000))
  steps.add(AndroidStep(executable:tools.java,arguments: @["-jar",tools.gradleJar,"--offline","--no-daemon","--max-workers=2","-Dorg.gradle.jvmargs=-Xmx1024m","assembleDebug"],workingDirectory:directory,timeoutMilliseconds:180_000))
  let apk=directory / "build/outputs/apk/debug/leaf-android-application-debug.apk"
  steps.add(androidVerificationSteps(project,tools,apk,directory,requiredAssets))
  let inspected=steps[^1].accept
  steps[^1].accept=proc(log:string)=
    if inspected!=nil:inspected(log)
    if symlinkExists(binary) or dirExists(binary):fail("Android output changed to a non-regular path")
    createDir(binary.parentDir)
    let temporary=createTempFile(".leaf-android-",".apk",binary.parentDir)
    temporary.cfile.close()
    defer:
      if fileExists(temporary.path):removeFile(temporary.path)
    copyRegular(apk,temporary.path)
    moveFile(temporary.path,binary)
  result=startAndroidSteps(steps,binary,directory)
