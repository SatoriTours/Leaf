## A real desktop fixture: automation sends physical mouse/keyboard events.
import leaf

var count = 0
var value = ""
let app = Application(title: "Leaf Nim Smoke", width: 480, height: 320,
  render: proc(ctx: BuildContext): Node =
    column(@[
      text("Nim 原生窗口", styles = style({"font_size": "24"})),
      button("增加", key = "add", onClick = proc(e: Event) =
        inc count
        echo "SMOKE count=", count),
      input(value, key = "entry", placeholder = "输入并按 Enter",
        onChange = (proc(e: Event) =
          value = e.value
          echo "SMOKE input=", value),
        onSubmit = proc(e: Event) = echo "SMOKE submit=", e.value)
    ], styles = style({"padding": "24", "gap": "16"})))

when isMainModule: quit(run(app))
