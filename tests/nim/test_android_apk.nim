import std/[unittest, strutils]
import leaf/[android_apk, project, core]
let p=Project(identifier:"dev.example.app",version:"1.2.3",
  android:AndroidProjectConfig(enabled:true,minSdk:26,targetSdk:36,versionCode:42,abis: @["x86_64"]))
const Badging="package: name='dev.example.app' versionCode='42' versionName='1.2.3'\nsdkVersion:'26'\ntargetSdkVersion:'36'\nlaunchable-activity: name='dev.example.app.MainActivity' label='' icon=''\nnative-code: 'x86_64'\n"
const Elf="Class: ELF64\nType: DYN (Shared object file)\nMachine: Advanced Micro Devices X86-64\n LOAD 0 0 0 0 0 R 0x4000\n NEEDED Shared library: [libandroid.so]\n"
suite "Android artifact identity":
  test "manifest and selected ABI identities match project configuration":
    validateAndroidBadging(p,Badging)
    # Build Tools 36 emits minSdkVersion; older aapt output used sdkVersion.
    validateAndroidBadging(p,Badging.replace("sdkVersion:","minSdkVersion:"))
    for pair in [("dev.example.app'","other.example.app'"),("versionCode='42'","versionCode='43'"),
        ("versionName='1.2.3'","versionName='1.2.4'"),("sdkVersion:'26'","sdkVersion:'25'"),
        ("targetSdkVersion:'36'","targetSdkVersion:'35'"),(".MainActivity'",".OtherActivity'"),
        ("native-code: 'x86_64'","native-code: 'arm64-v8a'"),
        ("native-code: 'x86_64'","native-code: 'x86_64' 'arm64-v8a'")]:
      expect UiError: validateAndroidBadging(p,Badging.replace(pair[0],pair[1]))
    expect UiError: validateAndroidBadging(p,"not an APK")

  test "ELF validation rejects wrong architecture alignment and desktop engines":
    validateAndroidElf("x86_64",Elf)
    validateAndroidElf("arm64-v8a",Elf.replace("Advanced Micro Devices X86-64","AArch64"))
    for text in [Elf.replace("ELF64","ELF32"),Elf.replace("DYN","EXEC"),
        Elf.replace("0x4000","0x1000"),Elf.replace("LOAD","NONE"),
        Elf.replace("X86-64","ARM"),Elf & " NEEDED Shared library: [libsqlite3.so]\n",
        Elf & " NEEDED Shared library: [libleaf_gpui.so]\n",Elf & " GLOBAL DEFAULT sqlite3_open\n"]:
      expect UiError: validateAndroidElf("x86_64",text)
