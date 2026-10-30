## Standalone, no-HUD, opt-in instrumented Release producer. Ordinary UI turns
## own work; WndProc/paint/accept execute no application callbacks.
when not defined(windows) or not defined(release) or not defined(gcOrc) or not defined(leafCanvasMeasure):
  {.error: "Compile on Windows -d:release --mm:orc -d:leafCanvasMeasure".}
import std/[os,json,strutils,monotimes,times,math]
import leaf
import leaf/[native_layout,ui_thread,checksum,process_metrics,widgets,host_protocol,backend_session]
import leaf/animation as animation
import leaf/backends/win32/[api,calls,host,backend,canvas]
import ../examples/graphics_lab/scene
import ./[canvas_config,canvas_report]
when defined(leafCanvasFixedDiagnostic):
  import ./canvas_fixed_schedule
  import leaf/backends/win32/canvas_cpu_probe
  type
    CpuFileTime {.importc:"FILETIME",header:"<windows.h>",bycopy.} = object
      dwLowDateTime,dwHighDateTime:uint32
    CpuTimes = object
      thread100ns,process100ns:uint64
  proc currentThread():pointer {.importc:"GetCurrentThread",header:"<windows.h>".}
  proc threadTimes(handle:pointer,created,exited,kernel,user:ptr CpuFileTime):int32 {.stdcall,importc:"GetThreadTimes",dynlib:"kernel32.dll".}
  proc processTimes(handle:pointer,created,exited,kernel,user:ptr CpuFileTime):int32 {.stdcall,importc:"GetProcessTimes",dynlib:"kernel32.dll".}
  proc ticks(value:CpuFileTime):uint64 = (uint64(value.dwHighDateTime) shl 32) or uint64(value.dwLowDateTime)
  proc cpuTimes():CpuTimes =
    var created,exited,kernel,user:CpuFileTime
    if threadTimes(currentThread(),addr created,addr exited,addr kernel,addr user)==0:
      raise newException(CanvasPerfError,"GetThreadTimes unavailable")
    result.thread100ns=ticks(kernel)+ticks(user)
    if processTimes(cast[pointer](-1),addr created,addr exited,addr kernel,addr user)==0:
      raise newException(CanvasPerfError,"GetProcessTimes unavailable")
    result.process100ns=ticks(kernel)+ticks(user)

const LeafCanvasSourceHash {.strdefine.} = "unverified"
const LeafCanvasToolchainHash {.strdefine.} = "unverified"
const WakeTimer = 65120'u
const CadenceNs = 16_666_667'i64

type
  NativeMemory {.importc:"PROCESS_MEMORY_COUNTERS",header:"<psapi.h>",bycopy.} = object
    cb,PageFaultCount:uint32
    PeakWorkingSetSize,WorkingSetSize,QuotaPeakPagedPoolUsage,QuotaPagedPoolUsage:csize_t
    QuotaPeakNonPagedPoolUsage,QuotaNonPagedPoolUsage,PagefileUsage,PeakPagefileUsage:csize_t
  CpuSample = object
    at_ms,interval_ms,timeline_ms,scene_sample_ms,frame_build_validate_ms:float64
    framework_commit_ms,native_resource_ms,cpu_draw_submit_ms,total_ms,record_ms:float64
    when defined(leafCanvasFixedDiagnostic):
      phase_index:int
      ui_thread_cpu_ms,process_cpu_ms:float64
      total_cpu_cycles,timeline_cpu_cycles,scene_sample_cpu_cycles,frame_build_cpu_cycles:uint64
      commit_inclusive_cpu_cycles,framework_cpu_cycles,native_resource_cpu_cycles,draw_submit_cpu_cycles:uint64
      draw_record_cpu_cycles,end_draw_cpu_cycles:uint64
