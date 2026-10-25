## T1: typed row sidecar. A list row root carries an owned
## `NativeRowBinding` (list handle, source generation, item index, item key)
## that travels the existing HostRecord/HostOp/entity/UpdateOp path: it is
## candidate-visible in prepare, published without allocation, kept by
## acceptedDelta/full metadata/restore/fullBatch, and rejected before any
## platform prepare when inconsistent. Keys are never parsed out of node ids.
import std/[unittest, tables, options, sets, algorithm, strutils]
import leaf/[core, widgets, components, backend, backend_session, host_session, host_protocol,
  host_reconcile, managed_runtime, native_host_adapter]
import leaf/component_description
import leaf/backends/headless

proc makeHost(sessionId = 101'u64, mountGeneration = 1'u64): HostContext =
  HostContext(sessionId: sessionId, mountGeneration: mountGeneration,
    contentWidth: 800, contentHeight: 600, scale: 1.0)

type RowFact = tuple[handle: NodeHandle, list: NodeHandle, index: int,
                     key: string, generation: uint64]

proc rowFacts(entities: Table[NodeHandle, MountedEntity],
              listHandle = NoHandle): seq[RowFact] =
  for handle, entity in entities:
    if entity.row.isSome:
      let binding = entity.row.get
      if listHandle == NoHandle or binding.listHandle == listHandle:
        result.add((handle, binding.listHandle, binding.itemIndex,
          binding.itemKey, binding.sourceGeneration))
  result.sort(proc(a, b: RowFact): int = cmp(a.index, b.index))

proc rowIndices(facts: seq[RowFact]): seq[int] =
  for fact in facts: result.add(fact.index)

proc rowKeys(facts: seq[RowFact]): seq[string] =
  for fact in facts: result.add(fact.key)

proc listProps(generation: uint64, count: int): HostProps =
  HostProps(list: some(HostListProps(sourceGeneration: generation,
    itemCount: count, heightMode: HostHeightMode.uniform, rowHeight: 10.0,
    estimate: 10.0, overscan: 0)))

proc rowBinding(list: NodeHandle, generation: uint64, index: int,
                key: string): Option[NativeRowBinding] =
  some(NativeRowBinding(listHandle: list, sourceGeneration: generation,
    itemIndex: index, itemKey: key))

# ---------------------------------------------------------------- fixtures
var rowItems: seq[string]
var rowStates: Table[int, State[int]]
var rowAlternate = false
var rowOutletAlternate = false
var nestedRowIndex = -1
var innerItems: seq[string] = @["i0", "i1", "i2"]
var listDescription: UiDescription

let BindingRow = defineComponent[int, State[int]]("RowBindingRow",
  proc(ctx: MountContext, index: int): State[int] =
    result = ctx.state(0)
    rowStates[index] = result
  ,
  proc(ctx: ComponentContext, index: int, state: State[int]): UiDescription =
    let alternate = (ctx.value(state) mod 2) == 1
    let container = if alternate: row(@[]) else: column(@[])
    hostShell(container, @[
      host(text(rowItems[index] & "/" & $ctx.value(state), key = "row-text"))]))

let NestedRow = defineComponent[int, State[int]]("RowBindingNested",
  proc(ctx: MountContext, index: int): State[int] = ctx.state(0),
  proc(ctx: ComponentContext, index: int, state: State[int]): UiDescription =
    if index == nestedRowIndex:
      # The nested list host is the row root itself.
      return componentList("inner", innerItems,
        proc(item: int): UiDescription = host(text(innerItems[item], key = "inner-row")),
        rowHeight = 10, overscan = 0)
    hostShell(column(@[]), @[host(text(rowItems[index], key = "row-text"))]))

let OutletRow = defineComponent[int, State[int]]("RowBindingOutlet",
  proc(ctx: MountContext, index: int): State[int] =
    result = ctx.state(0)
    rowStates[index] = result
  ,
  proc(ctx: ComponentContext, index: int, state: State[int]): UiDescription =
    let alternate = (ctx.value(state) mod 2) == 1
    let spec = PageOutletSpec(routerId: uint64(7000 + index), page: "main",
      view: "v", build: proc(): UiDescription =
        if alternate:
          hostShell(row(@[]), @[host(text("alt", key = "alt"))])
        else:
          hostShell(column(@[]), @[host(text("main", key = "main"))]))
    pageOutlet(spec, "outlet"))

let ListOwner = defineComponent[int, int]("RowBindingListOwner",
  proc(ctx: MountContext, p: int): int = p,
  proc(ctx: ComponentContext, p, model: int): UiDescription = listDescription)

proc buildList(builder: proc(index: int): UiDescription): UiDescription =
  hostShell(column(@[], key = "root"), @[
    componentList("list", rowItems, builder, rowHeight = 10, overscan = 0)])

proc listApp(builder: proc(index: int): UiDescription): Application =
  listDescription = buildList(builder)
  componentApplication(component(ListOwner, 0), "row-bindings", 800, 600)

proc labelItems(count: int) =
  rowItems = @[]
  for index in 0 ..< count: rowItems.add($index)

var rowBuilder: proc(index: int): UiDescription

