import std/[unittest, tables, monotimes, times, os, osproc, streams, strutils, unicode]
import leaf/[core, widgets, components, component_description, task_contracts]

proc errorLogMessage(kind: string): string =
  case kind
  of "cjk": repeat("界", 2000)
  of "emoji-split": repeat('a', 4093) & "😀tail"
  of "emoji-exact": repeat("😀", 1025)
  of "invalid": "bad:\xFF:\xF0\x9F"
  of "scalars": "\xED\xA0\x80|\xF4\x90\x80\x80|\xE0\x80\x80"
  else: raise newException(ValueError, "unknown error-log fixture")

proc runErrorLogChild(phase, kind: string) =
  let message = errorLogMessage(kind)
  var enabled = false
  let scope: ExecutionScope = proc(body: proc() {.closure.}) =
    if enabled and phase == "scope-entry": raise newException(ValueError, message)
    body()
    if enabled and phase == "scope-exit": raise newException(ValueError, message)
  let Hook = defineComponent[int, int]("LifecycleErrorLogChild",
    proc(ctx: MountContext, props: int): int =
      ctx.onMount(proc(event: LifecycleContext) =
        if phase == "callback": raise newException(ValueError, message))
      0,
    proc(ctx: ComponentContext, props, model: int): UiDescription = host(text("log")))
  let runtime = newRuntime(componentApplication(component(Hook, 0), "log child", executionScope = scope))
  enabled = true
  let report = runtime.pumpTasks()
  doAssert report.failed == 1
  doAssert report.callbacks == (if phase == "scope-entry": 0 else: 1)
  doAssert report.pending == (phase == "scope-entry")

# Each subprocess runs the real pump/error path, with stderr and stdout kept
# separate. It exits before unittest suites, so no test-runner text is captured.
let fixtureArgs = commandLineParams()
if fixtureArgs.len == 3 and fixtureArgs[0] == "--lifecycle-error-log":
  runErrorLogChild(fixtureArgs[1], fixtureArgs[2])
  quit(0)

proc captureFailureLog(phase, kind: string): tuple[output: string, exitCode: int] =
  let child = startProcess(getAppFilename(), args = @["--lifecycle-error-log", phase, kind], options = {})
  try:
    result.output = child.errorStream.readAll()
    result.exitCode = child.waitForExit()
    doAssert child.outputStream.readAll().len == 0
  finally: child.close()

type
  Observation = object
    label: string
    phase: LifecyclePhase
    owner, revision: uint64
  Fixture = ref object
    events: seq[Observation]
    states: Table[string, State[int]]
    contexts: seq[MountContext]
    visible, badRender: bool
    duplicate, borrowClosed, failInit: bool
    hooks: int
    childRenders: int

proc record(f: Fixture, label: string, ctx: LifecycleContext) =
  f.events.add Observation(label: label, phase: ctx.phase,
    owner: taskOwnerInternal(ctx.taskScope), revision: ctx.acceptedRevision)
  doAssert taskDomainInternal(ctx.taskScope) != nil

proc names(f: Fixture): seq[string] =
  for event in f.events: result.add($event.phase & ":" & event.label)

proc install(f: Fixture, ctx: MountContext, name: string) =
  if f.borrowClosed: f.contexts[0].onMount(proc(event: LifecycleContext) = discard)
  f.contexts.add(ctx)
  if f.hooks > 0:
    ctx.onMount(proc(event: LifecycleContext) = f.record(name, event))
    if f.duplicate: ctx.onMount(proc(event: LifecycleContext) = discard)
  if f.hooks > 1: ctx.onDispose(proc(event: LifecycleContext) = f.record(name, event))
  if f.hooks > 2: ctx.onActivate(proc(event: LifecycleContext) = f.record(name, event))
  if f.hooks > 3: ctx.onDeactivate(proc(event: LifecycleContext) = f.record(name, event))
  if f.failInit: fail("initializer rejected after hook registration")

