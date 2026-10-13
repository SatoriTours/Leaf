## Task 2: low-level page outlets and retained page lifecycle. Uses the managed
## runtime directly; the public renderPage/router API belongs to Task 3.
import std/[unittest, tables, options]
import leaf/[core, widgets, components, host_session]
import leaf/component_description
import leaf/managed_runtime

var initA, initB, renderA, renderB, clicksA = 0
var stateA, stateB: State[int]
var route: State[int]
var retentionPolicy = PageRetention.retainState
var outletKey = "outlet-key"
var duplicateOutlet = false
var aRootColumn = true

let PageA = defineComponent[int, State[int]]("OutletPageA",
  proc(ctx: MountContext, p: int): State[int] =
    inc initA
    stateA = ctx.state(0)
    stateA,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    inc renderA
    let n = ctx.value(s)
    let container = if aRootColumn: column(@[]) else: row(@[])
    hostShell(container, @[
      host(text("a" & $n, key="shared")),
      host(button("a+", key="count", onClick=proc(e: Event) =
        inc clicksA
        discard s.set(n + 1)))]))

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

let RouterHost = defineComponent[int, State[int]]("OutletRouterHost",
  proc(ctx: MountContext, p: int): State[int] =
    result = ctx.state(0)
    route = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    let index = ctx.value(s)
    let page = if index == 0: "a" else: "b"
    let spec = PageOutletSpec(routerId: 77, page: page, view: "main",
      retention: retentionPolicy, configurationBytes: 0,
      build: proc(): UiDescription =
        if index == 0: component(PageA, 0) else: component(PageB, 0))
    var children = @[pageOutlet(spec, outletKey)]
    if duplicateOutlet: children.add(pageOutlet(spec, outletKey & "-dup"))
    hostShell(column(@[], key="router-column"), children))

proc reset() =
  initA = 0; initB = 0; renderA = 0; renderB = 0; clicksA = 0
  retentionPolicy = PageRetention.retainState
  outletKey = "outlet-key"
  duplicateOutlet = false
  aRootColumn = true
  stateA = default(State[int]); stateB = default(State[int]); route = default(State[int])

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
