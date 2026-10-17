## Explicit load/error/retry, cancellation on leave and hidden retained work.
## Worker code owns only copied strings and its borrowed cancellation signal.
import std/os
import leaf
import leaf/components

proc exampleWork(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  # Bounded example work; real network/DB operations need their own deadlines.
  for i in 0..<50:
    if ctx.cancelled: return "cancelled"
    sleep(10)
  if input == "fail": raise newException(ValueError, "示例后台错误")
  "后台完成"

type TaskPageModel = ref object
  scope: TaskScope
  caption: State[string]

proc tasksApplication*(title = "Leaf component tasks"): Application =
  # Each application owns its router; none of this UI state enters TaskWork.
  var router: ComponentRouter
  proc start(m: TaskPageModel, mode: string, failing = false) =
    discard m.caption.set(mode & ":loading")
    discard startTask(m.scope, "request", (if failing: "fail" else: "ok"), exampleWork,
      (proc(value: string) =
        discard m.caption.set(mode & ":" & value)
        echo "tasks:result:", mode),
      (proc(error: TaskFailure) =
        discard m.caption.set(mode & ":error")
        echo "tasks:error:", mode, ":", error.message))
  let Page = defineComponent[string, TaskPageModel]("ExampleTaskPage",
    proc(ctx: MountContext, mode: string): TaskPageModel =
      let m = TaskPageModel(scope: ctx.taskScope(if mode == "retained": keepWhileRetained else: cancelOnDeactivate),
        caption: ctx.state(mode & ":idle"))
      ctx.onMount(proc(e: LifecycleContext) = echo "tasks:mount:", mode)
      # First visibility may be activate (e.g. an initially warm list row).
      # Neither callback assumes the other has run or starts duplicate work.
      ctx.onActivate(proc(e: LifecycleContext) = echo "tasks:activate:", mode)
      ctx.onDeactivate(proc(e: LifecycleContext) =
        if mode != "retained" and m.caption.read() == mode & ":loading":
          discard m.caption.set(mode & ":cancelled")
        echo "tasks:deactivate:", mode)
      ctx.onDispose(proc(e: LifecycleContext) = echo "tasks:dispose:", mode)
      m,
    proc(ctx: ComponentContext, mode: string, m: TaskPageModel): UiDescription =
      hostShell(column(@[]), @[
        host(text(ctx.value(m.caption), key = "status")),
        host(button("加载", key = "load", onClick = proc(e: Event) = start(m, mode))),
        host(button("模拟错误", key = "fail", onClick = proc(e: Event) = start(m, mode, true))),
        host(button("重试", key = "retry", onClick = proc(e: Event) = start(m, mode))),
        host(button("主页面", key = "go-main", onClick = proc(e: Event) = discard navigate(router, "main"))),
        host(button("其他页面", key = "go-other", onClick = proc(e: Event) = discard navigate(router, "other"))),
        host(button("隐藏继续", key = "go-retained", onClick = proc(e: Event) = discard navigate(router, "retained"))),
        host(button("离开销毁", key = "go-disposed", onClick = proc(e: Event) = discard navigate(router, "disposed")))]))
  let routes = @[
    Route(name: "main", path: "/", page: "main", view: "main"),
    Route(name: "other", path: "/other", page: "other", view: "main"),
    Route(name: "retained", path: "/retained", page: "retained", view: "main"),
    Route(name: "disposed", path: "/disposed", page: "disposed", view: "main")]
  proc definition(mode: string): ComponentPageDefinition =
    # Bind each route to its own call parameter, not one reused loop capture.
    ComponentPageDefinition(name: mode, views: @["main"],
      retention: (if mode == "disposed": PageRetention.disposeOnLeave else: PageRetention.retainState),
      build: proc(view: string): UiDescription = component(Page, mode))
  var pages: seq[ComponentPageDefinition]
  for name in ["main", "other", "retained", "disposed"]: pages.add(definition(name))
  let Root = defineComponent[int, int]("ExampleTasksRoot",
    proc(ctx: MountContext, p: int): int =
      router = newComponentRouter(ctx, routes, pages, "main")
      p,
    proc(ctx: ComponentContext, p, m: int): UiDescription = renderPage(ctx, router))
  componentApplication(component(Root, 0), title)

when isMainModule: quit(run(tasksApplication()))
