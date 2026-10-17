## Task 3: public managed page navigation. Exercises the exported controller and
## renderPage against a real component Runtime; the ABI1 compatibility view is
## the accepted `runtime.snapshot.toJson()` tree.
import std/[unittest, strutils, json]
import leaf/[core, widgets, components, host_session]
import leaf/component_description
import leaf/component_state
import leaf/managed_runtime
import leaf/task_contracts

var initA, initB, renderA, renderB, clicksA, lazyBuilds, bigInit = 0
var stateA, stateB: State[int]
var router: ComponentRouter
var outletKey = "page-outlet"
var showNav = true
var duplicateOutlet = false
var bigRouterCount = 1
var savedCtx, failedCtx: MountContext
var borrowSavedCtx = false
var showBorrower = false
var ctxMode = 0
var ctxFreshInit = 0
var ctxState: State[int]

let PageA = defineComponent[int, State[int]]("PublicPageA",
  proc(ctx: MountContext, p: int): State[int] =
    inc initA
    stateA = ctx.state(0)
    stateA,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    inc renderA
    let n = ctx.value(s)
    hostShell(column(@[]), @[
      host(text("a" & $n, key="shared")),
      host(button("a+", key="count", onClick=proc(e: Event) =
        inc clicksA
        discard s.set(n + 1)))]))

let PageB = defineComponent[int, State[int]]("PublicPageB",
  proc(ctx: MountContext, p: int): State[int] =
    inc initB
    stateB = ctx.state(0)
    stateB,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    inc renderB
    hostShell(column(@[]), @[
      host(text("b" & $ctx.value(s), key="shared")),
      host(text("b-only", key="b-only"))]))

let testRoutes = @[
  Route(name: "home", path: "/", page: "page", view: "main"),
  Route(name: "alt", path: "/alt", page: "page", view: "alt"),
  Route(name: "second", path: "/second", page: "other", view: "main")]
let testPages = @[
  ComponentPageDefinition(name: "page", views: @["main", "alt"],
    build: proc(view: string): UiDescription = component(PageA, view.len)),
  ComponentPageDefinition(name: "other", views: @["main"],
    build: proc(view: string): UiDescription = component(PageB, 0))]

let NavHost = defineComponent[int, int]("PublicNavHost",
  proc(ctx: MountContext, p: int): int =
    router = newComponentRouter(ctx, testRoutes, testPages, "/")
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    if duplicateOutlet:
      hostShell(column(@[], key="dup-column"), @[
        renderPage(ctx, router, outletKey),
        renderPage(ctx, router, outletKey & "-2")])
    else:
      renderPage(ctx, router, outletKey))

let Shell = defineComponent[int, int]("PublicShell",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    if showNav: hostShell(column(@[], key="shell"), @[component(NavHost, 0)])
    else: host(text("empty", key="empty")))

proc bigRoutes(): seq[Route] =
  for i in 0 ..< 5:
    let prefix = "/b" & $i
    result.add(Route(name: "big" & $i,
      path: prefix & repeat("p", MaxStringBytes - prefix.len),
      page: "big", view: "main"))

let bigPages = @[ComponentPageDefinition(name: "big", views: @["main"],
  build: proc(view: string): UiDescription = host(text("big", key="big")))]

let BigHost = defineComponent[int, int]("BigRouterHost",
  proc(ctx: MountContext, p: int): int =
    inc bigInit
    for i in 0 ..< bigRouterCount:
      discard newComponentRouter(ctx, bigRoutes(), bigPages, "big0")
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    host(text("big", key="big")))

let smallRoutes = @[Route(name: "small", path: "/", page: "small", view: "main")]
let smallPages = @[ComponentPageDefinition(name: "small", views: @["main"],
  build: proc(view: string): UiDescription = host(text("small", key="small")))]

let CtxOwner = defineComponent[int, State[int]]("CtxOwner",
  proc(ctx: MountContext, p: int): State[int] =
    savedCtx = ctx
    discard newComponentRouter(ctx, smallRoutes, smallPages, "small")
    result = ctx.state(0)
    ctxState = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    host(text("ctx-a", key="ctx-a")))

let CtxBorrower = defineComponent[int, int]("CtxBorrower",
  proc(ctx: MountContext, p: int): int =
    if borrowSavedCtx:
      discard newComponentRouter(savedCtx, bigRoutes(), bigPages, "big0")
    else:
      discard newComponentRouter(ctx, smallRoutes, smallPages, "small")
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    host(text("ctx-b", key="ctx-b")))

