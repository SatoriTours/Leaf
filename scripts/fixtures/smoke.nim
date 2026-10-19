## A real desktop fixture: automation sends physical mouse/keyboard events.
import leaf

type SmokeModel = object
  count: int
  value: string

let SmokeRoot = defineComponent[int, State[SmokeModel]]("SmokeRoot",
  proc(ctx: MountContext, p: int): State[SmokeModel] =
    ctx.state(SmokeModel()),
  proc(ctx: ComponentContext, p: int, model: State[SmokeModel]): UiDescription =
    let m = ctx.value(model)
    let node = column(@[
      text("Nim 原生窗口", styles = style({"font_size": "24"})),
      button("增加", key = "add", onClick = proc(e: Event) =
        discard model.update(proc(v: SmokeModel): SmokeModel =
          result = v; inc result.count; echo "SMOKE count=", result.count)),
      input(m.value, key = "entry", placeholder = "输入并按 Enter",
        onChange = (proc(e: Event) = discard model.update(proc(v: SmokeModel): SmokeModel =
          result = v; result.value = e.value; echo "SMOKE input=", result.value)),
        onSubmit = proc(e: Event) = echo "SMOKE submit=", e.value)
    ], styles = style({"padding": "24", "gap": "16"}))
    host(node))

let app = componentApplication(component(SmokeRoot, 0), "Leaf Nim Smoke", 480, 320)

when isMainModule: quit(run(app))
