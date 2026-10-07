## Pure incremental reconciliation: description diffing and entity identity
## allocation. No callbacks, Node references or platform state leave this
## module, and `accept` performs no external code.
import std/[tables, sets, algorithm]
import ./[core, styles, backend]

type
  PropsAdapter* = proc(node: Node): NormalizedProps {.closure.}
    ## Optional backward-compatible hook used by a session to diff effective
    ## (capability-filtered) properties instead of raw ones.

  ReconcilePlan* = object
    ## A complete candidate. `batch` is applied in order; `entities` and
    ## `byNodeId` become the accepted map only when `accept` succeeds.
    revision*: uint64
    baseRevision*: uint64
    batch*: UpdateBatch
    entities*: Table[NodeHandle, MountedEntity]
    byNodeId*: Table[string, NodeHandle]
    owner: uint64
    baseGeneration: uint64

  Reconciler* = ref object
    entities: Table[NodeHandle, MountedEntity]
    byNodeId: Table[string, NodeHandle]
    nextHandle: uint64
    revision: uint64
    owner: uint64
    generation: uint64

var ownerCounter: uint64

proc newReconciler*(): Reconciler =
  ## Handles are allocated monotonically and never reclaimed, so a discarded
  ## or rejected plan cannot make a future plan reuse a dead identity. Every
  ## reconciler also carries a unique owner token so it can never accept a
  ## plan produced by another reconciler.
  inc ownerCounter
  Reconciler(nextHandle: 1, owner: ownerCounter)

proc allocate(r: Reconciler): NodeHandle =
  result = NodeHandle(r.nextHandle)
  inc r.nextHandle