proc systemMetric(index:int32):int32 {.stdcall,importc:"GetSystemMetrics",dynlib:"user32.dll".}
proc processHandle():pointer {.importc:"GetCurrentProcess",header:"<windows.h>".}
proc processMemory(handle:pointer,counters:ptr NativeMemory,size:uint32):int32 {.stdcall,importc:"GetProcessMemoryInfo",dynlib:"psapi.dll".}
proc guiResources(handle:pointer,kind:uint32):uint32 {.stdcall,importc:"GetGuiResources",dynlib:"user32.dll".}
proc deviceCapability(dc:pointer,index:int32):int32 {.stdcall,importc:"GetDeviceCaps",dynlib:"gdi32.dll".}
proc ms(ns:int64):float64 = float64(ns)/1_000_000.0
proc since(start:MonoTime):int64 = (getMonoTime()-start).inNanoseconds
proc require(condition:bool,message:string) =
  if not condition:raise newException(CanvasPerfError,message)
proc observation(forceGc=true):JsonNode =
  let observed=if forceGc:collectObservation() else:observeProcess()
  var memory:NativeMemory
  memory.cb=uint32(sizeof(memory))
  let available=processMemory(processHandle(),addr memory,memory.cb)!=0
  result= %*{"heap_bytes":observed.heapBytes,"reserved_heap_bytes":observed.reservedHeapBytes,
    "cpu_ms":observed.cpuSeconds*1000,"gdi_objects":guiResources(processHandle(),0),
    "user_objects":guiResources(processHandle(),1),"rss_bytes":newJNull(),"peak_rss_bytes":newJNull()}
  if available:
    result["rss_bytes"]= %uint64(memory.WorkingSetSize)
    result["peak_rss_bytes"]= %uint64(memory.PeakWorkingSetSize)
proc counts(value:CanvasResourceCounts):JsonNode =
  %*[value.surfaces,value.scenes,value.geometries,value.textLayouts,
    value.layers,value.brushes,value.targets,value.factories]
proc refreshRate(window:HWND):JsonNode =
  let dc=GetDC(window)
  require(dc!=nil,"display DC unavailable")
  try:
    let hz=deviceCapability(dc,116) # VREFRESH; 0/1 mean unknown/default.
    result=if hz>1: %hz else:newJNull()
  finally:discard ReleaseDC(window,dc)

