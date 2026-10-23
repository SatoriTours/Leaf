## S0: backend-neutral list metadata. One pure owned value
## (`list_protocol.HostListProps`) is re-exported by `host_protocol`, stored on
## `MountedEntity`/`UpdateOp`, and must survive create/update/acceptedDelta/
## restore. A change to list facts alone is still an update, ordinary controls
## carry none, and out-of-budget metadata is rejected before any apply.
import std/[unittest, tables, options, math]
import ../fixture_app
import leaf/[core, widgets, backend, backend_session, host_protocol,
  host_session, native_host_adapter, list_protocol]
import leaf/backends/headless

proc app(render: proc(): Node): Application =
  fixtureApplication(render, "metadata", 800, 600)

proc makeHost(sessionId = 41'u64, mountGeneration = 1'u64): HostContext =
  HostContext(sessionId: sessionId, mountGeneration: mountGeneration,
    contentWidth: 800, contentHeight: 600, scale: 1.0)

var items: seq[string]
var rowHeight, estimate: float64
var overscan: int
var showList: bool

proc renderLists(): Node =
  var children: seq[Node]
  children.add(button("go", key = "go", onClick = proc(e: Event) = discard))
  if showList:
    children.add(virtualList("list", items,
      proc(index: int): Node = text(items[index], key = "row"),
      rowHeight = rowHeight, estimatedHeight = estimate, overscan = overscan))
  else:
    children.add(text("gone", key = "list"))
  column(children, key = "root")

proc resetLists(): void =
  items = @["a", "b", "c"]
  rowHeight = 24.0
  estimate = 40.0
  overscan = 0
  showList = true

proc metadata(entities: Table[NodeHandle, MountedEntity],
              handle: NodeHandle): HostListProps =
  let entity = entities.getOrDefault(handle)
  check entity.list.isSome
  if entity.list.isSome: entity.list.get
  else: HostListProps()

proc sameKind[T](a, b: T): bool = true

suite "pure list protocol":
  test "one definition is re-exported without a host_protocol cycle":
    let pure = list_protocol.HostListProps(sourceGeneration: 9,
      itemCount: 2, heightMode: list_protocol.HostHeightMode.variable,
      rowHeight: 0.0, estimate: 12.5, overscan: 3)
    # Compiles only while host_protocol re-exports the very same type instead
    # of declaring a second, structurally equal copy.
    check sameKind(pure, host_protocol.HostListProps())
    check host_protocol.HostProps(list: some(pure)).list == some(pure)
    check host_protocol.HostListProps(sourceGeneration: 9).itemCount == 0
    # The backend-visible types are the same pure value.
    check MountedEntity(list: some(pure)).list.get.estimate == 12.5
    check UpdateOp(kind: opCreate, list: some(pure)).list.get.overscan == 3
    check HostHeightMode.uniform != HostHeightMode.variable