suite "row bindings on the wire":
  test "fullBatch create carries rows that are candidate-visible in prepare":
    rowItems = @["a/item/1", "中文", "🙂", ""]
    rowBuilder = proc(index: int): UiDescription = component(BindingRow, index)
    let rt = newRuntime(listApp(rowBuilder))
    # Rows exist before any backend attaches, so the initial wire is fullBatch.
    discard rt.materialize("list", 0, 4)
    let revisionBefore = rt.acceptedRevision
    let recording = newRecordingBackend(fullCapabilities())
    var prepareRows: seq[RowFact]
    var revisionInPrepare = 0'u64
    var acceptedEntitiesInPrepare = -1
    let basePrepare = recording.backend.prepare
    recording.backend.prepare = proc(batch: UpdateBatch) =
      for op in batch.ops:
        if op.kind in {opCreate, opUpdate} and op.row.isSome:
          let binding = op.row.get
          prepareRows.add((op.handle, binding.listHandle, binding.itemIndex,
            binding.itemKey, binding.sourceGeneration))
      revisionInPrepare = rt.acceptedRevision
      acceptedEntitiesInPrepare = recording.entities.len
      basePrepare(batch)
    let session = attachBackend(rt, recording.backend, makeHost())
    let listHandle = session.handleFor(rt.find("list").id)
    let generation = rt.find("list").node.listSource.generation
    # Candidate view: the wire carries rows while the accepted view is empty.
    check acceptedEntitiesInPrepare == 0
    check revisionInPrepare == revisionBefore
    check rt.acceptedRevision == revisionBefore
    prepareRows.sort(proc(a, b: RowFact): int = cmp(a.index, b.index))
    check rowIndices(prepareRows) == @[0, 1, 2, 3]
    check rowKeys(prepareRows) == @["a/item/1", "中文", "🙂", ""]
    for fact in prepareRows:
      check fact.list == listHandle
      check fact.generation == generation
    # Accepted entities keep the same owned values.
    let facts = rowFacts(recording.entities)
    check rowIndices(facts) == @[0, 1, 2, 3]
    check rowKeys(facts) == @["a/item/1", "中文", "🙂", ""]
    for fact in facts:
      check fact.list == listHandle
      check fact.generation == generation
      check fact.handle != NoHandle
    session.dispose()

  test "viewport scroll binds protected non-contiguous rows by item index":
    labelItems(200)
    rowBuilder = proc(index: int): UiDescription = component(BindingRow, index)
    let rt = newRuntime(listApp(rowBuilder))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let source = rt.find("list").node.listSource
    check session.queueRows(RowViewportRequest(sessionId: session.sessionId,
      mountGeneration: session.mountGeneration, listHandle: handle,
      sourceGeneration: source.generation, first: 100, finish: 110,
      protected: @[0]))
    check session.drainRowRequests() == 1
    let facts = rowFacts(recording.entities)
    var expected = @[0]
    for index in 100 ..< 110: expected.add(index)
    check rowIndices(facts) == expected
    check rowKeys(facts) == @["0", "100", "101", "102", "103", "104", "105",
      "106", "107", "108", "109"]
    # The row handle is the host root; the entity index is the active sibling
    # position, never the item index.
    var siblingPositions: seq[int]
    for fact in facts:
      let entity = recording.entities.getOrDefault(fact.handle)
      check entity.parent == handle
      siblingPositions.add(entity.index)
    siblingPositions.sort()
    var expectedPositions: seq[int]
    for position in 0 ..< facts.len: expectedPositions.add(position)
    check siblingPositions == expectedPositions
    session.dispose()

  test "local row State keeps bindings and never exports a snapshot":
    labelItems(6)
    rowBuilder = proc(index: int): UiDescription = component(BindingRow, index)
    rowStates.clear()
    let rt = newRuntime(listApp(rowBuilder))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    let source = rt.find("list").node.listSource
    discard session.queueRows(RowViewportRequest(sessionId: session.sessionId,
      mountGeneration: session.mountGeneration, listHandle: handle,
      sourceGeneration: source.generation, first: 0, finish: 6))
    check session.drainRowRequests() == 1
    let before = rowFacts(recording.entities)
    check rowIndices(before) == @[0, 1, 2, 3, 4, 5]
    let exportsBefore = rt.updateStats.snapshotExports
    recording.history.setLen(0)
    recording.updates = 0
    recording.creates = 0
    check rowStates[0].set(2) == StateWriteResult.queued
    check rt.flush()
    let after = rowFacts(recording.entities)
    check rowIndices(after) == rowIndices(before)
    check rowKeys(after) == rowKeys(before)
    for index in 0 ..< after.len:
      check after[index].handle == before[index].handle
      check after[index].generation == before[index].generation
    check recording.creates == 0
    check rt.updateStats.snapshotExports == exportsBefore
    session.dispose()

  test "source-only replacement re-binds rows as row-only updates":
    labelItems(4)
    rowBuilder = proc(index: int): UiDescription = component(BindingRow, index)
    let rt = newRuntime(listApp(rowBuilder))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    discard session.queueRows(RowViewportRequest(sessionId: session.sessionId,
      mountGeneration: session.mountGeneration, listHandle: handle,
      sourceGeneration: rt.find("list").node.listSource.generation,
      first: 0, finish: 4))
    check session.drainRowRequests() == 1
    let oldGeneration = rt.find("list").node.listSource.generation
    let before = rowFacts(recording.entities)
    recording.history.setLen(0)
    recording.creates = 0
    recording.removes = 0
    # A re-render publishes a new ListSource with the same items.
    listDescription = buildList(rowBuilder)
    check rt.refresh()
    let newGeneration = rt.find("list").node.listSource.generation
    check newGeneration != oldGeneration
    let after = rowFacts(recording.entities)
    check rowIndices(after) == @[0, 1, 2, 3]
    check rowKeys(after) == @["0", "1", "2", "3"]
    for fact in after: check fact.generation == newGeneration
    # The managed runtime recreates row instances for a replaced ListSource, so
    # the rebind shows up as removes plus creates that already carry the new
    # generation; no stale binding may survive.
    check recording.removes > 0
    check recording.creates > 0
    for op in recording.history:
      if op.kind in {opCreate, opUpdate} and op.row.isSome:
        check op.row.get.sourceGeneration == newGeneration
    for op in recording.history:
      if op.kind == opRemove:
        check not recording.entities.hasKey(op.handle)
    # The list record itself is refreshed with the new list metadata.
    var listUpdates = 0
    for op in recording.history:
      if op.kind == opUpdate and op.handle == handle:
        inc listUpdates
        check op.list.isSome
        check op.list.get.sourceGeneration == newGeneration
    check listUpdates == 1
    session.dispose()

  test "warm rows are re-bound on re-activation":
    labelItems(40)
    rowBuilder = proc(index: int): UiDescription = component(BindingRow, index)
    let rt = newRuntime(listApp(rowBuilder))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    proc request(first, finish: int): RowViewportRequest =
      RowViewportRequest(sessionId: session.sessionId,
        mountGeneration: session.mountGeneration, listHandle: handle,
        sourceGeneration: rt.find("list").node.listSource.generation,
        first: first, finish: finish)
    discard session.queueRows(request(0, 5))
    check session.drainRowRequests() == 1
    check rowIndices(rowFacts(recording.entities)) == @[0, 1, 2, 3, 4]
    discard session.queueRows(request(20, 25))
    check session.drainRowRequests() == 1
    check rowIndices(rowFacts(recording.entities)) == @[20, 21, 22, 23, 24]
    discard session.queueRows(request(0, 5))
    check session.drainRowRequests() == 1
    let thirdPass = rowFacts(recording.entities)
    check rowIndices(thirdPass) == @[0, 1, 2, 3, 4]
    check rowKeys(thirdPass) == @["0", "1", "2", "3", "4"]
    session.dispose()

  test "nested list host is itself the outer row root":
    labelItems(4)
    nestedRowIndex = 1
    rowBuilder = proc(index: int): UiDescription = component(NestedRow, index)
    let rt = newRuntime(listApp(rowBuilder))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let outerHandle = session.handleFor(rt.find("list").id)
    discard session.queueRows(RowViewportRequest(sessionId: session.sessionId,
      mountGeneration: session.mountGeneration, listHandle: outerHandle,
      sourceGeneration: rt.find("list").node.listSource.generation,
      first: 0, finish: 4))
    check session.drainRowRequests() == 1
    let outerFacts = rowFacts(recording.entities, outerHandle)
    check rowIndices(outerFacts) == @[0, 1, 2, 3]
    # Row 1 renders the nested list directly: that host is the outer row root.
    let innerHandle = session.handleFor(rt.find("inner").id)
    check innerHandle == outerFacts[1].handle
    let innerEntity = recording.entities.getOrDefault(innerHandle)
    check innerEntity.row.isSome
    check innerEntity.row.get.listHandle == outerHandle
    check innerEntity.row.get.itemIndex == 1
    check innerEntity.row.get.itemKey == "1"
    check session.queueRows(RowViewportRequest(sessionId: session.sessionId,
      mountGeneration: session.mountGeneration, listHandle: innerHandle,
      sourceGeneration: rt.find("inner").node.listSource.generation,
      first: 0, finish: 3))
    check session.drainRowRequests() == 1
    let innerFacts = rowFacts(recording.entities, innerHandle)
    check rowIndices(innerFacts) == @[0, 1, 2]
    check rowKeys(innerFacts) == @["i0", "i1", "i2"]
    nestedRowIndex = -1
    session.dispose()

  test "a pageOutlet root replacement moves the row binding":
    labelItems(3)
    rowBuilder = proc(index: int): UiDescription = component(OutletRow, index)
    rowStates.clear()
    let rt = newRuntime(listApp(rowBuilder))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let listHandle = session.handleFor(rt.find("list").id)
    discard session.queueRows(RowViewportRequest(sessionId: session.sessionId,
      mountGeneration: session.mountGeneration, listHandle: listHandle,
      sourceGeneration: rt.find("list").node.listSource.generation,
      first: 0, finish: 3))
    check session.drainRowRequests() == 1
    let before = rowFacts(recording.entities)
    check rowIndices(before) == @[0, 1, 2]
    let oldRowRoot = before[1].handle
    # Re-render row 1 only: the outlet rebuilds a row root instead of a column.
    check rowStates[1].set(1) == StateWriteResult.queued
    check rt.flush()
    let after = rowFacts(recording.entities)
    check rowIndices(after) == @[0, 1, 2]
    check rowKeys(after) == @["0", "1", "2"]
    check after[1].handle != oldRowRoot
    check after[1].list == listHandle
    check recording.entities.getOrDefault(after[1].handle).row.get.itemIndex == 1
    session.dispose()

  test "component row root replacement keeps the row on the new host root":
    labelItems(3)
    rowBuilder = proc(index: int): UiDescription = component(BindingRow, index)
    rowStates.clear()
    let rt = newRuntime(listApp(rowBuilder))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(rt, recording.backend, makeHost())
    let listHandle = session.handleFor(rt.find("list").id)
    discard session.queueRows(RowViewportRequest(sessionId: session.sessionId,
      mountGeneration: session.mountGeneration, listHandle: listHandle,
      sourceGeneration: rt.find("list").node.listSource.generation,
      first: 0, finish: 3))
    check session.drainRowRequests() == 1
    let before = rowFacts(recording.entities)
    check rowIndices(before) == @[0, 1, 2]
    # Column -> row root swap for row 1 only.
    check rowStates[1].set(1) == StateWriteResult.queued
    check rt.flush()
    let after = rowFacts(recording.entities)
    check rowIndices(after) == @[0, 1, 2]
    check after[0].handle == before[0].handle
    check after[1].handle != before[1].handle
    check after[2].handle == before[2].handle
    for fact in after: check fact.generation == before[0].generation
    session.dispose()

  test "a row-only wire update keeps the props and rebinds the root":
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, sessionId = 108'u64)
    let list = NodeHandle(1)
    let rowRoot = NodeHandle(2)
    let listRecord = HostProps(list: some(HostListProps(sourceGeneration: 3,
      itemCount: 4, heightMode: HostHeightMode.uniform, rowHeight: 10.0,
      estimate: 10.0, overscan: 0)))
    consumer.prepare(HostBatch(sessionId: 108, baseRevision: 0,
      nextRevision: 1, ops: @[
        HostOp(kind: HostOpKind.create, handle: list, nodeId: "list",
          nodeKind: virtualList, props: listRecord),
        HostOp(kind: HostOpKind.create, handle: rowRoot, parent: list,
          nodeId: "row", nodeKind: text, props: HostProps(),
          row: rowBinding(list, 3, 0, "k0")),
        HostOp(kind: HostOpKind.setChildren, handle: list,
          children: @[rowRoot])]))
    consumer.apply()
    consumer.accept(1)
    let props = recording.entities.getOrDefault(rowRoot).props
    recording.history.setLen(0)
    # Same props, different item index/key: only the binding changes.
    consumer.prepare(HostBatch(sessionId: 108, baseRevision: 1,
      nextRevision: 2, ops: @[
        HostOp(kind: HostOpKind.update, handle: rowRoot, parent: list,
          nodeId: "row", nodeKind: text, props: HostProps(),
          row: rowBinding(list, 3, 2, "k2"))]))
    consumer.apply()
    consumer.accept(2)
    check recording.history.len == 1
    check recording.history[0].kind == opUpdate
    check recording.history[0].props == props
    check recording.history[0].row.isSome
    check recording.history[0].row.get.itemIndex == 2
    check recording.entities.getOrDefault(rowRoot).row.get.itemKey == "k2"
    check recording.entities.getOrDefault(rowRoot).props == props
    consumer.discardPrepared()

