import leaf

type KitModel = object
  accepted, enabled: bool
  name, saved: string

let Kit = defineComponent[int, State[KitModel]]("ExampleKit",
  proc(ctx: MountContext, p: int): State[KitModel] =
    ctx.state(KitModel(enabled: true, saved: "尚未保存")),
  proc(ctx: ComponentContext, p: int, model: State[KitModel]): UiDescription =
    let m = ctx.value(model)
    let body = column(@[
      text("Leaf · Nim", styles=style({"font_size": "26", "weight": "bold"})),
      text("原生组件，Nim 状态与事件", styles=style({"color": "#94a3b8"})),
      separator(),
      input(m.name, key="name", placeholder="输入名称", styles=style({"width": "360"}),
        onChange=(proc(e: Event) = discard model.update(proc(v: KitModel): KitModel =
          result = v; result.name = e.value))),
      checkbox("接受使用条款", m.accepted, key="accept",
        onChange=(proc(e: Event) = discard model.update(proc(v: KitModel): KitModel =
          result = v; result.accepted = e.checked))),
      switch("启用通知", m.enabled, key="notifications",
        onChange=(proc(e: Event) = discard model.update(proc(v: KitModel): KitModel =
          result = v; result.enabled = e.checked))),
      checkbox("禁用的选项", true, key="disabled", disabled=true),
      progress((if m.accepted: 100.0 else: 30.0), key="progress", styles=style({"width": "360"})),
      row(@[
        tag((if m.accepted: "准备就绪" else: "等待确认"),
          variant=(if m.accepted: "success" else: "warning")),
        spinner(), text("原生加载动画", styles=style({"font_size": "13"}))],
        styles=style({"gap": "10", "align": "center"})),
      row(@[
        button("保存", key="save", disabled=not m.accepted,
          onClick=(proc(e: Event) = discard model.update(proc(v: KitModel): KitModel =
            result = v; result.saved = "已保存：" & v.name))),
        button("重置", key="reset", variant="outline",
          onClick=(proc(e: Event) = discard model.update(proc(v: KitModel): KitModel =
            result = v; result.accepted = false; result.name = ""; result.saved = "尚未保存")))],
        styles=style({"gap": "12"})),
      text(m.saved, key="result")],
      styles=style({"padding": "32", "gap": "18", "width": "full"}))
    host(body))

proc kitApp*(): Application =
  componentApplication(component(Kit, 0), "Leaf Kit Gallery", 720, 620)

when isMainModule: quit(run(kitApp()))