suite "list metadata in native entities":
  test "create carries the complete typed list description":
    resetLists()
    let rt = newRuntime(app(renderLists))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let source = rt.find("list").node.listSource
    let created = recording.entities.getOrDefault(handle)
    check created.list.isSome
    let meta = created.list.get
    check meta.sourceGeneration == source.generation
    check meta.itemCount == 3
    check meta.heightMode == HostHeightMode.uniform
    check meta.rowHeight == 24.0
    check meta.estimate == 40.0
    check meta.overscan == 0
    # acceptedDelta / explicit accepted query carry the same owned value.
    check session.acceptedEntities.getOrDefault(handle).list == some(meta)
    # The create op itself carried the metadata.
    var createOps = 0
    for op in recording.history:
      if op.handle == handle and op.kind == opCreate:
        inc createOps
        check op.list == some(meta)
    check createOps == 1
    # Ordinary controls never carry list metadata.
    let buttonHandle = session.handleFor(rt.find("go").id)
    check recording.entities.getOrDefault(buttonHandle).list.isNone
    check session.acceptedEntities.getOrDefault(buttonHandle).list.isNone
    session.dispose()

  test "variable height metadata keeps the estimate and zero row height":
    resetLists()
    rowHeight = 0.0
    estimate = 55.0
    overscan = 2
    let rt = newRuntime(app(renderLists))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let meta = metadata(recording.entities, handle)
    check meta.heightMode == HostHeightMode.variable
    check meta.rowHeight == 0.0
    check meta.estimate == 55.0
    check meta.overscan == 2
    check meta.itemCount == 3
    session.dispose()

  test "only list facts changing is still an update":
    resetLists()
    let rt = newRuntime(app(renderLists))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let before = recording.entities.getOrDefault(handle)
    recording.creates = 0
    recording.updates = 0
    recording.history.setLen(0)
    # Same node, same normalized props; only list facts change. `overscan` is
    # left alone here: the managed driver already mounts overscan rows when a
    # list source is replaced, which is unrelated to metadata publication.
    estimate = 77.0
    check rt.dispatchRefresh("go", Event(kind: click))
    let after = recording.entities.getOrDefault(handle)
    check after.props == before.props
    check after.list.isSome
    check after.list.get.estimate == 77.0
    check after.list.get.overscan == 0
    check after.list.get.sourceGeneration == rt.find("list").node.listSource.generation
    check after.list.get.sourceGeneration != before.list.get.sourceGeneration
    check recording.creates == 0
    check recording.updates == 1
    check recording.history.len == 1
    check recording.history[0].kind == opUpdate
    check recording.history[0].handle == handle
    check recording.history[0].list == after.list
    check session.acceptedEntities.getOrDefault(handle).list == after.list
    session.dispose()

  test "removal drops the old metadata and never leaks it to a replacement":
    resetLists()
    let rt = newRuntime(app(renderLists))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    check recording.entities.getOrDefault(handle).list.isSome
    showList = false
    check rt.dispatchRefresh("go", Event(kind: click))
    check not recording.entities.hasKey(handle)
    check not session.acceptedEntities.hasKey(handle)
    let replacement = session.handleFor(rt.find("list").id)
    check replacement != handle
    check recording.entities.getOrDefault(replacement).list.isNone
    session.dispose()

  test "restore reproduces the complete accepted list metadata":
    resetLists()
    let rt = newRuntime(app(renderLists))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let accepted = recording.entities.getOrDefault(handle).list
    check accepted.isSome
    let revision = rt.acceptedRevision
    # Reject the list-only update after apply started, then restore.
    estimate = 91.0
    recording.failApplyAt = 1
    expect UiError:
      discard rt.dispatchRefresh("go", Event(kind: click))
    check rt.acceptedRevision == revision
    check recording.restoreCalls == 1
    check recording.entities.getOrDefault(handle).list == accepted
    recording.failApplyAt = 0
    check rt.dispatchRefresh("go", Event(kind: click))
    check recording.entities.getOrDefault(handle).list.get.estimate == 91.0
    session.dispose()

type DeltaRecorder = ref object
  calls: int
  upserts: seq[MountedEntity]

proc deltaRecordingBackend(recorder: DeltaRecorder): Backend =
  result = Backend(capabilities: fullCapabilities(),
    prepare: proc(batch: UpdateBatch) = discard,
    apply: proc(batch: UpdateBatch) = discard,
    discardPrepared: proc() = discard,
    restore: proc(entities: Table[NodeHandle, MountedEntity]) = discard,
    dispose: proc() = discard)
  result.acceptedDelta = proc(delta: HostAcceptedDelta) {.raises: [].} =
    inc recorder.calls
    for entity in delta.upserts: recorder.upserts.add(entity)

suite "accepted delta list metadata":
  test "typed delta upserts keep the new list facts":
    resetLists()
    let recorder = DeltaRecorder()
    let rt = newRuntime(app(renderLists))
    let session = attachBackend(rt, deltaRecordingBackend(recorder), makeHost())
    let handle = session.handleFor(rt.find("list").id)
    check recorder.calls == 1
    check recorder.upserts.len > 0
    var found = false
    for entity in recorder.upserts:
      if entity.handle == handle:
        found = true
        check entity.list.isSome
        check entity.list.get.itemCount == 3
    check found
    recorder.upserts.setLen(0)
    overscan = 1
    estimate = 66.0
    check rt.dispatchRefresh("go", Event(kind: click))
    check recorder.calls == 2
    found = false
    for entity in recorder.upserts:
      if entity.handle == handle:
        found = true
        check entity.list.get.overscan == 1
        check entity.list.get.estimate == 66.0
    check found
    session.dispose()

