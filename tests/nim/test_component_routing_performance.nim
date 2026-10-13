## Task 5: structural navigation work, static-sibling isolation and the cached
## registry charge. Counters are structural (component renders / host ops), not a
## claim of constant CPU time or FFI bytes.
import std/[unittest, options]
import leaf/[core, widgets, components, host_session]
import leaf/component_description
import leaf/component_state
import leaf/managed_runtime

var staticRenders = 0
var siblings = 100
var perfRouter: ComponentRouter
var batches: seq[HostBatch]

let PerfStatic = defineComponent[int, int]("PerfStatic",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    inc staticRenders
    host(text("s" & $p, key="s" & $p)))

let PerfPageA = defineComponent[int, State[int]]("PerfPageA",
  proc(ctx: MountContext, p: int): State[int] = ctx.state(0),
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    host(text("perf-a" & $ctx.value(s), key="perf-a")))
let PerfPageB = defineComponent[int, State[int]]("PerfPageB",
  proc(ctx: MountContext, p: int): State[int] = ctx.state(0),
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    host(text("perf-b" & $ctx.value(s), key="perf-b")))
let PerfPageC = defineComponent[int, State[int]]("PerfPageC",
  proc(ctx: MountContext, p: int): State[int] = ctx.state(0),
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    host(text("perf-c" & $ctx.value(s), key="perf-c")))

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

proc captureConsumer(sessionId: uint64): HostConsumer =
  HostConsumer(sessionId: sessionId,
    prepare: proc(batch: HostBatch) = batches.add(batch),
    apply: proc() = discard,
    accept: proc(revision: uint64) {.raises: [].} = discard,
    discardPrepared: proc() {.raises: [].} = discard)

proc newPerfRt(sessionId = 80'u64): tuple[rt: Runtime, session: HostSession] =
  staticRenders = 0
  batches.setLen(0)
  let rt = newRuntime(componentApplication(component(PerfShell, 0), "perf"))
  (rt, attachHostSession(rt, captureConsumer(sessionId)))

proc go(rt: Runtime, target: string) =
  discard navigate(perfRouter, target)
  check rt.flush()

suite "managed routing structural work":
  test "navigation_work_is_independent_of_static_siblings":
    for count in [100, 1000, 5000]:
      siblings = count
      let (rt, session) = newPerfRt()
      let initialRenders = staticRenders
      check initialRenders == count
      let exports = rt.updateStats().snapshotExports
      let rootHandle = session.handleFor(rt.find("perf-root").id)
      check uint64(rootHandle) != 0
      let firstStatic = session.handleFor(rt.find("s0").id)
      let lastStatic = session.handleFor(rt.find("s" & $(count - 1)).id)
      check uint64(firstStatic) != 0
      # Navigate A -> B and inspect the emitted host batch.
      batches.setLen(0)
      go(rt, "b")
      check staticRenders == initialRenders
      check rt.updateStats().snapshotExports == exports
      check uint64(session.handleFor(rt.find("s0").id)) == uint64(firstStatic)
      check uint64(session.handleFor(rt.find("s" & $(count - 1)).id)) == uint64(lastStatic)
      var staticOps = 0
      var childHandleVolume = 0
      for batch in batches:
        for op in batch.ops:
          if uint64(op.handle) == uint64(firstStatic) or uint64(op.handle) == uint64(lastStatic): inc staticOps
          if op.kind == HostOpKind.setChildren and uint64(op.handle) == uint64(rootHandle):
            childHandleVolume = max(childHandleVolume, op.children.len)
      check staticOps == 0
      # Changing the page root re-orders the shared parent, so the setChildren
      # array carries every unchanged sibling handle; report that volume.
      check childHandleVolume >= count + 1
      # Warm both pages once, then 100 revisits keep retention and work flat.
      go(rt, "a")
      let nodesWarm = rt.stats.mountedNodes
      let bytesWarm = rt.stats.treeBytes
      let rendersWarm = staticRenders
      for i in 0 ..< 100:
        go(rt, (if i mod 2 == 0: "b" else: "a"))
      check rt.stats.mountedNodes == nodesWarm
      check rt.stats.treeBytes == bytesWarm
      check staticRenders == rendersWarm
      check rt.find("perf-a") != nil
      # Explicit Snapshot is deliberately outside the op/render counters above.
      discard rt.snapshot
      session.close()

  when defined(leafProtocolProbes):
    test "warm_revisits_do_not_edit_or_rescan_the_registry":
      siblings = 100
      let (rt, session) = newPerfRt(81'u64)
      # Visit all three pages once so every registration exists.
      outletRegistryEdits = 0
      go(rt, "b")
      go(rt, "c")
      go(rt, "a")
      let edits = outletRegistryEdits
      check edits >= 2
      let bytesWarm = rt.stats.treeBytes
      let nodesWarm = rt.stats.mountedNodes
      # 100 A/B/C revisits must change no registration and rescan no keys.
      for i in 0 ..< 100:
        go(rt, (["b", "c", "a"][i mod 3]))
      check outletRegistryEdits == edits
      check rt.stats.treeBytes == bytesWarm
      check rt.stats.mountedNodes == nodesWarm
      session.close()
