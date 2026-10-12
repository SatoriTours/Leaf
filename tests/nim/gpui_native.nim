## Real X11 input and mouse dispatch into a Nim application using GPUI Kit.
import std/[os,json,monotimes,times,strtabs,tempfiles,strutils,algorithm]
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
  require(process.code==0,exe & " " & args.join(" ") & " failed (" & $process.code & "): " & process.output)
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
  let lists=getEnv("LEAF_TEST_LISTS")=="1"
  let watch=getEnv("LEAF_TEST_WATCH_STATUS")=="1"
  if watch:
    env["LEAF_WATCH_STATUS"]=directory/"status.json"
    writeStatus(env["LEAF_WATCH_STATUS"],0,"")
  let example=getEnv("LEAF_TEST_EXAMPLE")=="1"
  if not example and getEnv("LEAF_TEST_SKIP_FAIL")!="1":
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
  defer:
    discard child.poll()
    if getEnv("LEAF_KEEP_NATIVE_TEST")=="1":echo child.output
    child.close()
  let deadline=getMonoTime()+initDuration(seconds=20)
  while not isReady(directory/"ready.json","native-smoke",child.pid):
    require(not child.poll(),"GPUI window exited before readiness: " & child.output)
    require(getMonoTime()<deadline,"GPUI window readiness timeout")
    sleep(20)
  let window=command(xdotool,@["search","--name",(if example:"^Leaf" else:"^Leaf GPUI native smoke$")],root).splitLines()[0]
  discard command(xdotool,@["windowfocus",window],root)
  if getEnv("LEAF_TEST_RENDERING")=="1":
    let receipt=readFile(directory/"ready.json")
    proc renderingSamples():seq[JsonNode]=
      for line in lines(directory/"events.jsonl"):
        let entry=parseJson(line)
        if entry["phase"].getStr=="rendering" and entry["status"].getStr=="ok":
          result.add(entry["details"])
    require(renderingSamples().len>0,"initial rendering diagnostic missing")
    discard command(xdotool,@["windowsize",window,"800","600"],root)
    let until=getMonoTime()+initDuration(seconds=5)
    while true:
      let samples=renderingSamples()
      if samples.len>0 and samples[^1]["logical_size"]["width"].getFloat==800 and
          samples[^1]["logical_size"]["height"].getFloat==600:break
      require(getMonoTime()<until,"resized rendering diagnostic missing")
      sleep(20)
    sleep(200)
    let before=renderingSamples()
    discard command(xdotool,@["windowsize",window,"800","600"],root)
    sleep(200)
    require(renderingSamples()==before,"identical window size duplicated rendering diagnostics")
    for i,sample in before:
      let scale=sample["scale_factor"].getFloat
      require(scale>0,"invalid rendering scale")
      require(sample["device_size_calculated"]["width"].getFloat==sample["logical_size"]["width"].getFloat*scale,
        "invalid calculated device width")
      require(sample["device_size_calculated"]["height"].getFloat==sample["logical_size"]["height"].getFloat*scale,
        "invalid calculated device height")
      require(sample["dpi_from_scale_calculated"].getFloat==96*scale,"invalid calculated DPI")
      if i>0:require(sample!=before[i-1],"consecutive rendering diagnostics were not deduplicated")
    require(readFile(directory/"ready.json")==receipt,"resize rewrote readiness receipt")
    echo "Passed native rendering diagnostics: initial, resize, deduplication and unchanged ready receipt"
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
  if lists:
    proc requests():int=parseFile(directory/"geometry.json")["viewport_requests"].getInt
    proc caption(node:JsonNode,key:string):string=
      if node.kind!=JObject:return ""
      let id=node{"id"}.getStr
      if id.endsWith(":" & key):return node{"text"}.getStr
      if node.hasKey("children"):
        for child in node["children"]:
          result=caption(child,key)
          if result.len>0:return
    proc awaitCaption(key,expected:string)=
      let until=getMonoTime()+initDuration(seconds=5)
      while caption(parseFile(dump)["root"],key)!=expected:
        require(getMonoTime()<until,"caption did not update: " & key)
        sleep(20)
    proc visibleRows():seq[int]=
      for id,b in parseFile(directory/"geometry.json")["nodes"]:
        let start=id.rfind(":row-")
        let y=b["y"].getFloat+b["height"].getFloat/2
        if start>=0 and y>36 and y<475:result.add(parseInt(id[start+5..^1]))
      result.sort()
    sleep(200)
    echo "Initial variable-list viewport requests: ",requests()
    require(requests()<=5,"variable-height list used per-row FFI requests")
    let before=requests()
    clickTarget("add")
    awaitCaption("add","counter:1")
    sleep(200)
    require(requests()==before,"unrelated Counter repeated the viewport request")
    let visible=visibleRows()
    require(visible.len>5,"visible list rows missing")
    for index in visible:
      clickTarget("row-" & $index)
      awaitCaption("row-" & $index,$index & ":1")
    require(requests()==before,"row State update repeated the viewport request")
    discard command(xdotool,@["mousemove","--window",window,"150","250","click","--repeat","8","--delay","20","5"],root)
    let until=getMonoTime()+initDuration(seconds=5)
    while visibleRows().len==0 or visibleRows()[^1]<=visible[^1]:
      require(getMonoTime()<until,"list did not scroll")
      sleep(20)
    sleep(200)
    require(requests()-before<=16,"scroll used per-row FFI requests")
    let idle=requests()
    sleep(200)
    require(requests()==idle,"idle list keeps requesting frames")
    for index in visibleRows():
      if index notin visible:
        clickTarget("row-" & $index)
        awaitCaption("row-" & $index,$index & ":1")
    echo "Passed batched variable-height viewport, independent Counter, visible row State and scrolling"
  else:
    clickTarget("add")
  proc status():string =
    try:return parseFile(dump)["root"]["children"][(if example:1 else:2)]["text"].getStr
    except CatchableError:return ""
  proc awaitStatus(expected:string) =
    let deadline=getMonoTime()+initDuration(seconds=5)
    while status()!=expected:
      require(getMonoTime()<deadline,"expected " & expected & "; got " & status())
      require(not child.poll(),"GPUI test application exited")
      sleep(20)
  if lists:discard
  elif example:
    awaitStatus("1")
    clickTarget("reset")
    awaitStatus("0")
  else:
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
  if watch:
    for revision in 1..2:
      writeStatus(env["LEAF_WATCH_STATUS"],revision,(if revision==1:"watch 编译失败" else:""))
      let until=getMonoTime()+initDuration(seconds=5)
      while parseFile(directory/"geometry.json")["nodes"].hasKey("watch-error")!=(revision==1):
        require(getMonoTime()<until,"watch error did not show/clear at revision " & $revision)
        sleep(20)
    echo "Passed native watch error show and clear"
  discard command(xdotool,@["key","ctrl+q"],root)
  let closing=getMonoTime()+initDuration(seconds=5)
  while not child.poll():
    require(getMonoTime()<closing,"GPUI close timeout")
    sleep(20)
  require(child.code==0,"GPUI close failed: " & child.output)
  if lists:echo "Passed real variable-height list window and close"
  elif example:echo "Passed real component example window, increment, reset, ready and close"
  else:echo "Passed real Nim + GPUI + GPUI Kit window, click, input, Enter, ready, failed viewport and close"
when isMainModule:
  try:quit(main())
  except CatchableError as error:stderr.writeLine(error.msg);quit(1)
