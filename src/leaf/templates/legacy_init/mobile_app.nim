import leaf
import leaf/app_resources
when not defined(android): import leaf/project

proc projectDemoApp*(resources: HostResources = nil): Application =
  let message = if resources != nil: resources.readAsset("message.txt")
    else:
      when defined(android): raise newException(UiError, "Android application requires HostResources")
      else: readFile(asset("message.txt"))
  let demo = defineComponent[int, State[int]]("ProjectDemo",
    proc(ctx: MountContext, p: int): State[int] = ctx.state(0),
    proc(ctx: ComponentContext, p: int, count: State[int]): UiDescription =
      let n = ctx.value(count)
      host(column(@[
        text("Leaf Project", styles=style({"font_size": "26"})),
        text("Count: " & $n, key="count"),
        text(message, key="message"),
        button("Add", key="add", variant="primary",
          onClick=(proc(e: Event) = discard count.update(proc(v: int): int = v + 1)))],
        styles=style({"padding": "24", "gap": "12"}))))
  componentApplication(component(demo, 0), "Leaf Project Demo", 640, 480)
