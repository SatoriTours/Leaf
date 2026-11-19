import std/unittest
import leaf
import leaf/[host_session, host_protocol, backend]
import ./fixtures/declarative_implementation as library

component Stepper:
  model value: int
  prop minimum: int = 1
  prop maximum: int = 8
  view:
    row:
      button "-", key = "minus", disabled = value <= minimum:
        value -= 1
      text value:
        key: "value"
      button "+", key = "plus", disabled = value >= maximum:
        value += 1

component Booking:
  state:
    name = ""
    guests = 1
    receipt = ""
  view:
    column:
      textField name, key = "name"
      stepper guests, maximum = 2
      text "stable":
        key: "stable"
      text name & ":" & $guests:
        key: "preview"
      button "确认", key = "confirm", disabled = name.len == 0:
        receipt = name & ":" & $guests
      text receipt:
        key: "receipt"

component ImportedUse:
  state:
    count = 0
  view:
    column:
      library.importedControl(count = count)
      text count:
        key: "count"

component StepperGroup:
  model value: int
  prop bound: int = 8
  view:
    stepper value = value, maximum = bound

component BindingOnly:
  state:
    guests = 1
    limit = 2
  view:
    column:
      stepperGroup guests, bound = limit
      button "raise limit", key = "raise-limit":
        limit += 1

suite "declarative component bindings":
  test "field and child update the accepted parent model":
    let runtime = newRuntime(app(Booking, title = "预约"))
    defer: runtime.closeRuntime()
    check runtime.find("confirm").node.disabled
    discard runtime.dispatch("name", Event(kind: change, value: "Ada"))
    check not runtime.find("confirm").node.disabled
    discard runtime.dispatch("plus", Event(kind: click))
    check runtime.find("value").node.text == "2"
    check runtime.find("plus").node.disabled
    check runtime.find("preview").node.text == "Ada:2"
    discard runtime.dispatch("confirm", Event(kind: click))
    check runtime.find("receipt").node.text == "Ada:2"

  test "reconciliation neither creates nor patches unrelated hosts":
    let runtime = newRuntime(app(Booking))
    defer: runtime.closeRuntime()
    var batch: HostBatch
    let session = attachHostSession(runtime, HostConsumer(sessionId: 9131,
      prepare: proc(next: HostBatch) = batch = next,
      apply: proc() = discard,
      accept: proc(revision: uint64) {.raises: [].} = discard,
      discardPrepared: proc() {.raises: [].} = discard))
    defer: session.close()
    let stable = runtime.find("stable").id
    let count = runtime.find("value").id
    var stableHandle, countHandle: NodeHandle
    for op in batch.ops:
      if op.kind == HostOpKind.create and op.nodeId == stable: stableHandle = op.handle
      if op.kind == HostOpKind.create and op.nodeId == count: countHandle = op.handle
    check stableHandle != NoHandle
    check countHandle != NoHandle
    check runtime.dispatch("plus", Event(kind: click))
    var countUpdated = false
    for op in batch.ops:
      check op.kind notin {HostOpKind.create, HostOpKind.remove}
      check op.handle != stableHandle
      if op.kind == HostOpKind.update and op.handle == countHandle: countUpdated = true
    check countUpdated
    check runtime.find("stable").id == stable

  test "model forwarding and live prop expressions refresh child output":
    let runtime = newRuntime(app(BindingOnly))
    defer: runtime.closeRuntime()
    check runtime.dispatch("plus", Event(kind: click))
    check runtime.find("value").node.text == "2"
    check runtime.find("plus").node.disabled
    check runtime.dispatch("raise-limit", Event(kind: click))
    check not runtime.find("plus").node.disabled
    check runtime.dispatch("plus", Event(kind: click))
    check runtime.find("value").node.text == "3"

  test "a rejected host candidate rolls back both field and forwarded model writes":
    let runtime = newRuntime(app(Booking))
    defer: runtime.closeRuntime()
    var rejecting = false
    runtime.setValidator(proc(snapshot: Snapshot) =
      if rejecting: fail("candidate rejected"))
    rejecting = true
    expect UiError: discard runtime.dispatch("name", Event(kind: change, value: "Ada"))
    expect UiError: discard runtime.dispatch("plus", Event(kind: click))
    check runtime.find("preview").node.text == ":1"
    rejecting = false
    check runtime.dispatch("plus", Event(kind: click))
    check runtime.find("preview").node.text == ":2"

  test "an imported contract binds named arguments and keeps private defaults":
    let runtime = newRuntime(app(ImportedUse))
    defer: runtime.closeRuntime()
    check runtime.dispatch("imported", Event(kind: click))
    when defined(leafHeadlessOnly):
      check runtime.find("count").node.text == "4"
    else:
      check runtime.find("count").node.text == "2"

