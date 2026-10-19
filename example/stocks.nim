import ./ui
import ./pages/stocks
let Root = defineComponent[int, State[Stocks]]("ExampleStocksRoot",
  proc(ctx: MountContext, p: int): State[Stocks] =
    ctx.state(newStocks(windowSize = 240), snapshot = snapshotStocks),
  proc(ctx: ComponentContext, p: int, model: State[Stocks]): UiDescription =
    let state = ctx.value(model)
    state.model = model
    host(state.render()))
proc stocksApp*(): Application =
  componentApplication(component(Root, 0), "Leaf · K 线与盘口", 1240, 900)
when isMainModule: quit(run(stocksApp()))
