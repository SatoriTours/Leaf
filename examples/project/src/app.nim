import leaf
import leaf/project

proc projectDemoApp*(): Application =
  var count = 0
  let message = readFile(asset("message.txt"))
  Application(title: "Leaf Project Demo", width: 640, height: 480,
    render: proc(ctx: BuildContext): Node =
      column(@[
        text("Leaf Project", styles = style({"font_size": "26"})),
        text("Count: " & $count, key = "count"),
        text(message, key = "message"),
        button("Add", key = "add", variant = "primary",
          onClick = proc(e: Event) =
            inc count
            stderr.writeLine("count=" & $count))
      ], styles = style({"padding": "24", "gap": "12"})))
