import leaf

var leftRenders*, rightRenders* = 0

let CounterCard = defineComponent[string, State[int]]("ExampleCounterCard",
  proc(ctx: MountContext, cardKey: string): State[int] = ctx.state(0),
  proc(ctx: ComponentContext, cardKey: string, count: State[int]): UiDescription =
    let n = ctx.value(count)
    if cardKey == "left": inc leftRenders else: inc rightRenders
    host(column(@[
      text("独立计数器", styles=style({"font_size": "20", "weight": "bold"})),
      text($n, key=cardKey & "_count", styles=style({"font_size": "40", "color": "#93C5FD"})),
      button("增加", key=cardKey & "_increment",
        onClick=proc(e: Event) = discard count.update(proc(v: int): int = v + 1))],
      key="card", styles=style({"padding": "24", "gap": "16", "background": "#1F2937",
        "radius": "12", "width": "240"}))))

let Root = defineComponent[int, int]("ExampleComponentsRoot",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p, m: int): UiDescription =
    hostShell(column(@[], key="components-root"), @[
      host(text("组件组合", styles=style({"font_size": "28", "weight": "bold"}))),
      hostShell(row(@[], key="cards", styles=style({"gap": "20"})), @[
        component(CounterCard, "left", key="left"),
        component(CounterCard, "right", key="right")])]))

proc componentsApp*(): Application =
  componentApplication(component(Root, 0), "Leaf · Components", 620, 340)

when isMainModule: quit(run(componentsApp()))
