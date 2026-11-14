## Native non-modal popover demonstration.
##
## Every dismissal is only a request: Esc, an outside click, the close button and
## the Tab boundary all ask for open=false, and the "ignore" switch proves that a
## refused request leaves the accepted state and the real panel untouched.
import leaf
import leaf/ui as standard

type Model = object
  open, dialogOpen, nestedOpen: bool
  name, note, colour: string
  dark, ignoreClose, huge: bool
  requests, closes, commits, dialogRequests: int

proc colourOptions(): seq[Node] =
  @[standard.selectItem("red", "红色"), standard.selectItem("blue", "蓝色"),
    standard.selectItem("green", "绿色")]

let Demo = defineComponent[int, State[Model]]("PopoverDemo",
  proc(ctx: MountContext, p: int): State[Model] = ctx.state(Model()),
  proc(ctx: ComponentContext, p: int, state: State[Model]): UiDescription =
    let m = ctx.value(state)
    let update = proc(f: proc(old: Model): Model {.closure.}) =
      discard state.update(f)

    let panelBody = proc(inner: Model, keyPrefix: string): Node =
      ## Ordinary standard controls plus an existing select: the panel is a real
      ## owned window, not a generic framework container.
      var controls: seq[Node] = @[
        standard.label("名称筛选", key = keyPrefix & "-label"),
        standard.input(inner.name, key = keyPrefix & "-name",
          placeholder = "输入关键字",
          onChange = proc(e: Event) = update(proc(old: Model): Model =
            result = old
            result.name = e.value)),
        standard.field(@[standard.label("颜色"),
          standard.select(standard.selectTrigger(placeholder = "全部"),
            standard.selectContent(colourOptions()),
            value = inner.colour, open = inner.nestedOpen,
            label = "颜色", key = keyPrefix & "-colour",
            onChange = proc(e: Event) = update(proc(old: Model): Model =
              result = old
              inc result.commits
              result.colour = e.value),
            onOpenChange = proc(e: Event) = update(proc(old: Model): Model =
              result = old
              result.nestedOpen = e.open))]),
        standard.popoverClose("应用并关闭", key = keyPrefix & "-close")]
      if inner.huge:
        for index in 1 .. 60:
          controls.add(standard.label("占位行 " & $index, key = keyPrefix & "-fill-" & $index))
      standard.popoverContent(controls, key = keyPrefix & "-popover-body")

    let pagePopover = standard.popover(
      standard.popoverTrigger("筛选", key = "filter-trigger"),
      panelBody(m, "page"), open = m.open, name = "筛选面板", key = "filter",
      width = 320,
      onOpenChange = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        inc result.requests
        if not e.open: inc result.closes
        if not old.ignoreClose: result.open = e.open))

    let dialogPopover = standard.popover(
      standard.popoverTrigger("更多选项", key = "dialog-trigger"),
      panelBody(m, "dialog"), open = m.dialogOpen, name = "更多选项面板",
      key = "dialog-popover", width = 300,
      onOpenChange = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        inc result.dialogRequests
        result.dialogOpen = e.open))

    let dialog = standard.dialog("浮层中的表单", m.dialogOpen,
      description = "第一次 Esc 只关闭 Select，第二次关闭 Popover，第三次关闭对话框。",
      key = "dialog", onDismiss = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        result.dialogOpen = false),
      content = @[
        standard.field(@[standard.label("备注"),
          standard.input(m.note, key = "note", placeholder = "对话框内草稿",
            onChange = proc(e: Event) = update(proc(old: Model): Model =
              result = old
              result.note = e.value))]),
        standard.field(@[standard.label("更多"), dialogPopover])],
      footer = @[standard.button("关闭", key = "close-dialog",
        onClick = proc(e: Event) = update(proc(old: Model): Model =
          result = old
          if not old.ignoreClose: result.dialogOpen = false))])

    let themeButton = standard.button(
      (if m.dark: "浅色" else: "深色"), key = "theme",
      variant = UiVariant.outline, onClick = proc(e: Event) = update(
        proc(old: Model): Model =
          result = old
          result.dark = not old.dark))
    let ignore = standard.checkbox("忽略关闭请求", m.ignoreClose, key = "ignore",
      onChange = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        result.ignoreClose = e.checked))
    let huge = standard.checkbox("超长内容（应拒绝打开）", m.huge, key = "huge",
      onChange = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        result.huge = e.checked))
    let openDialog = standard.button("打开对话框", key = "open-dialog",
      variant = UiVariant.outline, onClick = proc(e: Event) = update(
        proc(old: Model): Model =
          result = old
          result.dialogOpen = true))
    let counters = standard.fieldDescription(
      "请求 " & $m.requests & " · 关闭 " & $m.closes & " · 提交 " &
        $m.commits & " · 当前名称 " & (if m.name.len == 0: "-" else: m.name),
      key = "counters")

    let header = standard.cardHeader(@[standard.cardTitle("浮层"),
      standard.cardDescription(
        "真实 owned 非模态面板 · 受控 open · Esc/外点/Tab 边界都是请求")])
    let body = standard.cardContent(@[pagePopover, counters, ignore, huge,
      openDialog])
    let footer = standard.cardFooter(@[themeButton])
    let heading = column(@[text("浮层 Popover", variant = "primary"),
      standard.cardDescription(
        "面板内可放文本、按钮、原生 EDIT 与既有 Select；主题切换保留草稿")],
      styles = style({"gap": "7", "width": "full"}))
    let page = column(@[heading, standard.card(@[header, body, footer]), dialog],
      styles = style({"padding": "32", "gap": "24", "width": "full"}))
    hostShell(standard.theme((if m.dark: UiColorMode.dark else: UiColorMode.light),
      column(@[], key = "theme"), key = "theme"), @[host(page)]))

quit run(componentApplication(component(Demo, 0), "Leaf — 浮层 Popover", 620, 760)
  .withNativeTheme(shadcnLight))
