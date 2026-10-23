## Opt-in native outlet: legacy renderPage remains a transparent outlet.
import std/[unittest, tables, options]
import leaf/[core, widgets, components, backend, backend_session, host_protocol,
  host_reconcile, native_host_adapter, native_layout, managed_runtime, gpui_ffi_v2,
  navigation_protocol]
import leaf/component_description
import leaf/backends/headless

var router: ComponentRouter
var transparent = false
var counter: State[int]

let routes = @[
  Route(name: "home", path: "/", page: "home", view: "main"),
  Route(name: "detail", path: "/detail", page: "detail", view: "main")]
let pages = @[
  ComponentPageDefinition(name: "home", views: @["main"],
    build: proc(view: string): UiDescription = host(text("home", key = "content"))),
  ComponentPageDefinition(name: "detail", views: @["main"],
    build: proc(view: string): UiDescription = host(text("detail", key = "content")))]

let Root = defineComponent[int, State[int]]("NativeNavigationOutlet",
  proc(ctx: MountContext, value: int): State[int] =
    router = newComponentRouter(ctx, routes, pages)
    result = ctx.state(value)
    counter = result,
  proc(ctx: ComponentContext, value: int, state: State[int]): UiDescription =
    discard ctx.value(state)
    let outlet = if transparent: renderPage(ctx, router)
      else: renderNavigation(ctx, router, key = "native-nav")
    hostShell(ui(NodeKind.column, key = "frame"), @[
      host(button("push", key = "push", onClick = proc(e: Event) =
        discard router.push("detail"))), outlet]))

proc fixture(): tuple[rt: Runtime, recording: RecordingBackend, session: BackendSession] =
  transparent = false
  result.rt = newRuntime(componentApplication(component(Root, 0), "navigation"))
  result.recording = newRecordingBackend(fullCapabilities())
  result.session = attachBackend(result.rt, result.recording.backend,
    HostContext(sessionId: 901, mountGeneration: 1, contentWidth: 400, contentHeight: 700, scale: 1))

proc navEntity(recording: RecordingBackend): MountedEntity =
  for entity in recording.entities.values:
    if entity.kind == NodeKind.navigation: return entity
  fail("native outlet missing")

