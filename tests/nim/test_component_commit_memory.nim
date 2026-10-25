## Stage-1 memory contracts: atomic publication, deferred retirement and
## delta-only accepted maps. Behavioural assertions always run; allocation
## counters and epoch probes run when the harness asks for them.
import std/[unittest, options, algorithm]
import leaf/[core, widgets, components, component_state, host_reconcile,
  host_session, managed_runtime, backend, commit_map]

var destructions {.global.} = 0

type Payload = object
  marker: int
  counter: ptr int

proc `=destroy`(value: var Payload) =
  if value.counter != nil: inc value.counter[]

proc `=copy`(dest: var Payload, source: Payload) =
  if dest.counter != nil: inc dest.counter[]
  dest.marker = source.marker
  dest.counter = source.counter

proc `=sink`(dest: var Payload, source: Payload) =
  if dest.counter != nil: inc dest.counter[]
  dest.marker = source.marker
  dest.counter = source.counter

proc payload(marker: int): Payload = Payload(marker: marker, counter: addr destructions)
proc payloadSnapshot(value: Payload): Payload = value

proc allocCount(): int =
  when defined(nimAllocStats):
    let stats = getAllocStats()
    for name, value in fieldPairs(stats):
      when name == "allocCount": result = value
  else: 0

proc snap(node: Node): Snapshot = Snapshot(title: "memory", width: 320, height: 200, root: mount(node))
var arbitraryInt {.global.} = 731

var clickValue: State[int]
var hostSync = true
let Clicker = defineComponent[int, State[int]]("MemoryClicker",
  proc(ctx: MountContext, p: int): State[int] =
    result = ctx.state(0); clickValue = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    let n = ctx.value(s)
    if hostSync:
      host(button($n, key="run", onClick = proc(e: Event) = discard s.update(proc(v: int): int = v + 1)))
    else:
      # State-only commit: the host subtree stays identical, the accepted
      # State value still advances.
      host(button("constant", key="run", onClick = proc(e: Event) = discard s.update(proc(v: int): int = v + 1))))

var keyCount: State[int]
let DupKeys = defineComponent[int, State[int]]("MemoryDupKeys",
  proc(ctx: MountContext, p: int): State[int] =
    result = ctx.state(2); keyCount = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    let n = ctx.value(s)
    var children: seq[UiDescription]
    for i in 0 ..< n:
      children.add(hostShell(row(@[]), @[host(text("dup" & $i, key = "dup"))]))
    hostShell(column(@[]), children))

var growRows: State[int]
let Rows = defineComponent[int, State[int]]("MemoryRows",
  proc(ctx: MountContext, p: int): State[int] =
    result = ctx.state(3); growRows = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    let n = ctx.value(s)
    var children: seq[UiDescription]
    for i in 0 ..< n: children.add(host(text("row-" & $i, key = "row-" & $i)))
    hostShell(column(@[]), children))

var keyedChildren = 2000
let KeyedMount = defineComponent[int, int]("MemoryKeyedMount",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    var children: seq[UiDescription]
    for i in 0 ..< keyedChildren:
      children.add(host(text("r" & $i, key = "km" & $i)))
    hostShell(column(@[]), children))

proc listApp(): Application =
  var keys: seq[string]
  for i in 0 ..< 50: keys.add("item-" & $i)
  componentApplication(componentList("list", keys,
    proc(index: int): UiDescription = host(text("row-" & $index)), overscan = 0), "list")

