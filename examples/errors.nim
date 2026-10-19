import leaf

type ErrorModel = object
  broken: bool
  message: string

let Errors = defineComponent[int, State[ErrorModel]]("ExampleErrors",
  proc(ctx: MountContext, p: int): State[ErrorModel] =
    ctx.state(ErrorModel(message: "点击按钮观察错误恢复")),
  proc(ctx: ComponentContext, p: int, model: State[ErrorModel]): UiDescription =
    let m = ctx.value(model)
    if m.broken: raise newException(ValueError, "演示：render 失败")
    let body = column(@[
      text("错误恢复", styles=style({"font_size": "28", "weight": "bold"})),
      text(m.message, key="message"),
      button("事件抛出异常", key="event_error",
        onClick=(proc(e: Event) = raise newException(ValueError, "演示：按钮回调失败"))),
      button("让 render 失败", key="render_error",
        onClick=(proc(e: Event) = discard model.update(proc(v: ErrorModel): ErrorModel =
          result = v; result.broken = true))),
      button("恢复界面", key="recover",
        onClick=(proc(e: Event) = discard model.update(proc(v: ErrorModel): ErrorModel =
          result = v; result.broken = false; result.message = "已恢复，应用继续运行")))],
      styles=style({"padding": "28", "gap": "16", "width": "full", "height": "full"}))
    host(body))

proc errorsApp*(): Application =
  componentApplication(component(Errors, 0), "Leaf · Errors", 560, 400)

when isMainModule: quit(run(errorsApp()))
