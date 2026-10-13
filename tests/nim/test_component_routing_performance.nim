## Task 5: structural navigation work, static-sibling isolation, retained State
## and the cached registry charge. Counters are structural (component renders /
## host ops / child-handle entries), never a claim of constant CPU time or FFI
## bytes.
import std/[unittest, options, sets]
import leaf/[core, widgets, components, host_session]
import leaf/component_description
import leaf/component_state
import leaf/managed_runtime

var staticRenders = 0
var siblings = 100
var perfRouter: ComponentRouter
var batches: seq[HostBatch]
var staticSet: HashSet[uint64]

var pageStateA, pageStateB, pageStateC: State[int]
var pageInitA, pageInitB, pageInitC = 0

let PerfStatic = defineComponent[int, int]("PerfStatic",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    inc staticRenders
    host(text("s" & $p, key="s" & $p)))

let PerfPageA = defineComponent[int, State[int]]("PerfPageA",
  proc(ctx: MountContext, p: int): State[int] =
    inc pageInitA
    result = ctx.state(0)
    pageStateA = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    host(text("perf-a" & $ctx.value(s), key="perf-a")))

let PerfPageB = defineComponent[int, State[int]]("PerfPageB",
  proc(ctx: MountContext, p: int): State[int] =
    inc pageInitB
    result = ctx.state(0)
    pageStateB = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    host(text("perf-b" & $ctx.value(s), key="perf-b")))

let PerfPageC = defineComponent[int, State[int]]("PerfPageC",
  proc(ctx: MountContext, p: int): State[int] =
    inc pageInitC
    result = ctx.state(0)
    pageStateC = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    host(text("perf-c" & $ctx.value(s), key="perf-c")))

var rootStateA, rootStateB: State[int]
var rootInitA, rootInitB = 0
var failReplace = false
var showReplace = true

let RootA = defineComponent[int, State[int]]("PerfRootA",
  proc(ctx: MountContext, p: int): State[int] =
    inc rootInitA
    result = ctx.state(0)
    rootStateA = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    host(text("root-a" & $ctx.value(s), key="root-a")))

let RootB = defineComponent[int, State[int]]("PerfRootB",
  proc(ctx: MountContext, p: int): State[int] =
    inc rootInitB
    result = ctx.state(0)
    rootStateB = result,
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    if failReplace: fail("replacement render failed")
    host(text("root-b" & $ctx.value(s), key="root-b")))

let perfRoutes = @[
  Route(name: "a", path: "/", page: "a", view: "main"),
  Route(name: "b", path: "/b", page: "b", view: "main"),
  Route(name: "c", path: "/c", page: "c", view: "main")]
let perfPages = @[
  ComponentPageDefinition(name: "a", views: @["main"],
    build: proc(view: string): UiDescription = component(PerfPageA, 0)),
  ComponentPageDefinition(name: "b", views: @["main"],
    build: proc(view: string): UiDescription = component(PerfPageB, 0)),
  ComponentPageDefinition(name: "c", views: @["main"],
    build: proc(view: string): UiDescription = component(PerfPageC, 0))]

let PerfRouterHost = defineComponent[int, int]("PerfRouterHost",
  proc(ctx: MountContext, p: int): int =
    perfRouter = newComponentRouter(ctx, perfRoutes, perfPages, "a")
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    renderPage(ctx, perfRouter))

let PerfShell = defineComponent[int, int]("PerfShell",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    var children: seq[UiDescription]
    for i in 0 ..< siblings: children.add(component(PerfStatic, i))
    children.add(component(PerfRouterHost, 0))
    hostShell(column(@[], key="perf-root"), children))

var replaceRouter: ComponentRouter
let replaceRoutes = @[
  Route(name: "v1", path: "/", page: "p", view: "v1"),
  Route(name: "v2", path: "/v2", page: "p", view: "v2"),
  Route(name: "q", path: "/q", page: "q", view: "main")]
