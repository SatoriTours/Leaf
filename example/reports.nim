import ./ui
import ./pages/reports
proc reportsApp*(): Application =
  let state = newReports(rowCount = 1000, renderAll = true)
  Application(title: "Leaf · 千行统计报表", width: 1240, height: 900, render: proc(ctx: BuildContext): Node = state.render(ctx))
when isMainModule: quit(run(reportsApp()))
