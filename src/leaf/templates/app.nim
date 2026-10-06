import leaf
import leaf/project

proc projectDemoApp*(): Application =
  var count = 0
  let message = readFile(asset("message.txt"))
  proc render(ctx: BuildContext): Node =
    view:
      column:
        styles: {"padding": "24", "gap": "12"}
        text "Leaf Project":
          styles: {"font_size": "26"}
        text "Count: " & $count:
          key: "count"
        text message:
          key: "message"
        button "Add":
          key: "add"
          variant: "primary"
          onClick(e):
            inc count
            stderr.writeLine("count=" & $count)
  Application(title: "Leaf Project Demo", width: 640, height: 480, render: render)
