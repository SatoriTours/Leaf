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

  test "busy dispose is explicitly rejected and remains retryable":
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
    var message = ""
    try:
      discard runtime.dispatch("go", Event(kind: click))
    except UiError as error:
      message = error.msg
    # A single close request during a commit is explicitly rejected, not lost.
    check "dispose" in message
    check recording.disposeCalls == 0
    check not session.disposed
    check runtime.committerOwner != 0
    check runtime.preparerOwner != 0
    # Retrying on a safe tick completes the release.
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

  test "failed teardown invalidates events and rows until retried":
    var items = @["a", "b"]
    var count = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        virtualList("list", items, proc(index: int): Node =
          text(items[index], key = "row")),
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let listHandle = session.handleFor(runtime.find("list").id)
    let goHandle = session.handleFor(runtime.find("go").id)
    var source = runtime.find("list").node.listSource
    discard session.requestRows(listHandle, source.generation, 0, 1)
    let before = runtime.snapshot.toJson()
    check session.enqueue(userEvent(session, goHandle, 1, Event(kind: click)))

    recording.failDispose = true
    expect UiError:
      dispose(session)
    check not session.disposed
    # Teardown started: the old queue is invalidated and new events, drains and
    # row requests cannot reach business state.
    check session.queuedEvents == 0
    check not session.enqueue(userEvent(session, goHandle, 2, Event(kind: click)))
    session.drainEvents()
    check count == 0
    source = runtime.find("list").node.listSource
    expect UiError:
      discard session.requestRows(listHandle, source.generation, 0, 2)
    check runtime.snapshot.toJson() == before
    check not runtime.eventsFrozen

    # Clearing the injected failure lets the same close request finish.
    recording.failDispose = false
    dispose(session)
    check session.disposed
    check recording.disposeCalls == 2

  test "conditional clear keeps update guard and execution scope":
    var depth = 0
    var scopeCalls = 0
    proc scope(body: proc() {.closure.}) =
      inc depth
      inc scopeCalls
      try: body()
      finally: dec depth
    var count = 0
    var busyRejected = false
    var sessionRef: BackendSession
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) =
          inc count
          try:
            sessionRef.runtime.clearCommitter(sessionRef.runtime.committerOwner)
          except UiError:
            busyRejected = true
          try:
            sessionRef.runtime.clearPreparer(sessionRef.runtime.preparerOwner)
          except UiError:
            busyRejected = true)], key = "root")

    let runtime = newRuntime(Application(title: "scope", width: 640, height: 480,
      render: render, executionScope: scope))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    sessionRef = session
    let applyCalls = recording.applyCalls
    check runtime.dispatch("go", Event(kind: click))
    check busyRejected
    check recording.applyCalls > applyCalls
    check runtime.committerOwner != 0
    check runtime.preparerOwner != 0

    # A failed owner leaves the hook untouched.
    let committerToken = runtime.committerOwner
    runtime.clearCommitter(committerToken + 1000)
    check runtime.committerOwner == committerToken

    # A valid-owner clear runs inside the application execution scope.
    let scopeBefore = scopeCalls
    runtime.clearCommitter(committerToken)
    check runtime.committerOwner == 0
    check scopeCalls == scopeBefore + 1
    let preparerToken = runtime.preparerOwner
    runtime.clearPreparer(preparerToken)
    check runtime.preparerOwner == 0
    check scopeCalls == scopeBefore + 2
    check depth == 0
    dispose(session)

  test "closing during a drain stops the remaining pending batch":
    var count = 0
    var sessionRef: BackendSession
    var recordingRef: RecordingBackend
    var triggerDispose = false
    var disposeFailed = false
    proc scope(body: proc() {.closure.}) =
      body()
      if triggerDispose:
        triggerDispose = false
        recordingRef.failDispose = true
        try:
          dispose(sessionRef)
        except UiError:
          disposeFailed = true
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")

    let runtime = newRuntime(Application(title: "closing", width: 640, height: 480,
      render: render, executionScope: scope))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    sessionRef = session
    recordingRef = recording
    let handle = session.handleFor(runtime.find("go").id)
    check session.enqueue(userEvent(session, handle, 1, Event(kind: click)))
    check session.enqueue(userEvent(session, handle, 2, Event(kind: click)))

    # After the first event's dispatch reaches the safe post-scope boundary, a
    # teardown starts and fails: the remaining local pending batch must not
    # reach business state.
    triggerDispose = true
    session.drainEvents()
    check disposeFailed
    check session.closing
    check not session.disposed
    check count == 1
    check runtime.find("count").node.text == "1"
    check session.queuedEvents == 0

    # Releasing the injected failure lets the same close request finish.
    recording.failDispose = false
    dispose(session)
    check session.disposed
    check recording.disposeCalls == 2

  test "duplicate attach preserves the active Backend resource owner":
    var count = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")
    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let before = runtime.snapshot.toJson()
    let entitiesBefore = recording.entities
    let revisionBefore = runtime.acceptedRevision
    let committerBefore = runtime.committerOwner
    let preparerBefore = runtime.preparerOwner
    let preparesBefore = recording.prepareCalls
    let appliesBefore = recording.applyCalls
    expect UiError:
      discard attachBackend(runtime, recording.backend, makeHost(sessionId = 8))
    check recording.prepareCalls == preparesBefore
    check recording.applyCalls == appliesBefore
    check recording.disposeCalls == 0
    check not recording.disposed
    check recording.entities == entitiesBefore
    check runtime.snapshot.toJson() == before
    check runtime.acceptedRevision == revisionBefore
    check runtime.committerOwner == committerBefore
    check runtime.preparerOwner == preparerBefore
    # Avoid cascading an expected RED into an uncaught disposed-backend error.
    if not recording.disposed:
      check runtime.dispatch("go", Event(kind: click))
      check runtime.find("count").node.text == "1"
      check runtime.acceptedRevision == revisionBefore + 1
      dispose(session)

  test "another Runtime cannot acquire an active Backend instance":
    var count = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")
    let firstRuntime = newRuntime(app(render))
    let secondRuntime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(firstRuntime, recording.backend, makeHost())
    let entitiesBefore = recording.entities
    expect UiError:
      discard attachBackend(secondRuntime, recording.backend, makeHost(sessionId = 8))
    check recording.prepareCalls == 1
    check recording.applyCalls == 1
    check recording.disposeCalls == 0
    check recording.entities == entitiesBefore
    check secondRuntime.committerOwner == 0
    check secondRuntime.preparerOwner == 0
    if not recording.disposed:
      check firstRuntime.dispatch("go", Event(kind: click))
      check firstRuntime.find("count").node.text == "1"
      dispose(session)

  test "occupied Runtime rejects a new Backend without acquiring resources":
    proc render(ctx: BuildContext): Node = text("x", key = "x")
    let runtime = newRuntime(app(render))
    let first = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, first.backend, makeHost())
    let other = newRecordingBackend(fullCapabilities())
    expect UiError:
      discard attachBackend(runtime, other.backend, makeHost(sessionId = 8))
    check other.prepareCalls == 0
    check other.applyCalls == 0
    check other.discardCalls == 0
    check other.disposeCalls == 0
    # The rejected Backend remains available to an unoccupied Runtime.
    if not other.disposed:
      let secondRuntime = newRuntime(app(render))
      let second = attachBackend(secondRuntime, other.backend, makeHost(sessionId = 8))
      check second.acceptedEntities.len == 1
      dispose(second)
    dispose(session)

  test "Scope exit failure at either attach stage leaves no hooks and permits retry":
    for stage in [1, 2]:
      var scopeCalls = 0
      var failAt = 0
      proc scope(body: proc() {.closure.}) =
        inc scopeCalls
        body()
        if scopeCalls == failAt: raise newException(UiError, "attach scope exit failed")
      proc render(ctx: BuildContext): Node = text("x", key = "x")
      let runtime = newRuntime(Application(title: "scope attach", width: 640, height: 480,
        render: render, executionScope: scope))
      let before = runtime.snapshot.toJson()
      let statsBefore = runtime.stats
      let revisionBefore = runtime.acceptedRevision
      let recording = newRecordingBackend(fullCapabilities())
      failAt = scopeCalls + stage
      expect UiError:
        discard attachBackend(runtime, recording.backend, makeHost())
      check recording.prepareCalls == 1
      check recording.applyCalls == 1
      check recording.disposeCalls == 1
      check recording.disposed
      check recording.entities.len == 0
      check runtime.committerOwner == 0
      check runtime.preparerOwner == 0
      check runtime.snapshot.toJson() == before
      check runtime.stats == statsBefore
      check runtime.acceptedRevision == revisionBefore
      check not runtime.installingUpdate
      failAt = 0
      if runtime.committerOwner == 0 and runtime.preparerOwner == 0:
        let retry = newRecordingBackend(fullCapabilities())
        let session = attachBackend(runtime, retry.backend, makeHost())
        check session.acceptedEntities.len == 1
        dispose(session)

  test "attach cleanup preserves primary error and attempts disposal after scoped clear errors":
    for failDispose in [false, true]:
      var scopeCalls = 0
      var failAt = 0
      proc scope(body: proc() {.closure.}) =
        inc scopeCalls
        let call = scopeCalls
        body()
        if call == failAt: raise newException(UiError, "primary install exit")
        if failAt != 0 and call > failAt:
          raise newException(UiError, "secondary cleanup exit")
      proc render(ctx: BuildContext): Node = text("x", key = "x")
      let runtime = newRuntime(Application(title: "cleanup", width: 640, height: 480,
        render: render, executionScope: scope))
      let recording = newRecordingBackend(fullCapabilities())
      recording.failDispose = failDispose
      failAt = scopeCalls + 2
      var message = ""
      try:
        discard attachBackend(runtime, recording.backend, makeHost())
      except UiError as error: message = error.msg
      check "primary install exit" in message
      check "secondary cleanup exit" in message
      check recording.disposeCalls == 1
      if failDispose: check "recording dispose failure" in message
      else: check recording.disposed
      check runtime.committerOwner == 0
      check runtime.preparerOwner == 0
      failAt = 0
      if runtime.committerOwner == 0 and runtime.preparerOwner == 0:
        let retry = newRecordingBackend(fullCapabilities())
        let session = attachBackend(runtime, retry.backend, makeHost())
        dispose(session)

  test "failed initial prepare discards and disposes its own resources despite cleanup errors":
    proc render(ctx: BuildContext): Node = text("x", key = "x")
    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    recording.failPrepare = true
    recording.failDiscard = true
    recording.failDispose = true
    var message = ""
    try:
      discard attachBackend(runtime, recording.backend, makeHost())
    except UiError as error: message = error.msg
    check "recording prepare failure" in message
    check "recording discard failure" in message
    check "recording dispose failure" in message
    check recording.discardCalls == 1
    check recording.disposeCalls == 1
    check runtime.committerOwner == 0
    check runtime.preparerOwner == 0

  test "attach cleanup never disposes a Backend whose hook could not be cleared":
    var scopeCalls = 0
    var failAt = 0
    proc scope(body: proc() {.closure.}) =
      inc scopeCalls
      if failAt != 0 and scopeCalls > failAt:
        raise newException(UiError, "cleanup scope entry failed")
      body()
      if scopeCalls == failAt: raise newException(UiError, "primary install exit")
    proc render(ctx: BuildContext): Node = text("x", key = "x")
    let runtime = newRuntime(Application(title: "retain", width: 640, height: 480,
      render: render, executionScope: scope))
    let recording = newRecordingBackend(fullCapabilities())
    failAt = scopeCalls + 2
    var message = ""
    try:
      discard attachBackend(runtime, recording.backend, makeHost())
    except UiError as error: message = error.msg
    check "primary install exit" in message
    check "cleanup scope entry failed" in message
    check recording.disposeCalls == 0
    check not recording.disposed
    check recording.entities.len == 1
    check runtime.committerOwner != 0
    failAt = 0
    # The retained hook references live resources; no bypass of Scope is used.
    check runtime.refresh()
    let secondRuntime = newRuntime(app(render))
    expect UiError:
      discard attachBackend(secondRuntime, recording.backend, makeHost(sessionId = 8))
    check recording.disposeCalls == 0
    runtime.clearCommitter(runtime.committerOwner)
    runtime.clearPreparer(runtime.preparerOwner)
    recording.backend.dispose()

  test "raw preparer install Scope failure restores accepted Native rows and invalidates old listeners":
    var failExit = false
    var depth, clicks, renders = 0
    proc scope(body: proc() {.closure.}) =
      inc depth
      try: body()
      finally: dec depth
      if failExit and depth == 0:
        failExit = false
        raise newException(UiError, "installation scope exit failed")
    proc render(ctx: BuildContext): Node =
      inc renders
      ctx.cached("list component", "stable", proc(): Node =
        column(@[virtualList("items", @["a", "b"], proc(index: int): Node =
          button("row " & $index, onClick = proc(e: Event) = inc clicks))], key = "root"))
    let runtime = newRuntime(Application(title: "rollback", width: 640, height: 480,
      render: render, executionScope: scope))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let listHandle = session.handleFor(runtime.find("items").id)
    let source = runtime.find("items").node.listSource
    discard session.requestRows(listHandle, source.generation, 0, 1)
    let rowHandle = session.handleFor(runtime.find("a").id)
    let oldEnvelope = userEvent(session, rowHandle, 1, Event(kind: click))
    check session.enqueue(oldEnvelope)
    let oldEntities = session.acceptedEntities
    let oldSnapshot = runtime.snapshot.toJson()
    let oldStats = runtime.stats
    let oldRevision = runtime.acceptedRevision
    let oldGeneration = session.mountGeneration
    let oldOwner = runtime.preparerOwner
    failExit = true
    expect UiError:
      discard runtime.installPreparer(proc(candidate: Runtime) =
        discard candidate.materialize("items", 0, 2))
    check runtime.snapshot.toJson() == oldSnapshot
    check runtime.stats == oldStats
    check runtime.acceptedRevision == oldRevision
    check runtime.preparerOwner == oldOwner
    check session.acceptedEntities == oldEntities
    check recording.entities == oldEntities
    check recording.restoreCalls == 1
    check session.mountGeneration == oldGeneration + 1
    check session.queuedEvents == 0
    check not session.enqueue(oldEnvelope)
    check not session.faulted
    check not runtime.eventsFrozen
    check renders == 1
    var failedHandle = NoHandle
    for op in recording.history:
      if op.kind == opCreate and op.nodeId.endsWith("/k:1:b"):
        failedHandle = op.handle
    check failedHandle != NoHandle
    # Retrying the raw API succeeds, but never recycles the rejected handle.
    discard runtime.installPreparer(proc(candidate: Runtime) =
      discard candidate.materialize("items", 0, 2))
    let newHandle = session.handleFor(runtime.find("b").id)
    check failedHandle < newHandle
    check recording.entities == session.acceptedEntities
    check session.enqueue(userEvent(session, rowHandle, 1, Event(kind: click)))
    session.drainEvents()
    check clicks == 1
    dispose(session)

  test "raw preparer Scope rollback restore failure faults Session and freezes direct dispatch":
    var failExit = false
    var depth, clicks = 0
    proc scope(body: proc() {.closure.}) =
      inc depth
      try: body()
      finally: dec depth
      if failExit and depth == 0:
        failExit = false
        raise newException(UiError, "primary install scope exit")
    proc render(ctx: BuildContext): Node =
      column(@[
        virtualList("items", @["a"], proc(index: int): Node = text("row")),
        button("go", key = "go", onClick = proc(e: Event) = inc clicks)], key = "root")
    let runtime = newRuntime(Application(title: "fault", width: 640, height: 480,
      render: render, executionScope: scope))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let oldEntities = session.acceptedEntities
    let before = runtime.snapshot.toJson()
    recording.failRestore = true
    failExit = true
    var message = ""
    try:
      runtime.setPreparer(proc(candidate: Runtime) =
        discard candidate.materialize("items", 0, 1))
    except UiError as error: message = error.msg
    check "primary install scope exit" in message
    check "recording restore failure" in message
    check recording.restoreCalls == 1
    check runtime.snapshot.toJson() == before
    check session.acceptedEntities == oldEntities
    check session.faulted
    check session.frozen
    check runtime.eventsFrozen
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    check clicks == 0
    dispose(session)

  test "raw setPreparer confirms pending rows once after Scope and no-op skips Backend":
    var depth = 0
    var inspectExit = false
    var sessionRef: BackendSession
    var runtimeRef: Runtime
    var recordingRef: RecordingBackend
    var oldEntities: Table[NodeHandle, MountedEntity]
    proc scope(body: proc() {.closure.}) =
      inc depth
      try: body()
      finally: dec depth
      if inspectExit and depth == 0:
        inspectExit = false
        check sessionRef.acceptedEntities == oldEntities
        check runtimeRef.find("items").children.len == 0
        check recordingRef.entities.len == oldEntities.len + 1
        check runtimeRef.installingUpdate
    proc render(ctx: BuildContext): Node =
      column(@[virtualList("items", @["a"], proc(index: int): Node = text("row"))])
    let runtime = newRuntime(Application(title: "confirm", width: 640, height: 480,
      render: render, executionScope: scope))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    sessionRef = session
    runtimeRef = runtime
    recordingRef = recording
    oldEntities = session.acceptedEntities
    let revisionBefore = runtime.acceptedRevision
    let applyBefore = recording.applyCalls
    inspectExit = true
    runtime.setPreparer(proc(candidate: Runtime) =
      discard candidate.materialize("items", 0, 1))
    check not inspectExit
    check runtime.find("items").children.len == 1
    check session.acceptedEntities.len == oldEntities.len + 1
    check recording.entities == session.acceptedEntities
    check recording.applyCalls == applyBefore + 1
    check runtime.acceptedRevision == revisionBefore + 1
    check recording.restoreCalls == 0
    let accepted = runtime.acceptedRevision
    let applied = recording.applyCalls
    let statsBefore = runtime.stats
    discard runtime.installPreparer(proc(candidate: Runtime) = discard)
    runtime.setPreparer(nil)
    check runtime.acceptedRevision == accepted
    check runtime.stats == statsBefore
    check recording.applyCalls == applied
    check recording.restoreCalls == 0
    dispose(session)

  test "rollback Scope errors preserve primary and never restore outside Scope":
    for entryFailure in [false, true]:
      var phase, depth = 0
      proc scope(body: proc() {.closure.}) =
        let rollback = depth == 0 and phase == 2
        if rollback and entryFailure:
          phase = 0
          raise newException(UiError, "secondary rollback scope entry")
        inc depth
        try: body()
        finally: dec depth
        if depth == 0 and phase == 1:
          phase = 2
          raise newException(UiError, "primary installation exit")
        if rollback:
          phase = 0
          raise newException(UiError, "secondary rollback scope exit")
      proc render(ctx: BuildContext): Node =
        column(@[virtualList("items", @["a"], proc(index: int): Node = text("row"))])
      let runtime = newRuntime(Application(title: "rollback scope", width: 640, height: 480,
        render: render, executionScope: scope))
      let recording = newRecordingBackend(fullCapabilities())
      let session = attachBackend(runtime, recording.backend, makeHost())
      let oldEntities = session.acceptedEntities
      phase = 1
      var message = ""
      try:
        discard runtime.installPreparer(proc(candidate: Runtime) =
          discard candidate.materialize("items", 0, 1))
      except UiError as error: message = error.msg
      check "primary installation exit" in message
      check "secondary rollback scope" in message
      check session.acceptedEntities == oldEntities
      check runtime.find("items").children.len == 0
      check recording.disposeCalls == 0
      if entryFailure:
        check recording.restoreCalls == 0
        check session.faulted
        check runtime.eventsFrozen
      else:
        check recording.restoreCalls == 1
        check recording.entities == oldEntities
        check not session.faulted
        check not runtime.eventsFrozen
      phase = 0
      dispose(session)

  test "pending install discard failure still restores Native and preserves Scope primary":
    var failExit = false
    var depth = 0
    proc scope(body: proc() {.closure.}) =
      inc depth
      try: body()
      finally: dec depth
      if failExit and depth == 0:
        failExit = false
        raise newException(UiError, "primary pending scope exit")
    proc render(ctx: BuildContext): Node =
      column(@[virtualList("items", @["a"], proc(index: int): Node = text("row"))])
    let runtime = newRuntime(Application(title: "discard rollback", width: 640, height: 480,
      render: render, executionScope: scope))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let oldEntities = session.acceptedEntities
    recording.failDiscard = true
    failExit = true
    var message = ""
    try:
      runtime.setPreparer(proc(candidate: Runtime) =
        discard candidate.materialize("items", 0, 1))
    except UiError as error: message = error.msg
    check "primary pending scope exit" in message
    check "recording discard failure" in message
    check recording.discardCalls == 1
    check recording.restoreCalls == 1
    check recording.entities == oldEntities
    check session.acceptedEntities == oldEntities
    check not session.faulted
    recording.failDiscard = false
    dispose(session)

  test "old Session disposal cannot detach the successor install lifecycle":
    var failExit = false
    var depth = 0
    proc scope(body: proc() {.closure.}) =
      inc depth
      try: body()
      finally: dec depth
      if failExit and depth == 0:
        failExit = false
        raise newException(UiError, "successor scope exit")
    proc render(ctx: BuildContext): Node =
      column(@[virtualList("items", @["a"], proc(index: int): Node = text("row"))])
    let runtime = newRuntime(Application(title: "owner lifecycle", width: 640, height: 480,
      render: render, executionScope: scope))
    let oldRecording = newRecordingBackend(fullCapabilities())
    let oldSession = attachBackend(runtime, oldRecording.backend, makeHost())
    runtime.clearCommitter(runtime.committerOwner)
    runtime.clearPreparer(runtime.preparerOwner)
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost(sessionId = 8))
    let owner = runtime.committerOwner
    dispose(oldSession)
    check runtime.committerOwner == owner
    failExit = true
    expect UiError:
      runtime.setPreparer(proc(candidate: Runtime) =
        discard candidate.materialize("items", 0, 1))
    check recording.restoreCalls == 1
    check recording.entities == session.acceptedEntities
    check runtime.find("items").children.len == 0
    check recording.entities.len == 2
    check oldRecording.restoreCalls == 0
    dispose(session)

  test "zero diff rejection settles the accepted value once":
    var model = "7"
    proc render(ctx: BuildContext): Node =
      column(@[input(model, key = "field",
        onChange = proc(e: Event) = discard)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    var settlements: seq[EventSettlement]
    recording.backend.settle = proc(value: EventSettlement) = settlements.add(value)
    let session = attachBackend(runtime, recording.backend, makeHost())
    let handle = session.handleFor(runtime.find("field").id)
    check session.enqueue(userEvent(session, handle, 1,
      Event(kind: change, value: "x")))
    session.drainEvents()
    check settlements.len == 1
    check settlements[0].handle == handle
    check settlements[0].props.control.value.get == "7"
    check settlements[0].revision == runtime.acceptedRevision
    check recording.prepared.len == 0
    check model == "7"

  test "settle happens for disabled controls and missing handlers":
    proc render(ctx: BuildContext): Node =
      column(@[input("v", key = "plain"), button("b", key = "off", disabled = true)],
        key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    var settlements = 0
    recording.backend.settle = proc(value: EventSettlement) = inc settlements
    let session = attachBackend(runtime, recording.backend, makeHost())
    let plain = session.handleFor(runtime.find("plain").id)
    let off = session.handleFor(runtime.find("off").id)
    check session.enqueue(userEvent(session, plain, 1,
      Event(kind: change, value: "v2")))
    check session.enqueue(userEvent(session, off, 2, Event(kind: click)))
    session.drainEvents()
    check settlements == 2

  test "accepted notification follows a successful accept only":
    var model = "a"
    proc render(ctx: BuildContext): Node =
      column(@[
        input(model, key = "field", onChange = proc(e: Event) = model = e.value),
        button("go", key = "go", onClick = proc(e: Event) = model = "b")], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    var acceptedCalls = 0
    var lastRevision = 0'u64
    recording.backend.accepted = proc(entities: Table[NodeHandle, MountedEntity],
                                      revision: uint64) =
      inc acceptedCalls
      lastRevision = revision
    let session = attachBackend(runtime, recording.backend, makeHost())
    check acceptedCalls == 1
    check runtime.dispatch("go", Event(kind: click))
    check acceptedCalls == 2
    check lastRevision == runtime.acceptedRevision
    check recording.entities == session.acceptedEntities

  test "restore rebinds the new generation once":
    var a, b = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($a, key = "a"), text($b, key = "b"),
        button("go", key = "go", onClick = proc(e: Event) = (inc a; inc b))],
        key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    var sessionRef: BackendSession
    var restoreGeneration = 0'u64
    var rebinds: seq[uint64]
    let originalRestore = recording.backend.restore
    recording.backend.restore = proc(entities: Table[NodeHandle, MountedEntity]) =
      restoreGeneration = sessionRef.mountGeneration
      originalRestore(entities)
    recording.backend.rebind = proc(sessionId, mountGeneration: uint64) =
      rebinds.add(mountGeneration)
    let session = attachBackend(runtime, recording.backend, makeHost())
    sessionRef = session
    check rebinds.len == 1
    check rebinds[0] == session.mountGeneration
    let generationBefore = session.mountGeneration

    recording.failApplyAt = 2
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    check restoreGeneration == generationBefore
    check rebinds.len == 2
    check rebinds[1] == generationBefore + 1
    check session.mountGeneration == generationBefore + 1
    check not session.faulted
    check not runtime.eventsFrozen

  test "rebind failure faults the session and freezes direct dispatch":
    var a, b = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($a, key = "a"), text($b, key = "b"),
        button("go", key = "go", onClick = proc(e: Event) = (inc a; inc b))],
        key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    var failRebind = false
    recording.backend.rebind = proc(sessionId, mountGeneration: uint64) =
      if failRebind: raise newException(UiError, "rebind failure")
    let session = attachBackend(runtime, recording.backend, makeHost())
    failRebind = true
    recording.failApplyAt = 2
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    check session.faulted
    check runtime.eventsFrozen
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))

  test "stale binding is never dispatched or settled":
    var count = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    var validBinding = true
    var settlements = 0
    recording.backend.bindingValid = proc(handle: NodeHandle,
                                          bindingGeneration: uint64): bool =
      validBinding
    recording.backend.settle = proc(value: EventSettlement) = inc settlements
    let session = attachBackend(runtime, recording.backend, makeHost())
    let handle = session.handleFor(runtime.find("go").id)
    var envelope = userEvent(session, handle, 1, Event(kind: click))
    envelope.bindingGeneration = 5
    check session.enqueue(envelope)
    validBinding = false
    session.drainEvents()
    check count == 0
    check settlements == 0
    check not session.enqueue(userEvent(session, handle, 2, Event(kind: click)))

  test "callback error still settles old accepted and is never replayed":
    proc render(ctx: BuildContext): Node =
      column(@[
        button("go", key = "go", onClick = proc(e: Event) =
          raise newException(UiError, "business boom"))], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    var settlements: seq[EventSettlement]
    recording.backend.settle = proc(value: EventSettlement) = settlements.add(value)
    let session = attachBackend(runtime, recording.backend, makeHost())
    let handle = session.handleFor(runtime.find("go").id)
    check session.enqueue(userEvent(session, handle, 1, Event(kind: click)))
    session.drainEvents()
    check settlements.len == 1
    check settlements[0].handle == handle
    check settlements[0].props.control.label.get == "go"
    session.drainEvents()
    check settlements.len == 1

  test "settle failure faults and stops the remaining batch":
    var count = 0
    proc render(ctx: BuildContext): Node =
      column(@[
        text($count, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc count)], key = "root")

    let runtime = newRuntime(app(render))
    let recording = newRecordingBackend(fullCapabilities())
    recording.backend.settle = proc(value: EventSettlement) =
      raise newException(UiError, "settle failure")
    let session = attachBackend(runtime, recording.backend, makeHost())
    let handle = session.handleFor(runtime.find("go").id)
    check session.enqueue(userEvent(session, handle, 1, Event(kind: click)))
    check session.enqueue(userEvent(session, handle, 2, Event(kind: click)))
    session.drainEvents()
    check session.faulted
    check runtime.eventsFrozen
    check count == 1

  test "nil optional hooks keep the A1 session behaviour":
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
    session.drainEvents()
    check count == 1
    check runtime.find("count").node.text == "1"
