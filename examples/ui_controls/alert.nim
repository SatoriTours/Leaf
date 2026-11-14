## Text Alert with native assertive live semantics; no EDIT provider replacement.
import leaf
import leaf/ui as standard

type Model = object
  dark, hidden, next, danger: bool
  draft: string
let Demo = defineComponent[int, State[Model]]("AlertDemo",
  proc(ctx: MountContext, p: int): State[Model] = ctx.state(Model(draft: "draft")),
  proc(ctx: ComponentContext, p: int, state: State[Model]): UiDescription =
    let m = ctx.value(state)
    var content = @[host(text("状态提醒", variant="primary")),
      host(standard.cardDescription("普通与危险提示 · 原生实时区域 · 不替换文本输入"))]
    if not m.hidden:
      content.add(host(standard.alert(@[standard.alertTitle("Notice"),
        standard.alertDescription(if m.next: "Details updated. This longer message wraps in a narrow window without covering the action buttons." else: "Details")],
        key="alert",variant=(if m.danger: UiVariant.destructive else: UiVariant.default))))
    content.add(host(standard.input(m.draft, key="draft", onChange=proc(e: Event)=
      discard state.update(proc(old: Model): Model =
        result=old; result.draft=e.value))))
    content.add(host(standard.button("Update alert", key="update", onClick=proc(e: Event)=
      discard state.update(proc(old: Model): Model =
        result=old; result.next=not old.next))))
    content.add(host(standard.button("Toggle alert", key="toggle", onClick=proc(e: Event)=
      discard state.update(proc(old: Model): Model =
        result=old; result.hidden=not old.hidden))))
    content.add(host(standard.button("Toggle theme", key="theme-button", variant=UiVariant.outline,
      onClick=proc(e: Event)=discard state.update(proc(old: Model): Model =
        result=old; result.dark=not old.dark))))
    content.add(host(standard.button("Toggle variant",key="variant",variant=UiVariant.outline,
      onClick=proc(e:Event)=discard state.update(proc(old:Model):Model=
        result=old;result.danger=not old.danger))))
    let body=hostShell(column(@[],styles=style({"padding":"24","gap":"16","width":"full"})),content)
    hostShell(standard.theme((if m.dark: UiColorMode.dark else: UiColorMode.light),column(@[]),key="theme"),@[body]))
quit run(componentApplication(component(Demo,0),"Leaf — 状态提醒",560,520).withNativeTheme(shadcnLight))