suite "row binding rejection happens before platform prepare":
  test "malformed bindings are refused by the reconciler":
    let r = newHostReconciler(1)
    let list = NodeHandle(1)
    let child = NodeHandle(2)
    let first = r.planDelta(HostChanges(upserts: @[
      HostRecord(handle: list, parent: NoHandle, nodeId: "list",
        kind: virtualList, props: listProps(7, 3)),
      HostRecord(handle: child, parent: list, nodeId: "row0", kind: text,
        props: HostProps(), row: rowBinding(list, 7, 0, "k0"))],
      children: @[HostChildren(parent: list, children: @[child])]), 1)
    r.accept(first)
    proc attempt(records: seq[HostRecord],
                 orders: seq[HostChildren] = @[]): bool =
      let candidate = r.planDelta(HostChanges(upserts: records, children: orders), 2)
      r.discard(candidate)
      true
    # Benchmark: the same shape still validates.
    check attempt(@[
      HostRecord(handle: list, parent: NoHandle, nodeId: "list",
        kind: virtualList, props: listProps(8, 3)),
      HostRecord(handle: child, parent: list, nodeId: "row0", kind: text,
        props: HostProps(), row: rowBinding(list, 8, 0, "k0"))],
      @[HostChildren(parent: list, children: @[child])])
    # Stale generation.
    expect UiError:
      discard attempt(@[
        HostRecord(handle: list, parent: NoHandle, nodeId: "list",
          kind: virtualList, props: listProps(9, 3)),
        HostRecord(handle: child, parent: list, nodeId: "row0", kind: text,
          props: HostProps(), row: rowBinding(list, 8, 0, "k0"))],
        @[HostChildren(parent: list, children: @[child])])
    # Index outside the item count.
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: child, parent: list, nodeId: "row0", kind: text,
          props: HostProps(), row: rowBinding(list, 8, 3, "k3"))]), 2)
    # A row root that is not a direct child of its list is refused.
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: child, parent: NoHandle, nodeId: "row0", kind: text,
          props: HostProps(), row: rowBinding(list, 8, 0, "k0"))]), 2)
    # Unknown list handle.
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: child, parent: list, nodeId: "row0", kind: text,
          props: HostProps(), row: rowBinding(NodeHandle(99), 8, 0, "k0"))]), 2)
    # Over-budget key and invalid UTF-8.
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: child, parent: list, nodeId: "row0", kind: text,
          props: HostProps(),
          row: rowBinding(list, 8, 0, repeat("k", MaxStringBytes + 1)))]), 2)
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: child, parent: list, nodeId: "row0", kind: text,
          props: HostProps(), row: rowBinding(list, 8, 0, "bad\xff"))]), 2)
    # A changed list may not leave a child without a matching binding.
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: list, parent: NoHandle, nodeId: "list",
          kind: virtualList, props: listProps(9, 3))],
        children: @[HostChildren(parent: list, children: @[child])]), 2)
    check r.revision == 1

  test "a changed list may not add an unbound child next to a bound one":
    let r = newHostReconciler(4)
    let list = NodeHandle(1)
    let bound = NodeHandle(2)
    let first = r.planDelta(HostChanges(upserts: @[
      HostRecord(handle: list, parent: NoHandle, nodeId: "list",
        kind: virtualList, props: listProps(5, 4)),
      HostRecord(handle: bound, parent: list, nodeId: "a", kind: text,
        props: HostProps(), row: rowBinding(list, 5, 0, "k0"))],
      children: @[HostChildren(parent: list, children: @[bound])]), 1)
    r.accept(first)
    let unbound = NodeHandle(3)
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: list, parent: NoHandle, nodeId: "list",
          kind: virtualList, props: listProps(5, 4)),
        HostRecord(handle: unbound, parent: list, nodeId: "b", kind: text,
          props: HostProps())],
        children: @[HostChildren(parent: list, children: @[bound, unbound])]), 2)
    # Binding both children validates.
    let candidate = r.planDelta(HostChanges(upserts: @[
      HostRecord(handle: list, parent: NoHandle, nodeId: "list",
        kind: virtualList, props: listProps(5, 4)),
      HostRecord(handle: unbound, parent: list, nodeId: "b", kind: text,
        props: HostProps(), row: rowBinding(list, 5, 1, "k1"))],
      children: @[HostChildren(parent: list, children: @[bound, unbound])]), 2)
    r.accept(candidate)
    check r.revision == 2

  test "a legacy snapshot list without typed rows is still accepted":
    # Snapshot plans never produce typed row bindings; the managed-only rule
    # must not turn the existing snapshot compatibility path into a rejection.
    let r = newHostReconciler(5)
    let listNode = virtualList("list", @["a", "b"],
      proc(index: int): Node = text($index, key = "row"),
      rowHeight = 10, overscan = 0)
    var rows: seq[MountedNode]
    for index in 0 ..< 2:
      rows.add(mountedDescription(text($index, key = "row"),
        "row-" & $index, @[], index))
    let rootMounted = mountedDescription(column(@[], key = "root"), "root-node",
      @[mountedDescription(listNode, "list-node", rows)])
    let snapshot = Snapshot(title: "t", width: 640, height: 480,
      root: rootMounted)
    let candidate = r.planSnapshot(snapshot, 1, hostCompatible)
    r.accept(candidate)
    check r.revision == 1
    # Two unbound list children are also accepted through a delta plan.
    let r2 = newHostReconciler(6)
    let list = NodeHandle(1)
    let a = NodeHandle(2)
    let b = NodeHandle(3)
    r2.accept(r2.planDelta(HostChanges(upserts: @[
      HostRecord(handle: list, parent: NoHandle, nodeId: "list",
        kind: virtualList, props: listProps(5, 4)),
      HostRecord(handle: a, parent: list, nodeId: "a", kind: text,
        props: HostProps()),
      HostRecord(handle: b, parent: list, nodeId: "b", kind: text,
        props: HostProps())],
      children: @[HostChildren(parent: list, children: @[a, b])]), 1))
    check r2.revision == 1

  test "duplicate row index or key in one list is refused":
    let r = newHostReconciler(2)
    let list = NodeHandle(1)
    let first = r.planDelta(HostChanges(upserts: @[
      HostRecord(handle: list, parent: NoHandle, nodeId: "list",
        kind: virtualList, props: listProps(3, 4))],
      children: @[HostChildren(parent: list, children: @[])]), 1)
    r.accept(first)
    let a = NodeHandle(10)
    let b = NodeHandle(11)
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: a, parent: list, nodeId: "a", kind: text,
          props: HostProps(), row: rowBinding(list, 3, 0, "k0")),
        HostRecord(handle: b, parent: list, nodeId: "b", kind: text,
          props: HostProps(), row: rowBinding(list, 3, 0, "k1"))],
        children: @[HostChildren(parent: list, children: @[a, b])]), 2)
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: a, parent: list, nodeId: "a", kind: text,
          props: HostProps(), row: rowBinding(list, 3, 0, "k0")),
        HostRecord(handle: b, parent: list, nodeId: "b", kind: text,
          props: HostProps(), row: rowBinding(list, 3, 1, "k0"))],
        children: @[HostChildren(parent: list, children: @[a, b])]), 2)
    # The row root must be in the list's final membership.
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: a, parent: list, nodeId: "a", kind: text,
          props: HostProps(), row: rowBinding(list, 3, 0, "k0"))],
        children: @[HostChildren(parent: list, children: @[])]), 2)
    check r.revision == 1

  test "a row root under a non-list parent is refused":
    let r = newHostReconciler(3)
    let list = NodeHandle(1)
    let label = NodeHandle(2)
    let rowRoot = NodeHandle(3)
    let first = r.planDelta(HostChanges(upserts: @[
      HostRecord(handle: list, parent: NoHandle, nodeId: "list",
        kind: virtualList, props: listProps(2, 4)),
      HostRecord(handle: label, parent: list, nodeId: "label", kind: text,
        props: HostProps(), row: rowBinding(list, 2, 0, "k0"))],
      children: @[HostChildren(parent: list, children: @[label])]), 1)
    r.accept(first)
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: rowRoot, parent: label, nodeId: "row", kind: text,
          props: HostProps(), row: rowBinding(label, 2, 1, "k1"))],
        children: @[HostChildren(parent: label, children: @[rowRoot]),
          HostChildren(parent: list, children: @[label])]), 2)
    check r.revision == 1

  test "an edited row may not collide with an accepted unedited peer":
    let r = newHostReconciler(21)
    let list = NodeHandle(1)
    let accepted = NodeHandle(2)
    r.accept(r.planDelta(HostChanges(upserts: @[
      HostRecord(handle: list, parent: NoHandle, nodeId: "list",
        kind: virtualList, props: listProps(7, 3)),
      HostRecord(handle: accepted, parent: list, nodeId: "row-a", kind: text,
        props: HostProps(), row: rowBinding(list, 7, 0, "k0"))],
      children: @[HostChildren(parent: list, children: @[accepted])]), 1))
    # Same item index as the accepted, unedited sibling.
    let sameIndex = NodeHandle(3)
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: sameIndex, parent: list, nodeId: "row-b",
          kind: text, props: HostProps(), row: rowBinding(list, 7, 0, "k1"))],
        children: @[HostChildren(parent: list,
          children: @[accepted, sameIndex])]), 2)
    # Same item key as the accepted, unedited sibling.
    let sameKey = NodeHandle(4)
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: sameKey, parent: list, nodeId: "row-c", kind: text,
          props: HostProps(), row: rowBinding(list, 7, 2, "k0"))],
        children: @[HostChildren(parent: list,
          children: @[accepted, sameKey])]), 2)
    check r.revision == 1

  test "a typed list may not silently drop every binding while keeping rows":
    let r = newHostReconciler(22)
    let list = NodeHandle(1)
    let child = NodeHandle(2)
    r.accept(r.planDelta(HostChanges(upserts: @[
      HostRecord(handle: list, parent: NoHandle, nodeId: "list",
        kind: virtualList, props: listProps(7, 3)),
      HostRecord(handle: child, parent: list, nodeId: "row-a", kind: text,
        props: HostProps(), row: rowBinding(list, 7, 0, "k0"))],
      children: @[HostChildren(parent: list, children: @[child])]), 1))
    # The list record changes and the only child keeps its membership but loses
    # its typed binding: that is a degraded contract, not a legal unbind.
    var changedList = HostRecord(handle: list, parent: NoHandle, nodeId: "list",
      kind: virtualList, props: listProps(7, 3))
    changedList.props.list.get.estimate = 11.0
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[changedList,
        HostRecord(handle: child, parent: list, nodeId: "row-a", kind: text,
          props: HostProps())],
        children: @[HostChildren(parent: list, children: @[child])]), 2)
    check r.revision == 1

  test "a pure row-only strip without list edits is still refused":
    # r2 defect 5: a Some->None edit on a row root does not change the list
    # record, its metadata or its membership, so the list must still be gated
    # through the *accepted* binding of the edited record.
    let r = newHostReconciler(31)
    let list = NodeHandle(1)
    let only = NodeHandle(2)
    r.accept(r.planDelta(HostChanges(upserts: @[
      HostRecord(handle: list, parent: NoHandle, nodeId: "list",
        kind: virtualList, props: listProps(7, 3)),
      HostRecord(handle: only, parent: list, nodeId: "row-a", kind: text,
        props: HostProps(), row: rowBinding(list, 7, 0, "k0"))],
      children: @[HostChildren(parent: list, children: @[only])]), 1))
    expect UiError:
      discard r.planDelta(HostChanges(upserts: @[
        HostRecord(handle: only, parent: list, nodeId: "row-a", kind: text,
          props: HostProps())]), 2)
    check r.revision == 1
    # With several bound peers, stripping one of them is refused as well.
    let r2 = newHostReconciler(32)
    let list2 = NodeHandle(1)
    let a = NodeHandle(2)
    let b = NodeHandle(3)
    r2.accept(r2.planDelta(HostChanges(upserts: @[
      HostRecord(handle: list2, parent: NoHandle, nodeId: "list",
        kind: virtualList, props: listProps(7, 3)),
      HostRecord(handle: a, parent: list2, nodeId: "row-a", kind: text,
        props: HostProps(), row: rowBinding(list2, 7, 0, "k0")),
      HostRecord(handle: b, parent: list2, nodeId: "row-b", kind: text,
        props: HostProps(), row: rowBinding(list2, 7, 1, "k1"))],
      children: @[HostChildren(parent: list2, children: @[a, b])]), 1))
    expect UiError:
      discard r2.planDelta(HostChanges(upserts: @[
        HostRecord(handle: b, parent: list2, nodeId: "row-b", kind: text,
          props: HostProps())]), 2)
    check r2.revision == 1
    # Controls: the same strip is legal once the row really leaves the list,
    # and a removed row's accepted binding does not block its bound sibling.
    r.accept(r.planDelta(HostChanges(removals: @[only],
      children: @[HostChildren(parent: list, children: @[])]), 2))
    check r.revision == 2
    r2.accept(r2.planDelta(HostChanges(removals: @[a],
      children: @[HostChildren(parent: list2, children: @[b])]), 2))
    check r2.revision == 2
    check r2.record(b).get.row.isSome

  test "legal unbinding: removing, reparenting or emptying a typed list":
    # (a) the last row leaves the list entirely (membership removal).
    let r = newHostReconciler(23)
    let list = NodeHandle(1)
    let row = NodeHandle(2)
    r.accept(r.planDelta(HostChanges(upserts: @[
      HostRecord(handle: list, parent: NoHandle, nodeId: "list",
        kind: virtualList, props: listProps(7, 3)),
      HostRecord(handle: row, parent: list, nodeId: "row-a", kind: text,
        props: HostProps(), row: rowBinding(list, 7, 0, "k0"))],
      children: @[HostChildren(parent: list, children: @[row])]), 1))
    r.accept(r.planDelta(HostChanges(removals: @[row],
      children: @[HostChildren(parent: list, children: @[])]), 2))
    check r.revision == 2
    # (b) an emptied typed list can be filled again with fresh bindings.
    r.accept(r.planDelta(HostChanges(upserts: @[
      HostRecord(handle: row, parent: list, nodeId: "row-b", kind: text,
        props: HostProps(), row: rowBinding(list, 7, 1, "k1"))],
      children: @[HostChildren(parent: list, children: @[row])]), 3))
    check r.revision == 3
    # (c) the whole typed list is removed together with its row.
    r.accept(r.planDelta(HostChanges(removals: @[row, list]), 4))
    check r.revision == 4
    # (d) a row reparented to another list is re-bound, not degraded.
    let r2 = newHostReconciler(24)
    let root = NodeHandle(1)
    let first = NodeHandle(2)
    let second = NodeHandle(3)
    let moving = NodeHandle(4)
    r2.accept(r2.planDelta(HostChanges(upserts: @[
      HostRecord(handle: root, parent: NoHandle, nodeId: "root",
        kind: column, props: HostProps()),
      HostRecord(handle: first, parent: root, nodeId: "first",
        kind: virtualList, props: listProps(7, 3)),
      HostRecord(handle: second, parent: root, nodeId: "second",
        kind: virtualList, props: listProps(9, 3)),
      HostRecord(handle: moving, parent: first, nodeId: "row-a", kind: text,
        props: HostProps(), row: rowBinding(first, 7, 0, "k0"))],
      children: @[HostChildren(parent: root, children: @[first, second]),
        HostChildren(parent: first, children: @[moving]),
        HostChildren(parent: second, children: @[])]), 1))
    r2.accept(r2.planDelta(HostChanges(upserts: @[
      HostRecord(handle: moving, parent: second, nodeId: "row-a", kind: text,
        props: HostProps(), row: rowBinding(second, 9, 2, "k2"))],
      children: @[HostChildren(parent: first, children: @[]),
        HostChildren(parent: second, children: @[moving])]), 2))
    check r2.revision == 2

