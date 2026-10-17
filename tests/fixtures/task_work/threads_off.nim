import std/strutils
import leaf/[core, widgets, components, task_contracts, task_worker]

static: doAssert not compileOption("threads")

let Legacy = defineComponent[int, int]("ThreadsOffLegacy",
  proc(ctx: MountContext, props: int): int = props,
  proc(ctx: ComponentContext, props, model: int): UiDescription =
    host(text($model)))
let runtime = newRuntime(componentApplication(component(Legacy, 7), "old components"))
doAssert runtime.snapshot.root != nil
doAssert default(LifecycleContext).acceptedRevision == 0

var rejected = false
try:
  discard newTaskWorkerPool()
except ValueError as error:
  rejected = "--threads:on" in error.msg
doAssert rejected
echo "threads-off legacy components work; background tasks explicitly rejected"