proc plan*(r: Reconciler, snapshot: Snapshot, revision: uint64,
          adapter: PropsAdapter = nil): ReconcilePlan =
  ## Diff a candidate description against the accepted entities. Identity is
  ## resolved structurally: a node reuses its entity only when the same node ID
  ## is accepted, its kind is unchanged, and its whole ancestor chain was
  ## reused. A replaced ancestor therefore recreates every descendant even when
  ## the descendant's string ID is identical. No string prefix is ever used to
  ## infer ancestry. When `adapter` is supplied it produces the stored and
  ## compared properties (for example capability-filtered effective props);
  ## the original three-argument call keeps using raw normalized props.
  var entities: Table[NodeHandle, MountedEntity]
  var byNodeId: Table[string, NodeHandle]
  var created: HashSet[NodeHandle]
  var reused: HashSet[NodeHandle]
  var children: Table[NodeHandle, seq[NodeHandle]]
  var createOps: seq[UpdateOp]

  proc visit(mounted: MountedNode, parent: NodeHandle, index: int,
             parentReused: bool): NodeHandle =
    let node = mounted.node
    let existing = r.byNodeId.getOrDefault(mounted.id, NoHandle)
    var handle: NodeHandle
    var nodeReused = false
    if parentReused and existing != NoHandle and r.entities.hasKey(existing) and
        r.entities[existing].kind == node.kind:
      handle = existing
      nodeReused = true
    else:
      handle = r.allocate()
    let entity = MountedEntity(handle: handle, parent: parent,
      nodeId: mounted.id, kind: node.kind,
      props: (if adapter != nil: adapter(node) else: normalizeProps(node)),
      index: index)
    entities[handle] = entity
    byNodeId[mounted.id] = handle
    children.mgetOrPut(parent, @[]).add(handle)
    if nodeReused:
      reused.incl(handle)
    else:
      created.incl(handle)
      createOps.add(UpdateOp(kind: opCreate, handle: handle, parent: parent,
        index: index, nodeId: mounted.id, nodeKind: node.kind,
        props: entity.props))
    for childIndex, child in mounted.children:
      discard visit(child, handle, childIndex, nodeReused)
    handle

  discard visit(snapshot.root, NoHandle, 0, true)

  # Removes run children-first so a removed parent never outlives its children.
  var removed: seq[tuple[depth: int, entity: MountedEntity]]
  for handle, entity in r.entities:
    if not entities.hasKey(handle):
      var depth = 0
      var current = entity.parent
      while current != NoHandle and r.entities.hasKey(current):
        inc depth
        current = r.entities[current].parent
      removed.add((depth, entity))
  removed.sort(proc(a, b: tuple[depth: int, entity: MountedEntity]): int =
    cmp(b.depth, a.depth))
  var removeOps: seq[UpdateOp]
  for item in removed:
    removeOps.add(UpdateOp(kind: opRemove, handle: item.entity.handle,
      parent: item.entity.parent, index: item.entity.index,
      nodeId: item.entity.nodeId, nodeKind: item.entity.kind))

  # Accepted sibling order per parent, needed to compute reorder moves.
  var acceptedChildren: Table[NodeHandle, seq[NodeHandle]]
  for handle, entity in r.entities:
    acceptedChildren.mgetOrPut(entity.parent, @[]).add(handle)
  var acceptedParents: seq[NodeHandle]
  for parent in acceptedChildren.keys: acceptedParents.add(parent)
  for parent in acceptedParents:
    acceptedChildren[parent].sort(proc(a, b: NodeHandle): int =
      cmp(r.entities[a].index, r.entities[b].index))

  # Reorder moves are computed against a simulation of the batch's own order
  # (removes, then creates, then moves), so every index is valid when applied
  # sequentially rather than reusing a stale index.
  var moveOps: seq[UpdateOp]
  for parent, candidateChildren in children:
    var current: seq[NodeHandle]
    for handle in acceptedChildren.getOrDefault(parent):
      if entities.hasKey(handle): current.add(handle)
    for handle in candidateChildren:
      if handle in created:
        current.insert(handle, min(entities[handle].index, current.len))
    for i in 0..<candidateChildren.len:
      if i >= current.len: break
      if current[i] == candidateChildren[i]: continue
      let target = candidateChildren[i]
      var j = i
      while j < current.len and current[j] != target: inc j
      if j >= current.len: continue
      moveOps.add(UpdateOp(kind: opMove, handle: target, parent: parent,
        index: i, nodeId: entities[target].nodeId,
        nodeKind: entities[target].kind))
      current.delete(j)
      current.insert(target, i)

  # Updates carry the complete normalized properties, so a removed property
  # restores its platform default.
  var updateOps: seq[UpdateOp]
  for handle in reused:
    let next = entities[handle]
    if next.props != r.entities[handle].props:
      updateOps.add(UpdateOp(kind: opUpdate, handle: handle, parent: next.parent,
        index: next.index, nodeId: next.nodeId, nodeKind: next.kind,
        props: next.props))

  result.baseRevision = r.revision
  result.baseGeneration = r.generation
  result.owner = r.owner
  result.revision = revision
  result.entities = entities
  result.byNodeId = byNodeId
  var ops: seq[UpdateOp]
  ops.add(removeOps)
  ops.add(createOps)
  ops.add(moveOps)
  ops.add(updateOps)
  result.batch = UpdateBatch(revision: revision, ops: ops)

proc accept*(r: Reconciler, plan: ReconcilePlan) =
  ## Publish a candidate. The authoritative baseline token is the private
  ## accepted-state generation, not the public revision number: a plan is
  ## rejected before any table changes when it was produced by another
  ## reconciler or generated before the current accepted state. Every
  ## successful accept advances the generation, so an older plan can never
  ## roll a live description back to an earlier baseline, even at the same
  ## revision. A no-change plan generated from the current state is still
  ## safe: it matches the generation, and accepting it simply advances it.
  if plan.owner != r.owner:
    fail("foreign reconcile plan: not produced by this reconciler")
  if plan.baseGeneration != r.generation:
    fail("stale reconcile plan: base generation " & $plan.baseGeneration &
      " does not match accepted generation " & $r.generation)
  if plan.revision < r.revision:
    fail("reconcile plan would move the accepted revision backwards: " &
      $plan.revision & " < " & $r.revision)
  r.entities = plan.entities
  r.byNodeId = plan.byNodeId
  r.revision = plan.revision
  inc r.generation
