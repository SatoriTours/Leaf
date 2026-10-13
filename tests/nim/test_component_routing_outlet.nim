## Task 2: low-level page outlets and retained page lifecycle. Uses the managed
## runtime directly; the public renderPage/router API belongs to Task 3.
import std/[unittest, options]
import leaf/[core, widgets, components, host_session]
import leaf/component_description
import leaf/managed_runtime

var initA, initB, initAlt, renderA, renderB, clicksA, localRender = 0
var stateA, stateB, localState, flip: State[int]
var route: State[int]
var retentionPolicy = PageRetention.retainState
var outletKey = "outlet-key"
var duplicateOutlet = false
var aRootColumn = true
var configurationBytes = 0
var currentView = "main"
var farmOutlets = 8
var nestedToken = 0'u64
var duplicateNested = false
var observedOps: seq[HostOp]

let PageA = defineComponent[int, State[int]]("OutletPageA",
  proc(ctx: MountContext, p: int): State[int] =
    inc initA
    stateA = ctx.state(0)
    stateA,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    inc renderA
    let n = ctx.value(s)
    let container = if aRootColumn: column(@[]) else: row(@[])
    var children = @[
      host(text("a" & $n, key="shared")),
      host(button("a+", key="count", onClick=proc(e: Event) =
        inc clicksA
        discard s.set(n + 1)))]
    if nestedToken != 0:
      children.add(pageOutlet(PageOutletSpec(routerId: nestedToken, page: "nested",
        view: "main",
        build: proc(): UiDescription = host(text("nested", key="nested"))),
        "nested-outlet"))
    hostShell(container, children))

let PageB = defineComponent[int, State[int]]("OutletPageB",
  proc(ctx: MountContext, p: int): State[int] =
    inc initB
    stateB = ctx.state(0)
    stateB,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    inc renderB
    hostShell(column(@[]), @[
      host(text("b" & $ctx.value(s), key="shared")),
      host(text("b-only", key="b-only"))]))

let PageAlt = defineComponent[int, int]("OutletPageAlt",
  proc(ctx: MountContext, p: int): int =
    inc initAlt
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    hostShell(column(@[]), @[host(text("alt", key="alt-only"))]))

let RouterHost = defineComponent[int, State[int]]("OutletRouterHost",
  proc(ctx: MountContext, p: int): State[int] =
    result = ctx.state(0)
    route = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    let index = ctx.value(s)
    let page = if index == 0: "a" else: "b"
    let view = currentView
    let configBytes = configurationBytes
    var buildProc: proc(): UiDescription {.closure.}
    if index == 0:
      if view == "main": buildProc = proc(): UiDescription = component(PageA, 0)
      else: buildProc = proc(): UiDescription = component(PageAlt, 0)
    else:
      buildProc = proc(): UiDescription = component(PageB, 0)
    let spec = PageOutletSpec(routerId: 77, page: page, view: view,
      retention: retentionPolicy, configurationBytes: configBytes, build: buildProc)
    var children = @[pageOutlet(spec, outletKey)]
    if duplicateOutlet: children.add(pageOutlet(spec, outletKey & "-dup"))
    if duplicateNested:
      children.add(pageOutlet(PageOutletSpec(routerId: nestedToken, page: "dup",
        view: "main", build: proc(): UiDescription = host(text("dup", key="dup"))),
        "dup-outlet"))
    hostShell(column(@[], key="router-column"), children))

proc farmOutlet(i: int): UiDescription =
  let page = "farm" & $i
  pageOutlet(PageOutletSpec(routerId: uint64(1000 + i), page: page, view: "main",
    build: proc(): UiDescription = host(text(page, key=page))),
    "farm-outlet-" & $i)

let OutletFarm = defineComponent[int, int]("OutletFarm",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    var children: seq[UiDescription]
    for i in 0 ..< farmOutlets: children.add(farmOutlet(i))
    hostShell(column(@[], key="farm-column"), children))

