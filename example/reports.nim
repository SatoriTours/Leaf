import ./ui
import ./pages/reports
let Root = defineComponent[int, State[Reports]]("ExampleReportsRoot",
  proc(ctx: MountContext, p: int): State[Reports] =
    ctx.state(newReports(rowCount = 1000, renderAll = true), snapshot = snapshotReports),
  proc(ctx: ComponentContext, p: int, model: State[Reports]): UiDescription =
    let state = ctx.value(model)
    state.model = model
    host(state.render()))
proc reportsApp*(): Application =
  componentApplication(component(Root, 0), "Leaf · 千行统计报表", 1240, 900)
when isMainModule: quit(run(reportsApp()))
