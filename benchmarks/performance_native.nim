## GPUI event-to-rendered-frame measurements for the unique managed runtime.
import std/[json,os,monotimes,times,strutils,sequtils]
import leaf
import leaf/[gpui_api,gpui_session,gpui_ffi_v2,gpui_build,performance_report,process_metrics,checksum]
import leaf/performance_scenarios
import ./measurement

type
  SceneModel = ref object
    kind, generation: int
    horizontal: bool

proc require(value: bool, message: string) =
  if not value: raise newException(ValueError, message)

proc makeSceneApp(kind: int): Application =
  var keys: seq[string]
  if kind > 0:
    for i in 0..<100_000: keys.add("item/" & $i)
  let Page = defineComponent[int, SceneModel]("NativePerformanceScene",
    proc(ctx: MountContext, p: int): SceneModel = SceneModel(kind: p),
    proc(ctx: ComponentContext, p: int, m: SceneModel): UiDescription =
      if m.kind == 0:
        var cells: seq[Node]
        for i in 0..<128:
          cells.add(text($i, key="cell/" & $i,
            styles=style({"width":"8","height":"8","background":"#123456"})))
        let body = if m.horizontal:
          host(row(cells, key="body", styles=style({"width":"full","height":"400"})))
        else:
          host(column(cells, key="body", styles=style({"width":"full","height":"400"})))
        hostShell(column(@[]), @[
          host(button("更新", key="update",
            onClick=(proc(e: Event) = m.horizontal = not m.horizontal),
            styles=style({"width":"120"}))), body])
      else:
        hostShell(column(@[]), @[
          host(button("更新", key="update", onClick=proc(e: Event) = inc m.generation)),
          componentList("list", keys,
            proc(index: int): UiDescription = host(text("Row " & $index & " generation " & $m.generation &
              (if m.kind == 2: " · GPUI variable row 中文内容 " & "x".repeat(index mod 3 + 1) else:""),
              key="row/" & $index)),
            rowHeight=(if m.kind == 1: 32.0 else: 0.0), estimatedHeight=32,
            overscan=0, styles=style({"width":"full","height":"320"}))]))
  componentApplication(component(Page, kind), "Nim + GPUI performance", 800, 600)

proc runScene(config: PerformanceConfig, kind: int, library: string): int =
  let api = loadGpui(library)
  let rt = newRuntime(makeSceneApp(kind))
  let session = openGpuiSession(rt, api)
  var operation, round = 0
  const cycle = 0
  var warming = true
  var pending, closed = false
  var latencies: seq[float64]
  var before = collectObservation()
  let roundStart = getMonoTime()
  session.onFrame = proc(sample: LeafFrameSample): bool =
    if pending:
      require(rt.stats.dispatches == uint64(operation + (if warming: config.warmup else: 0)),
        "native dispatch lost")
      if kind == 0:
        require(rt.find("body").children.len == 128, "static cell scene changed")
      else:
        require(rt.find("list").children.len > 0, "native viewport was not materialized")
        require(rt.find("list").node.listSource.len == 100_000, "list source changed")
      if not warming: latencies.add(sample.elapsed_ms)
      inc operation
      let limit = if warming: config.warmup else: config.iterations
      if operation == limit:
        if not warming:
          let after = collectObservation()
          emitStdout(%*{"type":"sample","scenario":NativeScenarios[kind],"group":"native",
            "round":round+1,"cycle":cycle+1,"operations":latencies.len,
            "latency_ms":latencies,"checks_passed":true,
            "resources":resourceRecord(before,after),
            "elapsed_wall_ms":float64((getMonoTime()-roundStart).inNanoseconds)/1_000_000,
            "runtime": %rt.stats})
          inc round
        operation = 0
        latencies.setLen(0)
        if warming:
          warming = false
          round = 0
        elif round == config.rounds:
          closed = true
          return true
        before = collectObservation()
    if kind > 0:
      let first = (operation * 50) mod 1000
      discard rt.materialize("list", first, first + 50)
    discard rt.dispatch("update", Event(kind: click))
    pending = true
    false
  result = session.run()
  require(result == 0 and closed, "native measurement failed")

proc main(): int =
  requireRelease()
  let config = harnessConfig()
  let library = ensureGpui()
  emitStdout(%*{"type":"header","schema":PerformanceSchema,"group":"native",
    "metadata":{"compiler":NimVersion,"platform":hostOS,"architecture":hostCPU,
      "release":true,"memory_manager":"orc","gpui_kit":"0.7.0","bridge_sha256":sha256File(library),
      "scope":"event-to-rendered-frame including scheduler; no hardware GPU claim"},
    "parameters":configDocument(config),"scenarios":NativeScenarios})
  for kind in 0..2:
    let code = runScene(config, kind, library)
    require(code == 0, "native scene failed: " & NativeScenarios[kind])
  0

when isMainModule:
  try: quit(main())
  except CatchableError as error:
    stderr.writeLine(error.msg); quit(1)
