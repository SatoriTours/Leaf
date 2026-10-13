## Task 4: navigation rejection, accepted-scope errors and nested disposal.
import std/[unittest, tables, options]
import leaf/[core, widgets, components, backend, host_session, native_host_adapter]
import leaf/component_description
import leaf/component_state
import leaf/managed_runtime

var initA, initB, clicksA, navCalls = 0
var stateA, stateB: State[int]
var router: ComponentRouter
var showNav = true

type FaultMode = enum none, build, validator, prepare, apply, scopeEntry, scopeExit
var fault = none

let PageA = defineComponent[int, State[int]]("FaultPageA",
  proc(ctx: MountContext, p: int): State[int] =
    inc initA
    stateA = ctx.state(0)
    stateA,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    let n = ctx.value(s)
    hostShell(column(@[]), @[
      host(text("a" & $n, key="shared")),
      host(button("a+", key="count", onClick=proc(e: Event) =
        inc clicksA
        discard s.set(n + 1))),
      host(button("nav", key="nav", onClick=proc(e: Event) =
        inc navCalls
        discard navigate(router, "second")))]))

let PageB = defineComponent[int, State[int]]("FaultPageB",
  proc(ctx: MountContext, p: int): State[int] =
    inc initB
    stateB = ctx.state(0)
    stateB,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    if fault == build: fail("candidate page build")
    hostShell(column(@[]), @[host(text("b" & $ctx.value(s), key="shared"))]))

let testRoutes = @[
  Route(name: "home", path: "/", page: "page", view: "main"),
  Route(name: "second", path: "/second", page: "other", view: "main")]
let testPages = @[
  ComponentPageDefinition(name: "page", views: @["main"],
    build: proc(view: string): UiDescription = component(PageA, 0)),
  ComponentPageDefinition(name: "other", views: @["main"],
    build: proc(view: string): UiDescription = component(PageB, 0))]

let NavHost = defineComponent[int, int]("FaultNavHost",
  proc(ctx: MountContext, p: int): int =
    router = newComponentRouter(ctx, testRoutes, testPages, "/")
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    renderPage(ctx, router))

let Shell = defineComponent[int, int]("FaultShell",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    if showNav: hostShell(column(@[], key="shell"), @[component(NavHost, 0)])
    else: host(text("empty", key="empty")))

proc faultConsumer(sessionId: uint64): HostConsumer =
  HostConsumer(sessionId: sessionId,
    prepare: proc(batch: HostBatch) =
      if fault == prepare: fail("consumer prepare"),
    apply: proc() =
      if fault == apply: fail("consumer apply"),
    accept: proc(revision: uint64) {.raises: [].} = discard,
    discardPrepared: proc() {.raises: [].} = discard)