proc main() =
  when defined(leafCanvasFixedDiagnostic):
    let fixed=parseFixedCanvasArgs(commandLineParams())
    let config=fixed.producer
  else:
    let config=parseCanvasArgs(commandLineParams())
  require(LeafCanvasSourceHash.len==64 and LeafCanvasToolchainHash.len==64,"verified compile-time source and toolchain hashes are required")
  for suffix in [".json",".csv"]:require(not fileExists(config.output & suffix),"refusing to overwrite report")
  require(getFileSize(config.environment)<=65536,"public environment metadata too large")
  let environment=parseFile(config.environment)
  require(environment.kind==JObject,"environment must be an object")
  let startId= $getTime().toUnix & "-" & $getMonoTime().ticks
  var load:LabLoad
  case config.loadName
  of "staticFrame":load=LabLoad.staticFrame
  of "properties":load=LabLoad.properties
  else:load=LabLoad.geometry
  let scene=newLabScene(count=config.objects,load=load)
  var items=newSeq[LabItem](config.objects)
  var samples=newSeq[CpuSample](config.capacity)
  let initial=scene.frameAt(
    when defined(leafCanvasFixedDiagnostic):fixed.schedule.initialPhase
    else:0.0)
  var current:State[CanvasFrame]
  let root=defineComponent[CanvasFrame,State[CanvasFrame]]("CanvasDurationProducer",
    proc(ctx:MountContext,frame:CanvasFrame):State[CanvasFrame] =
      result=ctx.state(frame,snapshot=proc(value:CanvasFrame):CanvasFrame=value)
      current=result,
    proc(ctx:ComponentContext,frame:CanvasFrame,state:State[CanvasFrame]):UiDescription =
      host(canvasNodeInternal(ctx.value(state),key="canvas",styles=style({"width":"960","height":"540"}))))
  let activity=newUiScopeActivity()
  let app=componentApplication(component(root,initial),"Leaf Canvas performance (CPU-side)",960,540)
  let rt=newRuntime(guardUiApplication(app,proc():uint64=uint64(GetCurrentThreadId()),activity))
  let baseline=canvasResourceCounts()
  let before=observation()
  var afterWarmup,atMeasureEnd:JsonNode
  var window:Win32Host
  var native:Win32Backend
  var canvasHandle:NodeHandle
  var rootWindow,canvasWindow:HWND
  var dpi:uint32
  var remote:bool
  var measured=false
  var warmFrames,used,requests,coalesced,cutoffDropped:int
  var phaseStarted,sceneStarted,previousFrameStarted:MonoTime
  var previousValid=false
  var nextDue:int64
  var warmElapsed,sampleElapsed:float64
  var measuredStart,finalDraw:CanvasDiagnostics
  var done=false
  var failure=""
  var lastRefresh:JsonNode
  var clockPairMs=Inf
  for i in 0..<128:
    let start=getMonoTime()
    clockPairMs=min(clockPairMs,ms(since(start)))

  proc environmentValid() =
    require(IsIconic(rootWindow)==0 and IsWindowVisible(rootWindow)!=0,"minimized/hidden measurement is invalid")
    var rect:RECT
    require(GetClientRect(canvasWindow,addr rect)!=0,"Canvas physical bounds unavailable")
    require(rect.right-rect.left==960 and rect.bottom-rect.top==540,"physical Canvas bounds changed or are not 960x540")
    require(GetDpiForWindow(canvasWindow)==dpi,"Canvas DPI changed")
    require((systemMetric(0x1000)!=0)==remote,"remote-session state changed")

  proc operation(record:bool) =
    environmentValid()
    when defined(leafCanvasFixedDiagnostic):
      let beforeCpu=cpuTimes()
      let beforeCycles=queryUiCycles()
      var timelineCycles,samplingCycles,buildCycles,commitCycles:uint64
    let started=getMonoTime()
    let beforeDraw=native.canvasDiagnostics(canvasHandle)
    var timelineNs,samplingNs,buildNs,resourceNs,drawNs,commitNs:int64
    var frame:CanvasFrame
    if load!=LabLoad.staticFrame:
      var mark=getMonoTime()
      when defined(leafCanvasFixedDiagnostic):
        var cycleMark=queryUiCycles()
      when defined(leafCanvasFixedDiagnostic):
        let phase=if record:fixed.schedule.phase(used) else:fixed.schedule.warmupPhase(warmFrames)
      else:
        var timeline=animation.newTimeline(animation.tween(0.0,1.0,duration=4000.ms,repeat=forever,autoplay=true))
        timeline.advance(ms((started-sceneStarted).inNanoseconds).ms)
        let phase=timeline.sample()
      timelineNs=since(mark)
      when defined(leafCanvasFixedDiagnostic):
        timelineCycles=cycleDelta(queryUiCycles(),cycleMark)
        cycleMark=queryUiCycles()
      mark=getMonoTime()
      scene.sampleIntoInternal(phase,items)
      samplingNs=since(mark)
      when defined(leafCanvasFixedDiagnostic):
        samplingCycles=cycleDelta(queryUiCycles(),cycleMark)
        cycleMark=queryUiCycles()
      mark=getMonoTime()
      frame=scene.frameFromItemsInternal(items)
      buildNs=since(mark)
      when defined(leafCanvasFixedDiagnostic):
        buildCycles=cycleDelta(queryUiCycles(),cycleMark)
      require(frame.commandCount==3*config.objects and frame.pathSegmentCount==4*(config.objects div 3),"sampled scene identity changed")
    when defined(leafCanvasFixedDiagnostic):
      let commitCycleStart=queryUiCycles()
    let commitStarted=getMonoTime()
    if load==LabLoad.staticFrame:
      require(native.repaintCanvasForMeasurementInternal(canvasHandle),"accepted repaint did not draw")
    else:
      let candidate=frame # Freeze closure capture; State/Host acceptance remains authoritative.
      current.update(proc(old:CanvasFrame):CanvasFrame=candidate)
      require(rt.flush(),"State/BackendSession frame was not accepted")
    let commitTotal=since(commitStarted)
    when defined(leafCanvasFixedDiagnostic):
      commitCycles=cycleDelta(queryUiCycles(),commitCycleStart)
    let afterDraw=native.canvasDiagnostics(canvasHandle)
    require(afterDraw.successfulDraws==beforeDraw.successfulDraws+1,"producer operation did not complete exactly one EndDraw")
    resourceNs=afterDraw.resourcePreparationNs-beforeDraw.resourcePreparationNs
    drawNs=afterDraw.drawSubmitNs-beforeDraw.drawSubmitNs
    require(resourceNs>=0 and drawNs>=0 and resourceNs+drawNs<=commitTotal,"overlapping native CPU instrumentation")
    commitNs=commitTotal-resourceNs-drawNs
    let total=since(started)
    when defined(leafCanvasFixedDiagnostic):
      let afterCycles=queryUiCycles()
      let afterCpu=cpuTimes()
      let resourceCycles=cycleDelta(afterDraw.resourcePreparationCycles,beforeDraw.resourcePreparationCycles)
      let drawCycles=cycleDelta(afterDraw.drawSubmitCycles,beforeDraw.drawSubmitCycles)
      require(afterCpu.thread100ns>=beforeCpu.thread100ns and afterCpu.process100ns>=beforeCpu.process100ns,"CPU counters moved backwards")
    if record:
      require(used<samples.len and previousValid,"sample capacity or frame interval anchor missing")
      let recording=getMonoTime()
      samples[used]=CpuSample(at_ms:ms((started-phaseStarted).inNanoseconds),
        interval_ms:ms((started-previousFrameStarted).inNanoseconds),timeline_ms:ms(timelineNs),
        scene_sample_ms:ms(samplingNs),frame_build_validate_ms:ms(buildNs),
        framework_commit_ms:ms(commitNs),native_resource_ms:ms(resourceNs),cpu_draw_submit_ms:ms(drawNs),total_ms:ms(total))
      when defined(leafCanvasFixedDiagnostic):
        samples[used].phase_index=used mod fixed.schedule.cycleFrames
        samples[used].total_cpu_cycles=cycleDelta(afterCycles,beforeCycles)
        samples[used].timeline_cpu_cycles=timelineCycles
        samples[used].scene_sample_cpu_cycles=samplingCycles
        samples[used].frame_build_cpu_cycles=buildCycles
        samples[used].commit_inclusive_cpu_cycles=commitCycles
        samples[used].native_resource_cpu_cycles=resourceCycles
        samples[used].draw_submit_cpu_cycles=drawCycles
        samples[used].draw_record_cpu_cycles=cycleDelta(afterDraw.drawRecordCycles,beforeDraw.drawRecordCycles)
        samples[used].end_draw_cpu_cycles=cycleDelta(afterDraw.endDrawCycles,beforeDraw.endDrawCycles)
        require(samples[used].draw_record_cpu_cycles<=drawCycles and samples[used].end_draw_cpu_cycles<=drawCycles-samples[used].draw_record_cpu_cycles,"native draw cycle stages overlap")
        samples[used].framework_cpu_cycles=frameworkCycles(commitCycles,resourceCycles,drawCycles)
        samples[used].ui_thread_cpu_ms=float64(afterCpu.thread100ns-beforeCpu.thread100ns)/10000.0
        samples[used].process_cpu_ms=float64(afterCpu.process100ns-beforeCpu.process100ns)/10000.0
      samples[used].record_ms=ms(since(recording))
      inc used
    else:inc warmFrames
    previousFrameStarted=started
    previousValid=true

  var nativeCalls=systemWin32Calls()
  let getMessage=nativeCalls.getMessage
  nativeCalls.getMessage=proc(message:ptr MSG,hwnd:HWND,first,last:UINT):BOOL =
    try:
      if not done:
        environmentValid()
        let elapsed=since(phaseStarted)
        let warmupDone =
          when defined(leafCanvasFixedDiagnostic):not fixed.schedule.warmingUp(warmFrames) and previousValid
          else:previousValid and elapsed>=int64(config.warmupMs)*1_000_000
        if not measured and warmupDone:
          warmElapsed=ms(elapsed)
          afterWarmup=observation() # GC/stat collection is outside the measurement window.
          measuredStart=native.canvasDiagnostics(canvasHandle)
          phaseStarted=getMonoTime()
          when defined(leafCanvasFixedDiagnostic):
            previousFrameStarted=phaseStarted
          nextDue=0
          measured=true
        let active=since(phaseStarted)
        let samplingDone =
          when defined(leafCanvasFixedDiagnostic):fixed.schedule.complete(used)
          else:active>=int64(config.sampleMs)*1_000_000
        if measured and samplingDone:
          sampleElapsed=ms(active)
          when not defined(leafCanvasFixedDiagnostic):
            let nominal=int((int64(config.sampleMs)*1_000_000-1) div CadenceNs)+1
            cutoffDropped=max(0,nominal-requests)
            requests+=cutoffDropped
          lastRefresh=refreshRate(canvasWindow)
          require(lastRefresh==environment["refresh_hz"],"display refresh rate changed")
          atMeasureEnd=observation(false)
          finalDraw=native.canvasDiagnostics(canvasHandle)
          done=true
          window.requestClose()
        elif defined(leafCanvasFixedDiagnostic) or active>=nextDue:
          let due =
            when defined(leafCanvasFixedDiagnostic):1
            else:int((active-nextDue) div CadenceNs)+1
          nextDue+=int64(due)*CadenceNs
          if measured:
            requests+=due
            coalesced+=due-1
          operation(measured)
    except Exception as error:
      failure=error.msg
      done=true
      window.requestClose()
    getMessage(message,hwnd,first,last)

  var pumpExit = -1
  try:
    window=createHost("Leaf Canvas performance (CPU-side)",DipSize(width:960,height:540),nativeCalls)
    rootWindow=window.windowHandle
    window.setStartupScope(proc():bool=activity.busy or rt.installingUpdate or rt.installingHook)
    native=newWin32Backend(window,renderer=CanvasRenderer.software)
    let session=native.attachWin32Backend(rt)
    native.bindSession(session)
    window.bindSession(session,proc():bool=activity.busy)
    window.setSafeTick(proc()=native.safeListTurn())
    canvasHandle=session.handleFor(rt.find("canvas").id)
    canvasWindow=native.canvasWindowForMeasurementInternal(canvasHandle)
    dpi=GetDpiForWindow(canvasWindow)
    remote=systemMetric(0x1000)!=0
    require(environment["remote_desktop"].getBool==remote,"public remote-session metadata differs")
    require(environment["refresh_hz"]==refreshRate(canvasWindow),"public refresh metadata differs")
    environmentValid()
    require(SetTimer(rootWindow,WakeTimer,1,nil)!=0,"producer wake timer failed")
    phaseStarted=getMonoTime();sceneStarted=phaseStarted
    when defined(leafCanvasFixedDiagnostic):
      previousFrameStarted=phaseStarted
      previousValid=true
    pumpExit=window.pump()
    # Surface is already retired by close. The last read must be taken before close.
  finally:
    if window!=nil:window.destroyHost()
    rt.closeRuntime()
  require(failure.len==0,failure)
  require(done and measured and pumpExit==0,"window closed before completed sampling")
  let after=canvasResourceCounts()
  require(after==baseline,"native resources did not return to baseline")
  let afterCleanup=observation()
  var raw=newJArray()
  for i in 0..<used:raw.add(%samples[i])
  var report= %*{"schema":1,"kind":"leaf-canvas-performance","status":"complete",
    "metadata":{"scene_version":LabSceneVersion,"seed":LabSeed,"objects":config.objects,
      "commands":3*config.objects,"path_segments":4*(config.objects div 3),"load":config.loadName,
      "circles":(config.objects+2) div 3,"rectangles":(config.objects+1) div 3,"triangles":config.objects div 3,
      "opacity":scene.opacity,"size_scale":scene.sizeScale,"interactive_bindings":0,"dynamic_ratio":(if load==LabLoad.staticFrame:0.0 else:1.0),
      "source_sha256":LeafCanvasSourceHash,"executable_sha256":sha256File(getAppFilename()),
      "compiler":NimVersion,"toolchain_sha256":LeafCanvasToolchainHash,"release":true,"memory_manager":"orc","instrumentation":"leafCanvasMeasure-v1",
      "renderer":"software","width_px":960,"height_px":540,"dpi":dpi,"environment":environment,
      "warmup_ms":config.warmupMs,"sample_ms":config.sampleMs,"cadence_ms":CanvasCadenceMs},
    "process":{"pid":getCurrentProcessId(),"start_id":startId},
    "warmup_elapsed_ms":warmElapsed,"sampled_elapsed_ms":sampleElapsed,
    "requests":requests,"coalesced":coalesced,"cutoff_dropped":cutoffDropped,
    "builds":(if load==LabLoad.staticFrame:0 else:used),
    "draw_attempts":finalDraw.drawAttempts-measuredStart.drawAttempts,
    "successful_draws":finalDraw.successfulDraws-measuredStart.successfulDraws,
    "environment_unchanged":true,"cleanup":{"successful":true,"window_destroyed":IsWindow(rootWindow)==0,
      "native_before":counts(baseline),"native_after":counts(after)},
    "resources":{"before":before,"after_warmup":afterWarmup,"at_measure_end":atMeasureEnd,"after_cleanup":afterCleanup},
    "observer":{"clock_pair_ms":clockPairMs},"gpu_ms":newJNull(),"display_fps":newJNull(),"samples":raw}
  when defined(leafCanvasFixedDiagnostic):
    require(used==fixed.schedule.sampleFrames,"fixed diagnostic did not complete its frame budget")
    report["kind"]= %"leaf-canvas-fixed-diagnostic"
    report["metadata"]["protocol"]= %"fixed-sequence-v1"
    report["metadata"]["warmup_frames"]= %warmFrames
    report["metadata"]["sample_frames"]= %used
    report["metadata"]["cycle_frames"]= %fixed.schedule.cycleFrames
    report["metadata"]["sequence_sha256"]= %fixed.schedule.fingerprint
    report["metadata"]["initial_phase"]= %fixed.schedule.initialPhase
    report["metadata"]["warmup_ms"]=newJNull()
    report["metadata"]["sample_ms"]=newJNull()
    report["metadata"]["cadence_ms"]=newJNull()
    report["metadata"]["cpu_clock"]= %"GetThreadTimes/GetProcessTimes; 100ns units, OS-quantized accounting; process may exceed wall"
    report["metadata"]["cpu_bracket"]= %"CPU reads enclose wall timer; query overhead not subtracted; wall-minus-CPU is not presentation wait"
    report["metadata"]["cycle_clock"]= %"QueryThreadCycleTime on UI thread only; raw counts, never time or GPU cycles; frequency/virtualization dependent"
    report["metadata"]["cycle_stages"]= %"commit_inclusive encloses resource+draw+framework; draw encloses draw_record+end_draw; total encloses timeline+sampling+build+commit; query overhead retained"
  else:
    report["summary"]=summarizeCanvas(report)
  when not defined(leafCanvasFixedDiagnostic):
    let csv=canvasCsv(report)
  let body= $report
  require(body.len<=16*1024*1024,"bounded report exceeded 16 MiB")
  when not defined(leafCanvasFixedDiagnostic):
    writeFile(config.output & ".csv",csv)
  writeFile(config.output & ".json",body & "\n")
  echo "Canvas CPU-side report complete; frames=",used," formal=",config.formal

when isMainModule:
  try:main()
  except CatchableError as error:
    stderr.writeLine(error.msg)
    quit(1)
