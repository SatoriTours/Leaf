import std/[strutils, algorithm, unicode]
import ../ui

type
  Status = enum paid, pending, refunded
  Filter = enum rfAll, rfPaid, rfPending, rfRefunded
  Record = object
    id, amount, day: int
    code, customer, region: string
    status: Status
  Selection = tuple[revision, count: int, query: string, filter: Filter, descending: bool]
  Reports* = ref object
    rowCount, revision, offset: int
    records, selected: seq[Record]
    query: string
    filter: Filter
    descending, renderAll, selectedValid: bool
    signature: Selection
    selectionVersion: int
    sourceVersion: int
    sourceNode: Node
    revenue, refunds: int
    daily: array[28, int]
    regional: array[4, int]
const Regions = ["华东", "华北", "华南", "西南"]
const Customers = ["林晓", "陈宁", "周然", "王禾", "许安"]
const StatusLabels = ["已支付", "待支付", "已退款"]
const Variants = ["success", "warning", "danger"]
const PageSize = 50
proc generate(state: Reports) =
  state.records.setLen(0)
  for id in 1..state.rowCount:
    state.records.add(Record(id: id, code: "ORD-" & align($id, 5, '0'), customer: Customers[id mod 5],
      region: Regions[id mod 4], amount: 8000 + (id * 791 + state.revision * 937) mod 240000,
      status: Status((id + state.revision) mod 3), day: id mod 28 + 1))
proc newReports*(rowCount = 500, renderAll = false): Reports =
  if rowCount notin [100, 500, 1000]: fail("unsupported report size")
  result = Reports(rowCount: rowCount, renderAll: renderAll, descending: true, sourceVersion: -1)
  result.generate()
proc select(state: Reports) =
  let signature: Selection = (state.revision, state.rowCount, state.query, state.filter, state.descending)
  if state.selectedValid and state.signature == signature: return
  state.selected.setLen(0)
  let needle = unicode.toLower(strutils.strip(state.query))
  for record in state.records:
    if state.filter != rfAll and ord(record.status) != ord(state.filter) - 1: continue
    if needle.len == 0 or needle in unicode.toLower(record.code & " " & record.customer & " " & record.region & " " & StatusLabels[ord(record.status)]):
      state.selected.add(record)
  let descending = state.descending
  state.selected.sort(proc(a, b: Record): int =
    if descending: cmp(b.amount, a.amount) else: cmp(a.amount, b.amount))
  state.revenue = 0; state.refunds = 0; state.daily = default(array[28, int]); state.regional = default(array[4, int])
  for record in state.selected:
    if record.status == paid:
      state.revenue += record.amount; state.daily[record.day - 1] += record.amount; state.regional[record.id mod 4] += record.amount
    elif record.status == refunded: state.refunds += record.amount
  state.signature = signature; state.selectedValid = true; inc state.selectionVersion
proc refresh(state: Reports) =
  inc state.revision; state.generate(); state.select()
  let lastOffset = if state.selected.len == 0: 0 else: (state.selected.len - 1) div PageSize * PageSize
  state.offset = min(state.offset, lastOffset)
proc sizeButton(state: Reports, count: int): Node =
  button($count & " 行", key = "report_size_" & $count, variant = (if state.rowCount == count: "primary" else: "outline"),
    onClick = proc(e: Event) = state.rowCount = count; state.offset = 0; state.generate())
proc filterButton(state: Reports, filter: Filter): Node =
  button(["全部", "已支付", "待支付", "已退款"][ord(filter)], key = "report_" & ["all", "paid", "pending", "refunded"][ord(filter)],
    variant = (if state.filter == filter: "primary" else: "ghost"), onClick = proc(e: Event) = state.filter = filter; state.offset = 0)
proc recordView(record: Record): Node =
  var cells: seq[Node]
  for i, value in [record.code, record.customer, record.region, "¥" & decimal(record.amount), StatusLabels[ord(record.status)],
    "2026-07-" & align($record.day, 2, '0')]:
    let styles = style({"width": $[110, 80, 60, 126, 88, 110][i], "font_size": "12"})
    cells.add(if i == 4: tag(value, variant = Variants[ord(record.status)], styles = styles) else: text(value, styles = styles))
  line(cells, "record_" & $record.id, 10, style({"min_height": "36"}))