proc newFaultRt(sessionId = 60'u64): tuple[rt: Runtime, session: HostSession] =
  var scope: ExecutionScope
  scope = proc(body: proc() {.closure.}) =
    if fault == scopeEntry: fail("scope entry")
    body()
    if fault == scopeExit: fail("scope exit")
  let rt = newRuntime(componentApplication(component(Shell, 0), "faults", executionScope = scope))
  rt.setValidator(proc(snapshot: Snapshot) =
    if fault == validator: fail("validator"))
  (rt, attachHostSession(rt, faultConsumer(sessionId)))

proc reset() =
  initA = 0; initB = 0; clicksA = 0; navCalls = 0
  stateA = default(State[int]); stateB = default(State[int])
  router = default(ComponentRouter)
  showNav = true
  fault = none

suite "managed page navigation rejection":
  test "navigation_rejection_preserves_all_accepted_state":
    for mode in [build, validator, prepare, apply, scopeEntry]:
      reset()
      fault = none
      let (rt, session) = newFaultRt()
      let revision = rt.acceptedRevision
      let acceptedA = stateA
      check acceptedA.read() == 0
      fault = mode
      check navigate(router, "second") == StateWriteResult.queued
      expect UiError:
        discard rt.flush()
      check rt.acceptedRevision == revision
      check currentRoute(router).name == "home"
      check acceptedA.read() == 0
      if mode == scopeEntry:
        # Scope entry fails before the candidate stage creates any State.
        check initB == 0
      else:
        check initB == 1
        check stateB.set(0) == StateWriteResult.disposed
      check rt.find("shared").node.text == "a0"
      # Recovery: clear the injector, old page events still work, then navigate.
      fault = none
      discard rt.flush()
      discard navigate(router, "home")
      check rt.flush()
      check rt.find("shared").node.text == "a0"
      discard rt.dispatch("count", Event(kind: click))
      check acceptedA.read() == 1
      discard navigate(router, "second")
      check rt.flush()
      check rt.find("shared").node.text == "b0"
      session.close()

  test "hidden_page_state_survives_navigation_and_dies_with_the_router":
    reset()
    let (rt, session) = newFaultRt(61'u64)
    let acceptedA = stateA
    discard navigate(router, "second")
    check rt.flush()
    # A is hidden and retained; its State still accepts updates.
    check acceptedA.set(5) == StateWriteResult.queued
    check rt.flush()
    check acceptedA.read() == 5
    expect UiError:
      discard rt.find("count")
    discard navigate(router, "home")
    check rt.flush()
    check rt.find("shared").node.text == "a5"
    # Unmounting the owner disposes the retained page State.
    showNav = false
    rt.invalidateRoot()
    check rt.flush()
    check acceptedA.set(6) == StateWriteResult.disposed
    check navigate(router, "second") == StateWriteResult.disposed
    session.close()

  test "accepted_scope_error_does_not_replay_navigation":
    reset()
    fault = none
    let (rt, session) = newFaultRt(62'u64)
    let revision = rt.acceptedRevision
    fault = scopeExit
    expect UiError:
      discard rt.dispatch("nav", Event(kind: click))
    check navCalls == 1
    check rt.acceptedRevision == revision + 1
    check currentRoute(router).name == "second"
    check rt.find("shared").node.text == "b0"
    fault = none
    discard rt.flush()
    check navCalls == 1
    check rt.acceptedRevision == revision + 1
    session.close()

  test "restore_failure_freezes_business_events":
    reset()
    let rt = newRuntime(componentApplication(component(Shell, 0), "restore"))
    var reject = false
    let backend = Backend(capabilities: fullCapabilities(),
      prepare: proc(batch: UpdateBatch) = discard,
      apply: proc(batch: UpdateBatch) =
        if reject: fail("apply failed"),
      discardPrepared: proc() = discard,
      restore: proc(entities: Table[NodeHandle, MountedEntity]) = fail("restore failed"),
      dispose: proc() = discard)
    let session = attachHostSession(rt, nativeHostConsumer(backend,
      onFault = proc(reason: string) {.raises: [].} = rt.freezeEvents(reason)))
    navCalls = 0
    reject = true
    expect UiError:
      discard rt.dispatch("nav", Event(kind: click))
    check navCalls == 1
    expect UiError:
      discard rt.dispatch("nav", Event(kind: click))
    check navCalls == 1
    session.close()

var deepRowHandles: Table[int, State[int]]
var innerState: State[int]
var innerInit = 0
var deepKeys: seq[string]

let DeepRow = defineComponent[int, State[int]]("DeepListRow",
  proc(ctx: MountContext, p: int): State[int] =
    result = ctx.state(p)
    deepRowHandles[p] = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    host(text($ctx.value(s), key="row")))

let InnerPage = defineComponent[int, State[int]]("DeepInnerPage",
  proc(ctx: MountContext, p: int): State[int] =
    inc innerInit
    result = ctx.state(0)
    innerState = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    host(text("inner" & $ctx.value(s), key="inner")))

var innerRouter: ComponentRouter
let innerRoutes = @[Route(name: "inner", path: "/", page: "inner", view: "main")]
let innerPages = @[ComponentPageDefinition(name: "inner", views: @["main"],
  build: proc(view: string): UiDescription = component(InnerPage, 0))]

let InnerRouterHost = defineComponent[int, int]("DeepInnerRouterHost",
  proc(ctx: MountContext, p: int): int =
    innerRouter = newComponentRouter(ctx, innerRoutes, innerPages, "inner")
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    renderPage(ctx, innerRouter))

proc deepKeysOnce(): seq[string] =
  if deepKeys.len == 0:
    for i in 0 ..< 100000: deepKeys.add($i)
  deepKeys

let DeepPage = defineComponent[int, int]("DeepPage",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    hostShell(column(@[], key="deep"), @[
      component(InnerRouterHost, 0),
      componentList("items", deepKeysOnce(),
        proc(i: int): UiDescription = component(DeepRow, i), rowHeight = 24, overscan = 0)]))

let OtherPage = defineComponent[int, int]("DeepOtherPage",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    host(text("other", key="other")))

var deepRouter: ComponentRouter
let deepRoutes = @[
  Route(name: "deep", path: "/", page: "deep", view: "main"),
  Route(name: "other", path: "/other", page: "other", view: "main")]
let deepPages = @[
  ComponentPageDefinition(name: "deep", views: @["main"],
    build: proc(view: string): UiDescription = component(DeepPage, 0)),
  ComponentPageDefinition(name: "other", views: @["main"],
    build: proc(view: string): UiDescription = component(OtherPage, 0))]

let DeepHost = defineComponent[int, int]("DeepHost",
  proc(ctx: MountContext, p: int): int =
    deepRouter = newComponentRouter(ctx, deepRoutes, deepPages, "deep")
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    renderPage(ctx, deepRouter))

var showDeep = true
let DeepShell = defineComponent[int, int]("DeepShell",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    if showDeep: hostShell(column(@[], key="deep-shell"), @[component(DeepHost, 0)])
    else: host(text("empty-deep", key="empty-deep")))

suite "managed nested page disposal":
  test "nested_router_and_warm_rows_are_disposed":
    deepRowHandles.clear()
    innerState = default(State[int])
    innerInit = 0
    showDeep = true
    let rt = newRuntime(componentApplication(component(DeepShell, 0), "deep"))
    let session = attachHostSession(rt, faultConsumer(63'u64))
    check innerInit == 1
    discard rt.materialize("items", 0, 50)
    check rt.listStats("items").activeRows == 50
    check deepRowHandles.len == 50
    discard rt.materialize("items", 5000, 5050)
    check deepRowHandles.len == 100
    check rt.listStats("items").activeRows == 50
    check rt.listStats("items").warmRows == 50
    # Retain the page (and its warm rows), then unmount the outer owner.
    discard navigate(deepRouter, "other")
    check rt.flush()
    expect UiError:
      discard rt.find("row")
    showDeep = false
    rt.invalidateRoot()
    check rt.flush()
    for i in 0 ..< 50:
      check deepRowHandles[i].set(i) == StateWriteResult.disposed
    for i in 5000 ..< 5050:
      check deepRowHandles[i].set(i) == StateWriteResult.disposed
    check innerState.set(1) == StateWriteResult.disposed
    session.close()
