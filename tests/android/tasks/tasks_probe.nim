## Device-only integration fixture. Business State and TaskService stay in Nim.
import std/[atomics, os]
import leaf/[core, components, component_description, component_state, widgets,
  managed_runtime, native_ffi, component_tasks]
import leaf/backends/android/ffi
export native_ffi

var factories, initializations, disposals, callbacks, failures: int
var ownerThread, resultThread: int
var workerThread: Atomic[int]
var calls: Atomic[int]
var firstReturned, firstReleased, secondStarted, cancelledWork: Atomic[bool]
var value: State[string]

proc work(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  workerThread.store(getThreadId())
  let attempt = calls.fetchAdd(1)
  if attempt > 0: secondStarted.store(true)
  while not ctx.cancelled and (attempt > 0 or not firstReleased.load()): sleep(1)
  if ctx.cancelled:
    cancelledWork.store(true)
    return "cancelled"
  firstReturned.store(true) # Reached return; completion publication follows it.
  input

proc application(): Application =
  inc factories
  ownerThread = getThreadId()
  var scope: TaskScope
  let Page = defineComponent[int, State[string]]("AndroidRetainedTasks",
    proc(ctx: MountContext, props: int): State[string] =
      inc initializations
      result = ctx.state("pending")
      value = result
      scope = ctx.taskScope(keepWhileRetained)
      ctx.onDispose(proc(event: LifecycleContext) = inc disposals),
    proc(ctx: ComponentContext, props: int, state: State[string]): UiDescription =
      host(column(@[
        text("Leaf · 后台任务", key="title"),
        text(ctx.value(state), key="result"),
        button("启动任务", variant="default", key="start", onClick=proc(event: Event) =
          discard startTask(scope,"echo","后台 中文😀",work,
            (proc(payload: string) =
              resultThread = getThreadId()
              inc callbacks
              discard state.set(payload)),
            (proc(error: TaskFailure) = inc failures),
            maxResultBytes=64))], key="root",
        styles=style({"padding":"24","gap":"16","width":"full"}))))
  componentApplication(component(Page,0),"Leaf Tasks",400,600)

registerAndroidApplication(application)
proc leaf_tasks_probe*(which: cint): cint {.exportc, dynlib, cdecl, raises:[].} =
  try:
    case which
    of 0: cint(factories)
    of 1: cint(initializations)
    of 2: cint(callbacks)
    of 3: cint(disposals)
    of 4: cint(calls.load())
    of 5: cint(firstReturned.load())
    of 6: cint(value.readAccepted() == "后台 中文😀")
    of 7: cint(workerThread.load() != 0 and workerThread.load() != ownerThread)
    of 8: cint(resultThread == ownerThread and callbacks > 0)
    of 9: cint(secondStarted.load())
    of 10:
      firstReleased.store(true)
      1
    of 11: cint(cancelledWork.load())
    of 12: cint(failures)
    else: -1
  except Exception: -2
