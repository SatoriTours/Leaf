import leaf

type ErrorState = ref object
  broken: bool
  message: string

proc errorsApp*(): Application =
  let state = ErrorState(message: "点击按钮观察错误恢复")
  Application(title: "Leaf · Errors", width: 560, height: 400,
    render: proc(ctx: BuildContext): Node =
      if state.broken: raise newException(ValueError, "演示：render 失败")
      column(@[
        text("错误恢复", styles = style({"font_size": "28", "weight": "bold"})),
        text(state.message, key = "message"),
        button("事件抛出异常", key = "event_error", onClick = proc(e: Event) =
          raise newException(ValueError, "演示：按钮回调失败")),
        button("让 render 失败", key = "render_error", onClick = proc(e: Event) = state.broken = true),
        button("恢复界面", key = "recover", onClick = proc(e: Event) =
          state.broken = false
          state.message = "已恢复，应用继续运行")
      ], styles = style({"padding": "28", "gap": "16", "width": "full", "height": "full"})))

when isMainModule: quit(run(errorsApp()))
