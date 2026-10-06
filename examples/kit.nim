import leaf

type KitState = ref object
  accepted: bool
  enabled: bool
  name: string
  saved: string

proc kitApp*(): Application =
  let state = KitState(enabled: true, saved: "尚未保存")
  proc render(ctx: BuildContext): Node =
    view:
      column:
        styles: {"padding": "32", "gap": "18", "width": "full"}
        text "Leaf · Nim":
          styles: {"font_size": "26", "weight": "bold"}
        text "原生组件，Nim 状态与事件":
          styles: {"color": "#94a3b8"}
        separator()
        input state.name:
          key: "name"
          placeholder: "输入名称"
          styles: {"width": "360"}
          onChange(e): state.name = e.value
        checkbox "接受使用条款", state.accepted:
          key: "accept"
          onChange(e): state.accepted = e.checked
        switch "启用通知", state.enabled:
          key: "notifications"
          onChange(e): state.enabled = e.checked
        checkbox "禁用的选项", true:
          key: "disabled"
          disabled: true
        progress (if state.accepted: 100.0 else: 30.0):
          key: "progress"
          styles: {"width": "360"}
        row:
          styles: {"gap": "10", "align": "center"}
          tag (if state.accepted: "准备就绪" else: "等待确认"):
            variant: (if state.accepted: "success" else: "warning")
          spinner()
          text "原生加载动画":
            styles: {"font_size": "13"}
        row:
          styles: {"gap": "12"}
          button "保存":
            key: "save"
            disabled: not state.accepted
            onClick(e): state.saved = "已保存：" & state.name
          button "重置":
            key: "reset"
            variant: "outline"
            onClick(e):
              state.accepted = false
              state.name = ""
              state.saved = "尚未保存"
        text state.saved:
          key: "result"
  Application(title: "Leaf Kit Gallery", width: 720, height: 620, render: render)

when isMainModule: quit(run(kitApp()))
