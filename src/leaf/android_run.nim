## Installing an APK preserves app data; device selection never picks the first of many.
import std/[os, strutils]
import ./[core, project, android_tools]

proc selectAndroidDevice*(output,requested:string):string =
  var ready:seq[string]
  for line in output.splitLines():
    let parts=line.splitWhitespace()
    if parts.len>=2 and parts[1]=="device":ready.add(parts[0])
  if requested.len>0:
    if requested notin ready:fail("requested Android device is not ready: " & requested)
    return requested
  if ready.len!=1:fail("run requires --device SERIAL unless exactly one Android device is ready")
  ready[0]

proc runAndroid*(project:Project,apk,requested:string):int =
  let tools=discoverAndroidTools(project.android.targetSdk)
  if not fileExists(tools.adb):fail("Android platform-tools/adb is missing")
  let list=androidToolOutput(tools.adb,@["devices","-l"],project.root,30)
  let device=selectAndroidDevice(list,requested)
  let installed=androidToolOutput(tools.adb,@["-s",device,"install","-r",apk],project.root,120)
  if "Success" notin installed:fail("adb did not confirm APK installation: " & installed)
  let launched=androidToolOutput(tools.adb,@["-s",device,"shell","am","start","-W","-n",
    project.identifier & "/" & project.identifier & ".MainActivity"],project.root,30)
  if "Status: ok" notin launched or "Error:" in launched or "Exception" in launched:
    fail("Android activity did not start: " & launched)
  stdout.writeLine("Started " & project.identifier & " on " & device)
  0
