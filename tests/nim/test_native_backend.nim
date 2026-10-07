import std/[unittest, json, tables, options, strutils]
import leaf/[core, widgets, styles, backend, backend_session]
import leaf/backends/headless

proc app(render: RenderProc): Application =
  Application(title: "backend", width: 800, height: 600, render: render)

proc makeHost(sessionId = 7'u64, mountGeneration = 1'u64): HostContext =
  HostContext(sessionId: sessionId, mountGeneration: mountGeneration,
    contentWidth: 800, contentHeight: 600, scale: 1.0)

proc userEvent(session: BackendSession, handle: NodeHandle, sequence: uint64,
               event: Event, observedRevision = 0'u64): EventEnvelope =
  EventEnvelope(session: session.sessionId, mountGeneration: session.mountGeneration,
    handle: handle, sequence: sequence, observedRevision: observedRevision,
    source: sourceUser, event: event)

suite "Recording backend sessions":
  test "stable input unrelated update creates no entities":
    var label = "A"
    proc render(ctx: BuildContext): Node =
      column(@[
        text(label, key = "label"),
        input("x", key = "field"),
        button("go", key = "go", onClick = proc(e: Event) = label = "B")], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let fieldHandle = session.handleFor(runtime.find("field").id)
    recording.inputState[fieldHandle] = "select:1-3"
    let createsBefore = recording.creates

    check runtime.dispatch("go", Event(kind: click))
    check runtime.find("label").node.text == "B"
    check recording.inputState.getOrDefault(fieldHandle) == "select:1-3"
    check recording.creates == createsBefore
    check session.acceptedEntities.hasKey(fieldHandle)

  test "prepare rejection publishes nothing":
    var count = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let createsBefore = recording.creates
    let before = runtime.snapshot.toJson()
    let revisionBefore = runtime.acceptedRevision

    recording.failPrepare = true
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    check runtime.snapshot.toJson() == before
    check runtime.acceptedRevision == revisionBefore
    check recording.creates == createsBefore
    check recording.discardCalls > 0
    check not session.faulted
    check not runtime.eventsFrozen

  test "partial apply restores accepted tree":
    var a, b = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($a, key = "a"), text($b, key = "b"),
        button("go", key = "go", onClick = proc(e: Event) =
          inc a; inc b)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let generationBefore = session.mountGeneration
    let entitiesBefore = recording.entities.len

    recording.failApplyAt = 2
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    check runtime.find("a").node.text == "0"
    check runtime.find("b").node.text == "0"
    check recording.restoreCalls > 0
    check session.mountGeneration == generationBefore + 1
    check recording.entities.len == entitiesBefore
    check not session.faulted

    recording.failApplyAt = 0
    check runtime.dispatch("go", Event(kind: click))
    check runtime.find("a").node.text == "2"
    check runtime.find("b").node.text == "2"

  test "failed restore blocks events":
    var count = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    recording.failApply = true
    recording.failRestore = true
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    check session.faulted
    check runtime.eventsFrozen
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    let handle = session.handleFor(runtime.find("go").id)
    check not session.enqueue(userEvent(session, handle, 1, Event(kind: click)))

  test "setter notifications never recurse":
    var count = 0
    var setterCalls = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    recording.onSetter = proc(handle: NodeHandle) =
      inc setterCalls
      discard session.enqueue(EventEnvelope(session: session.sessionId,
        mountGeneration: session.mountGeneration, handle: handle, sequence: 1,
        observedRevision: runtime.acceptedRevision, source: sourceSetter,
        event: Event(kind: change)))
    check runtime.dispatch("go", Event(kind: click))
    check setterCalls > 0
    check session.queuedEvents == 0

  test "queued events are revalidated":
    var clicks = 0
    var hasHandler = true
    proc render(ctx: BuildContext): Node =
      let callback = if hasHandler: (proc(e: Event) = inc clicks) else: nil
      column(@[
        button("go", key = "go", onClick = callback),
        button("off", key = "off", onClick = proc(e: Event) = hasHandler = false)],
        key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let handle = session.handleFor(runtime.find("go").id)
    check session.enqueue(userEvent(session, handle, 1, Event(kind: click)))
    check runtime.dispatch("off", Event(kind: click))
    session.drainEvents()
    check clicks == 0

  test "old revision listener remains usable":
    var clicks = 0
    proc render(ctx: BuildContext): Node =
      button("go", key = "go", onClick = proc(e: Event) = inc clicks)

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let handle = session.handleFor(runtime.find("go").id)
    check runtime.dispatch("go", Event(kind: click))
    check clicks == 1
    check runtime.acceptedRevision > 1
    check session.enqueue(userEvent(session, handle, 2, Event(kind: click),
      observedRevision = 1))
    session.drainEvents()
    check clicks == 2

  test "removed handle event is rejected":
    var showNote = true
    proc render(ctx: BuildContext): Node =
      var children: seq[Node]
      if showNote: children.add(text("note", key = "note"))
      children.add(button("hide", key = "hide", onClick = proc(e: Event) =
        showNote = false))
      column(children, key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let noteHandle = session.handleFor(runtime.find("note").id)
    check runtime.dispatch("hide", Event(kind: click))
    check not session.enqueue(userEvent(session, noteHandle, 1, Event(kind: click)))

  test "dispose invalidates session":
    var clicks = 0
    proc render(ctx: BuildContext): Node =
      button("go", key = "go", onClick = proc(e: Event) = inc clicks)

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let handle = session.handleFor(runtime.find("go").id)
    dispose(session)
    check recording.disposeCalls == 1
    check not session.enqueue(userEvent(session, handle, 1, Event(kind: click)))
    session.drainEvents()
    check clicks == 0
    dispose(session)
    check recording.disposeCalls == 1
    check runtime.dispatch("go", Event(kind: click))
    check clicks == 1

  test "drain keeps accepted tree when commit fails and does not repeat callbacks":
    var count = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let handle = session.handleFor(runtime.find("go").id)
    check session.enqueue(userEvent(session, handle, 1, Event(kind: click)))
    recording.failPrepare = true
    session.drainEvents()
    check count == 1
    check runtime.find("count").node.text == "0"
    check session.queuedEvents == 0
    recording.failPrepare = false
    session.drainEvents()
    check count == 1

  test "initial apply failure leaves no session":
    proc render(ctx: BuildContext): Node = button("go", key = "go")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    recording.failApply = true
    expect UiError:
      discard attachBackend(runtime, recording.backend, makeHost())
    check recording.disposeCalls == 1
    let retry = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, retry.backend, makeHost())
    check session.acceptedEntities.len > 0
    dispose(session)

  test "capabilities are validated before any apply":
    proc render(ctx: BuildContext): Node = progress(50.0)
    var capabilities = fullCapabilities()
    capabilities.kinds = capabilities.kinds - {NodeKind.progress}
    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(capabilities)
    expect UiError:
      discard attachBackend(runtime, recording.backend, makeHost())
    check recording.creates == 0
    check recording.applyCalls == 0

  test "100000 rows mount only viewport":
    var items: seq[string]
    for index in 0..<100_000: items.add("item-" & $index)
    var builds = 0
    proc render(ctx: BuildContext): Node =
      column(@[virtualList("list", items, proc(index: int): Node =
        inc builds
        text(items[index], key = "row"))], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let listHandle = session.handleFor(runtime.find("list").id)
    check builds == 0

    var source = runtime.find("list").node.listSource
    discard session.requestRows(listHandle, source.generation, 0, 20)
    check builds == 20
    check runtime.stats.builtItems == 20
    check recording.entities.len == 22

    source = runtime.find("list").node.listSource
    discard session.requestRows(listHandle, source.generation, 20, 40)
    check builds == 40
    check recording.entities.len == 22

    source = runtime.find("list").node.listSource
    discard session.requestRows(listHandle, source.generation, 0, 20)
    check builds == 40
    check runtime.stats.cachedItems <= 128

  test "reordered source follows item keys":
    var items = @["a", "b", "c", "d"]
    var clickCounts: Table[string, int]
    proc render(ctx: BuildContext): Node =
      column(@[
        virtualList("list", items, proc(index: int): Node =
          let item = items[index]
          button(item, key = "row", onClick = proc(e: Event) =
            clickCounts[item] = clickCounts.getOrDefault(item) + 1)),
        button("reorder", key = "reorder", onClick = proc(e: Event) =
          items = @["c", "a", "b", "d"])], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let listHandle = session.handleFor(runtime.find("list").id)
    var source = runtime.find("list").node.listSource
    discard session.requestRows(listHandle, source.generation, 0, 2)

    check runtime.dispatch("reorder", Event(kind: click))
    let list = runtime.find("list")
    check list.children.len == 2
    var visibleKeys: seq[string]
    for child in list.children:
      visibleKeys.add(list.node.listSource.itemKey(child.listIndex))
    check visibleKeys == @["a", "b"]
    for child in list.children:
      check child.node.text == list.node.listSource.itemKey(child.listIndex)

    discard runtime.dispatch(list.children[0].id, Event(kind: click))
    check clickCounts.getOrDefault("a") == 1
    check clickCounts.getOrDefault("c") == 0

  test "failed row commit keeps accepted callbacks":
    var items = @["a", "b", "c"]
    var rowClicks = 0
    proc render(ctx: BuildContext): Node =
      column(@[virtualList("list", items, proc(index: int): Node =
        button(items[index], key = "row", onClick = proc(e: Event) =
          inc rowClicks))], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let listHandle = session.handleFor(runtime.find("list").id)
    var source = runtime.find("list").node.listSource
    discard session.requestRows(listHandle, source.generation, 0, 2)
    let before = runtime.snapshot.toJson()
    check runtime.find("list").children.len == 2

    recording.failApply = true
    source = runtime.find("list").node.listSource
    expect UiError:
      discard session.requestRows(listHandle, source.generation, 0, 3)
    check runtime.snapshot.toJson() == before
    check runtime.find("list").children.len == 2
    check session.acceptedEntities.hasKey(listHandle)

    recording.failApply = false
    discard runtime.dispatch(runtime.find("list").children[0].id, Event(kind: click))
    check rowClicks == 1

  test "obsolete source generation is rejected":
    var items = @["a", "b", "c"]
    proc render(ctx: BuildContext): Node =
      column(@[
        virtualList("list", items, proc(index: int): Node =
          text(items[index], key = "row")),
        button("touch", key = "touch", onClick = proc(e: Event) = discard)],
        key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let listHandle = session.handleFor(runtime.find("list").id)
    let staleGeneration = runtime.find("list").node.listSource.generation
    check runtime.dispatch("touch", Event(kind: click))
    expect UiError:
      discard session.requestRows(listHandle, staleGeneration, 0, 2)

  test "capability warning emitted once":
    var label = "A"
    proc render(ctx: BuildContext): Node =
      column(@[
        text(label, key = "label", styles = style({"background": "#ffffff"})),
        button("go", key = "go", onClick = proc(e: Event) = label = "B")],
        key = "root")

    var capabilities = fullCapabilities()
    capabilities.decorations = capabilities.decorations - {dfBackground}
    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(capabilities)
    let session = attachBackend(runtime, recording.backend, makeHost(), compatible)
    check session.capabilityIssues.len == 1
    check session.capabilityIssues[0].property == "background"
    check runtime.dispatch("go", Event(kind: click))
    check runtime.dispatch("go", Event(kind: click))
    check session.capabilityIssues.len == 1

    let secondRuntime = newRuntime(app(render))
    let secondRecording = newRecordingBackend(capabilities)
    let second = attachBackend(secondRuntime, secondRecording.backend, makeHost(),
      compatible)
    check second.capabilityIssues.len == 1

  test "unsupported decoration stays effective and produces no spurious updates":
    var decorated = true
    proc render(ctx: BuildContext): Node =
      let styles = if decorated: style({"background": "#ffffff"}) else: default(Styles)
      column(@[
        text("hi", key = "label", styles = styles),
        button("go", key = "go", onClick = proc(e: Event) = decorated = false)],
        key = "root")

    var capabilities = fullCapabilities()
    capabilities.decorations = capabilities.decorations - {dfBackground}
    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(capabilities)
    let session = attachBackend(runtime, recording.backend, makeHost(), compatible)
    let labelHandle = session.handleFor(runtime.find("label").id)
    check session.acceptedEntities[labelHandle].props.decoration.background.isNone

    let updatesBefore = recording.updates
    check runtime.dispatch("go", Event(kind: click))
    check recording.updates == updatesBefore
  test "failed second attach keeps the existing session hooks":
    var count = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")

    let runtime = newRuntime(app(render))
    let first = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, first.backend, makeHost())
    let applyCalls = first.applyCalls
    let second = newRecordingBackend(fullCapabilities())
    expect UiError:
      discard attachBackend(runtime, second.backend, makeHost(sessionId = 8))
    check second.applyCalls == 0
    check runtime.dispatch("go", Event(kind: click))
    check runtime.find("count").node.text == "1"
    check first.applyCalls > applyCalls
    dispose(session)

  test "old session dispose does not remove a newer session hook":
    var count = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")

    let runtime = newRuntime(app(render))
    let recA = newRecordingBackend(fullCapabilities())
    let sessionA = attachBackend(runtime, recA.backend, makeHost())
    runtime.setCommitter(nil)
    runtime.setPreparer(nil)
    let recB = newRecordingBackend(fullCapabilities())
    let sessionB = attachBackend(runtime, recB.backend, makeHost(sessionId = 9))
    dispose(sessionA)
    check runtime.dispatch("go", Event(kind: click))
    check runtime.find("count").node.text == "1"
    check recB.applyCalls > 1
    dispose(sessionB)

  test "dispose during a commit defers safely and remains retryable":
    var count = 0
    var sessionRef: BackendSession
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) =
          inc count
          dispose(sessionRef))], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    sessionRef = session
    var raised = false
    try:
      discard runtime.dispatch("go", Event(kind: click))
    except UiError:
      raised = true
    check not raised
    check recording.disposeCalls == 0
    check not session.disposed
    dispose(session)
    check session.disposed
    check recording.disposeCalls == 1

  test "backend dispose failure stays retryable":
    proc render(ctx: BuildContext): Node = button("go", key = "go")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    recording.failDispose = true
    expect UiError:
      dispose(session)
    check not session.disposed
    check recording.disposeCalls == 1
    recording.failDispose = false
    dispose(session)
    check session.disposed
    check recording.disposeCalls == 2

  test "busy drain keeps queued user events for a later drain":
    var count = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let handle = session.handleFor(runtime.find("go").id)
    var injected = false
    var duringApply = -1
    recording.onSetter = proc(h: NodeHandle) =
      if not injected:
        injected = true
        discard session.enqueue(userEvent(session, handle, 1, Event(kind: click),
          observedRevision = runtime.acceptedRevision))
        session.drainEvents()
        duringApply = session.queuedEvents
    check runtime.dispatch("go", Event(kind: click))
    check duringApply == 1
    check count == 1
    check session.queuedEvents == 1
    session.drainEvents()
    check count == 2
    check session.queuedEvents == 0

  test "viewport restore failure rejects the candidate":
    var failBuild = false
    var items = @["a", "b"]
    proc render(ctx: BuildContext): Node =
      column(@[
        virtualList("list", items, proc(index: int): Node =
          if failBuild: raise newException(UiError, "row build failed")
          text(items[index], key = "row")),
        button("go", key = "go", onClick = proc(e: Event) = discard)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let listHandle = session.handleFor(runtime.find("list").id)
    var source = runtime.find("list").node.listSource
    discard session.requestRows(listHandle, source.generation, 0, 1)
    check runtime.find("list").children.len == 1
    let before = runtime.snapshot.toJson()
    failBuild = true
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    check runtime.snapshot.toJson() == before
    check runtime.find("list").children.len == 1

  test "ancestor replacement migrates viewport tracking":
    var useRow = false
    var items = @["a", "b"]
    proc render(ctx: BuildContext): Node =
      let list = virtualList("list", items, proc(index: int): Node =
        text(items[index], key = "row"))
      let go = button("go", key = "go", onClick = proc(e: Event) = useRow = true)
      if useRow: row(@[list, go], key = "panel")
      else: column(@[list, go], key = "panel")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let listId = runtime.find("list").id
    let oldHandle = session.handleFor(listId)
    var source = runtime.find("list").node.listSource
    discard session.requestRows(oldHandle, source.generation, 0, 1)
    check runtime.find("list").children.len == 1

    check runtime.dispatch("go", Event(kind: click))
    check runtime.find("list").id == listId
    check session.handleFor(listId) != oldHandle
    check runtime.find("list").children.len == 1
    check runtime.dispatch("go", Event(kind: click))
    check runtime.find("list").children.len == 1

  test "every mandatory backend hook is validated before apply":
    proc render(ctx: BuildContext): Node = button("go", key = "go")
    for missing in ["prepare", "apply", "discardPrepared", "restore", "dispose"]:
      let runtime = newRuntime(app(render))
      let recording = newRecordingBackend(fullCapabilities())
      case missing
      of "prepare": recording.backend.prepare = nil
      of "apply": recording.backend.apply = nil
      of "discardPrepared": recording.backend.discardPrepared = nil
      of "restore": recording.backend.restore = nil
      of "dispose": recording.backend.dispose = nil
      else: discard
      expect UiError:
        discard attachBackend(runtime, recording.backend, makeHost())
      check recording.applyCalls == 0

  test "cleanup failure does not skip restore":
    var a, b = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($a, key = "a"), text($b, key = "b"),
        button("go", key = "go", onClick = proc(e: Event) =
          inc a; inc b)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    recording.failApplyAt = 2
    recording.failDiscard = true
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    check recording.restoreCalls > 0
    check runtime.find("a").node.text == "0"
    check not session.faulted

    recording.failApplyAt = 2
    recording.failDiscard = true
    recording.failRestore = true
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    check session.faulted
    check runtime.eventsFrozen

  test "prepare failure with cleanup exception keeps the primary error":
    var count = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let before = runtime.snapshot.toJson()
    recording.failPrepare = true
    recording.failDiscard = true
    var message = ""
    try:
      discard runtime.dispatch("go", Event(kind: click))
    except UiError as error:
      message = error.msg
    check "prepare failed" in message
    check "discard" in message
    check runtime.snapshot.toJson() == before
    check not session.faulted
