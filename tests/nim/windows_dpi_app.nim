## Pure acceptance content shared by frozen baseline and new framework/DLL.
import leaf

type DpiModel = object
  count: int
  value: string

let Root = defineComponent[int, State[DpiModel]]("WindowsDpiRoot",
  proc(ctx: MountContext, p: int): State[DpiModel] =
    ctx.state(DpiModel(value: "中文输入与 IME 验证")),
  proc(ctx: ComponentContext, p: int, model: State[DpiModel]): UiDescription =
    let m = ctx.value(model)
    host(column(@[
      text("Leaf Windows DPI · 中文 Aa 0123456789", key="title",
        styles=style({"font_size":"20"})),
      text("计数：" & $m.count, key="count"),
      button("点击增加", key="add", onClick=proc(e:Event) =
        discard model.update(proc(v: DpiModel): DpiModel = (result = v; inc result.count))),
      input(m.value, key="entry", placeholder="输入中文，测试光标和选区",
        onChange=proc(e:Event) = discard model.update(proc(v: DpiModel): DpiModel =
          (result = v; result.value = e.value))),
      text("缩放由 GPUI 处理；检查命中、IME、窗口调整和最大化。")],
      styles=style({"padding":"24","gap":"16","width":"full","height":"full"}))))
proc dpiApp*(): Application =
  componentApplication(component(Root, 0), "Leaf Windows DPI 验收", 640, 480)
when isMainModule: quit(run(dpiApp()))