proc tree(f: Fixture, label = "parent"): UiDescription =
  let Leaf = defineComponent[string, State[int]]("LifecycleLeaf",
    proc(ctx: MountContext, name: string): State[int] =
      f.install(ctx, name)
      result = ctx.state(0)
      f.states[name] = result,
    proc(ctx: ComponentContext, name: string, state: State[int]): UiDescription =
      inc f.childRenders
      if f.badRender: fail("candidate render rejected")
      host(text($ctx.value(state), key = name)))
  let Parent = defineComponent[string, int]("LifecycleParent",
    proc(ctx: MountContext, name: string): int =
      f.install(ctx, name)
      0,
    proc(ctx: ComponentContext, name: string, model: int): UiDescription =
      if f.visible:
        # Deliberately reverse lexical key order to catch Table/key sorting.
        hostShell(column(@[]), @[
          component(Leaf, name & "-z", key = "z"),
          component(Leaf, name & "-a", key = "a")])
      else: host(text("empty")))
  component(Parent, label)

proc drain(runtime: Runtime) =
  for i in 0..<2000:
    if not runtime.pumpTasks().pending: return
  fail("lifecycle pump failed to drain")

suite "accepted component lifecycle":
  test "mount waits for ordinary pump and follows parent then tree sibling order":
    let f = Fixture(visible: true, hooks: 4)
    let runtime = newRuntime(componentApplication(f.tree(), "lifecycle"))
    check f.events.len == 0
    let before = runtime.acceptedRevision
    runtime.drain()
    check f.names == @["mount:parent", "mount:parent-z", "mount:parent-a"]
    for event in f.events:
      check event.owner != 0
      check event.revision == 1
    check f.events[0].owner != f.events[1].owner
    check runtime.acceptedRevision == before
    let renders = runtime.updateStats.componentRenders
    let exports = runtime.updateStats.snapshotExports
    check not runtime.pumpTasks().pending
    check runtime.updateStats.componentRenders == renders
    check runtime.updateStats.snapshotExports == exports

  test "dispose follows accepted children order and State is dead before callback":
    let f = Fixture(visible: true, hooks: 4)
    let runtime = newRuntime(componentApplication(f.tree(), "dispose"))
    runtime.drain()
    f.events.setLen(0)
    f.visible = false
    discard runtime.refresh()
    check f.events.len == 0
    check f.states["parent-z"].set(1) == StateWriteResult.disposed
    runtime.drain()
    check f.names == @["dispose:parent-z", "dispose:parent-a"]
    for event in f.events: check event.revision == 2

  test "closed or failed MountContext cannot borrow a later owner's open frame":
    let f = Fixture(visible: false, hooks: 1)
    let runtime = newRuntime(componentApplication(f.tree(), "closed frame"))
    runtime.drain()
    expect UiError: f.contexts[0].onMount(proc(ctx: LifecycleContext) = discard)
    f.visible = true
    f.borrowClosed = true
    expect UiError: discard runtime.refresh()
    check runtime.acceptedRevision == 1
    check f.events.len == 1
    f.borrowClosed = false
    f.failInit = true
    expect UiError: discard runtime.refresh()
    let failed = f.contexts[^1]
    expect UiError: failed.onDispose(proc(ctx: LifecycleContext) = discard)
    f.failInit = false
    discard runtime.refresh()
    runtime.drain()
    check f.names == @["mount:parent", "mount:parent-z", "mount:parent-a"]

  test "duplicate registration and nil callback reject initialization":
    let f = Fixture(visible: false, hooks: 1, duplicate: true)
    expect UiError: discard newRuntime(componentApplication(f.tree(), "duplicate"))
    check f.events.len == 0
    let Invalid = defineComponent[int, int]("NilLifecycleHook",
      proc(ctx: MountContext, props: int): int =
        ctx.onMount(nil)
        0,
      proc(ctx: ComponentContext, props, model: int): UiDescription = host(text("bad")))
    expect UiError: discard newRuntime(componentApplication(component(Invalid, 0), "nil hook"))

  test "rejected render and backend candidate never publish mount callbacks":
    let f = Fixture(visible: false, hooks: 4)
    let runtime = newRuntime(componentApplication(f.tree(), "rejection"))
    runtime.drain()
    f.events.setLen(0)
    f.visible = true
    f.badRender = true
    expect UiError: discard runtime.refresh()
    runtime.drain()
    check f.events.len == 0
    f.badRender = false
    var rejectBackend = false
    runtime.setCommitter(proc(accepted, candidate: Runtime) =
      if rejectBackend: fail("backend rejected"))
    rejectBackend = true
    expect UiError: discard runtime.refresh()
    runtime.drain()
    check f.events.len == 0
    check runtime.acceptedRevision == 1
    check f.states["parent-z"].set(1) == StateWriteResult.disposed
    runtime.setCommitter(nil)
    discard runtime.refresh()
    runtime.drain()
    check f.names == @["mount:parent-z", "mount:parent-a"]

  test "first hook charges hook and implicit scope once, unused owner costs nothing":
    var costs: seq[int]
    for count in 0..2:
      let f = Fixture(visible: false, hooks: count)
      let runtime = newRuntime(componentApplication(f.tree(), "cost"))
      costs.add(ownedDescriptionBytes(f.contexts[0]))
      runtime.drain()
    check costs == @[0, 256, 384]

  test "scope refusal preserves callbacks, callback State writes commit and errors do not replay":
    var refuse, exitError: bool
    var events: seq[string]
    var state: State[int]
    let scope: ExecutionScope = proc(body: proc() {.closure.}) =
      if refuse: fail("scope entry refused")
      body()
      if exitError: fail("scope exit failed")
    let Writer = defineComponent[int, State[int]]("LifecycleWriter",
      proc(ctx: MountContext, props: int): State[int] =
        result = ctx.state(0)
        state = result
        ctx.onMount(proc(event: LifecycleContext) =
          events.add("mount")
          discard state.set(7)),
      proc(ctx: ComponentContext, props: int, value: State[int]): UiDescription =
        host(text($ctx.value(value), key = "value")))
    let runtime = newRuntime(componentApplication(component(Writer, 0), "writer", executionScope = scope))
    refuse = true
    check runtime.pumpTasks().pending
    check events.len == 0
    check state.read() == 0
    refuse = false
    exitError = true
    let report = runtime.pumpTasks()
    check report.callbacks == 1
    check report.failed == 1
    check state.read() == 7
    check events == @["mount"]
    exitError = false
    runtime.drain()
    check events == @["mount"]

  test "callback failure continues remaining owners and pumping is not reentrant":
    var events: seq[string]
    var runtime: Runtime
    let Hook = defineComponent[string, int]("FailingLifecycleHook",
      proc(ctx: MountContext, name: string): int =
        ctx.onMount(proc(event: LifecycleContext) =
          events.add(name)
          if name == "first":
            expect UiError: discard runtime.pumpTasks()
            fail("callback failed"))
        0,
      proc(ctx: ComponentContext, name: string, model: int): UiDescription = host(text(name)))
    runtime = newRuntime(componentApplication(hostShell(column(@[]), @[
      component(Hook, "first", key = "z"), component(Hook, "second", key = "a")]), "callbacks"))
    let report = runtime.pumpTasks()
    check report.callbacks == 2
    check report.failed == 1
    check events == @["first", "second"]
    runtime.drain()
    check events == @["first", "second"]

  test "accepted mount records survive candidate scope-exit failure and deliver once":
    let f = Fixture(visible: false, hooks: 4)
    var rejectExit = false
    let scope: ExecutionScope = proc(body: proc() {.closure.}) =
      body()
      if rejectExit: fail("accepted candidate scope exit")
    let runtime = newRuntime(componentApplication(f.tree(), "accepted cleanup", executionScope = scope))
    runtime.drain()
    f.events.setLen(0)
    f.visible = true
    rejectExit = true
    expect UiError: discard runtime.refresh()
    check runtime.acceptedRevision == 2
    check f.events.len == 0
    rejectExit = false
    runtime.drain()
    check f.names == @["mount:parent-z", "mount:parent-a"]
    for event in f.events: check event.revision == 2
    runtime.drain()
    check f.events.len == 2

  test "enter callbacks revalidate owner after application scope entry":
    var events: seq[string]
    var visible = true
    var unmountOnEntry = false
    var runtime: Runtime
    let scope: ExecutionScope = proc(body: proc() {.closure.}) =
      if unmountOnEntry:
        unmountOnEntry = false
        visible = false
        discard runtime.refresh()
      body()
    let Child = defineComponent[int, int]("LifecycleScopeChangedChild",
      proc(ctx: MountContext, props: int): int =
        ctx.onMount(proc(event: LifecycleContext) = events.add("mount"))
        ctx.onDispose(proc(event: LifecycleContext) = events.add("dispose"))
        0,
      proc(ctx: ComponentContext, props, model: int): UiDescription = host(text("child")))
    let Root = defineComponent[int, int]("LifecycleScopeChangedRoot",
      proc(ctx: MountContext, props: int): int = 0,
      proc(ctx: ComponentContext, props, model: int): UiDescription =
        if visible: component(Child, 0) else: host(text("gone")))
    runtime = newRuntime(componentApplication(component(Root, 0), "scope change", executionScope = scope))
    unmountOnEntry = true
    runtime.drain()
    check events == @["dispose"]

  test "each pump delivers at most 64 records and stops starting callbacks after four milliseconds":
    var calls = 0
    var slow = false
    let Hook = defineComponent[int, int]("LifecyclePumpBudgetHook",
      proc(ctx: MountContext, props: int): int =
        ctx.onMount(proc(event: LifecycleContext) =
          inc calls
          if slow:
            let until = getMonoTime() + initDuration(milliseconds = 8)
            while getMonoTime() < until: discard)
        0,
      proc(ctx: ComponentContext, props, model: int): UiDescription = host(text($props)))
    var children: seq[UiDescription]
    for i in 0..<80: children.add(component(Hook, i, key = $i))
    let runtime = newRuntime(componentApplication(hostShell(column(@[]), children), "pump quota"))
    let report = runtime.pumpTasks()
    check report.pending
    check report.callbacks > 0
    check report.callbacks <= 64
    runtime.drain()
    check calls == 80
    calls = 0
    slow = true
    children.setLen(0)
    for i in 0..<3: children.add(component(Hook, i, key = $i))
    let timed = newRuntime(componentApplication(hostShell(column(@[]), children), "pump time"))
    check timed.pumpTasks().callbacks == 1
    check calls == 1
    timed.drain()
    check calls == 3

