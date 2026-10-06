import ./ui
import ./pages/chat
proc chatApp*(): Application =
  let state = newChat(1000, true)
  proc render(ctx: BuildContext): Node = state.render(ctx)
  Application(title: "Leaf · 即时聊天压力测试", width: 1240, height: 900, render: render)
when isMainModule: quit(run(chatApp()))
