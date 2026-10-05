import leaf

type KitState = ref object
  accepted: bool
  enabled: bool
  name: string
  saved: string

proc kitApp*(): Application =
  let state = KitState(enabled: true, saved: "尚未保存")
  Application(title: "Leaf Kit Gallery", width: 720, height: 620,
    render: proc(ctx: BuildContext): Node =
      column(@[
        text("Leaf · Nim", styles = style({"font_size": "26", "weight": "bold"})),
        text("原生组件，Nim 状态与事件", styles = style({"color": "#94a3b8"})),
        separator(),
        input(state.name, key = "name", placeholder = "输入名称", styles = style({"width": "360"}),
          onChange = proc(e: Event) = state.name = e.value),
        checkbox("接受使用条款", state.accepted, key = "accept",
          onChange = proc(e: Event) = state.accepted = e.checked),
        switch("启用通知", state.enabled, key = "notifications",
          onChange = proc(e: Event) = state.enabled = e.checked),
        checkbox("禁用的选项", true, key = "disabled", disabled = true),
        progress((if state.accepted: 100.0 else: 30.0), key = "progress", styles = style({"width": "360"})),
        row(@[
          tag((if state.accepted: "准备就绪" else: "等待确认"),
            variant = (if state.accepted: "success" else: "warning")),
          spinner(), text("原生加载动画", styles = style({"font_size": "13"}))
        ], styles = style({"gap": "10", "align": "center"})),
        row(@[
          button("保存", key = "save", disabled = not state.accepted,
            onClick = proc(e: Event) = state.saved = "已保存：" & state.name),
          button("重置", key = "reset", variant = "outline", onClick = proc(e: Event) =
            state.accepted = false
            state.name = ""
            state.saved = "尚未保存")
        ], styles = style({"gap": "12"})),
        text(state.saved, key = "result")
      ], styles = style({"padding": "32", "gap": "18", "width": "full"})))

when isMainModule: quit(run(kitApp()))