proc render*(state: Reports, ctx: BuildContext): Node =
  state.select()
  var controls, metrics, filters, headers: seq[Node]
  for count in [100, 500, 1000]: controls.add(state.sizeButton(count))
  controls.add(label("合成订单数据")); controls.add(button("更新报表", key = "report_refresh", onClick = proc(e: Event) = state.refresh()))
  for metric in [("源数据行数", $state.rowCount, "report_count"), ("符合筛选", $state.selected.len, "report_matches"),
    ("已支付金额", "¥" & decimal(state.revenue), "report_revenue"), ("退款金额", "¥" & decimal(state.refunds), "report_refunds")]:
    metrics.add(card(@[label(metric[0]), title(metric[1], metric[2], 23)], "metric_" & metric[2], grow()))
  let charts = ctx.cached("reports/charts", $state.selectionVersion, proc(): Node =
    let peak = max(state.daily.max, 1)
    var bars, regions: seq[Node]
    for i, amount in state.daily:
      bars.add(stack(@[segment(max(float64(amount) * 88 / float64(peak), 1), color = (if i mod 7 == 0: Accent else: "#3B6578")),
        label((if i mod 7 == 0: $(i + 1) else: ""))], "daily_" & $i, styles = merged(grow(), style({"justify": "end"}))))
    regions.add(title("地区收入占比", size = 17))
    for i, region in Regions:
      regions.add(line(@[label(region), label("¥" & decimal(state.regional[i]))]))
      regions.add(progress((if state.revenue == 0: 0.0 else: float64(state.regional[i]) * 100 / float64(state.revenue))))
    line(@[card(@[title("每日收入 / 28 天", size = 17), line(bars, gap = 5, styles = style({"height": "116"})),
      label("横轴：日期　纵轴：已支付订单收入")], "revenue_chart", grow()), card(regions, "regional_report", style({"width": "262"}))]))
  for filter in Filter: filters.add(state.filterButton(filter))
  filters.add(switch("完整数据 / 虚拟列表", state.renderAll, key = "report_full", onChange = proc(e: Event) = state.renderAll = e.checked; state.offset = 0))
  for i, label in ["订单", "客户", "地区", "金额", "状态", "日期"]:
    headers.add(text(label, styles = style({"width": $[110, 80, 60, 126, 88, 110][i], "font_size": "12", "color": Muted})))
  let first = if state.renderAll: 0 else: min(state.offset, state.selected.len)
  let finish = if state.renderAll: state.selected.len else: min(first + PageSize, state.selected.len)
  var rows: Node
  if state.renderAll and state.selected.len > 0:
    if state.sourceNode == nil or state.sourceVersion != state.selectionVersion:
      let selected = state.selected
      var keys: seq[string]
      for record in selected: keys.add("record_" & $record.id)
      state.sourceNode = virtualList("report_rows", keys, proc(i: int): Node = recordView(selected[i]),
        rowHeight = 40, styles = style({"height": "330", "width": "full"}))
      state.sourceVersion = state.selectionVersion
    rows = state.sourceNode
  else:
    var visible: seq[Node]
    for i in first..<finish: visible.add(recordView(state.selected[i]))
    if visible.len == 0: visible.add(label("没有符合条件的订单。", "report_empty"))
    rows = stack(visible, "report_rows", 4, style({"height": "330", "overflow": "scroll"}))
  let start = if finish == first: 0 else: first + 1
  page("经营统计报表", "筛选、排序、分页和全量渲染，对比大数据集的更新与滚动表现。", @[
    line(controls), line(metrics), charts, card(@[
      line(@[input(state.query, key = "report_search", placeholder = "订单号 / 客户 / 地区 / 状态", styles = grow(),
        onChange = proc(e: Event) = state.query = e.value; state.offset = 0),
        button((if state.descending: "金额 ↓" else: "金额 ↑"), key = "report_sort", onClick = proc(e: Event) = state.descending = not state.descending)]),
      line(filters, gap = 10), line(headers, gap = 10), separator(), rows,
      line(@[label($start & "–" & $finish & " / " & $state.selected.len, "report_range"),
        button("上一页", key = "report_previous", disabled = state.renderAll or state.offset == 0,
          onClick = proc(e: Event) = state.offset = max(0, state.offset - PageSize)),
        button("下一页", key = "report_next", disabled = state.renderAll or finish >= state.selected.len,
          onClick = proc(e: Event) = state.offset += PageSize)])], "report_table"),
    line(@[label("当前数据范围"), text($(finish - first), "report_rendered"), label("行 / " &
      (if state.renderAll: "完整数据，按视口构建" else: "50 行分页") & " · 更新 " & $state.revision & " 次")])], height = 1260)