suite "atomic publication keeps accepted content":
  test "discarded host candidate changes no accepted entry":
    let r = newHostReconciler(77)
    let mounted = mount(column(@[text("a", key = "x"), text("b", key = "y")], key = "root"))
    let rootId = mounted.id
    let xId = mounted.children[0].id
    let yId = mounted.children[1].id
    let first = r.planSnapshot(Snapshot(title: "memory", width: 320, height: 200, root: mounted),
      1, hostCompatible)
    r.accept(first)
    r.finishPublish(first)
    let x = r.handleFor(xId)
    let y = r.handleFor(yId)
    let root = r.handleFor(rootId)
    check uint64(x) != 0
    check uint64(y) != 0
    let records = (r.record(x).get.nodeId, r.record(y).get.nodeId, r.record(root).get.nodeId)
    let children = r.children(x)
    check r.revision == 1
    let second = r.planSnapshot(snap(column(@[text("changed", key = "x"), text("new", key = "z")], key = "root")),
      2, hostCompatible)
    r.discard(second)
    check r.revision == 1
    check r.handleFor(xId) == x
    check r.handleFor(yId) == y
    check r.handleFor(rootId) == root
    check (r.record(x).get.nodeId, r.record(y).get.nodeId, r.record(root).get.nodeId) == records
    check r.children(x) == children
    # The discarded candidate does not poison the next attempt.
    let changed = mount(column(@[text("changed", key = "x"), text("new", key = "z")], key = "root"))
    let third = r.planSnapshot(Snapshot(title: "memory", width: 320, height: 200, root: changed),
      2, hostCompatible)
    r.accept(third)
    r.finishPublish(third)
    check r.revision == 2
    check r.handleFor(changed.children[1].id) != NoHandle
    check r.handleFor(xId) == x
    check r.record(x).get.nodeId == xId

  test "rejected backend apply keeps accepted tree, State and revision":
    var fail = false
    let rt = newRuntime(componentApplication(component(Clicker, 0), "reject"))
    let session = attachHostSession(rt, HostConsumer(sessionId: 501,
      prepare: proc(batch: HostBatch) = discard,
      apply: proc() =
        if fail: fail("simulated apply failure"),
      accept: proc(revision: uint64) {.raises: [].} = discard,
      discardPrepared: proc() {.raises: [].} = discard))
    let revision = rt.acceptedRevision
    let text = rt.find("run").node.text
    fail = true
    expect UiError: discard rt.dispatch("run", Event(kind: click))
    check rt.acceptedRevision == revision
    check rt.find("run").node.text == text
    check clickValue.read() == 0
    fail = false
    check rt.dispatch("run", Event(kind: click))
    check clickValue.read() == 1
    check rt.find("run").node.text == "1"
    session.close()

  test "key summary moves ambiguity to uniqueness and removal":
    let rt = newRuntime(componentApplication(component(DupKeys, 0), "keys"))
    discard rt.flush()
    expect UiError: discard rt.find("dup")
    keyCount.set(1)
    discard rt.flush()
    check rt.find("dup").node.text == "dup0"
    keyCount.set(0)
    discard rt.flush()
    expect UiError: discard rt.find("dup")

suite "state retirement waits for acceptance":
  test "publish swaps values and only finish runs destructors":
    destructions = 0
    let store = newStateStore(9001)
    let state = store.allocateState(41, payload(0), snapshot = payloadSnapshot)
    destructions = 0
    check state.queueSet(payload(1)) == StateWriteResult.queued
    let attempt = store.beginAttempt()
    destructions = 0
    when defined(nimAllocStats):
      let before = allocCount()
    store.publishAttempt(attempt)
    when defined(nimAllocStats):
      check allocCount() - before == 0
    check destructions == 0
    store.finishAttempt(attempt)
    check destructions == 1
    # Reading the accepted value later copies it; the marker is the published
    # candidate, proving the swap happened before retirement.
    check state.readAccepted().marker == 1

  test "owner disposal retires cells until finish":
    destructions = 0
    let store = newStateStore(9002)
    let state = store.allocateState(51, payload(0), snapshot = payloadSnapshot)
    destructions = 0
    let plan = store.prepareDisposeOwner(51)
    publishDisposeOwner(plan)
    check destructions == 0
    check not state.stateAlive()
    finishDisposeOwner(plan)
    check destructions == 1
    # The accepted store no longer exposes the owner's cells.
    expect UiError: discard state.readAccepted()

suite "viewport restaging":
  test "second viewport discards the first sealed patch":
    let rt = newRuntime(listApp())
    let first = rt.runtimeDriver.stage(true)
    check first != nil
    let rows = first.stageViewport("list", 0, 5, @[])
    check rows != nil
    # Same staged driver: the first prepared patch must be discarded and the
    # final viewport alone published.
    let second = rows.stageViewport("list", 10, 15, @[])
    check second != nil
    second.publish()
    let node = second.find("list")
    checkpoint("viewport rows=" & $node.children.len)
    check node.children.len == 5
    var indices: seq[int]
    for child in node.children: indices.add(child.listIndex)
    indices.sort()
    check indices == @[10, 11, 12, 13, 14]
    second.finishCommit()

  test "repeated viewport requests stay consistent":
    let rt = newRuntime(listApp())
    discard rt.materialize("list", 0, 4)
    check rt.listStats("list").activeRows == 4
    discard rt.materialize("list", 20, 24)
    check rt.listStats("list").activeRows == 4
    discard rt.materialize("list", 0, 0)
    check rt.find("list").node.kind == NodeKind.virtualList