suite "row bindings survive publication and restore":
  test "acceptedDelta, full metadata and restore keep rows":
    labelItems(8)
    rowBuilder = proc(index: int): UiDescription = component(BindingRow, index)
    var deltas: seq[HostAcceptedDelta]
    let plain = newRecordingBackend(fullCapabilities())
    let rt = newRuntime(listApp(rowBuilder))
    var backend = plain.backend
    backend.acceptedDelta = proc(delta: HostAcceptedDelta) {.raises: [].} =
      deltas.add(HostAcceptedDelta(revision: delta.revision,
        upserts: delta.upserts, removals: delta.removals, orders: delta.orders,
        issues: delta.issues))
    let session = attachBackend(rt, backend, makeHost())
    let handle = session.handleFor(rt.find("list").id)
    proc request(first, finish: int): RowViewportRequest =
      RowViewportRequest(sessionId: session.sessionId,
        mountGeneration: session.mountGeneration, listHandle: handle,
        sourceGeneration: rt.find("list").node.listSource.generation,
        first: first, finish: finish)
    discard session.queueRows(request(0, 3))
    check session.drainRowRequests() == 1
    var deltaRows: seq[RowFact]
    for delta in deltas:
      for entity in delta.upserts:
        if entity.row.isSome:
          let binding = entity.row.get
          deltaRows.add((entity.handle, binding.listHandle, binding.itemIndex,
            binding.itemKey, binding.sourceGeneration))
    deltaRows.sort(proc(a, b: RowFact): int = cmp(a.index, b.index))
    check rowIndices(deltaRows) == @[0, 1, 2]
    check rowKeys(deltaRows) == @["0", "1", "2"]
    # A rejected apply restores the previous row bindings.
    let before = rowFacts(plain.entities)
    let revision = rt.acceptedRevision
    plain.failApplyAt = 1
    check session.queueRows(request(3, 5))
    expect UiError:
      discard session.drainRowRequests()
    check rt.acceptedRevision == revision
    let restored = rowFacts(plain.entities)
    check rowIndices(restored) == rowIndices(before)
    for index in 0 ..< restored.len:
      check restored[index].handle == before[index].handle
      check restored[index].generation == before[index].generation
    plain.failApplyAt = 0
    session.dispose()
    # Full metadata fallback for a backend without acceptedDelta.
    let fallback = newRecordingBackend(fullCapabilities())
    var fallbackTable: Table[NodeHandle, MountedEntity]
    fallback.backend.accepted = proc(entities: Table[NodeHandle, MountedEntity],
                                     revision: uint64) {.raises: [].} =
      fallbackTable = entities
    let fallbackSession = attachBackend(rt, fallback.backend, makeHost(102'u64))
    check rowIndices(rowFacts(fallbackTable)) == @[0, 1, 2]
    fallbackSession.dispose()

  test "row create, update and remove keep accept and publish allocation-free":
    when defined(leafProtocolProbes) and defined(nimAllocStats):
      labelItems(8)
      rowBuilder = proc(index: int): UiDescription = component(BindingRow, index)
      let rt = newRuntime(listApp(rowBuilder))
      let recording = newRecordingBackend(fullCapabilities())
      let session = attachBackend(rt, recording.backend, makeHost())
      let handle = session.handleFor(rt.find("list").id)
      proc request(first, finish: int): RowViewportRequest =
        RowViewportRequest(sessionId: session.sessionId,
          mountGeneration: session.mountGeneration, listHandle: handle,
          sourceGeneration: rt.find("list").node.listSource.generation,
          first: first, finish: finish)
      # create
      managedPublishAllocations = -1
      nativeAcceptAllocations = -1
      discard session.queueRows(request(0, 4))
      check session.drainRowRequests() == 1
      check managedPublishAllocations == 0
      check nativeAcceptAllocations == 0
      # update (row-only rebind through a new source generation)
      listDescription = buildList(rowBuilder)
      managedPublishAllocations = -1
      nativeAcceptAllocations = -1
      check rt.refresh()
      check managedPublishAllocations == 0
      check nativeAcceptAllocations == 0
      check rowIndices(rowFacts(recording.entities)) == @[0, 1, 2, 3]
      # remove (rows leave the viewport)
      managedPublishAllocations = -1
      nativeAcceptAllocations = -1
      discard session.queueRows(request(4, 6))
      check session.drainRowRequests() == 1
      check managedPublishAllocations == 0
      check nativeAcceptAllocations == 0
      check rowIndices(rowFacts(recording.entities)) == @[4, 5]
      session.dispose()

## r1: the native adapter validates a raw HostBatch on the *candidate view*
## (`entities + edits - removals`). A produced-elsewhere or forged wire must be
## refused before `backend.prepare`; the producer's own checks are not trusted.
proc rawBatch(sessionId: uint64, base, next: uint64, ops: seq[HostOp]): HostBatch =
  HostBatch(sessionId: sessionId, baseRevision: base, nextRevision: next, ops: ops)

proc listWire(list: NodeHandle, generation = 7'u64, count = 3): HostOp =
  HostOp(kind: HostOpKind.create, handle: list, parent: NoHandle,
    nodeId: "list", nodeKind: virtualList,
    props: HostProps(list: some(HostListProps(sourceGeneration: generation,
      itemCount: count, heightMode: HostHeightMode.uniform, rowHeight: 10.0,
      estimate: 10.0, overscan: 0))))

proc rowWire(row, list: NodeHandle, index: int, key: string,
             generation = 7'u64): HostOp =
  HostOp(kind: HostOpKind.create, handle: row, parent: list, nodeId: "row-" & $index,
    nodeKind: text, props: HostProps(),
    row: rowBinding(list, generation, index, key))

proc seedList(consumer: HostConsumer, recording: RecordingBackend,
              sessionId: uint64, list, row: NodeHandle) =
  consumer.prepare(rawBatch(sessionId, 0, 1, @[
    listWire(list), rowWire(row, list, 0, "k0"),
    HostOp(kind: HostOpKind.setChildren, handle: list, children: @[row])]))
  consumer.apply()
  consumer.accept(1)
  check recording.prepareCalls == 1

suite "native adapter candidate-view row gate":
  test "a row update in the same batch as its list removal is refused":
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, sessionId = 201'u64)
    seedList(consumer, recording, 201'u64, NodeHandle(1), NodeHandle(2))
    let before = recording.prepareCalls
    expect UiError:
      consumer.prepare(rawBatch(201'u64, 1, 2, @[
        HostOp(kind: HostOpKind.update, handle: NodeHandle(2), parent: NodeHandle(1),
          nodeId: "row-0", nodeKind: text, props: HostProps(),
          row: rowBinding(NodeHandle(1), 7, 0, "k0")),
        HostOp(kind: HostOpKind.remove, handle: NodeHandle(1))]))
    check recording.prepareCalls == before

  test "duplicate item index or key in one batch is refused":
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, sessionId = 202'u64)
    expect UiError:
      consumer.prepare(rawBatch(202'u64, 0, 1, @[
        listWire(NodeHandle(1)),
        rowWire(NodeHandle(2), NodeHandle(1), 0, "k0"),
        rowWire(NodeHandle(3), NodeHandle(1), 0, "k1"),
        HostOp(kind: HostOpKind.setChildren, handle: NodeHandle(1),
          children: @[NodeHandle(2), NodeHandle(3)])]))
    check recording.prepareCalls == 0
    expect UiError:
      consumer.prepare(rawBatch(202'u64, 0, 1, @[
        listWire(NodeHandle(1)),
        rowWire(NodeHandle(2), NodeHandle(1), 0, "k0"),
        rowWire(NodeHandle(3), NodeHandle(1), 1, "k0"),
        HostOp(kind: HostOpKind.setChildren, handle: NodeHandle(1),
          children: @[NodeHandle(2), NodeHandle(3)])]))
    check recording.prepareCalls == 0

  test "a bound row outside the list's final membership is refused":
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, sessionId = 203'u64)
    expect UiError:
      consumer.prepare(rawBatch(203'u64, 0, 1, @[
        listWire(NodeHandle(1)),
        rowWire(NodeHandle(2), NodeHandle(1), 0, "k0")]))
    check recording.prepareCalls == 0

  test "invalid or oversized row keys are refused":
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, sessionId = 204'u64)
    expect UiError:
      consumer.prepare(rawBatch(204'u64, 0, 1, @[
        listWire(NodeHandle(1)), rowWire(NodeHandle(2), NodeHandle(1), 0, "bad\xff"),
        HostOp(kind: HostOpKind.setChildren, handle: NodeHandle(1),
          children: @[NodeHandle(2)])]))
    check recording.prepareCalls == 0
    expect UiError:
      consumer.prepare(rawBatch(204'u64, 0, 1, @[
        listWire(NodeHandle(1)),
        rowWire(NodeHandle(2), NodeHandle(1), 0, repeat("k", MaxStringBytes + 1)),
        HostOp(kind: HostOpKind.setChildren, handle: NodeHandle(1),
          children: @[NodeHandle(2)])]))
    check recording.prepareCalls == 0

  test "stripping the binding of a child that stays in the list is refused":
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, sessionId = 205'u64)
    seedList(consumer, recording, 205'u64, NodeHandle(1), NodeHandle(2))
    let before = recording.prepareCalls
    expect UiError:
      consumer.prepare(rawBatch(205'u64, 1, 2, @[
        HostOp(kind: HostOpKind.update, handle: NodeHandle(2), parent: NodeHandle(1),
          nodeId: "row-0", nodeKind: text, props: HostProps())]))
    check recording.prepareCalls == before

  test "legally unbinding a row and legacy row-less lists still reach prepare":
    # Removing the row and emptying the list is a legal unbind.
    let recording = newRecordingBackend(fullCapabilities())
    let consumer = nativeHostConsumer(recording.backend, sessionId = 206'u64)
    seedList(consumer, recording, 206'u64, NodeHandle(1), NodeHandle(2))
    consumer.prepare(rawBatch(206'u64, 1, 2, @[
      HostOp(kind: HostOpKind.setChildren, handle: NodeHandle(1), children: @[]),
      HostOp(kind: HostOpKind.remove, handle: NodeHandle(2))]))
    consumer.apply()
    consumer.accept(2)
    check recording.prepareCalls == 2
    check not recording.entities.hasKey(NodeHandle(2))
    # A raw wire that never used typed rows is a legacy candidate and passes.
    let legacyRecording = newRecordingBackend(fullCapabilities())
    let legacy = nativeHostConsumer(legacyRecording.backend, sessionId = 207'u64)
    legacy.prepare(rawBatch(207'u64, 0, 1, @[
      listWire(NodeHandle(1)),
      HostOp(kind: HostOpKind.create, handle: NodeHandle(2), parent: NodeHandle(1),
        nodeId: "row-0", nodeKind: text, props: HostProps()),
      HostOp(kind: HostOpKind.setChildren, handle: NodeHandle(1),
        children: @[NodeHandle(2)])]))
    legacy.apply()
    legacy.accept(1)
    check legacyRecording.prepareCalls == 1
