## Native modal Dialog / AlertDialog demonstration.
##
## Every level is a real captioned owned window (non-topmost) with an
## in-application scrim; nothing is drawn inside the page. The caller owns
## "open": Esc, the X control, a scrim click and the system close only deliver a
## dismiss request to the level that owns them, so closing the inner level never
## closes the outer one, and the "reject close" switch shows a request that the
## application deliberately ignores.
import leaf
import leaf/ui as standard

type Model = object
  dark, dialogOpen, alertOpen, innerOpen, rejectClose: bool
  name: string
  renamed: bool
  saved, cancelled, deleted, dismissals: int
  pageNote: string

let Demo = defineComponent[int, State[Model]]("DialogDemo",
  proc(ctx: MountContext, p: int): State[Model] =
    ctx.state(Model(name: "Ada Lovelace")),
  proc(ctx: ComponentContext, p: int, state: State[Model]): UiDescription =
    let m = ctx.value(state)
    # One handler per level: a dismiss request only ever closes its own level.
    let closeOuter = proc(e: Event) =
      discard state.update(proc(old: Model): Model =
        result = old
        inc result.dismissals
        if not old.rejectClose: result.dialogOpen = false)
    let closeInner = proc(e: Event) =
      discard state.update(proc(old: Model): Model =
        result = old
        inc result.dismissals
        if not old.rejectClose: result.innerOpen = false)
    let closeAlert = proc(e: Event) =
      discard state.update(proc(old: Model): Model =
        result = old
        inc result.dismissals
        if not old.rejectClose: result.alertOpen = false)
    var content: seq[Node]
    content.add(column(@[
      text("模态对话框与危险确认", variant = "primary"),
      standard.cardDescription("真实 owned 窗口 · 应用内遮罩 · Esc/关闭/遮罩只提出关闭请求")],
      styles = style({"gap": "7", "width": "full"})))
    content.add(standard.card(@[
      standard.cardHeader(@[standard.cardTitle("Dialog 与 AlertDialog"),
        standard.cardDescription("嵌套打开时只关闭最上层；关闭后焦点回到触发按钮。")]),
      standard.cardContent(@[
        standard.button("打开对话框", key = "open-dialog",
          onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
            result = old; result.dialogOpen = true)),
        standard.button("打开危险确认", key = "open-alert", variant = UiVariant.destructive,
          onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
            result = old; result.alertOpen = true)),
        standard.field(@[standard.label("页面备注"),
          standard.input(m.pageNote, key = "page-note", onChange = proc(e: Event) =
            discard state.update(proc(old: Model): Model =
              result = old; result.pageNote = e.value))]),
        standard.checkbox("忽略关闭请求（受控拒绝）", m.rejectClose, key = "reject",
          onChange = proc(e: Event) = discard state.update(proc(old: Model): Model =
            result = old; result.rejectClose = e.checked)),
        standard.fieldDescription(
          "已保存 " & $m.saved & " 次 · 已取消 " & $m.cancelled & " 次 · 已删除 " &
          $m.deleted & " 次 · 关闭请求 " & $m.dismissals & " 次", key = "counters")]),
      standard.cardFooter(@[
        standard.button("切换浅色/深色", key = "theme", variant = UiVariant.outline,
          onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
            result = old; result.dark = not old.dark))])]))
    content.add(standard.dialog((if m.renamed: "编辑联系人（已重命名）" else: "编辑联系人"),
      m.dialogOpen,
      description = "名称会写入临时草稿，关闭后不会保存。",
      key = "dialog",
      onDismiss = closeOuter,
      content = @[
        standard.field(@[standard.label("名称"),
          standard.input(m.name, key = "name", onChange = proc(e: Event) =
            discard state.update(proc(old: Model): Model =
              result = old; result.name = e.value))]),
        standard.fieldDescription("Tab 只在本层内循环；背景窗口已禁用。")],
      footer = @[
        standard.button("取消", key = "cancel", variant = UiVariant.outline,
          onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
            result = old
            result.dialogOpen = false
            inc result.cancelled)),
        standard.button("重命名标题", key = "rename", variant = UiVariant.outline,
          onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
            result = old; result.renamed = not old.renamed)),
        standard.button("打开内层对话框", key = "open-inner", variant = UiVariant.outline,
          onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
            result = old; result.innerOpen = true)),
        standard.button("保存", key = "save",
          onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
            result = old
            result.dialogOpen = false
            inc result.saved))]))
    content.add(standard.dialog("内层对话框", m.innerOpen,
      description = "只关闭最上层并恢复外层的焦点与可用状态。",
      key = "dialog-inner",
      onDismiss = closeInner,
      content = @[standard.fieldDescription("外层仍然打开，主窗口保持禁用。")],
      footer = @[standard.button("关闭内层", key = "close-inner",
        onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
          result = old; result.innerOpen = false))]))
    content.add(standard.alertDialog("删除联系人",
      standard.alertDialogCancel("保留", key = "alert-cancel",
        onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
          result = old
          result.alertOpen = false
          inc result.cancelled)),
      m.alertOpen,
      action = standard.alertDialogAction("删除", key = "alert-delete",
        variant = UiVariant.destructive,
        onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
          result = old
          result.alertOpen = false
          inc result.deleted)),
      description = "该操作不能撤销。遮罩点击与 Esc 只请求取消，不执行删除。",
      key = "alert",
      onDismiss = closeAlert))
    let page = column(content,
      styles = style({"padding": "32", "gap": "24", "width": "full"}))
    hostShell(standard.theme((if m.dark: UiColorMode.dark else: UiColorMode.light),
      column(@[], key = "theme"), key = "theme"), @[host(page)]))
quit run(componentApplication(component(Demo, 0), "Leaf — 模态对话框", 640, 620)
  .withNativeTheme(shadcnLight))