suite "typed native navigation host":
  test "opt-in outlet owns one real host and preserves transparent legacy outlet":
    var f = fixture()
    let nav = f.recording.navEntity()
    check nav.navigation.isSome
    check nav.navigation.get.depth == 1
    check nav.navigation.get.previousEntryId == 0
    check f.recording.childrenOf(nav.handle).len == 1
    check nav.props.control.hasBack
    f.session.dispose()
    transparent = true
    f.rt = newRuntime(componentApplication(component(Root, 0), "navigation"))
    f.recording = newRecordingBackend(fullCapabilities())
    f.session = attachBackend(f.rt, f.recording.backend, HostContext(sessionId: 902, mountGeneration: 1, contentWidth: 400, contentHeight: 700, scale: 1))
    for entity in f.recording.entities.values:
      check entity.kind != NodeKind.navigation
      check entity.navigation.isNone
    f.session.dispose()

  test "history-only changes update metadata while keeping native host identity":
    let f = fixture()
    let before = f.recording.navEntity()
    discard router.push("home")
    discard f.rt.flush()
    let after = f.recording.navEntity()
    check after.handle == before.handle
    check after.props == before.props
    check after.navigation.get.depth == 2
    check after.navigation.get.currentEntryId != before.navigation.get.currentEntryId
    check after.navigation.get.previousEntryId == before.navigation.get.currentEntryId
    check after.navigation.get.historyRevision > before.navigation.get.historyRevision
    var updated = false
    for op in f.recording.history:
      if op.handle == after.handle and op.kind == opUpdate and op.navigation == after.navigation:
        updated = true
    check updated
    f.session.dispose()

  test "native back callback queues through the same Runtime transaction exactly once":
    let f = fixture()
    discard router.push("detail")
    discard f.rt.flush()
    let nav = f.recording.navEntity()
    check f.rt.dispatch(nav.nodeId, Event(kind: EventKind.back, navigationRequestId: 10))
    check router.currentRoute.name == "home"
    check router.history.len == 1
    let revision = f.rt.acceptedRevision
    discard f.rt.dispatch(nav.nodeId, Event(kind: EventKind.back, navigationRequestId: 10))
    check f.rt.acceptedRevision == revision
    f.session.dispose()

  test "partial native failure restores accepted navigation metadata and history":
    let f = fixture()
    let before = f.recording.navEntity()
    let revision = f.rt.acceptedRevision
    f.recording.failApplyAt = 2
    discard router.push("detail")
    expect UiError: discard f.rt.flush()
    check router.currentRoute.name == "home"
    check router.history.len == 1
    check f.rt.acceptedRevision == revision
    check f.recording.navEntity().navigation == before.navigation
    check f.recording.restoreCalls == 1
    f.recording.failApplyAt = 0
    check not f.rt.flush()
    discard router.push("detail")
    check f.rt.flush()
    check f.recording.navEntity().navigation.get.depth == 2
    f.session.dispose()

  test "unsupported backends reject before native prepare rather than flattening":
    transparent = false
    let rt = newRuntime(componentApplication(component(Root, 0), "navigation"))
    var caps = fullCapabilities()
    caps.kinds.excl(NodeKind.navigation)
    let recording = newRecordingBackend(caps)
    expect UiError: discard attachBackend(rt, recording.backend, HostContext(sessionId: 903, mountGeneration: 1, contentWidth: 400, contentHeight: 700, scale: 1))
    check recording.prepareCalls == 0

  test "GPUI wire refuses native navigation without changing old ABI":
    let f = fixture()
    let nav = f.recording.navEntity()
    let op = HostOp(kind: HostOpKind.create, handle: nav.handle,
      nodeKind: NodeKind.navigation, props: HostProps(navigation: nav.navigation))
    expect UiError: discard encodeBatch(HostBatch(sessionId: 901, nextRevision: 1, ops: @[op]))
    f.session.dispose()

  test "native navigation layout arranges its active page inside its own bounds":
    let f = fixture()
    let nav = f.recording.navEntity()
    let boxes = layoutTree(f.recording.entities, DipSize(width: 400, height: 700),
      proc(entity: MountedEntity, available: DipSize): DipSize = DipSize(width: 40, height: 24))
    check boxes.len == f.recording.entities.len
    var navBox, childBox: DipRect
    let child = f.recording.childrenOf(nav.handle)[0]
    for box in boxes:
      if box.handle == nav.handle: navBox = box.rect
      if box.handle == child: childBox = box.rect
    check childBox.x >= navBox.x
    check childBox.y >= navBox.y
    check childBox.x + childBox.width <= navBox.x + navBox.width
    check childBox.y + childBox.height <= navBox.y + navBox.height
    f.session.dispose()

  test "description rejects navigation metadata on other kinds and malformed endpoints":
    let valid = HostNavigationProps(routerId: 1, historyRevision: 1,
      currentEntryId: 1, depth: 1)
    expect UiError: discard ui(NodeKind.column, navigation = some(valid))
    expect UiError: discard ui(NodeKind.navigation)
    var invalid = valid
    invalid.previousEntryId = 2
    expect UiError: discard ui(NodeKind.navigation, navigation = some(invalid))
    expect UiError: discard ui(NodeKind.column, onBack = proc(e: Event) = discard)

  test "host reconciliation rejects zero or multiple active pages":
    let valid = HostNavigationProps(routerId: 1, historyRevision: 1,
      currentEntryId: 1, depth: 1)
    for children in [newSeq[Node](), @[text("a"), text("b")]]:
      let r = newHostReconciler(904)
      expect UiError:
        discard r.planSnapshot(Snapshot(root: mount(ui(NodeKind.navigation,
          navigation = some(valid), children = children))), 1, nativeStrict)
      check r.revision == 0

  test "raw host metadata and child shape are gated before backend preparation":
    let valid = HostNavigationProps(routerId: 1, historyRevision: 1,
      currentEntryId: 1, depth: 1)
    for mode in 0..4:
      let recording = newRecordingBackend(fullCapabilities())
      let consumer = nativeHostConsumer(recording.backend, 905)
      var metadata = some(valid)
      var kind = NodeKind.navigation
      if mode == 0: metadata = none(HostNavigationProps)
      if mode == 1: kind = NodeKind.column
      if mode == 2:
        var bad = valid
        bad.depth = 0
        metadata = some(bad)
      let count = if mode == 4: 2 else: 0
      var ops = @[HostOp(kind: HostOpKind.create, handle: NodeHandle(1),
        nodeId: "nav", nodeKind: kind, props: HostProps(navigation: metadata))]
      var children: seq[NodeHandle]
      for index in 0..<count:
        let handle = NodeHandle(index + 2)
        ops.add(HostOp(kind: HostOpKind.create, handle: handle, parent: NodeHandle(1),
          nodeId: "child" & $index, nodeKind: NodeKind.text))
        children.add(handle)
      ops.add(HostOp(kind: HostOpKind.setChildren, handle: NodeHandle(1), children: children))
      expect UiError: consumer.prepare(HostBatch(sessionId: 905, nextRevision: 1, ops: ops))
      check recording.prepareCalls == 0


