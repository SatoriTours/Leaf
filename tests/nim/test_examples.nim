import std/[unittest, tables]
import leaf
import ../../examples/[counter, todo, components, errors, kit]

suite "Migrated Nim application behaviors":
  test "counter increments and resets":
    let runtime = newRuntime(counterApp())
    check not runtime.dispatch("reset", Event(kind: click))
    for i in 0..<5: discard runtime.dispatch("add", Event(kind: click))
    check runtime.find("count").node.text == "5"
    discard runtime.dispatch("reset", Event(kind: click))
    check runtime.find("count").node.text == "0"

  test "todo submit toggle and delete use captured stable task IDs":
    let runtime = newRuntime(todoApp())
    discard runtime.dispatch("entry", Event(kind: change, value: "  第一项  "))
    discard runtime.dispatch("entry", Event(kind: submit))
    check runtime.find("task_1").node.text == "第一项"
    check runtime.find("entry").node.text == ""
    discard runtime.dispatch("entry", Event(kind: change, value: "第二项"))
    discard runtime.dispatch("add", Event(kind: click))
    discard runtime.dispatch("toggle_1", Event(kind: click))
    check runtime.find("summary").node.text == "已完成 1 / 2"
    discard runtime.dispatch("remove_1", Event(kind: click))
    expect UiError: discard runtime.find("task_1")
    check runtime.find("task_2").node.text == "第二项"
    check runtime.find("summary").node.text == "已完成 0 / 1"

  test "component instances have independent state":
    let runtime = newRuntime(componentsApp())
    expect UiError: discard runtime.find("increment")
    discard runtime.dispatch("i:0/i:1/k:4:left/k:9:increment", Event(kind: click))
    check runtime.find("i:0/i:1/k:4:left/k:5:count").node.text == "1"
    check runtime.find("i:0/i:1/k:5:right/k:5:count").node.text == "0"

  test "error demonstration recovers using last successful callbacks":
    let runtime = newRuntime(errorsApp())
    expect ValueError: discard runtime.dispatch("event_error", Event(kind: click))
    expect ValueError: discard runtime.dispatch("render_error", Event(kind: click))
    check runtime.dispatch("recover", Event(kind: click))
    check runtime.find("message").node.text == "已恢复，应用继续运行"

  test "gallery controlled inputs switches and save reset":
    let runtime = newRuntime(kitApp())
    check not runtime.dispatch("save", Event(kind: click))
    discard runtime.dispatch("name", Event(kind: change, value: "Nim 用户"))
    discard runtime.dispatch("accept", Event(kind: change, checked: true))
    discard runtime.dispatch("notifications", Event(kind: change, checked: false))
    discard runtime.dispatch("save", Event(kind: click))
    check runtime.find("result").node.text == "已保存：Nim 用户"
    check runtime.find("notifications").node.attributes["checked"] == "false"
    discard runtime.dispatch("reset", Event(kind: click))
    check runtime.find("name").node.text == ""
    check runtime.find("accept").node.attributes["checked"] == "false"
    check runtime.find("result").node.text == "尚未保存"
