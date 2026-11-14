## Real native radio groups. A click or Space only requests the accepted value;
## the example can refuse it without the native siblings drifting out of sync.
import leaf
import leaf/ui as standard

type Model = object
  shipping: string
  payment: string
  refuse, dark, dialogOpen: bool
  status: string

proc optionLabel(value: string): string =
  case value
  of "standard": "标准配送"
  of "express": "加急配送"
  of "pickup": "门店自取"
  of "card": "银行卡"
  of "cash": "货到付款"
  of "invoice": "对公转账"
  else: value

proc shippingItems(prefix: string, closed: bool): seq[Node] =
  result = @[
    standard.radioGroupItem("standard", "标准配送", key = prefix & "-standard"),
    standard.radioGroupItem("express", "加急配送", key = prefix & "-express"),
    standard.radioGroupItem("pickup", (if closed: "自取（暂停）" else: "门店自取"),
      key = prefix & "-pickup", disabled = closed)]

proc paymentItems(prefix: string): seq[Node] =
  @[
    standard.radioGroupItem("card", "银行卡", key = prefix & "-card"),
    standard.radioGroupItem("cash", "货到付款", key = prefix & "-cash"),
    standard.radioGroupItem("invoice", "对公转账", key = prefix & "-invoice")]

let Demo = defineComponent[int, State[Model]]("RadioGroupDemo",
  proc(ctx: MountContext, p: int): State[Model] = ctx.state(Model(
    shipping: "standard", status: "已接受：标准配送")),
  proc(ctx: ComponentContext, p: int, state: State[Model]): UiDescription =
    let m = ctx.value(state)
    let update = proc(f: proc(old: Model): Model {.closure.}) = discard state.update(f)
    let chooseShipping = proc(e: Event) = update(proc(old: Model): Model =
      result = old
      if old.refuse: result.status = "已拒绝：" & optionLabel(e.value) & "（保持已接受值）"
      else:
        result.shipping = e.value
        result.status = "已接受：" & optionLabel(e.value))
    let choosePayment = proc(e: Event) = update(proc(old: Model): Model =
      result = old
      if old.refuse: result.status = "已拒绝：" & optionLabel(e.value) & "（保持未选择）"
      else:
        result.payment = e.value
        result.status = "已接受支付：" & optionLabel(e.value))
    proc payField(prefix: string): Node =
      standard.field(@[
        standard.label("支付方式（初始未选择）"),
        standard.radioGroup(paymentItems(prefix), m.payment,
          key = prefix & "-payment", label = "支付方式", onChange = choosePayment)],
        key = prefix & "-payment-field")
    proc shipField(prefix: string, closed: bool): Node =
      standard.field(@[
        standard.label("配送方式"),
        standard.radioGroup(shippingItems(prefix, closed), m.shipping,
          key = prefix & "-shipping", label = "配送方式",
          onChange = chooseShipping)], key = prefix & "-shipping-field")
    let dialogBody = standard.scrollArea(standard.scrollAreaContent(@[
      shipField("dialog", closed = true),
      payField("dialog"),
      standard.label("滚动区域内的单选组保持真实原生选择语义。", key = "dialog-note"),
      standard.checkbox("拒绝对话框内选择", m.refuse, key = "dialog-refuse",
        onChange = proc(e: Event) = update(proc(old: Model): Model =
          result = old
          result.refuse = e.checked))],
      key = "dialog-content"), 260, key = "dialog-viewport")
    let dialog = standard.dialog("选择配送与支付", m.dialogOpen, key = "dialog",
      description = "两个单选组位于同一个可滚动模态视口中。",
      content = @[dialogBody],
      footer = @[standard.button("关闭", key = "dialog-close",
        onClick = proc(e: Event) = update(proc(old: Model): Model =
          result = old
          result.dialogOpen = false))],
      onDismiss = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        result.dialogOpen = false))
    let page = column(@[
      standard.label("Native RadioGroup"),
      row(@[
        standard.button("打开对话框", key = "open",
          onClick = proc(e: Event) = update(proc(old: Model): Model =
            result = old
            result.dialogOpen = true)),
        standard.button("切换主题", key = "theme-toggle",
          onClick = proc(e: Event) = update(proc(old: Model): Model =
            result = old
            result.dark = not old.dark))], styles = style({"gap": "12"})),
      standard.checkbox("拒绝每次选择", m.refuse, key = "refuse",
        onChange = proc(e: Event) = update(proc(old: Model): Model =
          result = old
          result.refuse = e.checked)),
      shipField("page", closed = false),
      payField("page"),
      standard.label(m.status, key = "status"),
      dialog],
      styles = style({"padding": "20", "gap": "12", "width": "full"}))
    hostShell(standard.theme((if m.dark: UiColorMode.dark else: UiColorMode.light),
      column(@[], key = "theme"), key = "theme"), @[host(page)]))

quit run(componentApplication(component(Demo, 0), "Leaf - RadioGroup", 560, 520)
  .withNativeTheme(shadcnLight))
