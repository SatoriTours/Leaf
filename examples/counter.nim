import leaf

type Counter = ref object
  count: int

proc counterApp*(): Application =
  let state = Counter()
  proc render(ctx: BuildContext): Node =
    view:
      column:
        styles: {"padding": "32", "gap": "20", "width": "full", "height": "full",
          "align": "center", "justify": "center"}
        text "Leaf 计数器":
          styles: {"font_size": "28", "weight": "bold"}
        text $state.count:
          key: "count"
          styles: {"font_size": "64", "color": "#93C5FD"}
        row:
          styles: {"gap": "12"}
          button "增加 +1":
            key: "add"
            onClick(e): inc state.count
          button "重置":
            key: "reset"
            disabled: state.count == 0
            onClick(e): state.count = 0
        text "界面和业务逻辑由 Nim 定义":
          styles: {"color": "#9CA3AF"}
  Application(title: "Leaf · Counter", width: 520, height: 400, render: render)

when isMainModule: quit(run(counterApp()))
