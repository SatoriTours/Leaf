## Native single-select demonstration.
##
## Two real entry points share one controlled model: a standalone select on the
## page and a second select inside a modal Dialog. Both value and open are the
## caller's accepted state, so a commit or an open/close request never rewrites
## them by itself; the "ignore" switches show a request the application refuses.
import leaf
import leaf/ui as standard

type Model = object
  value, dialogValue, longValue, note: string
  open, dialogOpen, dialogVisible, longOpen: bool
  rejectOpen, rejectValue, rejectClose, dark, reversed: bool
  commits, openRequests, dismissals, longCommits: int

proc colourOptions(reversed = false): seq[Node] =
  var items = @[
    standard.selectItem("red", "红色"),
    standard.selectItem("green", "绿色（禁用）", disabled = true),
    standard.selectItem("blue", "蓝色"),
    standard.selectItem("amber", "琥珀色"),
    standard.selectItem("violet", "紫罗兰"),
    standard.selectItem("slate", "石板灰")]
  if reversed:
    # Same stable keys, different display order: the accepted value must not
    # follow the position.
    var flipped: seq[Node]
    for index in countdown(items.high, 0): flipped.add(items[index])
    items = flipped
  items

proc longOptions(): seq[Node] =
  for index in 1 .. 20:
    result.add(standard.selectItem("item-" & $index, "选项" & $index,
      disabled = index == 5))

proc labelOf(value: string): string =
  case value
  of "red": "红色"
  of "blue": "蓝色"
  of "amber": "琥珀色"
  of "violet": "紫罗兰"
  of "slate": "石板灰"
  else: "未选择"

let Demo = defineComponent[int, State[Model]]("SelectDemo",
  proc(ctx: MountContext, p: int): State[Model] = ctx.state(Model()),
  proc(ctx: ComponentContext, p: int, state: State[Model]): UiDescription =
    let m = ctx.value(state)
    let update = proc(f: proc(old: Model): Model {.closure.}) =
      discard state.update(f)

    let pageSelect = standard.select(
      standard.selectTrigger(placeholder = "选择一个颜色", key = "colour-trigger"),
      standard.selectContent(colourOptions(m.reversed), key = "colour-content"),
      value = m.value, open = m.open, key = "colour", label = "颜色",
      onChange = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        inc result.commits
        if not old.rejectValue: result.value = e.value),
      onOpenChange = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        inc result.openRequests
        if e.open:
          if not old.rejectOpen: result.open = true
        elif not old.rejectClose:
          result.open = false))

    let dialogSelect = standard.select(
      standard.selectTrigger(placeholder = "选择内层颜色", key = "dialog-trigger"),
      standard.selectContent(colourOptions(m.reversed), key = "dialog-content"),
      value = m.dialogValue, open = m.dialogOpen, key = "dialog-colour",
      label = "内层颜色",
      onChange = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        result.dialogValue = e.value),
      onOpenChange = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        result.dialogOpen = e.open))

    let rejectOpen = standard.checkbox("忽略打开请求（受控拒绝）", m.rejectOpen,
      key = "reject-open", onChange = proc(e: Event) = update(
        proc(old: Model): Model =
          result = old
          result.rejectOpen = e.checked))
    let rejectValue = standard.checkbox("忽略数值提交（受控拒绝）", m.rejectValue,
      key = "reject-value", onChange = proc(e: Event) = update(
        proc(old: Model): Model =
          result = old
          result.rejectValue = e.checked))
    let stateText = standard.fieldDescription(
      "已接受的值：" & labelOf(m.value) & "（key: " &
        (if m.value.len == 0: "-" else: m.value) & "）", key = "state")
    let counters = standard.fieldDescription(
      "提交 " & $m.commits & " 次 · 开关请求 " & $m.openRequests &
        " 次 · Dialog 关闭请求 " & $m.dismissals & " 次", key = "counters")
    let openDialog = standard.button("打开含下拉的对话框", key = "open-dialog",
      onClick = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        result.dialogVisible = true))
    let themeButton = standard.button("切换浅色/深色", key = "theme",
      variant = UiVariant.outline, onClick = proc(e: Event) = update(
        proc(old: Model): Model =
          result = old
          result.dark = not old.dark))

    let longSelect = standard.select(
      standard.selectTrigger(placeholder = "长列表", key = "long-trigger"),
      standard.selectContent(longOptions(), key = "long-content"),
      value = m.longValue, open = m.longOpen, key = "long", label = "长列表",
      onChange = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        inc result.longCommits
        result.longValue = e.value),
      onOpenChange = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        result.longOpen = e.open))
    let longState = standard.fieldDescription(
      "长列表已接受：" & (if m.longValue.len == 0: "-" else: m.longValue) &
        "（20 项，第 5 项禁用，弹层内滚动）", key = "long-state")
    let reverseButton = standard.button("重排选项", key = "reverse",
      variant = UiVariant.outline, onClick = proc(e: Event) = update(
        proc(old: Model): Model =
          result = old
          result.reversed = not old.reversed))
    let body = standard.cardContent(@[pageSelect, stateText, rejectOpen,
      rejectValue, counters, longSelect, longState])
    let footer = standard.cardFooter(@[openDialog, themeButton, reverseButton])
    let header = standard.cardHeader(@[standard.cardTitle("颜色"),
      standard.cardDescription("禁用项会被跳过；重复标签仍以稳定 key 提交。")])
    let card = standard.card(@[header, body, footer])

    let dialog = standard.dialog("表单中的下拉", m.dialogVisible,
      description = "第一次 Esc 只关闭下拉；外层对话框与背景门控保持不变。",
      key = "dialog",
      onDismiss = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        inc result.dismissals
        if not old.rejectClose:
          result.dialogVisible = false
          result.dialogOpen = false),
      content = @[
        standard.field(@[standard.label("备注"),
          standard.input(m.note, key = "note", placeholder = "临时草稿",
            onChange = proc(e: Event) = update(proc(old: Model): Model =
              result = old
              result.note = e.value))]),
        standard.field(@[standard.label("内层颜色"), dialogSelect]),
        standard.checkbox("忽略关闭请求", m.rejectClose, key = "reject-close",
          onChange = proc(e: Event) = update(proc(old: Model): Model =
            result = old
            result.rejectClose = e.checked))],
      footer = @[standard.button("关闭", key = "close-dialog",
        onClick = proc(e: Event) = update(proc(old: Model): Model =
          result = old
          result.dialogVisible = false))])

    let heading = column(@[text("单选下拉 Select", variant = "primary"),
      standard.cardDescription(
        "真实 owned 弹层 · 受控 value/open · 上下/Home/End/字符定位 · Tab/Esc/外点请求收起")],
      styles = style({"gap": "7", "width": "full"}))
    let page = column(@[heading, card, dialog],
      styles = style({"padding": "32", "gap": "24", "width": "full"}))
    hostShell(standard.theme((if m.dark: UiColorMode.dark else: UiColorMode.light),
      column(@[], key = "theme"), key = "theme"), @[host(page)]))

quit run(componentApplication(component(Demo, 0), "Leaf — 单选下拉 Select", 560, 780)
  .withNativeTheme(shadcnLight))
