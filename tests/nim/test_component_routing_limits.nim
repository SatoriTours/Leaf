## Task 4: aggregate routing budgets shared by retained pages, registries,
## configuration, warm rows and UTF-8 text.
import std/[unittest, options, strutils]
import leaf/[core, widgets, components, host_session]
import leaf/component_description
import leaf/component_state
import leaf/managed_runtime

var router: ComponentRouter
var showLimits = true
var bigNodes = 0
var bigNodeText = 1
var bigChinese = false
var bigGroups = 0
var bigDepth = 0
var bigState: State[int]
var bigInit = 0
var failedBig: seq[State[int]]

proc bigText(): string =
  if bigChinese: repeat("中", bigNodeText div 3)
  else: repeat("x", bigNodeText)

let HomePage = defineComponent[int, int]("LimitsHomePage",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    host(text("home", key="home")))

let BigLeaf = defineComponent[int, int]("LimitsLeaf",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    host(text("leaf", key="leaf" & $p)))

let BigPair = defineComponent[int, int]("LimitsPair",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    component(BigLeaf, p))

let BigPage = defineComponent[int, State[int]]("LimitsBigPage",
  proc(ctx: MountContext, p: int): State[int] =
    inc bigInit
    result = ctx.state(0)
    bigState = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    var children: seq[UiDescription]
    for i in 0 ..< bigNodes:
      children.add(host(text(bigText(), key="n" & $i)))
    for i in 0 ..< bigGroups:
      children.add(component(BigPair, i))
    var node = hostShell(column(@[]), children)
    for i in 0 ..< bigDepth:
      node = hostShell(column(@[]), @[node])
    node)

let limitRoutes = @[
  Route(name: "home", path: "/", page: "home", view: "main"),
  Route(name: "big", path: "/big", page: "big", view: "main"),
  Route(name: "big2", path: "/big2", page: "big2", view: "main")]
let limitPages = @[
  ComponentPageDefinition(name: "home", views: @["main"],
    build: proc(view: string): UiDescription = component(HomePage, 0)),
  ComponentPageDefinition(name: "big", views: @["main"],
    build: proc(view: string): UiDescription = component(BigPage, 0)),
  ComponentPageDefinition(name: "big2", views: @["main"],
    build: proc(view: string): UiDescription = component(BigPage, 1))]

let LimitsHost = defineComponent[int, int]("LimitsHost",
  proc(ctx: MountContext, p: int): int =
    router = newComponentRouter(ctx, limitRoutes, limitPages, "home")
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    renderPage(ctx, router))

let LimitsShell = defineComponent[int, int]("LimitsShell",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    if showLimits: hostShell(column(@[], key="limits-shell"), @[component(LimitsHost, 0)])
    else: host(text("empty-limits", key="empty-limits")))

proc consumer(sessionId: uint64): HostConsumer =
  HostConsumer(sessionId: sessionId,
    prepare: proc(batch: HostBatch) = discard,
    apply: proc() = discard,
    accept: proc(revision: uint64) {.raises: [].} = discard,
    discardPrepared: proc() {.raises: [].} = discard)

proc resetLimits() =
  router = default(ComponentRouter)
  showLimits = true
  bigNodes = 0
  bigNodeText = 1
  bigChinese = false
  bigGroups = 0
  bigDepth = 0
  bigState = default(State[int])
  bigInit = 0
  failedBig.setLen(0)