let LocalCounter = defineComponent[int, State[int]]("LocalCounter",
  proc(ctx: MountContext, p: int): State[int] =
    result = ctx.state(0)
    localState = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    inc localRender
    host(text("local" & $ctx.value(s), key="local")))

let WorkloadHost = defineComponent[int, int]("WorkloadHost",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    hostShell(column(@[], key="workload"), @[
      component(RouterHost, 0),
      component(OutletFarm, 0),
      component(LocalCounter, 0)]))

let LogicalPage = defineComponent[int, State[int]]("LogicalPage",
  proc(ctx: MountContext, p: int): State[int] =
    result = ctx.state(0)
    flip = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    let n = ctx.value(s)
    host(if n == 0: button("logical", key="shared")
      else: text("logical", key="shared")))

let LogicalRouter = defineComponent[int, int]("LogicalRouter",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    pageOutlet(PageOutletSpec(routerId: 500, page: "logical", view: "main",
      build: proc(): UiDescription = component(LogicalPage, 0)), "logical-outlet"))

proc recordingConsumer(sessionId: uint64): HostConsumer =
  HostConsumer(sessionId: sessionId,
    prepare: proc(batch: HostBatch) =
      for op in batch.ops: observedOps.add(op),
    apply: proc() = discard,
    accept: proc(revision: uint64) {.raises: [].} = discard,
    discardPrepared: proc() {.raises: [].} = discard)