suite "host list metadata budget":
  test "item count beyond the list budget is rejected before apply":
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, sessionId = 77'u64)
    let tooMany = HostListProps(sourceGeneration: 1,
      itemCount: MaxListItems + 1, heightMode: HostHeightMode.uniform,
      rowHeight: 10.0, estimate: 40.0, overscan: 0)
    let wire = HostBatch(sessionId: 77, baseRevision: 0, nextRevision: 1, ops: @[
      HostOp(kind: HostOpKind.create, handle: NodeHandle(1), nodeId: "huge",
        nodeKind: NodeKind.virtualList, props: HostProps(list: some(tooMany)))])
    expect UiError:
      consumer.prepare(wire)
    check recording.prepareCalls == 0

  test "inconsistent metadata is rejected before apply":
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, sessionId = 78'u64)
    let inconsistent = HostListProps(sourceGeneration: 1, itemCount: 2,
      heightMode: HostHeightMode.variable, rowHeight: 10.0, estimate: 40.0,
      overscan: 0)
    let wire = HostBatch(sessionId: 78, baseRevision: 0, nextRevision: 1, ops: @[
      HostOp(kind: HostOpKind.create, handle: NodeHandle(1), nodeId: "bad",
        nodeKind: NodeKind.virtualList, props: HostProps(list: some(inconsistent)))])
    expect UiError:
      consumer.prepare(wire)
    check recording.prepareCalls == 0

  test "valid metadata still reaches prepare unchanged":
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, sessionId = 79'u64)
    let good = HostListProps(sourceGeneration: 4, itemCount: 2,
      heightMode: HostHeightMode.variable, rowHeight: 0.0, estimate: 33.0,
      overscan: 1)
    let wire = HostBatch(sessionId: 79, baseRevision: 0, nextRevision: 1, ops: @[
      HostOp(kind: HostOpKind.create, handle: NodeHandle(1), nodeId: "ok",
        nodeKind: NodeKind.virtualList, props: HostProps(list: some(good)))])
    consumer.prepare(wire)
    check recording.prepareCalls == 1
    check recording.prepared.len == 1
    check recording.prepared[0].list == some(good)
    consumer.discardPrepared()

## r1: the neutral budget contract must reject non-finite list numbers itself.
## The only producer today (`virtualList`) already gates NaN/Inf, but a platform
## factory may feed the wire directly, so `invalidReason` stays self-contained.
const MaxListDimension = 1_000_000.0

proc legalBoundaries(): seq[HostListProps] =
  result = @[
    HostListProps(sourceGeneration: 1, itemCount: 0,
      heightMode: HostHeightMode.uniform, rowHeight: 1e-6, estimate: 1e-6,
      overscan: 0),
    HostListProps(sourceGeneration: 1, itemCount: MaxListItems,
      heightMode: HostHeightMode.uniform, rowHeight: MaxListDimension,
      estimate: MaxListDimension, overscan: 32),
    HostListProps(sourceGeneration: high(uint64), itemCount: 100_000,
      heightMode: HostHeightMode.variable, rowHeight: 0.0, estimate: 40.0,
      overscan: 32)]

suite "list metadata numeric bounds":
  test "non-finite row height and estimate are rejected":
    for prop in legalBoundaries(): check invalidReason(prop, MaxListItems).len == 0
    let good = HostListProps(sourceGeneration: 1, itemCount: 2,
      heightMode: HostHeightMode.uniform, rowHeight: 24.0, estimate: 40.0,
      overscan: 0)
    check invalidReason(good, MaxListItems).len == 0
    for value in [NaN, Inf, -Inf]:
      var heightProps = good
      heightProps.rowHeight = value
      check invalidReason(heightProps, MaxListItems).len != 0
      var estimateProps = good
      estimateProps.estimate = value
      check invalidReason(estimateProps, MaxListItems).len != 0
      var variableProps = good
      variableProps.heightMode = HostHeightMode.variable
      variableProps.rowHeight = value
      check invalidReason(variableProps, MaxListItems).len != 0
    check invalidReason(HostListProps(sourceGeneration: 1, itemCount: 1,
      heightMode: HostHeightMode.uniform, rowHeight: NaN, estimate: 40.0,
      overscan: 0), MaxListItems).len != 0
    # The non-finite rejection is not an excuse to narrow the legal range.
    var top = good
    top.rowHeight = MaxListDimension
    top.estimate = MaxListDimension
    check invalidReason(top, MaxListItems).len == 0
    top.rowHeight = MaxListDimension + 1.0
    check invalidReason(top, MaxListItems).len != 0
    top.rowHeight = 24.0
    top.estimate = MaxListDimension + 1.0
    check invalidReason(top, MaxListItems).len != 0

  test "non-finite wire metadata is rejected before apply":
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, sessionId = 80'u64)
    let nanHeight = HostListProps(sourceGeneration: 1, itemCount: 2,
      heightMode: HostHeightMode.uniform, rowHeight: NaN, estimate: 40.0,
      overscan: 0)
    let wire = HostBatch(sessionId: 80, baseRevision: 0, nextRevision: 1, ops: @[
      HostOp(kind: HostOpKind.create, handle: NodeHandle(1), nodeId: "nan",
        nodeKind: NodeKind.virtualList, props: HostProps(list: some(nanHeight)))])
    expect UiError:
      consumer.prepare(wire)
    check recording.prepareCalls == 0