proc backFact(f: tuple[rt: Runtime, recording: RecordingBackend, session: BackendSession],
    sequence: uint64, phase: NavigationBackPhase, requestId = 1'u64): NavigationBackFact =
  let nav = f.recording.navEntity()
  NavigationBackFact(sessionId: f.session.sessionId,
    mountGeneration: f.session.mountGeneration, handle: uint64(nav.handle),
    bindingGeneration: 7, observedRevision: f.rt.acceptedRevision,
    sequence: sequence, requestId: requestId, navigation: nav.navigation.get, phase: phase)

proc pushedFixture(): tuple[rt: Runtime, recording: RecordingBackend, session: BackendSession] =
  result = fixture()
  result.recording.backend.bindingValid = proc(handle: NodeHandle, generation: uint64): bool =
    generation == 7
  discard router.push("detail")
  discard result.rt.flush()

proc pushClick(f: tuple[rt: Runtime, recording: RecordingBackend, session: BackendSession],
    sequence: uint64): EventEnvelope =
  EventEnvelope(session: f.session.sessionId, mountGeneration: f.session.mountGeneration,
    handle: f.session.handleFor(f.rt.find("push").id), sequence: sequence,
    observedRevision: f.rt.acceptedRevision, bindingGeneration: 7,
    event: Event(kind: EventKind.click))

suite "native navigation safe turn":
  test "begin and cancel record facts without rendering or business delivery":
    let f = pushedFixture()
    let revision = f.rt.acceptedRevision
    check f.session.queueNavigation(f.backFact(1, NavigationBackPhase.begin))
    check f.session.pendingNavigation == 1
    check router.history.len == 2
    check f.session.queuedEvents == 0
    check f.session.queueNavigation(f.backFact(2, NavigationBackPhase.cancel))
    check f.session.pendingNavigation == 0
    f.session.drainEvents()
    check router.history.len == 2
    check f.rt.acceptedRevision == revision
    check not f.session.queueNavigation(f.backFact(3, NavigationBackPhase.confirm))
    f.session.dispose()

  test "confirmed back waits for lifecycle gate and can be cancelled before delivery":
    let f = pushedFixture()
    check f.session.queueNavigation(f.backFact(1, NavigationBackPhase.begin))
    check f.session.queueNavigation(f.backFact(2, NavigationBackPhase.confirm))
    check router.history.len == 2
    f.session.drainEvents(proc(): bool {.raises: [].} = false)
    check f.session.queuedEvents == 1
    check f.session.queueNavigation(f.backFact(3, NavigationBackPhase.cancel))
    f.session.drainEvents()
    check router.history.len == 2
    check f.session.queuedEvents == 0
    check f.session.pendingNavigation == 0
    f.session.dispose()

  test "one accepted back uses the ordinary event queue and cannot be forged":
    let f = pushedFixture()
    let fact = f.backFact(1, NavigationBackPhase.begin)
    check not f.session.enqueue(EventEnvelope(session: fact.sessionId,
      mountGeneration: fact.mountGeneration, handle: NodeHandle(fact.handle),
      bindingGeneration: 7, observedRevision: fact.observedRevision, sequence: 1,
      event: Event(kind: EventKind.back, navigationRequestId: 1)))
    check f.session.queueNavigation(fact)
    check f.session.queueNavigation(f.backFact(2, NavigationBackPhase.confirm))
    f.session.drainEvents()
    check router.history.len == 1
    check f.session.pendingNavigation == 0
    check not f.session.queueNavigation(f.backFact(3, NavigationBackPhase.confirm))
    f.session.dispose()

  test "click before back invalidates the captured history in shared event order":
    let f = pushedFixture()
    check f.session.enqueue(f.pushClick(1))
    check f.session.queueNavigation(f.backFact(2, NavigationBackPhase.begin))
    check f.session.queueNavigation(f.backFact(3, NavigationBackPhase.confirm))
    f.session.drainEvents()
    check router.history.len == 3
    check f.session.pendingNavigation == 0
    f.session.dispose()

  test "back before click pops then pushes in shared event order":
    let f = pushedFixture()
    check f.session.queueNavigation(f.backFact(1, NavigationBackPhase.begin))
    check f.session.queueNavigation(f.backFact(2, NavigationBackPhase.confirm))
    check f.session.enqueue(f.pushClick(3))
    f.session.drainEvents()
    check router.history.len == 2
    check f.session.pendingNavigation == 0
    f.session.dispose()

  test "changed binding is rejected and does not consume a later valid sequence":
    let f = pushedFixture()
    var bad = f.backFact(100, NavigationBackPhase.begin)
    bad.bindingGeneration = 99
    check not f.session.queueNavigation(bad)
    check f.session.queueNavigation(f.backFact(1, NavigationBackPhase.begin))
    f.recording.backend.bindingValid = proc(handle: NodeHandle, generation: uint64): bool = false
    f.session.drainEvents()
    check f.session.pendingNavigation == 0
    f.session.dispose()

  test "failed back restores accepted history and consumes the request without idle retry":
    let f = pushedFixture()
    let revision = f.rt.acceptedRevision
    let mount = f.session.mountGeneration
    let old = f.backFact(1, NavigationBackPhase.begin)
    check f.session.queueNavigation(old)
    check f.session.queueNavigation(f.backFact(2, NavigationBackPhase.confirm))
    f.recording.failApplyAt = 2
    f.session.drainEvents()
    check router.history.len == 2
    check f.rt.acceptedRevision == revision
    check f.session.mountGeneration > mount
    check f.session.pendingNavigation == 0
    check not f.session.queueNavigation(old)
    f.recording.failApplyAt = 0
    f.session.drainEvents()
    check router.history.len == 2
    check not f.rt.flush()
    check f.session.queueNavigation(f.backFact(1, NavigationBackPhase.begin, 2))
    check f.session.queueNavigation(f.backFact(2, NavigationBackPhase.confirm, 2))
    f.session.drainEvents()
    check router.history.len == 1
    f.session.dispose()

  test "close invalidates unconfirmed and confirmed facts immediately":
    let f = pushedFixture()
    check f.session.queueNavigation(f.backFact(1, NavigationBackPhase.begin))
    check f.session.queueNavigation(f.backFact(2, NavigationBackPhase.confirm))
    f.session.requestClose()
    check f.session.pendingNavigation == 0
    check f.session.queuedEvents == 0
    check not f.session.queueNavigation(f.backFact(3, NavigationBackPhase.begin, 2))
    f.session.drainEvents()
    check router.history.len == 2
    f.session.dispose()

  test "cancelled confirmations do not accumulate ordinary event envelopes":
    let f = pushedFixture()
    for index in 0..<300:
      let base = uint64(index * 3)
      let request = uint64(index + 1)
      check f.session.queueNavigation(f.backFact(base + 1, NavigationBackPhase.begin, request))
      check f.session.queueNavigation(f.backFact(base + 2, NavigationBackPhase.confirm, request))
      check f.session.queueNavigation(f.backFact(base + 3, NavigationBackPhase.cancel, request))
    check f.session.pendingNavigation == 0
    check f.session.queuedEvents == 0
    check router.history.len == 2
    f.session.dispose()

  test "facts captured during apply cannot pop the newly accepted history":
    let f = pushedFixture()
    let old = f.backFact(1, NavigationBackPhase.begin)
    var confirmed = old
    confirmed.phase = NavigationBackPhase.confirm
    confirmed.sequence = 2
    var captures = 0
    f.recording.onSetter = proc(handle: NodeHandle) =
      if captures != 0: return
      inc captures
      check f.session.queueNavigation(old)
      check f.session.queueNavigation(confirmed)
      f.session.drainEvents()
      check router.history.len == 2
    discard router.push("home")
    discard f.rt.flush()
    check captures == 1
    check router.history.len == 3
    f.session.drainEvents()
    check router.history.len == 3
    check f.session.pendingNavigation == 0
    f.session.dispose()

  test "raw navigation cannot be its own active page":
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, 906)
    let metadata = HostNavigationProps(routerId: 1, historyRevision: 1,
      currentEntryId: 1, depth: 1)
    expect UiError:
      consumer.prepare(HostBatch(sessionId: 906, nextRevision: 1, ops: @[
        HostOp(kind: HostOpKind.create, handle: NodeHandle(1), nodeId: "self",
          nodeKind: NodeKind.navigation, props: HostProps(navigation: some(metadata))),
        HostOp(kind: HostOpKind.setChildren, handle: NodeHandle(1), children: @[NodeHandle(1)])]))
    check recording.prepareCalls == 0

  test "frozen Runtime rejects new native facts":
    let f = pushedFixture()
    f.rt.freezeEvents("test terminal freeze")
    check not f.session.queueNavigation(f.backFact(1, NavigationBackPhase.begin))
    check f.session.pendingNavigation == 0
    f.session.dispose()


  test "accepted history changes retire queued envelopes as well as pending facts":
    let f = pushedFixture()
    for index in 0..<100:
      let base = uint64(index * 2)
      let request = uint64(index + 1)
      check f.session.queueNavigation(f.backFact(base + 1, NavigationBackPhase.begin, request))
      check f.session.queuedEvents == 0
      check f.session.queueNavigation(f.backFact(base + 2, NavigationBackPhase.confirm, request))
      discard router.push("detail")
      discard f.rt.flush()
    # Another ordinary capture prunes the last stale history before reserving.
    check f.session.queueNavigation(f.backFact(201, NavigationBackPhase.begin, 101))
    check f.session.queuedEvents == 0
    check f.session.queueNavigation(f.backFact(202, NavigationBackPhase.cancel, 101))
    check f.session.pendingNavigation == 0
    check router.history.len == 102
    f.session.dispose()


  test "retiring obsolete navigation preserves queued ordinary clicks":
    let f = pushedFixture()
    check f.session.enqueue(f.pushClick(1))
    check f.session.queueNavigation(f.backFact(2, NavigationBackPhase.begin))
    check f.session.queueNavigation(f.backFact(3, NavigationBackPhase.confirm))
    discard router.push("detail")
    discard f.rt.flush()
    check f.session.queueNavigation(f.backFact(4, NavigationBackPhase.begin, 2))
    check f.session.queuedEvents == 1
    check f.session.queueNavigation(f.backFact(5, NavigationBackPhase.cancel, 2))
    f.session.drainEvents()
    check router.history.len == 4
    check f.session.queuedEvents == 0
    f.session.dispose()

  test "unrelated accepted updates preserve the captured history and old observed revision":
    let f = pushedFixture()
    let old = f.backFact(1, NavigationBackPhase.begin)
    discard counter.set(10)
    discard f.rt.flush()
    check f.rt.acceptedRevision > old.observedRevision
    check f.session.queueNavigation(old)
    var confirmation = old
    confirmation.sequence = 2
    confirmation.phase = NavigationBackPhase.confirm
    check f.session.queueNavigation(confirmation)
    f.session.drainEvents()
    check router.history.len == 1
    check counter.read() == 10
    f.session.dispose()
