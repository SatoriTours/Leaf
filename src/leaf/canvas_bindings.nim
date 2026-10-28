## Prepared Canvas identity/projection metadata. No handlers, Runtime, clock,
## window or native resource ownership lives here.
import std/[tables, options]
import ./[graphics, canvas_input]

type
  CanvasBindingInfo* = object
    id*: CanvasBindingId
    key*, structuralParent*: string
    kind*: int
    mask*: uint32
    parent: CanvasBindingId
    inverseParent, inverseLocal: Option[Matrix3x2]
  BindingStorage = ref object
    session, mount: uint64
    records: seq[CanvasBindingInfo]
    byKey: Table[string, int]
    bySlot: Table[uint64, int]
    rootKey: string
    rootHitEnabled: bool
    bytes: int
  CanvasBindingSnapshot* = object
    owned: BindingStorage

proc binding*(snapshot: CanvasBindingSnapshot, key: string): Option[CanvasBindingInfo] =
  if snapshot.owned == nil or not snapshot.owned.byKey.hasKey(key): return none(CanvasBindingInfo)
  some(snapshot.owned.records[snapshot.owned.byKey[key]])
proc binding*(snapshot: CanvasBindingSnapshot, id: CanvasBindingId): Option[CanvasBindingInfo] =
  if snapshot.owned == nil or id.session != snapshot.owned.session or id.mount != snapshot.owned.mount or
      not snapshot.owned.bySlot.hasKey(id.binding): return none(CanvasBindingInfo)
  let record = snapshot.owned.records[snapshot.owned.bySlot[id.binding]]
  if record.id != id: return none(CanvasBindingInfo)
  some(record)
proc bindingKey*(snapshot: CanvasBindingSnapshot, id: CanvasBindingId): Option[string] =
  let found = snapshot.binding(id)
  if found.isSome: some(found.get.key) else: none(string)
proc ownedBytes*(snapshot: CanvasBindingSnapshot): int =
  if snapshot.owned == nil: 0 else: snapshot.owned.bytes
proc rootKey*(snapshot: CanvasBindingSnapshot): string =
  if snapshot.owned == nil: "" else: snapshot.owned.rootKey
proc rootHitEnabled*(snapshot: CanvasBindingSnapshot): bool =
  snapshot.owned != nil and snapshot.owned.rootHitEnabled
iterator bindings*(snapshot: CanvasBindingSnapshot): CanvasBindingInfo =
  if snapshot.owned != nil:
    for record in snapshot.owned.records: yield record

proc prepareCanvasBindings*(frame: CanvasFrame, session, mount: uint64, nextSlot: var uint64,
    previous = default(CanvasBindingSnapshot), maxBytes = MaxCanvasOwnedBytes): CanvasBindingSnapshot =
  if frame.isNil or session == 0 or mount == 0 or maxBytes <= 0 or maxBytes > MaxCanvasOwnedBytes:
    raise newException(GraphicsError, "invalid Canvas binding preparation context")
  let data = BindingStorage(session: session, mount: mount, rootHitEnabled: true)
  data.bytes = sizeof(data[])
  proc reserve(amount: int) =
    if amount > maxBytes-data.bytes: raise newException(GraphicsError, "Canvas binding metadata quota exceeded")
    data.bytes += amount
  reserve(0)
  proc install(entry: CanvasInteraction, kind: int, parent: CanvasBindingId,
      inverseParent, inverseLocal: Option[Matrix3x2], counter: var uint64): CanvasBindingId =
    if entry.eventMask == 0: return
    if data.records.len >= MaxCanvasInteractionBindings:
      raise newException(GraphicsError, "Canvas binding quota exceeded")
    let old = previous.binding(entry.key)
    var record = CanvasBindingInfo(key: entry.key, structuralParent: entry.parentIdentity,
      kind: kind, mask: entry.eventMask, parent: parent,
      inverseParent: inverseParent, inverseLocal: inverseLocal)
    if old.isSome and old.get.id.session == session and old.get.id.mount == mount and
        old.get.kind == kind and old.get.structuralParent == entry.parentIdentity:
      record.id = old.get.id
      record.key = old.get.key # Canonical live identity string, not each render's copy.
    else:
      if counter == high(uint64): raise newException(GraphicsError, "Canvas binding identity exhausted")
      inc counter # Never rolled back or recycled, including rejected candidates.
      record.id = CanvasBindingId(session: session, mount: mount, binding: counter, generation: 1)
    reserve(sizeof(CanvasBindingInfo)+record.key.len+record.structuralParent.len+96)
    let index = data.records.len
    data.records.add(record)
    data.byKey[record.key] = index
    data.bySlot[record.id.binding] = index
    record.id
  var annotations = initTable[int, CanvasInteraction]()
  let identity = some(identityMatrix())
  var rootId: CanvasBindingId
  for entry in frame.interactions:
    if entry.commandIndex == -1:
      data.rootKey = entry.key
      data.rootHitEnabled = entry.hitTest
      rootId = install(entry, -1, default(CanvasBindingId), identity, identity, nextSlot)
    else: annotations[entry.commandIndex] = entry
  type Scope = object
    world: Matrix3x2
    owner: CanvasBindingId
  var scopes = @[Scope(world: identityMatrix(), owner: rootId)]
  var index = 0
  for command in frame.commands:
    if command.kind == DrawKind.endGroup:
      scopes.setLen(scopes.len-1)
    else:
      let parent = scopes[^1]
      let world = if command.kind == DrawKind.beginGroup: parent.world*command.transform else: parent.world
      var owner = parent.owner
      if annotations.hasKey(index):
        let entry = annotations[index]
        let installed = install(entry, ord(command.kind), parent.owner, parent.world.inverse, world.inverse, nextSlot)
        if installed.binding != 0: owner = installed
      if command.kind == DrawKind.beginGroup: scopes.add(Scope(world: world, owner: owner))
    inc index
  CanvasBindingSnapshot(owned: data)

proc pointerTarget*(snapshot: CanvasBindingSnapshot, id: CanvasBindingId, frameId: uint64,
    canvasFromScreen: Matrix3x2, includeRoute = true): Option[PointerTarget] =
  let found = snapshot.binding(id)
  if found.isNone or frameId == 0: return none(PointerTarget)
  let record = found.get
  var target = PointerTarget(id: id, frameId: frameId, canvasFromScreen: canvasFromScreen,
    parentFromCanvas: record.inverseParent.get(default(Matrix3x2)),
    localFromCanvas: record.inverseLocal.get(default(Matrix3x2)))
  if includeRoute:
    var route: seq[CanvasSourceRoute]
    var current = found
    while current.isSome:
      let value = current.get
      route.add(CanvasSourceRoute(id: value.id, mask: value.mask))
      if route.len > MaxCanvasDepth+2: raise newException(GraphicsError, "Canvas route depth exceeded")
      current = snapshot.binding(value.parent)
    target = target.withSourceRouteInternal(route)
  some(target)
