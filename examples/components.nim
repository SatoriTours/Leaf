import leaf

type CounterCard = ref object
  label: string
  count: int

proc render(state: CounterCard, key: string): Node =
  view:
    column:
      key: key
      styles: {"padding": "24", "gap": "16", "background": "#1F2937",
        "radius": "12", "width": "240"}
      text state.label:
        styles: {"font_size": "20", "weight": "bold"}
      text $state.count:
        key: "count"
        styles: {"font_size": "40", "color": "#93C5FD"}
      button "增加":
        key: "increment"
        onClick(e): inc state.count

proc componentsApp*(): Application =
  let left = CounterCard(label: "独立计数器 A")
  let right = CounterCard(label: "独立计数器 B")
  proc render(ctx: BuildContext): Node =
    view:
      column:
        styles: {"padding": "32", "gap": "24", "width": "full", "height": "full"}
        text "组件组合":
          styles: {"font_size": "28", "weight": "bold"}
        row:
          styles: {"gap": "20"}
          left.render("left")
          right.render("right")
  Application(title: "Leaf · Components", width: 620, height: 340, render: render)

when isMainModule: quit(run(componentsApp()))
