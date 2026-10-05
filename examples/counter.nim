import leaf

type Counter = ref object
  count: int

proc counterApp*(): Application =
  let state = Counter()
  result = Application(title: "Leaf · Counter", width: 520, height: 400,
    render: proc(ctx: BuildContext): Node =
      column(@[
        text("Leaf 计数器", styles = style({"font_size": "28", "weight": "bold"})),
        text($state.count, key = "count", styles = style({"font_size": "64", "color": "#93C5FD"})),
        row(@[
          button("增加 +1", key = "add", onClick = proc(e: Event) = inc state.count),
          button("重置", key = "reset", disabled = state.count == 0,
            onClick = proc(e: Event) = state.count = 0)], styles = style({"gap": "12"})),
        text("界面和业务逻辑由 Nim 定义", styles = style({"color": "#9CA3AF"}))
      ], styles = style({"padding": "32", "gap": "20", "width": "full", "height": "full",
        "align": "center", "justify": "center"})))

when isMainModule: quit(run(counterApp()))