when defined(leafProtocolProbes):
  suite "publication allocation windows":
    proc checkManagedPublish(label: string, runtime: Runtime, body: proc()) =
      when defined(nimAllocStats):
        managedPublishAllocations = -1
        body()
        let allocations = managedPublishAllocations
        checkpoint(label & " publish allocations=" & $allocations)
        check allocations == 0
      else:
        body()

    test "cold, hot, dynamic and state-only managed commits":
      hostSync = true
      # Initial refresh publication happens inside newRuntime.
      when defined(nimAllocStats): managedPublishAllocations = -1
      let rt = newRuntime(componentApplication(component(Clicker, 0, key = "dynamic-" & $arbitraryInt), "dynamic title"))
      when defined(nimAllocStats):
        checkpoint("cold publish allocations=" & $managedPublishAllocations)
        check managedPublishAllocations == 0
      checkManagedPublish("hot", rt, proc() = discard rt.dispatch("run", Event(kind: click)))
      clickValue.set(7)
      checkManagedPublish("state-batch", rt, proc() = discard rt.flush())
      hostSync = false
      checkManagedPublish("state-only", rt, proc() = discard rt.dispatch("run", Event(kind: click)))
      check rt.find("run").node.text == "constant"
      check clickValue.read() == 8

    test "unmount and key churn publish without allocation":
      when defined(nimAllocStats): managedPublishAllocations = -1
      let rt = newRuntime(componentApplication(component(Rows, 0), "rows"))
      when defined(nimAllocStats):
        checkpoint("rows-initial publish allocations=" & $managedPublishAllocations)
        check managedPublishAllocations == 0
      growRows.set(12)
      checkManagedPublish("rows-grow", rt, proc() = discard rt.flush())
      growRows.set(2)
      checkManagedPublish("rows-unmount", rt, proc() = discard rt.flush())
      expect UiError: discard rt.find("row-9")
      check rt.find("row-1").node.text == "row-1"

    test "dynamic host ids publish without allocation":
      let r = newHostReconciler(901)
      let handle = r.reserveHandle()
      let dynamicId = "root/dynamic-" & $arbitraryInt & "/" & $321
      let candidate = r.planDelta(HostChanges(upserts: @[HostRecord(handle: handle,
        nodeId: dynamicId, kind: NodeKind.text,
        props: normalizeHostProps(text("first"), hostCompatible))]), 1)
      let before = allocCount()
      r.publish(candidate)
      checkpoint("host dynamic publish allocations=" & $(allocCount() - before))
      when defined(nimAllocStats): check hostPublishAllocations == 0
      r.finishPublish(candidate)
      let update = r.planDelta(HostChanges(upserts: @[HostRecord(handle: handle,
        nodeId: dynamicId, kind: NodeKind.text,
        props: normalizeHostProps(text("second"), hostCompatible))]), 2)
      r.publish(update)
      when defined(nimAllocStats): check hostPublishAllocations == 0
      r.finishPublish(update)
      check r.handleFor(dynamicId) == handle

    test "list viewport and delayed installation confirm publish without allocation":
      let rt = newRuntime(listApp())
      discard rt.flush()
      checkManagedPublish("viewport", rt, proc() = discard rt.materialize("list", 0, 8))
      checkManagedPublish("viewport-2", rt, proc() = discard rt.materialize("list", 8, 16))
      let prepared = newRuntime(listApp())
      when defined(nimAllocStats): managedPublishAllocations = -1
      let token = prepared.installPreparer(proc(candidate: Runtime) =
        discard candidate.materialize("list", 0, 8))
      check token != 0
      when defined(nimAllocStats):
        checkpoint("install confirm publish allocations=" & $managedPublishAllocations)
        check managedPublishAllocations == 0
      check prepared.find("list").node.kind == NodeKind.virtualList

when defined(leafProtocolProbes):
  suite "r1 large keyed mount":
    test "key delta index keeps a full keyed mount near linear":
      keyDeltaComparisons = 0
      let rt = newRuntime(componentApplication(component(KeyedMount, 0), "keyed"))
      check rt.find("km0").node.text == "r0"
      check rt.find("km1999").node.text == "r1999"
      checkpoint("keyDeltaComparisons=" & $keyDeltaComparisons)
      # A pure O(K^2) scan over 2000 keys is about 2,000,000 comparisons; the
      # threshold index stays near K + threshold^2/2.
      check keyDeltaComparisons < 200000

when defined(leafProtocolProbes):
  suite "r1 commit validation":
    test "stale editEpoch is rejected before apply and publishes nothing":
      hostSync = true
      let rt = newRuntime(componentApplication(component(Clicker, 0, key = "epoch"), "epoch"))
      clickValue.set(3)
      let revision = rt.acceptedRevision
      let staged = rt.runtimeDriver.stage(false)
      check staged != nil
      corruptPreparedEpochForTest(staged)
      expect UiError: staged.validateCommit()
      staged.reject()
      check rt.acceptedRevision == revision
      check clickValue.read() == 0
      # A fresh commit after the rejected staging still publishes normally.
      clickValue.set(4)
      check rt.flush()
      check clickValue.read() == 4