proc consumer(sessionId: uint64): HostConsumer
proc newRtWorkload(sessionId = 20'u64): tuple[rt: Runtime, session: HostSession] =
  let rt = newRuntime(componentApplication(component(WorkloadHost, 0), "workload"))
  (rt, attachHostSession(rt, consumer(sessionId)))

proc reset() =
  initA = 0; initB = 0; initAlt = 0; renderA = 0; renderB = 0; clicksA = 0; localRender = 0
  retentionPolicy = PageRetention.retainState
  outletKey = "outlet-key"
  duplicateOutlet = false
  aRootColumn = true
  configurationBytes = 0
  currentView = "main"
  farmOutlets = 8
  nestedToken = 0'u64
  duplicateNested = false
  observedOps.setLen(0)
  stateA = default(State[int]); stateB = default(State[int])
  route = default(State[int]); localState = default(State[int]); flip = default(State[int])

proc consumer(sessionId: uint64): HostConsumer =
  HostConsumer(sessionId: sessionId,
    prepare: proc(batch: HostBatch) = discard,
    apply: proc() = discard,
    accept: proc(revision: uint64) {.raises: [].} = discard,
    discardPrepared: proc() {.raises: [].} = discard)

proc newRt(sessionId = 1'u64): tuple[rt: Runtime, session: HostSession] =
  let rt = newRuntime(componentApplication(component(RouterHost, 0), "outlets"))
  (rt, attachHostSession(rt, consumer(sessionId)))

proc go(rt: Runtime, index: int) =
  discard route.set(index)
  discard rt.flush()

proc texts(mounted: MountedNode): seq[string] =
  result.add(mounted.node.text)
  for child in mounted.children: result.add(texts(child))

suite "managed page outlet specs":
  test "invalid outlet specs are rejected before use":
    expect UiError:
      discard pageOutlet(PageOutletSpec(routerId: 0, page: "a", view: "v",
        build: proc(): UiDescription = nil), "k")
    expect UiError:
      discard pageOutlet(PageOutletSpec(routerId: 1, page: "", view: "v",
        build: proc(): UiDescription = nil), "k")
    expect UiError:
      discard pageOutlet(PageOutletSpec(routerId: 1, page: "a", view: "v",
        configurationBytes: -1, build: proc(): UiDescription = nil), "k")
    expect UiError:
      discard pageOutlet(PageOutletSpec(routerId: 1, page: "a", view: "v",
        configurationBytes: MaxTreeBytes + 1, build: proc(): UiDescription = nil), "k")
    expect UiError:
      discard pageOutlet(PageOutletSpec(routerId: 1, page: "a", view: "v",
        configurationBytes: high(int), build: proc(): UiDescription = nil), "k")
    expect UiError:
      discard pageOutlet(PageOutletSpec(routerId: 1, page: "a", view: "v"), "k")
    expect UiError:
      discard pageOutlet(PageOutletSpec(routerId: 1, page: "bad\xff", view: "v",
        build: proc(): UiDescription = nil), "k")
    expect UiError:
      discard outletSpec(host(text("not an outlet", key="n")))

suite "managed page outlet retention":
  test "retention_remounts_hosts_without_reinitializing_state":
    reset()
    let (rt, session) = newRt()
    check initA == 1
    check initB == 0
    for i in 0 ..< 3: discard rt.dispatch("count", Event(kind: click))
    check stateA.read() == 3
    check rt.find("shared").node.text == "a3"
    let handleBefore = session.handleFor(rt.find("count").id)
    check uint64(handleBefore) != 0
    go(rt, 1)
    check rt.find("shared").node.text == "b0"
    check session.record(handleBefore).isNone
    let rendersA = renderA
    go(rt, 0)
    check stateA.read() == 3
    check rt.find("shared").node.text == "a3"
    check initA == 1
    check renderA > rendersA
    let handleAfter = session.handleFor(rt.find("count").id)
    check uint64(handleAfter) != uint64(handleBefore)
    check not session.dispatch(handleBefore, 1, rt.acceptedRevision, 1, 1, Event(kind: click))
    check session.dispatch(handleAfter, 2, rt.acceptedRevision, 1, 1, Event(kind: click))
    check stateA.read() == 4
    session.close()

  test "dispose_on_leave_reinitializes":
    reset()
    retentionPolicy = PageRetention.disposeOnLeave
    let (rt, session) = newRt()
    discard rt.dispatch("count", Event(kind: click))
    check stateA.read() == 1
    let oldState = stateA
    go(rt, 1)
    check oldState.set(5) == StateWriteResult.disposed
    check initA == 1
    go(rt, 0)
    check initA == 2
    check stateA.read() == 0
    check rt.find("shared").node.text == "a0"
    session.close()

  test "inactive_state_accepts_without_rendering":
    reset()
    let (rt, session) = newRt()
    let inactive = stateA
    let rendersA = renderA
    go(rt, 1)
    check inactive.set(7) == StateWriteResult.queued
    check rt.flush()
    check inactive.read() == 7
    check renderA == rendersA
    go(rt, 0)
    check rt.find("shared").node.text == "a7"
    session.close()

  test "outlet_walkers_export_only_active_page":
    reset()
    let (rt, session) = newRt()
    check rt.find("shared").node.text == "a0"
    var exported = texts(rt.snapshot.root)
    check "a0" in exported
    check "b0" notin exported
    check "b-only" notin exported
    go(rt, 1)
    check rt.find("shared").node.text == "b0"
    exported = texts(rt.snapshot.root)
    check "b0" in exported
    check "a0" notin exported
    expect UiError:
      discard rt.find("missing-on-b")
    session.close()

  test "dynamic_page_root_updates_the_host_parent":
    reset()
    let (rt, session) = newRt()
    let routerHandle = session.handleFor(rt.find("router-column").id)
    check uint64(routerHandle) != 0
    let rootBefore = managedReconciler(rt).children(routerHandle)
    check rootBefore.len == 1
    aRootColumn = false
    rt.invalidateRoot()
    check rt.flush()
    check rt.find("shared").node.text == "a0"
    let rootAfter = managedReconciler(rt).children(routerHandle)
    check rootAfter.len == 1
    check uint64(rootAfter[0]) != uint64(rootBefore[0])
    session.close()

  test "outlet_key_change_is_not_a_duplicate_router":
    reset()
    let (rt, session) = newRt()
    discard rt.dispatch("count", Event(kind: click))
    let retainedA = stateA
    go(rt, 1)
    outletKey = "renamed-outlet-key"
    rt.invalidateRoot()
    check rt.flush()
    check rt.find("shared").node.text == "b0"
    check initB == 2
    check retainedA.set(5) == StateWriteResult.disposed
    session.close()

  test "duplicate_router_id_is_rejected_before_acceptance":
    reset()
    duplicateOutlet = false
    let (rt, session) = newRt()
    let revision = rt.acceptedRevision
    duplicateOutlet = true
    rt.invalidateRoot()
    expect UiError:
      discard rt.flush()
    check rt.acceptedRevision == revision
    check rt.find("shared").node.text == "a0"
    session.close()

  test "oversized_configuration_bytes_reject_without_poisoning_the_attempt":
    reset()
    let (rt, session) = newRt()
    let revision = rt.acceptedRevision
    check stateA.read() == 0
    configurationBytes = MaxTreeBytes + 1
    rt.invalidateRoot()
    expect UiError:
      discard rt.flush()
    check rt.acceptedRevision == revision
    check stateA.read() == 0
    check rt.find("shared").node.text == "a0"
    configurationBytes = 0
    check stateA.set(4) == StateWriteResult.queued
    check rt.flush()
    check stateA.read() == 4
    session.close()

  test "logical_root_outlet_chain_updates_ancestor_boundary":
    reset()
    let rt = newRuntime(componentApplication(component(LogicalRouter, 0), "logical"))
    let session = attachHostSession(rt, recordingConsumer(30'u64))
    let before = session.handleFor(rt.find("shared").id)
    check uint64(before) != 0
    observedOps.setLen(0)
    check flip.set(1) == StateWriteResult.queued
    check rt.flush()
    let after = session.handleFor(rt.find("shared").id)
    check uint64(after) != uint64(before)
    check session.record(before).isNone
    var boundary = false
    for op in observedOps:
      if op.kind == HostOpKind.boundary and uint64(op.boundary.root) == uint64(after) and
          op.boundary.parent == 0'u64:
        boundary = true
    check boundary
    session.close()

  test "same_page_view_swaps_component_type_and_disposes_old_state":
    reset()
    let (rt, session) = newRt()
    discard rt.dispatch("count", Event(kind: click))
    check stateA.read() == 1
    let oldA = stateA
    currentView = "alt"
    rt.invalidateRoot()
    check rt.flush()
    check oldA.set(9) == StateWriteResult.disposed
    check initAlt == 1
    check rt.find("alt-only").node.text == "alt"
    expect UiError:
      discard rt.find("shared")
    currentView = "main"
    rt.invalidateRoot()
    check rt.flush()
    check initA == 2
    check rt.find("shared").node.text == "a0"
    check oldA.set(9) == StateWriteResult.disposed
    session.close()

  test "hidden_retained_outlet_still_occupies_its_router_token":
    reset()
    nestedToken = 700
    let (rt, session) = newRt()
    check uint64(session.handleFor(rt.find("nested").id)) != 0
    go(rt, 1)
    expect UiError:
      discard rt.find("nested")
    duplicateNested = true
    rt.invalidateRoot()
    expect UiError:
      discard rt.flush()
    session.close()

  when defined(leafProtocolProbes):
    test "local_and_inactive_state_updates_do_not_scan_the_outlet_index":
      reset()
      outletIndexLookups = 0
      outletIndexEdits = 0
      let (rt, session) = newRtWorkload()
      # Setup touched and registered every farm and router outlet once.
      check outletIndexLookups >= uint64(farmOutlets)
      for i in 0 ..< farmOutlets:
        check rt.find("farm" & $i) != nil
      outletIndexLookups = 0
      outletIndexEdits = 0
      check localState.set(1) == StateWriteResult.queued
      check rt.flush()
      check localState.read() == 1
      check outletIndexLookups == 0
      check outletIndexEdits == 0
      go(rt, 1)
      outletIndexLookups = 0
      outletIndexEdits = 0
      check stateA.set(5) == StateWriteResult.queued
      check rt.flush()
      check stateA.read() == 5
      check outletIndexLookups == 0
      check outletIndexEdits == 0
      session.close()