let replacePages = @[
  ComponentPageDefinition(name: "p", views: @["v1", "v2"],
    build: proc(view: string): UiDescription =
      if view == "v1": component(RootA, 0) else: component(RootB, 0)),
  ComponentPageDefinition(name: "q", views: @["main"], retention: PageRetention.disposeOnLeave,
    build: proc(view: string): UiDescription = component(RootA, 0))]

let ReplaceHost = defineComponent[int, int]("PerfReplaceHost",
  proc(ctx: MountContext, p: int): int =
    replaceRouter = newComponentRouter(ctx, replaceRoutes, replacePages, "v1")
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    renderPage(ctx, replaceRouter))

let ReplaceShell = defineComponent[int, int]("PerfReplaceShell",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    if showReplace: hostShell(column(@[], key="replace-shell"), @[component(ReplaceHost, 0)])
    else: host(text("empty-replace", key="empty-replace")))

proc captureConsumer(sessionId: uint64): HostConsumer =
  HostConsumer(sessionId: sessionId,
    prepare: proc(batch: HostBatch) = batches.add(batch),
    apply: proc() = discard,
    accept: proc(revision: uint64) {.raises: [].} = discard,
    discardPrepared: proc() {.raises: [].} = discard)

proc resetPerf() =
  staticRenders = 0
  pageInitA = 0; pageInitB = 0; pageInitC = 0
  pageStateA = default(State[int]); pageStateB = default(State[int]); pageStateC = default(State[int])
  batches.setLen(0)
  staticSet.clear()