let CtxFailer = defineComponent[int, int]("CtxFailer",
  proc(ctx: MountContext, p: int): int =
    failedCtx = ctx
    fail("initializer failed"),
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    host(text("ctx-f", key="ctx-f")))

let CtxBorrowFailed = defineComponent[int, int]("CtxBorrowFailed",
  proc(ctx: MountContext, p: int): int =
    discard newComponentRouter(failedCtx, smallRoutes, smallPages, "small")
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    host(text("ctx-bf", key="ctx-bf")))

let CtxFresh = defineComponent[int, int]("CtxFresh",
  proc(ctx: MountContext, p: int): int =
    inc ctxFreshInit
    discard newComponentRouter(ctx, smallRoutes, smallPages, "small")
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    host(text("ctx-fresh", key="ctx-fresh")))

let CtxShell = defineComponent[int, int]("CtxShell",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    var children = @[component(CtxOwner, 0)]
    if showBorrower: children.add(component(CtxBorrower, 0))
    case ctxMode
    of 1: children.add(component(CtxFailer, 0))
    of 2: children.add(component(CtxBorrowFailed, 0))
    of 3: children.add(component(CtxFresh, 0))
    else: discard
    hostShell(column(@[], key="ctx-shell"), children))

proc consumer(sessionId: uint64): HostConsumer =
  HostConsumer(sessionId: sessionId,
    prepare: proc(batch: HostBatch) = discard,
    apply: proc() = discard,
    accept: proc(revision: uint64) {.raises: [].} = discard,
    discardPrepared: proc() {.raises: [].} = discard)

proc reset() =
  initA = 0; initB = 0; renderA = 0; renderB = 0; clicksA = 0; lazyBuilds = 0; bigInit = 0
  outletKey = "page-outlet"
  showNav = true
  duplicateOutlet = false
  bigRouterCount = 1
  savedCtx = nil
  failedCtx = nil
  borrowSavedCtx = false
  showBorrower = false
  ctxMode = 0
  ctxFreshInit = 0
  ctxState = default(State[int])
  stateA = default(State[int]); stateB = default(State[int])
  router = default(ComponentRouter)

