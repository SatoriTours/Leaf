import ./ui
import ./pages/chat
let Root = defineComponent[int, State[Chat]]("ExampleChatRoot",
  proc(ctx: MountContext, p: int): State[Chat] =
    ctx.state(newChat(1000, true), snapshot = snapshotChat),
  proc(ctx: ComponentContext, p: int, model: State[Chat]): UiDescription =
    let state = ctx.value(model)
    state.model = model
    host(state.render()))
proc chatApp*(): Application =
  componentApplication(component(Root, 0), "Leaf · 即时聊天压力测试", 1240, 900)
when isMainModule: quit(run(chatApp()))
