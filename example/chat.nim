import ./ui
import ./pages/chat
proc chatApp*(): Application =
  let state = newChat(1000, true)
  Application(title: "Leaf · 即时聊天压力测试", width: 1240, height: 900,
    render: proc(ctx: BuildContext): Node = state.render(ctx))
when isMainModule: quit(run(chatApp()))
