import leaf
import leaf/project

let Demo = defineComponent[int, State[int]]("ProjectDemo",
  proc(ctx: MountContext, p: int): State[int] = ctx.state(0),
  proc(ctx: ComponentContext, p: int, count: State[int]): UiDescription =
    let n = ctx.value(count)
    let message = readFile(asset("message.txt"))
    let body = column(@[
      text("Leaf Project", styles=style({"font_size": "26"})),
      text("Count: " & $n, key="count"),
      text(message, key="message"),
      button("Add", key="add", variant="primary",
        onClick=(proc(e: Event) = discard count.update(proc(v: int): int = v + 1); stderr.writeLine("count=" & $ctx.value(count))))],
      styles=style({"padding": "24", "gap": "12"}))
    host(body))

proc projectDemoApp*(): Application =
  componentApplication(component(Demo, 0), "Leaf Project Demo", 640, 480)
