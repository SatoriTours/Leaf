import std/[unittest, tables]
import leaf
import ../../examples/[counter, todo, components, errors, kit]
import leaf/host_session

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
    discard runtime.dispatch("left_increment", Event(kind: click))
    check runtime.find("left_count").node.text == "1"
    check runtime.find("right_count").node.text == "0"

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


suite "real component State transactions":
  test "rejected counter apply does not leak into the next accepted event":
    var reject = false
    let rt = newRuntime(counterApp())
    let session = attachHostSession(rt, HostConsumer(sessionId: 99101,
      prepare: proc(batch: HostBatch) = discard,
      apply: proc() =
        if reject: fail("probe rejects candidate"),
      accept: proc(revision: uint64) {.raises: [].} = discard,
      discardPrepared: proc() {.raises: [].} = discard))
    check rt.find("count").node.text == "0"
    reject = true
    expect UiError: discard rt.dispatch("add", Event(kind: click))
    check rt.find("count").node.text == "0"
    reject = false
    check rt.dispatch("add", Event(kind: click))
    check rt.find("count").node.text == "1"
    session.close()
    rt.closeRuntime()

  test "independent counter components rerender locally":
    leftRenders = 0
    rightRenders = 0
    let rt = newRuntime(componentsApp())
    let leftBefore = leftRenders
    let rightBefore = rightRenders
    check rt.dispatch("left_increment", Event(kind: click))
    check rt.find("left_count").node.text == "1"
    check rightRenders == rightBefore
    check leftRenders == leftBefore + 1
    check rt.find("right_count").node.text == "0"

type Pair = object
  a, b: int
let PairRoot = defineComponent[int, State[Pair]]("ExamplePairRoot",
  proc(ctx: MountContext, p: int): State[Pair] = ctx.state(Pair()),
  proc(ctx: ComponentContext, p: int, pair: State[Pair]): UiDescription =
    let current = ctx.value(pair)
    host(column(@[
      text($current.a & ":" & $current.b, key="pair_value"),
      button("twice", key="pair_twice", onClick=proc(e: Event) =
        discard pair.update(proc(v: Pair): Pair = (result = v; inc result.a))
        discard pair.update(proc(v: Pair): Pair = (result = v; inc result.a))),
      button("a", key="pair_a", onClick=proc(e: Event) =
        discard pair.update(proc(v: Pair): Pair = (result = v; inc result.a))),
      button("b", key="pair_b", onClick=proc(e: Event) =
        discard pair.update(proc(v: Pair): Pair = (result = v; inc result.b)))])))


suite "queued State updaters":
  test "two updaters in one event accumulate from the queued current":
    let rt = newRuntime(componentApplication(component(PairRoot, 0), "Pair"))
    check rt.dispatch("pair_twice", Event(kind: click))
    check rt.find("pair_value").node.text == "2:0"
    rt.closeRuntime()

  test "a rejected field update does not roll back an independent field":
    var reject = false
    let rt = newRuntime(componentApplication(component(PairRoot, 0), "Pair"))
    let session = attachHostSession(rt, HostConsumer(sessionId: 99102,
      prepare: proc(batch: HostBatch) = discard,
      apply: proc() =
        if reject: fail("probe rejects pair candidate"),
      accept: proc(revision: uint64) {.raises: [].} = discard,
      discardPrepared: proc() {.raises: [].} = discard))
    check rt.dispatch("pair_b", Event(kind: click))
    check rt.find("pair_value").node.text == "0:1"
    reject = true
    expect UiError: discard rt.dispatch("pair_a", Event(kind: click))
    check rt.find("pair_value").node.text == "0:1"
    reject = false
    check rt.dispatch("pair_a", Event(kind: click))
    check rt.find("pair_value").node.text == "1:1"
    session.close()
    rt.closeRuntime()