proc newLimitsRt(sessionId = 70'u64): tuple[rt: Runtime, session: HostSession] =
  let rt = newRuntime(componentApplication(component(LimitsShell, 0), "limits"))
  (rt, attachHostSession(rt, consumer(sessionId)))

proc rejected(rt: Runtime, revision: uint64, page, activeKey, activePage: string) =
  ## Every rejection must actually initialize a fresh candidate page and then
  ## dispose that candidate State; the accepted ledger must not move.
  let before = bigInit
  discard navigate(router, page)
  expect UiError:
    discard rt.flush()
  check rt.acceptedRevision == revision
  check currentRoute(router).name == activePage
  check rt.find(activeKey) != nil
  check bigInit == before + 1
  failedBig.add(bigState)
  check failedBig[^1].set(0) == StateWriteResult.disposed

suite "managed routing budgets":
  test "node_budget_rejects_aggregate_growth":
    resetLimits()
    let (rt, session) = newLimitsRt()
    let revision = rt.acceptedRevision
    bigNodes = 10005
    bigNodeText = 1
    rejected(rt, revision, "big", "home", "home")
    bigNodes = 100
    discard navigate(router, "big")
    check rt.flush()
    check rt.acceptedRevision == revision + 1
    check rt.find("n0") != nil
    session.close()

  test "component_budget_rejects_more_than_many_leaf_hosts":
    resetLimits()
    let (rt, session) = newLimitsRt(71'u64)
    let revision = rt.acceptedRevision
    # 5001 Pair -> Leaf -> host groups: 10002 components, only ~5000 hosts.
    bigGroups = 5001
    rejected(rt, revision, "big", "home", "home")
    bigGroups = 100
    discard navigate(router, "big")
    check rt.flush()
    check rt.acceptedRevision == revision + 1
    check rt.find("leaf0") != nil
    session.close()

  test "byte_budget_counts_utf8_and_rejects":
    resetLimits()
    let (rt, session) = newLimitsRt(72'u64)
    let revision = rt.acceptedRevision
    bigChinese = true
    bigNodeText = 1048576
    bigNodes = 17
    rejected(rt, revision, "big", "home", "home")
    bigNodes = 5
    discard navigate(router, "big")
    check rt.flush()
    check rt.acceptedRevision == revision + 1
    check rt.find("n0") != nil
    session.close()

  test "depth_budget_rejects_deep_nesting":
    resetLimits()
    let (rt, session) = newLimitsRt(73'u64)
    let revision = rt.acceptedRevision
    bigDepth = 200
    rejected(rt, revision, "big", "home", "home")
    bigDepth = 5
    discard navigate(router, "big")
    check rt.flush()
    check rt.acceptedRevision == revision + 1
    session.close()

  test "retained_pages_share_the_runtime_budget_and_release_on_unmount":
    resetLimits()
    showLimits = false
    let emptyRt = newRuntime(componentApplication(component(LimitsShell, 0), "limits-empty"))
    let emptyBytes = emptyRt.stats.treeBytes
    resetLimits()
    showLimits = true
    bigNodes = 6000
    bigNodeText = 1
    let (rt, session) = newLimitsRt(74'u64)
    discard navigate(router, "big")
    check rt.flush()
    let acceptedBig = bigState
    check acceptedBig.read() == 0
    discard navigate(router, "home")
    check rt.flush()
    # Hidden retained page accepts a State update without rendering.
    check acceptedBig.set(7) == StateWriteResult.queued
    check rt.flush()
    check acceptedBig.read() == 7
    let revision = rt.acceptedRevision
    let bytesBig = rt.stats.treeBytes
    # A second large page is rejected by the shared budget while big is retained.
    rejected(rt, revision, "big2", "home", "home")
    check acceptedBig.read() == 7
    check rt.stats.treeBytes == bytesBig
    discard navigate(router, "big")
    check rt.flush()
    check rt.acceptedRevision == revision + 1
    check acceptedBig.read() == 7
    let bytesRestored = rt.stats.treeBytes
    # Repeated rejections each create and dispose a fresh candidate State,
    # leave the accepted page/route/revision/cost untouched, and never
    # accumulate candidate owner cost.
    for i in 0 ..< 5:
      rejected(rt, revision + 1, "big2", "n0", "big")
      check acceptedBig.read() == 7
      check rt.stats.treeBytes == bytesRestored
      check currentRoute(router).name == "big"
    check failedBig.len == 6
    # A legal recovery update and navigation still succeed afterwards.
    check acceptedBig.set(9) == StateWriteResult.queued
    check rt.flush()
    check acceptedBig.read() == 9
    discard navigate(router, "home")
    check rt.flush()
    check currentRoute(router).name == "home"
    # Every failed candidate handle stayed disposed through the whole run.
    for handle in failedBig:
      check handle.set(0) == StateWriteResult.disposed
    # Unmounting releases every retained page back to the empty baseline.
    showLimits = false
    rt.invalidateRoot()
    check rt.flush()
    check rt.stats.treeBytes == emptyBytes
    check acceptedBig.set(8) == StateWriteResult.disposed
    session.close()
