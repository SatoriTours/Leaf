import std/strutils
import ../ui

type Dashboard* = ref object
  month: bool
  query: string
  refreshCount: int
const Projects = [(1, "品牌官网改版", "林晓", 76, "进行中"),
  (2, "移动端组件规范", "陈宁", 100, "已完成"), (3, "用户反馈中心", "周然", 42, "进行中"),
  (4, "数据分析面板", "林晓", 18, "待启动")]
proc newDashboard*(): Dashboard = Dashboard()
proc render*(state: Dashboard, ctx: BuildContext): Node =
  var metrics: seq[Node]
  let values = if state.month: [486, 86, 72, 97] else: [128, 24, 18, 94]
  for i, name in ["活跃成员", "新增任务", "已完成任务", "交付达成率"]:
    metrics.add(card(@[label(name), title($(values[i] + (if i == 0: state.refreshCount else: 0)) &
      (if i == 3: "%" else: ""), "metric_value_" & $i, 32), label(["较上期 +12%", "较上期 +8%", "较上期 +16%", "目标 90%"][i])],
      "metric_" & $i, grow()))
  let chart = ctx.cached("dashboard/chart", $state.month, proc(): Node =
    var bars: seq[Node]
    let heights = if state.month: [12, 18, 15, 24, 20, 28, 25] else: [6, 10, 8, 14, 11, 18, 15]
    for i, value in heights:
      bars.add(stack(@[label($value), segment(float64(value * 4), color = (if i == 5: Accent else: "#3B6578")),
        label((if state.month: "第" & $(i + 1) & "期" else: ["一", "二", "三", "四", "五", "六", "日"][i]))],
        "bar_" & $i, 8, merged(grow(), style({"justify": "end"}))))
    card(@[line(@[title("任务完成趋势"), tag((if state.month: "本月" else: "本周"), key = "period_label")]),
      line(bars, "chart", styles = style({"height": "168"})), label("横轴：统计周期　纵轴：完成任务数")], "activity", grow()))
  var projects: seq[Node] = @[line(@[title("近期项目"), input(state.query, key = "project_search",
    placeholder = "搜索项目、负责人或状态", styles = style({"width": "280"}),
    onChange = proc(e: Event) = state.query = e.value)]), separator()]
  var matches = 0
  for project in Projects:
    if state.query.strip notin project[1] & " " & project[2] & " " & project[4]: continue
    inc matches
    projects.add(line(@[stack(@[text(project[1]), label("负责人：" & project[2])], styles = grow()),
      stack(@[progress(float64(project[3])), label("完成 " & $project[3] & "%")], styles = style({"width": "150"})),
      tag(project[4], variant = (if project[3] == 100: "success" else: "info"), styles = style({"width": "90"}))], "project_" & $project[0]))
  if matches == 0: projects.add(label("没有匹配的项目，试试其他关键词。", "project_empty"))
  page("工作概览", "你好，林晓。这里是团队的项目进展与近期动态。", @[
    line(@[button("最近 7 天", key = "period_week", variant = (if state.month: "outline" else: "primary"), onClick = proc(e: Event) = state.month = false),
      button("最近 30 天", key = "period_month", variant = (if state.month: "primary" else: "outline"), onClick = proc(e: Event) = state.month = true),
      label("示例数据"), button("刷新数据", key = "refresh", onClick = proc(e: Event) = inc state.refreshCount)]),
    line(metrics), line(@[chart, card(@[title("本期目标"), title((if state.month: "72 / 86" else: "18 / 24"), size = 36),
      label("已完成 / 新增任务"), progress((if state.month: 84.0 else: 75.0), key = "goal_progress"), separator(),
      tag("进展顺利", variant = "success"), label("持续推进，让每一步都看得见。")], "goal", style({"width": "242"}))]),
    card(projects, "projects"), label("已刷新 " & $state.refreshCount & " 次 · 筛选后 " & $matches & " 个项目", "dashboard_status")], height = 1060)
