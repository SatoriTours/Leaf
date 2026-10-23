## Inspect APK metadata and native libraries using the installed Android/JDK tools.
import std/[os, strutils, algorithm, sequtils]
import ./[core, project, checksum, android_tools, android_job]

type AndroidAssetInput* = tuple[name,source:string]

proc quotedField(line,key:string):string =
  let mark=key & "='"
  let first=line.find(mark)
  if first<0:fail("APK metadata missing " & key)
  let start=first+mark.len
  let finish=line.find('\'',start)
  if finish<0:fail("APK metadata has unterminated " & key)
  line[start..<finish]

proc validateAndroidBadging*(project:Project,output:string) =
  var packageLine,activity,minSdk,targetSdk,native:string
  for line in output.splitLines():
    if line.startsWith("package: "):packageLine=line
    elif line.startsWith("launchable-activity: "):activity=line
    elif line.startsWith("sdkVersion:'"):minSdk=line
    elif line.startsWith("minSdkVersion:'"):minSdk=line.replace("minSdkVersion:","sdkVersion:")
    elif line.startsWith("targetSdkVersion:'"):targetSdk=line
    elif line.startsWith("native-code: "):native=line[13..^1]
  if quotedField(packageLine,"name")!=project.identifier or
      quotedField(packageLine,"versionCode")!= $project.android.versionCode or
      quotedField(packageLine,"versionName")!=project.version:
    fail("APK package or version differs from leaf.json")
  if minSdk!="sdkVersion:'" & $project.android.minSdk & "'" or
      targetSdk!="targetSdkVersion:'" & $project.android.targetSdk & "'":
    fail("APK SDK levels differ from leaf.json")
  if quotedField(activity,"name")!=project.identifier & ".MainActivity":
    fail("APK launcher differs from the Leaf activity")
  var actual=native.splitWhitespace().mapIt(it.strip(chars={'\''}))
  var expected=project.android.abis
  actual.sort();expected.sort()
  if actual!=expected:fail("APK native ABIs differ from leaf.json")

proc validateAndroidElf*(abi,output:string) =
  let machine=if abi=="arm64-v8a":"AArch64" elif abi=="x86_64":"Advanced Micro Devices X86-64" else: "invalid ABI"
  var classOk,typeOk,machineOk=false
  var loads=0
  for line in output.splitLines():
    let clean=line.strip()
    if clean.startsWith("Class:") and "ELF64" in clean:classOk=true
    if clean.startsWith("Type:") and "DYN" in clean:typeOk=true
    if clean.startsWith("Machine:") and clean.endsWith(machine):machineOk=true
    if clean.startsWith("LOAD "):
      inc loads
      let value=clean.splitWhitespace()[^1]
      try:
        let alignment=parseHexInt(value)
        if alignment<0x4000 or alignment mod 0x4000!=0:fail("Android library LOAD alignment is below 16KiB")
      except ValueError:fail("invalid Android library LOAD alignment")
    if "sqlite3_" in clean or "libsqlite" in clean.toLowerAscii() or "gpui" in clean.toLowerAscii():
      fail("Android library exposes an external SQLite or desktop engine")
  if not classOk or not typeOk or not machineOk or loads==0:
    fail("APK does not contain the selected Android shared library architecture")

proc elfStep(tools:AndroidTools,library,abi,directory:string):AndroidStep =
  result=AndroidStep(executable:tools.readelf,arguments: @["--wide","-h","-l","-d","--dyn-syms",library],
    workingDirectory:directory,timeoutMilliseconds:10_000)
  result.accept=proc(output:string)=validateAndroidElf(abi,output)

proc androidVerificationSteps*(project:Project,tools:AndroidTools,apk,directory:string,
    assets:seq[AndroidAssetInput]):seq[AndroidStep] =
  let metadata=AndroidStep(executable:tools.aapt2,arguments: @["dump","badging",apk],
    workingDirectory:directory,timeoutMilliseconds:30_000,
    accept:proc(output:string)=validateAndroidBadging(project,output))
  result.add(metadata)
  let extracted=directory / "apk-inspection"
  createDir(extracted)
  var entries:seq[string]
  for abi in project.android.abis:entries.add("lib/" & abi & "/libleaf_android.so")
  for asset in assets:
    discard portableRelative(asset.name)
    entries.add(asset.name)
  var extract=AndroidStep(executable:tools.jar,arguments: @["-xf",apk] & entries,
    workingDirectory:extracted,timeoutMilliseconds:30_000)
  extract.accept=proc(output:string)=
    for asset in assets:
      let path=extracted / asset.name
      if not fileExists(path) or getFileSize(path)!=getFileSize(asset.source) or
          sha256File(path)!=sha256File(asset.source):
        fail("APK asset/license differs from build inputs: " & asset.name)
  result.add(extract)
  for abi in project.android.abis:
    result.add(elfStep(tools,extracted / "lib" / abi / "libleaf_android.so",abi,extracted))
