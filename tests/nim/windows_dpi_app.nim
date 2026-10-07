## Pure acceptance content shared by frozen baseline and new framework/DLL.
import leaf
var count = 0
var value = "中文输入与 IME 验证"
proc dpiApp*(): Application =
  proc render(ctx: BuildContext): Node =
    column(@[
      text("Leaf Windows DPI · 中文 Aa 0123456789", key="title",
        styles=style({"font_size":"20"})),
      text("计数：" & $count, key="count"),
      button("点击增加", key="add", onClick=proc(e:Event)=inc count),
      input(value, key="entry", placeholder="输入中文，测试光标和选区",
        onChange=proc(e:Event)=value=e.value),
      text("缩放由 GPUI 处理；检查命中、IME、窗口调整和最大化。")],
      styles=style({"padding":"24","gap":"16","width":"full","height":"full"}))
  Application(title:"Leaf Windows DPI 验收",width:640,height:480,render:render)
when isMainModule:quit(run(dpiApp()))
