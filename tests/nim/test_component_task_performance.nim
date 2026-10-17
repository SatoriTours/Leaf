import std/[unittest, atomics, os, monotimes, times, json]
import leaf/[core, widgets, components, host_session]
import ../../examples/component_tasks

var workerCalls: Atomic[int]
proc echoWork(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  discard workerCalls.fetchAdd(1)
  input
var targetState: State[string]
var targetScope: TaskScope
var staticRenders, completed: int
let Static = defineComponent[int, int]("TaskPerfStatic",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p, m: int): UiDescription =
    inc staticRenders
    host(text("static" & $p, key = "s" & $p)))
let Target = defineComponent[int, State[string]]("TaskPerfTarget",
  proc(ctx: MountContext, p: int): State[string] =
    targetScope = ctx.taskScope()
    targetState = ctx.state("idle")
    targetState,
  proc(ctx: ComponentContext, p: int, s: State[string]): UiDescription = host(text(ctx.value(s), key = "target")))
proc pumpUntil(rt: Runtime, done: proc(): bool {.closure.}) =
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while not done():
    discard rt.pumpTasks()
    doAssert getMonoTime() < deadline, "worker completion timed out"
    sleep(1)

suite "real task completion structural performance":
  test "100 1000 5000 static siblings keep handles and render only target":
    for size in [100, 1000, 5000]:
      staticRenders = 0; completed = 0; workerCalls.store(0)
      let Root = defineComponent[int, int]("TaskPerfRoot",
        proc(ctx: MountContext, p: int): int = p,
        proc(ctx: ComponentContext, p, m: int): UiDescription =
          var children: seq[UiDescription]
          for i in 0..<p: children.add(component(Static, i))
          children.add(component(Target, 0))
          hostShell(column(@[]), children))
      let rt = newRuntime(componentApplication(component(Root, size), "task performance"))
      let session = attachHostSession(rt, HostConsumer(sessionId: 701,
        prepare: proc(batch: HostBatch) = discard,
        apply: proc() = discard,
        accept: proc(revision: uint64) {.raises: [].} = discard,
        discardPrepared: proc() {.raises: [].} = discard))
      try:
        discard rt.pumpTasks() # settle lifecycle before taking the measurement
        var handles: seq[NodeHandle]
        for i in 0..<size: handles.add(session.handleFor(rt.find("s" & $i).id))
        rt.uiTask(proc() = discard startTask(targetScope, "measure", "后台完成", echoWork,
          proc(value: string) =
            inc completed
            discard targetState.set(value)))
        let before = rt.updateStats()
        let renders = rt.stats.renders
        let started = getMonoTime()
        rt.pumpUntil(proc(): bool = completed == 1)
        let completionWallMs = float64((getMonoTime()-started).inNanoseconds)/1e6
        let after = rt.updateStats()
        check rt.stats.renders - renders == 1
        check after.snapshotExports == before.snapshotExports
        check staticRenders == size
        check rt.find("target").node.text == "后台完成"
        check workerCalls.load() == 1
        var afterHandles: seq[NodeHandle]
        for i in 0..<size: afterHandles.add(session.handleFor(rt.find("s" & $i).id))
        check afterHandles == handles
        let revision = rt.acceptedRevision
        discard rt.pumpTasks()
        check rt.acceptedRevision == revision
        echo $(%*{"static": size, "completion_wall_ms": completionWallMs,
          "componentRenders": rt.stats.renders-renders, "snapshotExports": after.snapshotExports-before.snapshotExports,
          "unrelatedHandles": handles.len, "workerCalls": workerCalls.load()})
      finally:
        session.close()
        rt.closeRuntime()

suite "task example user behavior":
  test "load completes without another event and error retry completes":
    let rt = newRuntime(tasksApplication())
    try:
      discard rt.pumpTasks()
      check rt.dispatch("load", Event(kind: click))
      check rt.find("status").node.text == "main:loading"
      rt.pumpUntil(proc(): bool = rt.find("status").node.text == "main:后台完成")
      check rt.dispatch("fail", Event(kind: click))
      rt.pumpUntil(proc(): bool = rt.find("status").node.text == "main:error")
      check rt.dispatch("retry", Event(kind: click))
      rt.pumpUntil(proc(): bool = rt.find("status").node.text == "main:后台完成")
    finally: rt.closeRuntime()