proc newPerfRt(sessionId = 80'u64): tuple[rt: Runtime, session: HostSession] =
  resetPerf()
  let rt = newRuntime(componentApplication(component(PerfShell, 0), "perf"))
  (rt, attachHostSession(rt, captureConsumer(sessionId)))

proc go(rt: Runtime, target: string) =
  discard navigate(perfRouter, target)
  check rt.flush()

proc staticHandleSnapshot(session: HostSession, rt: Runtime): seq[uint64] =
  for i in 0 ..< siblings:
    result.add(uint64(session.handleFor(rt.find("s" & $i).id)))

suite "managed routing structural work":
  test "navigation_work_is_independent_of_static_siblings":
    for count in [100, 1000, 5000]:
      siblings = count
      let (rt, session) = newPerfRt()
      let initialRenders = staticRenders
      check initialRenders == count
      # Warm every page and store distinct non-zero State before measuring.
      go(rt, "b")
      check pageStateB.set(22) == StateWriteResult.queued
      check rt.flush()
      go(rt, "c")
      check pageStateC.set(33) == StateWriteResult.queued
      check rt.flush()
      go(rt, "a")
      check pageStateA.set(11) == StateWriteResult.queued
      check rt.flush()
      check rt.find("perf-a").node.text == "perf-a11"
      check pageInitA == 1; check pageInitB == 1; check pageInitC == 1
      let savedA = pageStateA
      let savedB = pageStateB
      let savedC = pageStateC
      let initialA = pageInitA
      let initialB = pageInitB
      let initialC = pageInitC
      let exports = rt.updateStats().snapshotExports
      let bytesWarm = rt.stats.treeBytes
      let nodesWarm = rt.stats.mountedNodes
      let rootHandle = session.handleFor(rt.find("perf-root").id)
      check uint64(rootHandle) != 0
      let staticHandles = staticHandleSnapshot(session, rt)
      for handle in staticHandles: staticSet.incl(handle)
      # Collect the known boundary component ids from a warm A->B->A pair so
      # the measured navigation can be checked against exact page/ancestor ids.
      var knownBoundaries: HashSet[uint64]
      batches.setLen(0)
      go(rt, "b")
      go(rt, "a")
      for batch in batches:
        for op in batch.ops:
          if op.kind == HostOpKind.boundary:
            knownBoundaries.incl(uint64(op.boundary.id))
      check knownBoundaries.len >= 1
      check rt.find("perf-a").node.text == "perf-a11"
      let leavingA = session.handleFor(rt.find("perf-a").id)
      # Measure one A -> B navigation against the full static/oracle set.
      batches.setLen(0)
      go(rt, "b")
      let enteringB = session.handleFor(rt.find("perf-b").id)
      check rt.find("perf-b").node.text == "perf-b22"
      var createOps, removeOps, updateOps, boundaryOps, setChildrenOps, childEntries, staticTargetOps, windowOps = 0
      for batch in batches:
        for op in batch.ops:
          case op.kind
          of HostOpKind.create:
            inc createOps
            if uint64(op.handle) != uint64(enteringB): inc staticTargetOps
          of HostOpKind.remove:
            inc removeOps
            if uint64(op.handle) != uint64(leavingA): inc staticTargetOps
          of HostOpKind.update:
            inc updateOps
            if uint64(op.handle) in staticSet: inc staticTargetOps
          of HostOpKind.setChildren:
            inc setChildrenOps
            childEntries += op.children.len
            if uint64(op.handle) != uint64(rootHandle): inc staticTargetOps
          of HostOpKind.boundary:
            inc boundaryOps
            if uint64(op.boundary.id) notin knownBoundaries: inc staticTargetOps
            # A removal boundary carries root 0; otherwise the boundary must
            # point at the leaving/entering page or a required ancestor.
            let root=uint64(op.boundary.root)
            if root!=0 and root!=uint64(leavingA) and root!=uint64(enteringB) and
                root!=uint64(rootHandle):
              inc staticTargetOps
            if root in staticSet: inc staticTargetOps
          of HostOpKind.window: inc windowOps
          if op.kind in {HostOpKind.create, HostOpKind.update, HostOpKind.remove} and
              uint64(op.parent) in staticSet:
            inc staticTargetOps
      let totalOps = createOps + removeOps + updateOps + setChildrenOps + boundaryOps
      check staticTargetOps == 0
      check createOps == 1
      check removeOps == 1
      check updateOps == 0
      check setChildrenOps == 1
      check boundaryOps == 3
      check totalOps == 6
      check windowOps == 0
      check childEntries == count + 1
      # Every static handle stays stable (shared-parent children may reference them).
      let afterHandles = staticHandleSnapshot(session, rt)
      check afterHandles == staticHandles
      check staticRenders == initialRenders
      check rt.updateStats().snapshotExports == exports
      echo "perf size=", count, " ops=", totalOps,
        " create=", createOps, " remove=", removeOps, " update=", updateOps,
        " setChildren=", setChildrenOps, " boundary=", boundaryOps,
        " childEntries=", childEntries, " childArrayBytes=", childEntries * 8,
        " childEntriesPerSet=", (if setChildrenOps == 0: 0 else: childEntries div setChildrenOps),
        " staticRendersInitial=", initialRenders, " staticRenderDelta=", staticRenders - initialRenders,
        " snapshotDelta=", rt.updateStats().snapshotExports - exports
      # 100 complete A -> B -> A roundtrips (200 legs) preserve State identity,
      # values, retention size and static isolation.
      for i in 0 ..< 100:
        go(rt, "b")
        check savedB.read() == 22
        check rt.find("perf-b").node.text == "perf-b22"
        go(rt, "a")
        check savedA.read() == 11
        check rt.find("perf-a").node.text == "perf-a11"
      check pageInitA == initialA
      check pageInitB == initialB
      check pageInitC == initialC
      check savedC.read() == 33
      check staticRenders == initialRenders
      check rt.stats.mountedNodes == nodesWarm
      check rt.stats.treeBytes == bytesWarm
      check rt.updateStats().snapshotExports == exports
      discard rt.snapshot
      session.close()

  when defined(leafProtocolProbes):
    test "warm_revisits_do_not_edit_or_rescan_the_registry":
      siblings = 100
      let (rt, session) = newPerfRt(81'u64)
      go(rt, "b"); check pageStateB.set(22) == StateWriteResult.queued; check rt.flush()
      go(rt, "c"); check pageStateC.set(33) == StateWriteResult.queued; check rt.flush()
      go(rt, "a"); check pageStateA.set(11) == StateWriteResult.queued; check rt.flush()
      let savedA = pageStateA
      let savedB = pageStateB
      let savedC = pageStateC
      let edits = outletRegistryEdits
      check edits >= 2
      let bytesWarm = rt.stats.treeBytes
      let nodesWarm = rt.stats.mountedNodes
      for i in 0 ..< 100:
        let target = ["b", "c", "a"][i mod 3]
        go(rt, target)
        case target
        of "b": check savedB.read() == 22
        of "c": check savedC.read() == 33
        else: check savedA.read() == 11
      check outletRegistryEdits == edits
      check rt.stats.treeBytes == bytesWarm
      check rt.stats.mountedNodes == nodesWarm
      session.close()

  test "same_page_root_replacement_keeps_registry_cost_stable":
    rootInitA = 0; rootInitB = 0
    rootStateA = default(State[int]); rootStateB = default(State[int])
    failReplace = false; showReplace = true
    let rt = newRuntime(componentApplication(component(ReplaceShell, 0), "replace"))
    let session = attachHostSession(rt, captureConsumer(82'u64))
    check rootInitA == 1
    let firstA = rootStateA
    check firstA.set(5) == StateWriteResult.queued
    check rt.flush()
    check firstA.read() == 5
    # Replace the page root type: the registry keeps the page key, only the
    # uint64 root id changes, so no new entry charge may be added.
    discard navigate(replaceRouter, "v2")
    check rt.flush()
    check rootInitB == 1
    check firstA.set(6) == StateWriteResult.disposed
    let acceptedB = rootStateB
    check acceptedB.read() == 0
    let bytesAfterFirst = rt.stats.treeBytes
    for i in 0 ..< 50:
      discard navigate(replaceRouter, (if i mod 2 == 0: "v1" else: "v2"))
      check rt.flush()
      check rt.stats.treeBytes == bytesAfterFirst
    check rootInitA == 26
    check rootInitB == 26
    session.close()

  test "registry_add_delete_rollback_and_unmount_baseline":
    rootInitA = 0; rootInitB = 0
    rootStateA = default(State[int]); rootStateB = default(State[int])
    failReplace = false
    # Measured empty Shell baseline with the owner absent.
    showReplace = false
    let emptyRt = newRuntime(componentApplication(component(ReplaceShell, 0), "replace-empty"))
    let emptyBytes = emptyRt.stats.treeBytes
    # Real owner: page p (retainState, RootA) plus a disposeOnLeave page q.
    showReplace = true
    let rt = newRuntime(componentApplication(component(ReplaceShell, 0), "replace"))
    let session = attachHostSession(rt, captureConsumer(83'u64))
    check rootInitA == 1
    let savedA = rootStateA
    check savedA.set(5) == StateWriteResult.queued
    check rt.flush()
    let baselineP = rt.stats.treeBytes
    # Visit q: an absent key adds its entry fee and subtree.
    discard navigate(replaceRouter, "q")
    check rt.flush()
    check rootInitA == 2
    check rt.stats.treeBytes > baselineP
    # Return to p: disposeOnLeave erases q, restoring the exact baseline.
    discard navigate(replaceRouter, "v1")
    check rt.flush()
    check savedA.read() == 5
    check rt.stats.treeBytes == baselineP
    # A rejected same-page root replacement keeps route, value and cost and
    # disposes the real candidate State.
    failReplace = true
    let beforeReject = rt.stats.treeBytes
    discard navigate(replaceRouter, "v2")
    expect UiError:
      discard rt.flush()
    check currentRoute(replaceRouter).view == "v1"
    check savedA.read() == 5
    check rt.stats.treeBytes == beforeReject
    check rootInitB == 1
    check rootStateB.set(0) == StateWriteResult.disposed
    # Legal replacement succeeds at the same cost (equal-size key and text).
    failReplace = false
    discard navigate(replaceRouter, "v2")
    check rt.flush()
    check rt.stats.treeBytes == beforeReject
    check rootInitB == 2
    let acceptedB = rootStateB
    check savedA.set(7) == StateWriteResult.disposed
    # Removing the owner restores the measured empty baseline exactly.
    showReplace = false
    rt.invalidateRoot()
    check rt.flush()
    check rt.stats.treeBytes == emptyBytes
    check acceptedB.set(8) == StateWriteResult.disposed
    session.close()
