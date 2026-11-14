## Managed spinner with native polite live semantics; no EDIT provider replacement.
import leaf
import leaf/ui as standard

type Model = object
  dark, hidden, next: bool
  draft: string
let Demo = defineComponent[int, State[Model]]("SpinnerDemo",
  proc(ctx: MountContext, p: int): State[Model] = ctx.state(Model(draft: "draft")),
  proc(ctx: ComponentContext, p: int, state: State[Model]): UiDescription =
    let m = ctx.value(state)
    var content = @[host(text("加载指示", variant="primary")),
      host(standard.cardDescription("共享动画时钟 · 隐藏暂停 · 卸载停止"))]
    if not m.hidden:
      content.add(standard.spinner(label=(if m.next: "Loading next" else: "Loading"), key="spinner"))
    content.add(host(standard.input(m.draft, key="draft", onChange=proc(e: Event)=
      discard state.update(proc(old: Model): Model =
        result=old; result.draft=e.value))))
    content.add(host(standard.button("Update status", key="update", onClick=proc(e: Event)=
      discard state.update(proc(old: Model): Model =
        result=old; result.next=not old.next))))
    content.add(host(standard.button("Toggle spinner", key="toggle", onClick=proc(e: Event)=
      discard state.update(proc(old: Model): Model =
        result=old; result.hidden=not old.hidden))))
    content.add(host(standard.button("Toggle theme", key="theme-button", variant=UiVariant.outline,
      onClick=proc(e: Event)=discard state.update(proc(old: Model): Model =
        result=old; result.dark=not old.dark))))
    let body=hostShell(column(@[],styles=style({"padding":"24","gap":"16","width":"full"})),content)
    hostShell(standard.theme((if m.dark: UiColorMode.dark else: UiColorMode.light),column(@[]),key="theme"),@[body]))
quit run(componentApplication(component(Demo,0),"Leaf — 加载指示",520,420).withNativeTheme(shadcnLight))