suite "lifecycle admission budgets":
  test "pending events share the description budget and reject navigation before backend apply":
    var navigation: ComponentRouter
    var padding = 0
    var events: seq[string]
    var refused = false
    var applies = 0
    let scope: ExecutionScope = proc(body: proc() {.closure.}) =
      if refused: fail("pump entry refused")
      body()
    let Page = defineComponent[string, int]("LifecycleByteBudgetPage",
      proc(ctx: MountContext, name: string): int =
        ctx.accountOwnedDescriptionBytes(padding)
        ctx.onMount(proc(event: LifecycleContext) = events.add("mount:" & name))
        ctx.onDispose(proc(event: LifecycleContext) = events.add("dispose:" & name))
        0,
      proc(ctx: ComponentContext, name: string, model: int): UiDescription = host(text(name, key = "budget-page")))
    let Navigator = defineComponent[int, int]("LifecycleByteBudgetNavigator",
      proc(ctx: MountContext, props: int): int =
        navigation = newComponentRouter(ctx, @[
          Route(name: "A", path: "/A", page: "A", view: "main"),
          Route(name: "B", path: "/B", page: "B", view: "main")], @[
          ComponentPageDefinition(name: "A", views: @["main"], retention: PageRetention.disposeOnLeave,
            build: proc(view: string): UiDescription = component(Page, "A")),
          ComponentPageDefinition(name: "B", views: @["main"], retention: PageRetention.disposeOnLeave,
            build: proc(view: string): UiDescription = component(Page, "B"))], "A")
        0,
      proc(ctx: ComponentContext, props, model: int): UiDescription = renderPage(ctx, navigation))
    let probe = newRuntime(componentApplication(component(Navigator, 0), "bytes", executionScope = scope))
    padding = MaxTreeBytes - probe.stats.treeBytes
    let runtime = newRuntime(componentApplication(component(Navigator, 0), "bytes", executionScope = scope))
    check runtime.stats.treeBytes == MaxTreeBytes
    runtime.setCommitter(proc(accepted, candidate: Runtime) = inc applies)
    let beforeApplies = applies
    refused = true
    check runtime.pumpTasks().pending
    check runtime.pumpTasks().pending
    refused = false
    expect UiError: runtime.uiTask(proc() = discard navigation.navigate("B"))
    check applies == beforeApplies
    check navigation.currentRoute.name == "A"
    check runtime.acceptedRevision == 1
    check runtime.find("budget-page").node.text == "A"
    check events.len == 0
    runtime.drain()
    check events == @["mount:A"]
    # The rejected new owner's callback did not leak. Free another event's
    # worth of description capacity and accept the replacement normally.
    padding -= 128
    runtime.uiTask(proc() = discard navigation.navigate("B"))
    runtime.drain()
    check events == @["mount:A", "dispose:A", "mount:B"]
    check runtime.stats.treeBytes <= MaxTreeBytes

  test "scope refusal backlog remains bounded at 40000 records and preserves old route":
    var navigation: ComponentRouter
    var refuse = false
    var callbacks = 0
    let scope: ExecutionScope = proc(body: proc() {.closure.}) =
      if refuse: fail("pump refused")
      body()
    let Leaf = defineComponent[int, int]("LifecycleCountBudgetLeaf",
      proc(ctx: MountContext, props: int): int =
        ctx.onMount(proc(event: LifecycleContext) = inc callbacks)
        ctx.onActivate(proc(event: LifecycleContext) = inc callbacks)
        ctx.onDeactivate(proc(event: LifecycleContext) = inc callbacks)
        0,
      proc(ctx: ComponentContext, props, model: int): UiDescription = host(text($props)))
    proc page(view: string): UiDescription =
      var children: seq[UiDescription]
      for i in 0..<2000: children.add(component(Leaf, i, key = $i))
      hostShell(column(@[]), children)
    let Navigator = defineComponent[int, int]("LifecycleCountBudgetNavigator",
      proc(ctx: MountContext, props: int): int =
        navigation = newComponentRouter(ctx, @[
          Route(name: "A", path: "/A", page: "A", view: "main"),
          Route(name: "B", path: "/B", page: "B", view: "main")], @[
          ComponentPageDefinition(name: "A", views: @["main"], build: page),
          ComponentPageDefinition(name: "B", views: @["main"], build: page)], "A")
        0,
      proc(ctx: ComponentContext, props, model: int): UiDescription = renderPage(ctx, navigation))
    let runtime = newRuntime(componentApplication(component(Navigator, 0), "count", executionScope = scope))
    runtime.drain()
    callbacks = 0
    # Ten transitions reserve exactly 40000 records. Exit callbacks remain
    # valid even across later activity epochs, so every pump really attempts
    # (and is refused) application scope entry rather than just dropping stale mounts.
    for round in 0..<10:
      runtime.uiTask(proc() = discard navigation.navigate(if round mod 2 == 0: "B" else: "A"))
      refuse = true
      let report = runtime.pumpTasks()
      check report.pending
      check report.failed == 1
      refuse = false
    check callbacks == 0
    let revision = runtime.acceptedRevision
    expect UiError: runtime.uiTask(proc() = discard navigation.navigate("B"))
    check runtime.acceptedRevision == revision
    check navigation.currentRoute.name == "A"
    check runtime.stats.treeBytes <= MaxTreeBytes
    runtime.drain()
    # Old enter records are stale; all 10 exits plus the latest enter survive.
    check callbacks == 22000
    runtime.uiTask(proc() = discard navigation.navigate("B"))
    runtime.drain()
    check navigation.currentRoute.name == "B"

suite "lifecycle error log encoding":
  for phase in ["callback", "scope-entry", "scope-exit"]:
    test phase & " logs bounded complete Unicode scalars and keeps event metadata":
      let cases = @[
        ("cjk", repeat("界", 1365)),
        ("emoji-split", repeat('a', 4093)),
        ("emoji-exact", repeat("😀", 1024)),
        ("invalid", "bad:�:��"),
        ("scalars", "���|����|���")]
      for (kind, expected) in cases:
        checkpoint("real stderr fixture: " & phase & "/" & kind)
        let captured = captureFailureLog(phase, kind)
        require captured.exitCode == 0
        let prefix = "leaf: lifecycle owner=1 revision=1 phase=mount: "
        require captured.output.startsWith(prefix)
        let message = captured.output[prefix.len..^1].strip(chars = {'\r', '\n'})
        check message.len <= 4096
        check validateUtf8(message) == -1
        var validScalars = true
        for rune in message.runes:
          if int(rune) < 0 or int(rune) > 0x10FFFF or int(rune) in 0xD800..0xDFFF:
            validScalars = false
        check validScalars
        let matchesExpected = message == expected
        check matchesExpected
