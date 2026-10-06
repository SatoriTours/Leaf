import ./ui
import ./pages/stocks
proc stocksApp*(): Application =
  let state = newStocks(windowSize = 240)
  proc render(ctx: BuildContext): Node = state.render(ctx)
  Application(title: "Leaf · K 线与盘口", width: 1240, height: 900, render: render)
when isMainModule: quit(run(stocksApp()))
