## Real X11 input and mouse dispatch into a Nim application using GPUI Kit.
import std/[os,json,monotimes,times,strtabs,tempfiles,strutils]
import leaf/[build,project,process_io,watch_ipc]
proc require(value:bool,message:string) =
  if not value:raise newException(IOError,message)
proc command(exe:string,args:seq[string],root:string):string =
  let process=startManaged(exe,args,root)
  defer:process.close()
  let deadline=getMonoTime()+initDuration(seconds=10)
  while not process.poll():
    if getMonoTime()>deadline:raise newException(IOError,"test command timeout")
    sleep(10)
  require(process.code==0,process.output)
  process.output.strip()
proc main():int =
  when not defined(linux):
    stderr.writeLine("Real desktop smoke currently uses X11; run cargo test for portable GPUI controls")
    return 1
  let root=currentSourcePath().parentDir.parentDir.parentDir
  let directory=createTempDir("leaf-gpui-native-","")
  defer:
    if getEnv("LEAF_KEEP_NATIVE_TEST")!="1":removeDir(directory)
    else:echo "Native evidence: ",directory
  let xdotool=getEnv("LEAF_TEST_XDOTOOL",findExe("xdotool"))
  require(xdotool.len>0,"xdotool is required")
  let binary=build(readProject(root/getEnv("LEAF_TEST_APP","tests/nim/gpui_native_app.nim")),directory/"native-app")
  var env=newStringTable(modeCaseSensitive)
  for key,value in envPairs():env[key]=value
  env["LEAF_TEST_GEOMETRY"]=directory/"geometry.json"
  env["LEAF_WATCH_READY"]=directory/"ready.json"
  env["LEAF_WATCH_TOKEN"]="native-smoke"
  block:
    env["LEAF_TEST_FAIL_LIST"]="1"
    let failedLog=directory/"failed-events.jsonl"
    let failed=startManaged(binary,@["--log-file",failedLog],root,env)
    defer:failed.close()
    let deadline=getMonoTime()+initDuration(seconds=20)
    while not failed.poll():
      require(not fileExists(directory/"ready.json"),"failed viewport published readiness")
      require(getMonoTime()<deadline,"failed initial viewport did not stop watch candidate")
      sleep(20)
    require(not fileExists(directory/"ready.json"),"failed viewport published readiness")
    require(fileExists(failedLog) and "initial row failed" in readFile(failedLog),
      "failed candidate did not exercise Nim list callback: " & failed.output)
    env.del("LEAF_TEST_FAIL_LIST")
  let dump=directory/"tree.json"
  let child=startManaged(binary,@["--dump-tree",dump,"--log-file",directory/"events.jsonl"],root,env)
  defer:child.close()
  let deadline=getMonoTime()+initDuration(seconds=20)
  while not isReady(directory/"ready.json","native-smoke",child.pid):
    require(not child.poll(),"GPUI window exited before readiness: " & child.output)
    require(getMonoTime()<deadline,"GPUI window readiness timeout")
    sleep(20)
  let window=command(xdotool,@["search","--name","^Leaf GPUI native smoke$"],root).splitLines()[0]
  discard command(xdotool,@["windowfocus",window],root)
  proc clickTarget(key:string) =
    let deadline=getMonoTime()+initDuration(seconds=5)
    while true:
      if fileExists(directory/"geometry.json"):
        let nodes=parseFile(directory/"geometry.json")["nodes"]
        for id,bounds in nodes:
          if id==key or id.endsWith(":" & key) or id.endsWith(":" & key & "/r"):
            let x=int(bounds["x"].getFloat+bounds["width"].getFloat/2)
            let y=int(bounds["y"].getFloat+bounds["height"].getFloat/2)
            echo "Click ",key," at ",x,",",y
            discard command(xdotool,@["mousemove","--window",window,$x,$y,"click","1"],root)
            return
      require(getMonoTime()<deadline,"geometry target not found: " & key)
      sleep(20)
  clickTarget("add")
  proc status():string =
    try:return parseFile(dump)["root"]["children"][2]["text"].getStr
    except CatchableError:return ""
  proc awaitStatus(expected:string) =
    let deadline=getMonoTime()+initDuration(seconds=5)
    while status()!=expected:
      require(getMonoTime()<deadline,"expected " & expected & "; got " & status())
      require(not child.poll(),"GPUI test application exited")
      sleep(20)
  awaitStatus("1:中文输入:0")
  clickTarget("entry")
  discard command(xdotool,@["key","ctrl+a"],root)
  discard command(xdotool,@["type","--clearmodifiers","--delay","1","nim gpui"],root)
  awaitStatus("1:nim gpui:0")
  discard command(xdotool,@["key","Return"],root)
  awaitStatus("1:nim gpui:1")
  # A rejected update restores the accepted input; reset replaces its buffer.
  clickTarget("reject")
  sleep(100)
  awaitStatus("1:nim gpui:1")
  clickTarget("reset")
  awaitStatus("1:中文输入:1")
  # Select only the final character. This catches selection loss on model sync.
  clickTarget("entry")
  discard command(xdotool,@["key","End","shift+Left"],root)
  discard command(xdotool,@["type","--clearmodifiers","X"],root)
  awaitStatus("1:中文输X:1")
  discard command(xdotool,@["windowsize",window,"800","600"],root)
  discard command(xdotool,@["windowunmap",window],root)
  discard command(xdotool,@["windowmap",window,"windowfocus",window],root)
  clickTarget("add")
  awaitStatus("2:中文输X:1")
  discard command(xdotool,@["key","ctrl+q"],root)
  let closing=getMonoTime()+initDuration(seconds=5)
  while not child.poll():
    require(getMonoTime()<closing,"GPUI close timeout")
    sleep(20)
  require(child.code==0,"GPUI close failed: " & child.output)
  echo "Passed real Nim + GPUI + GPUI Kit window, click, input, Enter, ready, failed viewport and close"
when isMainModule:
  try:quit(main())
  except CatchableError as error:stderr.writeLine(error.msg);quit(1)
