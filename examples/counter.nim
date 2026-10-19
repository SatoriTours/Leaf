import leaf

let Counter = defineComponent[int, State[int]]("ExampleCounter",
  proc(ctx: MountContext, p: int): State[int] = ctx.state(0),
  proc(ctx: ComponentContext, p: int, count: State[int]): UiDescription =
    let n = ctx.value(count)
    componentView:
      column:
        styles: {"padding": "32", "gap": "20", "width": "full", "height": "full",
          "align": "center", "justify": "center"}
        text "Leaf 计数器":
          styles: {"font_size": "28", "weight": "bold"}
        text $n:
          key: "count"
          styles: {"font_size": "64", "color": "#93C5FD"}
        row:
          styles: {"gap": "12"}
          button "增加 +1":
            key: "add"
            onClick(e): discard count.update(proc(v: int): int = v + 1)
          button "重置":
            key: "reset"
            disabled: n == 0
            onClick(e): discard count.set(0)
        text "界面和业务逻辑由 Nim 定义":
          styles: {"color": "#9CA3AF"})

proc counterApp*(): Application =
  componentApplication(component(Counter, 0), "Leaf · Counter", 520, 400)

when isMainModule: quit(run(counterApp()))
