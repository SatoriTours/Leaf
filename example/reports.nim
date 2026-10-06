import ./ui
import ./pages/reports
proc reportsApp*(): Application =
  let state = newReports(rowCount = 1000, renderAll = true)
  proc render(ctx: BuildContext): Node = state.render(ctx)
  Application(title: "Leaf · 千行统计报表", width: 1240, height: 900, render: render)
when isMainModule: quit(run(reportsApp()))
