## GPUI event-to-rendered-frame measurements include frame scheduling and draw.
import std/[json,os,monotimes,times,strutils]
import leaf
import leaf/[gpui_api,gpui_bridge,gpui_build,performance_report,process_metrics,checksum]
import leaf/performance_scenarios
import ./measurement

type
  Scene = ref object
    kind,generation:int
    horizontal:bool
    source:Node
    cells:seq[Node]
  Driver = ref object
    host:DesktopBridge
    config:PerformanceConfig
    scenes:array[3,Scene]
    scene,cycle,round,operation,total:int
    warming,pending,closed:bool
    latencies:seq[float64]
    before:ProcessObservation
    roundStart,cycleStart:MonoTime
    response,error:string

proc require(value:bool,message:string) =
  if not value:raise newException(PerformanceError,message)
proc makeSource(scene:Scene,keys:seq[string]):Node =
  let generation=scene.generation
  virtualList("list",keys,proc(i:int):Node =
    text("Row " & $i & " generation " & $generation &
      (if scene.kind==2:" · GPUI variable row 中文内容 ".repeat(i mod 3+1) else:""),
      key="row/" & $i),rowHeight=(if scene.kind==1:32.0 else:0.0),estimatedHeight=32,
    styles=style({"width":"full","height":"320"}))
proc makeDriver(config:PerformanceConfig):Driver =
  result=Driver(config:config,warming:true,cycle:1,round:1)
  var keys:seq[string]
  for i in 0..<100_000:keys.add("item/" & $i)
  for i in 0..2:
    let scene=Scene(kind:i)
    if i==0:
      for index in 0..<128:scene.cells.add(text($index,key="cell/" & $index,
        styles=style({"width":"8","height":"8","background":"#123456"})))
    else:scene.source=makeSource(scene,keys)
    result.scenes[i]=scene
  let driver=result
  driver.host=newDesktopBridge(Application(title:"Nim + GPUI performance",width:800,height:600,
    render:proc(ctx:BuildContext):Node =
      let scene=driver.scenes[driver.scene]
      let update=button("更新",key="update",onClick=proc(e:Event) =
        inc scene.generation
        if scene.kind==0:scene.horizontal=not scene.horizontal
        else:scene.source=makeSource(scene,keys))
      let toolbar=row(@[input("你好",key="entry",styles=style({"width":"240"})),update],styles=style({"gap":"12"}))
      let body=if scene.kind==0:
        (if scene.horizontal:row(scene.cells,key="body",styles=style({"width":"full","height":"400"}))
         else:column(scene.cells,key="body",styles=style({"width":"full","height":"400"})))
        else:scene.source
      column(@[toolbar,body],key="root",styles=style({"width":"full","height":"full","gap":"12"}))))

proc nextFrame(driver:Driver,elapsed:JsonNode):JsonNode =
  if driver.pending:
    require(elapsed.kind in {JFloat,JInt},"missing GPUI frame measurement")
    require(driver.host.runtime.stats.dispatches==uint64(driver.total),"native dispatch lost")
    require(driver.host.runtime.find("entry").node.text=="你好","Chinese input model changed")
    if driver.scene>0:require(driver.host.runtime.find("list").children.len>0,"native viewport was not materialized")
    if not driver.warming:driver.latencies.add(elapsed.getFloat)
    inc driver.operation
    let limit=if driver.warming:driver.config.warmup else:driver.config.iterations
    if driver.operation==limit:
      if not driver.warming:
        let after=collectObservation()
        emitStdout(%*{"type":"sample","scenario":NativeScenarios[driver.scene],"group":"native",
          "round":driver.round,"cycle":driver.cycle,"operations":driver.latencies.len,
          "latency_ms":driver.latencies,"checks_passed":true,
          "resources":resourceRecord(driver.before,after),
          "elapsed_wall_ms":float64((getMonoTime()-driver.roundStart).inNanoseconds)/1_000_000,
          "runtime": %driver.host.runtime.stats})
        inc driver.round
      driver.operation=0
      driver.latencies.setLen(0)
      if driver.warming or driver.round>driver.config.rounds:
        driver.round=1
        inc driver.scene
        if driver.scene==3:
          driver.scene=0
          if driver.warming:driver.warming=false
          else:
            emitStdout(%*{"type":"cycle_complete","group":"native","cycle":driver.cycle,
              "samples":3*driver.config.rounds,"elapsed_wall_ms":float64((getMonoTime()-driver.cycleStart).inNanoseconds)/1_000_000})
            if driver.cycle==driver.config.repeats:
              driver.closed=true
              emitStdout(%*{"type":"complete","group":"native","cycles":driver.config.repeats})
            else:
              inc driver.cycle
              if driver.config.intervalSeconds>0:sleep(int(driver.config.intervalSeconds*1000))
          driver.cycleStart=getMonoTime()
        if not driver.closed:discard driver.host.runtime.refresh()
      driver.roundStart=getMonoTime()
      driver.before=collectObservation()
  else:
    driver.roundStart=getMonoTime()
    driver.cycleStart=driver.roundStart
    driver.before=collectObservation()
  if not driver.closed:
    require(driver.host.runtime.dispatch("update",Event(kind:click)),"native update rejected")
    inc driver.total
    driver.pending=true
  %*{"snapshot":driver.host.runtime.snapshot.toJson(),"rows":[],"close":driver.closed}

proc profileCallback(context:pointer,data:ptr uint8,len:csize_t):cstring {.cdecl.} =
  let driver=cast[Driver](context)
  try:
    var raw=newString(int(len))
    if len>0:copyMem(addr raw[0],data,int(len))
    let message=parseJson(raw)
    if message["op"].getStr=="frame":driver.response = $driver.nextFrame(message["elapsed_ms"])
    else:return desktopCallback(cast[pointer](driver.host),data,len)
  except Exception as error:
    driver.error=error.msg
    driver.response = $(%*{"snapshot":driver.host.runtime.snapshot.toJson(),"rows":[],"error":error.msg,"close":true})
  driver.response.cstring

proc main():int =
  requireRelease()
  let config=harnessConfig()
  let library=ensureGpui()
  let api=loadGpui(library)
  require(api.frames!=nil,"GPUI frame measurement ABI missing")
  let driver=makeDriver(config)
  emitStdout(%*{"type":"header","schema":PerformanceSchema,"group":"native",
    "metadata":{"compiler":NimVersion,"platform":hostOS,"architecture":hostCPU,
      "release":true,"memory_manager":"orc","gpui_kit":"0.7.0","bridge_sha256":sha256File(library),
      "scope":"event-to-rendered-frame including scheduler; no hardware GPU claim"},
    "parameters":configDocument(config),"scenarios":NativeScenarios})
  let snapshot = $driver.host.runtime.snapshot.toJson()
  let code=api.frames(cast[ptr uint8](snapshot.cstring),csize_t(snapshot.len),profileCallback,cast[pointer](driver))
  require(code==0 and driver.closed and driver.error.len==0,"native measurement failed: " & driver.error)
when isMainModule:
  try:quit(main())
  except CatchableError as error:stderr.writeLine(error.msg);quit(1)
