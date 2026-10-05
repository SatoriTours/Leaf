import ./ui
import ./pages/stocks
proc stocksApp*(): Application =
  let state = newStocks(windowSize = 240)
  Application(title: "Leaf · K 线与盘口", width: 1240, height: 900, render: proc(ctx: BuildContext): Node = state.render(ctx))
when isMainModule: quit(run(stocksApp()))