contract PlatformControl:
  model count: int
  prop increment: int = 2

implement PlatformControl:
  view:
    button "shared", key = "platform":
      count += increment

implement PlatformControl, platform = headless:
  view:
    button "headless override", key = "platform":
      count += increment * 2

component ContractUse:
  state:
    count = 0
  view:
    column:
      platformControl count
      text count:
        key: "count"

component DateForm:
  state:
    day = date(2026, 7, 18)
  view:
    column:
      datePicker day, earliest = date(2026, 7, 17), latest = date(2026, 7, 20)
      text $day:
        key: "chosen"

suite "component contracts and date picker":
  test "selects the override for the requested platform or the shared body":
    let runtime = newRuntime(app(ContractUse))
    defer: runtime.closeRuntime()
    when defined(leafHeadlessOnly):
      check runtime.find("platform").node.text == "headless override"
    else:
      check runtime.find("platform").node.text == "shared"
    discard runtime.dispatch("platform", Event(kind: click))
    when defined(leafHeadlessOnly):
      check runtime.find("count").node.text == "4"
    else:
      check runtime.find("count").node.text == "2"

  test "invalid and cancelled dates do not write; confirming publishes the date":
    let runtime = newRuntime(app(DateForm))
    defer: runtime.closeRuntime()
    discard runtime.dispatch("date-open", Event(kind: click))
    discard runtime.dispatch("date-draft", Event(kind: change, value: "2026-07-16"))
    check runtime.find("date-confirm").node.disabled
    discard runtime.dispatch("date-draft", Event(kind: change, value: "2026-07-21"))
    check runtime.find("date-confirm").node.disabled
    discard runtime.dispatch("date-draft", Event(kind: change, value: "2026-02-30"))
    check runtime.find("date-confirm").node.disabled
    discard runtime.dispatch("date-draft", Event(kind: change, value: "2026-07-20"))
    check runtime.find("chosen").node.text == "2026-07-18"
    discard runtime.dispatch("date-cancel", Event(kind: click))
    check runtime.find("chosen").node.text == "2026-07-18"
    discard runtime.dispatch("date-open", Event(kind: click))
    check runtime.find("date-draft").node.text == "2026-07-18"
    discard runtime.dispatch("date-draft", Event(kind: change, value: "2026-07-17"))
    discard runtime.dispatch("date-confirm", Event(kind: click))
    check runtime.find("chosen").node.text == "2026-07-17"


component LeapForm:
  state:
    day = date(2028, 2, 28)
  view:
    column:
      datePicker day, earliest = date(2028, 2, 28), latest = date(2028, 3, 1)
      text $day:
        key: "chosen"

suite "date picker calendar navigation":
  test "step through leap day within bounds without writing until confirmation":
    let runtime = newRuntime(app(LeapForm))
    defer: runtime.closeRuntime()
    discard runtime.dispatch("date-open", Event(kind: click))
    check runtime.find("date-previous").node.disabled
    check runtime.dispatch("date-next", Event(kind: click))
    check runtime.find("date-draft").node.text == "2028-02-29"
    check runtime.dispatch("date-next", Event(kind: click))
    check runtime.find("date-next").node.disabled
    check runtime.find("date-draft").node.text == "2028-03-01"
    check runtime.find("chosen").node.text == "2028-02-28"
    discard runtime.dispatch("date-confirm", Event(kind: click))
    check runtime.find("chosen").node.text == "2028-03-01"

contract MissingContract:
  model value: int
implement MissingContract, platform = ios:
  view:
    text value

static:
  doAssert not compiles(block:
    component LiteralModel:
      view:
        stepper 1)
  doAssert not compiles(block:
    component ConstantField:
      view:
        textField "fixed")
  doAssert not compiles(block:
    component ExpressionModel:
      state:
        guests = 1
      view:
        stepper guests + 1)
  doAssert not compiles(block:
    component ReadOnlySource:
      prop initial: int = 1
      view:
        stepper initial)
  doAssert not compiles(block:
    component WrongType:
      state:
        name = "Ada"
      view:
        stepper name)
  doAssert not compiles(block:
    component AssignProp:
      prop maximum: int = 8
      view:
        button "bad":
          maximum = 1)
  doAssert not compiles(block:
    component IncrementProp:
      prop maximum: int = 8
      view:
        button "bad":
          max_imum += 1)
  doAssert not compiles(block:
    component WriteThroughVar:
      prop maximum: int = 8
      view:
        button "bad":
          inc maximum)
  doAssert not compiles(block:
    component BadClick:
      view:
        button "bad":
          onClick:
            discard
          discard)
  when not defined(ios):
    doAssert not compiles(block:
      component MissingImplementation:
        state:
          amount = 0
        view:
          missingContract amount)
