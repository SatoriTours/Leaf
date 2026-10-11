## Recording backend: a dependency-free, non-graphical Backend used to verify
## native sessions. It replays batches against a real entity map so tests see
## the actual intermediate state, not just "the plan was called".
##
## It has no platform resources, no graphics toolkit and no test-only hook in
## Runtime or core; failure injection lives entirely here.
import std/[tables, algorithm]
import ../[core, backend]

type
  RecordingBackend* = ref object
    backend*: Backend
    entities*: Table[NodeHandle, MountedEntity]
    children*: Table[NodeHandle, seq[NodeHandle]]
    history*: seq[UpdateOp]
    prepared*: seq[UpdateOp]
    creates*, updates*, moves*, removes*: int
    prepareCalls*, applyCalls*, discardCalls*, restoreCalls*, disposeCalls*: int
    failPrepare*, failApply*, failRestore*: bool
    failDiscard*, failDispose*: bool
    failApplyAt*: int
      ## 1-based op index to fail at during apply; 0 disables.
    disposed*: bool
    onSetter*: proc(handle: NodeHandle) {.closure.}
    inputState*: Table[NodeHandle, string]
      ## Simulated backend-temporary input selection; not native IME.

proc childrenOf*(recording: RecordingBackend, parent: NodeHandle): seq[NodeHandle] =
  recording.children.getOrDefault(parent)

proc findHandle(list: seq[NodeHandle], handle: NodeHandle): int =
  for index, item in list:
    if item == handle: return index
  -1

proc prepareImpl(recording: RecordingBackend, batch: UpdateBatch) =
  inc recording.prepareCalls
  if recording.failPrepare: raise newException(UiError, "recording prepare failure")
  recording.prepared = batch.ops

proc discardImpl(recording: RecordingBackend) =
  inc recording.discardCalls
  if recording.failDiscard:
    raise newException(UiError, "recording discard failure")
  recording.prepared.setLen(0)

proc applyImpl(recording: RecordingBackend, batch: UpdateBatch) =
  inc recording.applyCalls
  if recording.disposed: raise newException(UiError, "recording backend is disposed")
  var position = 0
  for op in batch.ops:
    inc position
    if recording.failApply or
        (recording.failApplyAt > 0 and position >= recording.failApplyAt):
      raise newException(UiError, "recording apply failure at op " & $position)
    if batch.isDelta:
      case op.kind
      of opCreate:
        recording.entities[op.handle]=MountedEntity(handle:op.handle,parent:op.parent,index:op.index,
          nodeId:op.nodeId,kind:op.nodeKind,props:op.props)
        inc recording.creates
      of opUpdate:
        recording.entities[op.handle].props=op.props;inc recording.updates
        if recording.onSetter!=nil:recording.onSetter(op.handle)
      of opMove:
        recording.entities[op.handle].parent=op.parent
        recording.entities[op.handle].index=op.index;inc recording.moves
      of opRemove:
        recording.entities.del(op.handle);recording.children.del(op.handle)
        recording.inputState.del(op.handle);inc recording.removes
      recording.history.add(op)
      continue
    case op.kind
    of opCreate:
      if op.parent != NoHandle and not recording.entities.hasKey(op.parent):
        raise newException(UiError, "create parent is not mounted")
      if recording.entities.hasKey(op.handle):
        raise newException(UiError, "duplicate entity handle")
      recording.entities[op.handle] = MountedEntity(handle: op.handle,
        parent: op.parent, nodeId: op.nodeId, kind: op.nodeKind,
        props: op.props, index: op.index)
      recording.children.mgetOrPut(op.parent, @[]).insert(op.handle, op.index)
      inc recording.creates
    of opUpdate:
      if not recording.entities.hasKey(op.handle):
        raise newException(UiError, "update handle is not mounted")
      recording.entities[op.handle].props = op.props
      inc recording.updates
      if recording.onSetter != nil: recording.onSetter(op.handle)
    of opMove:
      if not recording.entities.hasKey(op.handle):
        raise newException(UiError, "move handle is not mounted")
      if recording.entities[op.handle].parent != op.parent:
        raise newException(UiError, "move parent mismatch")
      let at = findHandle(recording.children.getOrDefault(op.parent), op.handle)
      if at >= 0: recording.children[op.parent].delete(at)
      recording.children.mgetOrPut(op.parent, @[]).insert(op.handle, op.index)
      recording.entities[op.handle].index = op.index
      inc recording.moves
    of opRemove:
      if not recording.entities.hasKey(op.handle):
        raise newException(UiError, "remove handle is not mounted")
      if recording.children.getOrDefault(op.handle).len > 0:
        raise newException(UiError, "remove handle still has live children")
      let at = findHandle(recording.children.getOrDefault(op.parent), op.handle)
      if at >= 0: recording.children[op.parent].delete(at)
      recording.entities.del(op.handle)
      recording.inputState.del(op.handle)
      inc recording.removes
    recording.history.add(op)

  if batch.isDelta:
    for order in batch.finalOrders:recording.children[order.parent]=order.children

proc restoreImpl(recording: RecordingBackend,
                 entities: Table[NodeHandle, MountedEntity]) =
  inc recording.restoreCalls
  if recording.failRestore: raise newException(UiError, "recording restore failure")
  recording.entities = entities
  recording.children.clear()
  for handle, entity in entities:
    recording.children.mgetOrPut(entity.parent, @[]).add(handle)
  var parents: seq[NodeHandle]
  for parent in recording.children.keys: parents.add(parent)
  for parent in parents:
    recording.children[parent].sort(proc(a, b: NodeHandle): int =
      cmp(entities[a].index, entities[b].index))

proc disposeImpl(recording: RecordingBackend) =
  inc recording.disposeCalls
  if recording.failDispose:
    raise newException(UiError, "recording dispose failure")
  if recording.disposed: return
  recording.disposed = true
  recording.entities.clear()
  recording.children.clear()
  recording.prepared.setLen(0)

proc newRecordingBackend*(capabilities: BackendCapabilities): RecordingBackend =
  let recording = RecordingBackend()
  recording.backend = Backend(
    capabilities: capabilities,
    prepare: proc(batch: UpdateBatch) = recording.prepareImpl(batch),
    apply: proc(batch: UpdateBatch) = recording.applyImpl(batch),
    discardPrepared: proc() = recording.discardImpl(),
    restore: proc(entities: Table[NodeHandle, MountedEntity]) =
      recording.restoreImpl(entities),
    dispose: proc() = recording.disposeImpl())
  recording