proc newRt(sessionId = 1'u64): tuple[rt: Runtime, session: HostSession] =
  let rt = newRuntime(componentApplication(component(Shell, 0), "routing"))
  (rt, attachHostSession(rt, consumer(sessionId)))

suite "public managed page navigation":
  test "public_navigation_preserves_page_state":
    reset()
    let (rt, session) = newRt()
    check initA == 1
    check initB == 0
    for i in 0 ..< 3: discard rt.dispatch("count", Event(kind: click))
    check stateA.read() == 3
    check rt.find("shared").node.text == "a3"
    discard navigate(router, "second")
    check rt.flush()
    check initB == 1
    check rt.find("shared").node.text == "b0"
    check initA == 1
    check stateA.read() == 3
    discard navigate(router, "/")
    check rt.flush()
    check rt.find("shared").node.text == "a3"
    check initA == 1
    discard navigate(router, "alt")
    check rt.flush()
    check currentRoute(router).view == "alt"
    check rt.find("shared").node.text == "a3"
    check initA == 1
    discard navigate(router, "second")
    discard navigate(router, "home")
    check rt.flush()
    check currentRoute(router).name == "home"
    let renders = renderA
    discard navigate(router, "home")
    check rt.flush()
    check renderA == renders
    session.close()

  test "owner_and_single_outlet_are_enforced":
    reset()
    let (rt, session) = newRt()
    let revision = rt.acceptedRevision
    # right owner on a standalone store returns a lazy outlet
    let store = newStateStore(3)
    store.setPhase(StatePhase.initializing)
    let standalone = newComponentRouter(newMountContext(store, 42), testRoutes, testPages, "/")
    store.setPhase(StatePhase.idle)
    let attempt = store.beginAttempt()
    store.setPhase(StatePhase.rendering)
    check renderPage(newComponentContext(store, attempt, 42), standalone).kind ==
      DescriptionKind.pageOutlet
    expect UiError:
      discard renderPage(newComponentContext(store, attempt, 43), standalone)
    store.setPhase(StatePhase.idle)
    store.reject(attempt)
    let acceptedA = stateA
    # cross-runtime context is rejected
    let other = newStateStore(4)
    let otherAttempt = other.beginAttempt()
    expect UiError:
      discard renderPage(newComponentContext(other, otherAttempt, 42), router)
    other.reject(otherAttempt)
    # two outlets for one router are rejected before acceptance
    duplicateOutlet = true
    rt.invalidateRoot()
    expect UiError:
      discard rt.flush()
    check rt.acceptedRevision == revision
    check rt.find("shared").node.text == "a0"
    check acceptedA.read() == 0
    duplicateOutlet = false
    rt.invalidateRoot()
    check rt.flush()
    session.close()

  test "router_key_change_and_parent_removal_dispose_all_pages":
    reset()
    var (rt, session) = newRt()
    discard rt.dispatch("count", Event(kind: click))
    let retainedA = stateA
    discard navigate(router, "second")
    check rt.flush()
    let retainedB = stateB
    outletKey = "renamed-page-outlet"
    rt.invalidateRoot()
    check rt.flush()
    check retainedA.set(5) == StateWriteResult.disposed
    check retainedB.set(5) == StateWriteResult.disposed
    check initB == 2
    let currentB = stateB
    showNav = false
    rt.invalidateRoot()
    check rt.flush()
    check currentB.set(5) == StateWriteResult.disposed
    check navigate(router, "missing") == StateWriteResult.disposed
    session.close()
    # navigate and remove the parent in the same candidate never resurrects pages
    reset()
    let (rt2, session2) = newRt(2'u64)
    let pageA = stateA
    discard navigate(router, "second")
    showNav = false
    rt2.invalidateRoot()
    check rt2.flush()
    check pageA.set(5) == StateWriteResult.disposed
    check navigate(router, "missing") == StateWriteResult.disposed
    session2.close()

  test "controller_configuration_budget_is_counted_once_and_released":
    reset()
    showNav = false
    let emptyRt = newRuntime(componentApplication(component(Shell, 0), "empty-shell"))
    let emptyBytes = emptyRt.stats.treeBytes
    reset()
    let (rt, session) = newRt()
    let withRouter = rt.stats.treeBytes
    check withRouter > emptyBytes
    # A pure root re-render is byte-stable and does not recount the controller.
    rt.invalidateRoot()
    check rt.flush()
    check rt.stats.treeBytes == withRouter
    # First visit to B legitimately adds the B subtree and its registry key.
    discard navigate(router, "second")
    check rt.flush()
    let warmB = rt.stats.treeBytes
    check warmB > withRouter
    discard navigate(router, "home")
    check rt.flush()
    let warmA = rt.stats.treeBytes
    # Warm A<->B navigation only reuses retained metadata per address.
    discard navigate(router, "second")
    check rt.flush()
    check rt.stats.treeBytes == warmB
    discard navigate(router, "home")
    check rt.flush()
    check rt.stats.treeBytes == warmA
    rt.invalidateRoot()
    check rt.flush()
    check rt.stats.treeBytes == warmA
    # Removing the owner releases the full owned configuration charge: the tree
    # is exactly the empty-Shell baseline, and remount/unmount is repeatable.
    showNav = false
    rt.invalidateRoot()
    check rt.flush()
    check rt.stats.treeBytes == emptyBytes
    showNav = true
    rt.invalidateRoot()
    check rt.flush()
    check rt.stats.treeBytes == withRouter
    showNav = false
    rt.invalidateRoot()
    check rt.flush()
    check rt.stats.treeBytes == emptyBytes
    session.close()

  test "aggregate_unrendered_controller_budget_is_rejected":
    reset()
    bigRouterCount = 1
    # A single legal unrendered controller initializes and its config is charged.
    let control = newRuntime(componentApplication(host(text("big", key="big")), "big-control"))
    let controlBytes = control.stats.treeBytes
    let single = newRuntime(componentApplication(component(BigHost, 0), "big-one"))
    check bigInit == 1
    check single.stats.treeBytes > controlBytes
    # Same owner, two large controllers that are never rendered.
    reset()
    bigRouterCount = 2
    expect UiError:
      discard newRuntime(componentApplication(component(BigHost, 0), "big-same"))
    # Different owners, one large controller each, aggregate over budget.
    reset()
    bigRouterCount = 1
    expect UiError:
      discard newRuntime(componentApplication(
        hostShell(column(@[], key="bigroot"), @[component(BigHost, 0), component(BigHost, 0)]),
        "big-owners"))

  test "renderPage_is_lazy_and_builds_only_when_reconciled":
    reset()
    let lazyPages = @[ComponentPageDefinition(name: "lazy", views: @["main"],
      build: proc(view: string): UiDescription =
        inc lazyBuilds
        host(text("lazy", key="lazy")))]
    let lazyRoutes = @[Route(name: "lazy", path: "/", page: "lazy", view: "main")]
    let store = newStateStore(5)
    store.setPhase(StatePhase.initializing)
    let standalone = newComponentRouter(newMountContext(store, 7), lazyRoutes, lazyPages, "/")
    store.setPhase(StatePhase.idle)
    let attempt = store.beginAttempt()
    store.setPhase(StatePhase.rendering)
    let outlet = renderPage(newComponentContext(store, attempt, 7), standalone)
    check lazyBuilds == 0
    check outlet.kind == DescriptionKind.pageOutlet
    check outletSpec(outlet).page == "lazy"
    store.setPhase(StatePhase.idle)
    store.reject(attempt)

  test "accepted_snapshot_exports_only_the_active_page":
    reset()
    let (rt, session) = newRt()
    var tree = $rt.snapshot.toJson()
    check "a0" in tree
    check "b0" notin tree
    discard navigate(router, "second")
    check rt.flush()
    tree = $rt.snapshot.toJson()
    check "b0" in tree
    check "a0" notin tree
    let revision = rt.acceptedRevision
    duplicateOutlet = true
    rt.invalidateRoot()
    expect UiError:
      discard rt.flush()
    check rt.acceptedRevision == revision
    let rejected = $rt.snapshot.toJson()
    check "b0" in rejected
    check "a0" notin rejected
    session.close()

  test "sealed_mount_context_cannot_charge_a_later_initialization":
    reset()
    showBorrower = false
    borrowSavedCtx = true
    let rt = newRuntime(componentApplication(component(CtxShell, 0), "ctx-frame"))
    let session = attachHostSession(rt, consumer(40'u64))
    let aCharge = ownedDescriptionBytes(savedCtx)
    check aCharge > 0
    let revision = rt.acceptedRevision
    showBorrower = true
    rt.invalidateRoot()
    expect UiError:
      discard rt.flush()
    check rt.acceptedRevision == revision
    check ownedDescriptionBytes(savedCtx) == aCharge
    check ctxState.read() == 0
    check rt.find("ctx-a") != nil
    # The same Runtime continues; B may use its own fresh initialization frame.
    borrowSavedCtx = false
    rt.invalidateRoot()
    check rt.flush()
    check rt.acceptedRevision == revision + 1
    check rt.find("ctx-b") != nil
    session.close()

  test "failed_initializer_seals_its_context_for_the_same_store":
    reset()
    ctxMode = 0
    let rt = newRuntime(componentApplication(component(CtxShell, 0), "ctx-exc"))
    let session = attachHostSession(rt, consumer(41'u64))
    let revision = rt.acceptedRevision
    let aCharge = ownedDescriptionBytes(savedCtx)
    # A candidate child initializer saves its context and throws.
    ctxMode = 1
    rt.invalidateRoot()
    expect UiError:
      discard rt.flush()
    check failedCtx != nil
    check rt.acceptedRevision == revision
    check ctxState.read() == 0
    check rt.find("ctx-a") != nil
    # The same Runtime is still usable. In the next candidate a sibling
    # initializer borrows the failed context while this same store is in the
    # initializing phase, so only the seal can reject it.
    ctxMode = 2
    rt.invalidateRoot()
    expect UiError:
      discard rt.flush()
    check rt.acceptedRevision == revision
    check ownedDescriptionBytes(savedCtx) == aCharge
    check rt.find("ctx-a") != nil
    # A legitimate fresh-context initializer still succeeds afterwards.
    ctxMode = 3
    rt.invalidateRoot()
    check rt.flush()
    check ctxFreshInit == 1
    check rt.find("ctx-fresh") != nil
    session.close()

suite "accepted page lifecycle":
  test "A B A preserves owner and orders exits before enters, router unmount disposes retained pages":
    var events: seq[string]
    var navigation: ComponentRouter
    var visible = true
    var retainedState: State[int]
    var rendersA = 0
    proc hooks(ctx: MountContext, label: string) =
      ctx.onMount(proc(event: LifecycleContext) = events.add("mount:" & label))
      ctx.onActivate(proc(event: LifecycleContext) = events.add("activate:" & label))
      ctx.onDeactivate(proc(event: LifecycleContext) = events.add("deactivate:" & label))
      ctx.onDispose(proc(event: LifecycleContext) = events.add("dispose:" & label))
    let Child = defineComponent[string, State[int]]("LifecycleRouteChild",
      proc(ctx: MountContext, label: string): State[int] =
        hooks(ctx, label & "-child")
        result = ctx.state(0)
        if label == "A": retainedState = result,
      proc(ctx: ComponentContext, label: string, state: State[int]): UiDescription =
        if label == "A": inc rendersA
        host(text($ctx.value(state), key = "lifecycle-page")))
    let Page = defineComponent[string, int]("LifecycleRouteParent",
      proc(ctx: MountContext, label: string): int =
        hooks(ctx, label)
        0,
      proc(ctx: ComponentContext, label: string, model: int): UiDescription = component(Child, label))
    let Navigator = defineComponent[int, int]("LifecycleNavigator",
      proc(ctx: MountContext, props: int): int =
        navigation = newComponentRouter(ctx, @[
          Route(name: "A", path: "/A", page: "A", view: "main"),
          Route(name: "B", path: "/B", page: "B", view: "main")], @[
          ComponentPageDefinition(name: "A", views: @["main"], build: proc(view: string): UiDescription = component(Page, "A")),
          ComponentPageDefinition(name: "B", views: @["main"], build: proc(view: string): UiDescription = component(Page, "B"))], "A")
        0,
      proc(ctx: ComponentContext, props, model: int): UiDescription = renderPage(ctx, navigation))
    let Root = defineComponent[int, int]("LifecycleRouterRoot",
      proc(ctx: MountContext, props: int): int = 0,
      proc(ctx: ComponentContext, props, model: int): UiDescription =
        if visible: component(Navigator, 0) else: host(text("unmounted")))
    let runtime = newRuntime(componentApplication(component(Root, 0), "route lifecycle"))
    discard runtime.pumpTasks()
    check events == @["mount:A", "mount:A-child"]
    events.setLen(0)
    runtime.uiTask(proc() = discard navigation.navigate("B"))
    discard runtime.pumpTasks()
    check events == @["deactivate:A-child", "deactivate:A", "mount:B", "mount:B-child"]
    let count = rendersA
    discard retainedState.set(7)
    discard runtime.flush()
    check rendersA == count
    events.setLen(0)
    runtime.uiTask(proc() = discard navigation.navigate("A"))
    discard runtime.pumpTasks()
    check events == @["deactivate:B-child", "deactivate:B", "activate:A", "activate:A-child"]
    check retainedState.read() == 7
    events.setLen(0)
    visible = false
    discard runtime.refresh()
    discard runtime.pumpTasks()
    check events == @["dispose:A-child", "dispose:B-child", "dispose:A", "dispose:B"]
    check retainedState.set(9) == StateWriteResult.disposed
    check navigation.navigate("B") == StateWriteResult.disposed

  test "disposeOnLeave emits dispose without deactivate":
    var events: seq[string]
    var navigation: ComponentRouter
    let Page = defineComponent[string, int]("LifecycleDisposablePage",
      proc(ctx: MountContext, label: string): int =
        ctx.onMount(proc(event: LifecycleContext) = events.add("mount:" & label))
        ctx.onDeactivate(proc(event: LifecycleContext) = events.add("deactivate:" & label))
        ctx.onDispose(proc(event: LifecycleContext) = events.add("dispose:" & label))
        0,
      proc(ctx: ComponentContext, label: string, model: int): UiDescription = host(text(label)))
    let Navigator = defineComponent[int, int]("LifecycleDisposableNavigator",
      proc(ctx: MountContext, props: int): int =
        navigation = newComponentRouter(ctx, @[
          Route(name: "A", path: "/A", page: "A", view: "main"),
          Route(name: "B", path: "/B", page: "B", view: "main")], @[
          ComponentPageDefinition(name: "A", views: @["main"], retention: PageRetention.disposeOnLeave,
            build: proc(view: string): UiDescription = component(Page, "A")),
          ComponentPageDefinition(name: "B", views: @["main"], build: proc(view: string): UiDescription = component(Page, "B"))], "A")
        0,
      proc(ctx: ComponentContext, props, model: int): UiDescription = renderPage(ctx, navigation))
    let runtime = newRuntime(componentApplication(component(Navigator, 0), "dispose route"))
    discard runtime.pumpTasks()
    events.setLen(0)
    runtime.uiTask(proc() = discard navigation.navigate("B"))
    discard runtime.pumpTasks()
    check events == @["dispose:A", "mount:B"]
