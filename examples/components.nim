import leaf

type CounterCard = ref object
  label: string
  count: int

proc render(state: CounterCard, key: string): Node =
  column(@[
    text(state.label, styles = style({"font_size": "20", "weight": "bold"})),
    text($state.count, key = "count", styles = style({"font_size": "40", "color": "#93C5FD"})),
    button("增加", key = "increment", onClick = proc(e: Event) = inc state.count)
  ], key = key, styles = style({"padding": "24", "gap": "16",
    "background": "#1F2937", "radius": "12", "width": "240"}))

proc componentsApp*(): Application =
  let left = CounterCard(label: "独立计数器 A")
  let right = CounterCard(label: "独立计数器 B")
  Application(title: "Leaf · Components", width: 620, height: 340,
    render: proc(ctx: BuildContext): Node =
      column(@[
        text("组件组合", styles = style({"font_size": "28", "weight": "bold"})),
        row(@[left.render("left"), right.render("right")], styles = style({"gap": "20"}))
      ], styles = style({"padding": "32", "gap": "24", "width": "full", "height": "full"})))

when isMainModule: quit(run(componentsApp()))
