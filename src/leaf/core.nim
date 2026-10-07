## Immutable UI descriptions. Application state belongs to native Nim objects;
## callbacks are published only after a complete, validated render succeeds.
import std/[tables, sets, json, math, unicode, algorithm]
import ./diagnostics

const
  MaxNodes* = 10_000
  MaxDepth* = 64
  MaxStringBytes* = 1_048_576
  MaxTreeBytes* = 16_777_216
  MaxListItems* = 100_000

type
  UiError* = object of CatchableError
  NodeKind* = enum
    column, row, text, button, input, checkbox, toggle, progress, tag,
    separator, spinner, virtualList
  EventKind* = enum
    click, change, submit
  Event* = object
    kind*: EventKind
    value*: string
    checked*: bool
  Callback* = proc(event: Event) {.closure.}
  Styles* = Table[string, string]
  Node* = ref object
    nodeKind: NodeKind
    nodeKey, label, hint: string
    inactive: bool
    nodeStyles, nodeAttributes: Styles
    descendants: seq[Node]
    handlers: array[EventKind, Callback]
    source: ListSource
  RowBuilder* = proc(index: int): Node {.closure.}
  ListSource* = ref object
    generation: uint64
    itemKeys: seq[string]
    keyBytes: int
    builder: RowBuilder
    uniformHeight, estimate: float64
    extraRows: int
  MountedNode* = ref object
    description: Node
    identity, lookupKey: string
    descendants: seq[MountedNode]
    itemIndex: int
  Snapshot* = object
    title*: string
    width*, height*: int
    root*: MountedNode
  SnapshotValidator* = proc(snapshot: Snapshot) {.closure.}
  CacheEntry = object
    revision: string
    node: Node
    dependencies: seq[string]
  BuildContext* = ref object
    previous, candidate: Table[string, CacheEntry]
    active: seq[string]
    dependencies: seq[seq[string]]
    hits, misses: int
    building: bool
  RenderProc* = proc(context: BuildContext): Node {.closure.}
  ExecutionScope* = proc(body: proc() {.closure.}) {.closure.}
  Application* = object
    title*: string
    width*, height*: int
    render*: RenderProc
    executionScope*: ExecutionScope
  PerformanceStats* = object
    renders*, builtNodes*, cacheHits*, cacheMisses*, dispatches*: uint64
    builtItems*, rowCacheHits*: uint64
    cachedSubtrees*, mountedNodes*, treeBytes*: int
    cachedItems*, cachedRowBytes*: int
  RowEntry = object
    node: MountedNode
    used: uint64
    bytes: int
  RowCache = object
    source: ListSource
    rows: Table[int, RowEntry]
  Runtime* = ref object
    app: Application
    current: Snapshot
    index: Table[string, MountedNode]
    keys: Table[string, seq[MountedNode]]
    context: BuildContext
    counters: PerformanceStats
    inUpdate: bool
    rowCaches: Table[string, RowCache]
    rowClock: uint64
    validator: SnapshotValidator
    preparer: RuntimePreparer
    descriptionBytes: int
    diagnostics: Diagnostics
  RuntimePreparer* = proc(candidate: Runtime) {.closure.}

proc fail*(message: string) {.noreturn.} =
  raise newException(UiError, message)

proc validString(value: string) =
  if value.len > MaxStringBytes: fail("string exceeds 1 MiB")
  if validateUtf8(value) != -1: fail("UI text is not valid UTF-8")

proc style*(pairs: openArray[(string, string)]): Styles =
  for (key, value) in pairs:
    validString(key)
    validString(value)
    result[key] = value

proc kind*(node: Node): NodeKind = node.nodeKind
proc key*(node: Node): string = node.nodeKey
proc text*(node: Node): string = node.label
proc placeholder*(node: Node): string = node.hint
proc disabled*(node: Node): bool = node.inactive
proc styles*(node: Node): Styles = node.nodeStyles
proc attributes*(node: Node): Styles = node.nodeAttributes
proc children*(node: Node): seq[Node] = node.descendants
proc listSource*(node: Node): ListSource = node.source
proc handler*(node: Node, event: EventKind): Callback = node.handlers[event]
proc node*(mounted: MountedNode): Node = mounted.description
proc id*(mounted: MountedNode): string = mounted.identity
proc children*(mounted: MountedNode): seq[MountedNode] = mounted.descendants
proc listIndex*(mounted: MountedNode): int = mounted.itemIndex
var listGeneration: uint64

proc generation*(source: ListSource): uint64 = source.generation
proc len*(source: ListSource): int = source.itemKeys.len
proc itemKey*(source: ListSource, index: int): string = source.itemKeys[index]
proc rowHeight*(source: ListSource): float64 = source.uniformHeight
proc estimatedHeight*(source: ListSource): float64 = source.estimate
proc overscan*(source: ListSource): int = source.extraRows
proc buildRow*(source: ListSource, index: int): Node = source.builder(index)

proc ui*(kind: NodeKind, key = "", text = "", placeholder = "",
         children: seq[Node] = @[], styles: Styles = default(Styles),
         attributes: Styles = default(Styles), disabled = false,
         onClick: Callback = nil, onChange: Callback = nil,
         onSubmit: Callback = nil): Node =
  for value in [key, text, placeholder]: validString(value)
  for pairs in [styles, attributes]:
    for name, value in pairs:
      validString(name)
      validString(value)
  if kind notin {column, row, virtualList} and children.len != 0:
    fail("leaf controls cannot have children")
  if onClick != nil and kind != button: fail("click requires a button")
  if onChange != nil and kind notin {input, checkbox, toggle}:
    fail("change requires an input, checkbox or switch")
  if onSubmit != nil and kind != input: fail("submit requires an input")
  Node(nodeKind: kind, nodeKey: key, label: text, hint: placeholder,
    descendants: children, nodeStyles: styles, nodeAttributes: attributes,
    inactive: disabled, handlers: [onClick, onChange, onSubmit])

proc virtualList*(key: string, keys: seq[string], builder: RowBuilder,
                  rowHeight = 0.0, estimatedHeight = 100.0, overscan = 2,
                  styles: Styles = default(Styles)): Node =
  if key.len == 0 or builder == nil: fail("virtual list needs a key and builder")
  if keys.len > MaxListItems: fail("list exceeds 100000 items")
  if classify(estimatedHeight) in {fcNan, fcInf, fcNegInf} or
      estimatedHeight <= 0 or estimatedHeight > 1_000_000:
    fail("estimated height must be finite and positive")
  if classify(rowHeight) in {fcNan, fcInf, fcNegInf} or
      rowHeight < 0 or rowHeight > 1_000_000:
    fail("row height must be zero or finite and positive")
  if overscan < 0 or overscan > 32: fail("invalid list overscan")
  var seen: HashSet[string]
  var bytes = 0
  for item in keys:
    validString(item)
    bytes += item.len
    if bytes > MaxTreeBytes: fail("list keys exceed 16 MiB")
    if item in seen: fail("duplicate list key: " & item)
    seen.incl(item)
  result = ui(NodeKind.virtualList, key = key, styles = styles)
  inc listGeneration
  result.source = ListSource(generation: listGeneration, itemKeys: keys, builder: builder,
    keyBytes: bytes, uniformHeight: rowHeight, estimate: estimatedHeight, extraRows: overscan)

proc cached*(context: BuildContext, key, revision: string,
             build: proc(): Node {.closure.}): Node =
  ## The cache key identifies a component/subtree, not an output node key.
  ## Include all state read by `build` in revision. Nested caches are retained.
  if context == nil or not context.building: fail("cache used outside render")
  if key.len == 0: fail("cache key cannot be empty")
  if context.candidate.len >= MaxNodes and key notin context.candidate:
    fail("too many cached subtrees")
  if key in context.active: fail("recursive cache dependency: " & key)
  if context.dependencies.len > 0: context.dependencies[^1].add(key)
  if key in context.candidate:
    if context.candidate[key].revision != revision:
      fail("conflicting cache revisions: " & key)
    inc context.hits
    return context.candidate[key].node
  if key in context.previous and context.previous[key].revision == revision:
    inc context.hits
    proc retain(name: string) =
      if name in context.candidate: return
      let entry = context.previous[name]
      context.candidate[name] = entry
      for child in entry.dependencies: retain(child)
    retain(key)
    return context.candidate[key].node
  inc context.misses
  context.active.add(key)
  context.dependencies.add(@[])
  try:
    result = build()
    if result == nil: fail("cache builder returned nil")
    context.candidate[key] = CacheEntry(revision: revision, node: result,
      dependencies: context.dependencies[^1])
  finally:
    context.active.setLen(context.active.len - 1)
    context.dependencies.setLen(context.dependencies.len - 1)

proc segment(key: string, index: int): string =
  if key.len == 0: "i:" & $index else: "k:" & $key.len & ":" & key

proc mountImpl(node: Node, parent: string, index, depth: int,
               forcedKey: string, forceKey: bool, count: var int): MountedNode =
  if node == nil: fail("render returned nil node")
  inc count
  if count > MaxNodes or depth > MaxDepth: fail("UI exceeds 10000 nodes or depth 64")
  let key = if forceKey: forcedKey else: node.nodeKey
  let part = segment(key, index)
  result = MountedNode(description: node,
    identity: (if parent.len == 0: part else: parent & "/" & part), lookupKey: key, itemIndex: -1)
  if result.identity.len > MaxStringBytes: fail("node ID exceeds 1 MiB")
  for i, child in node.descendants:
    result.descendants.add(mountImpl(child, result.identity, i, depth + 1, "", false, count))

proc mount*(node: Node, parent = "", index = 0, depth = 0): MountedNode =
  var count = 0
  mountImpl(node, parent, index, depth, "", false, count)

proc inspect(mounted: MountedNode, index: var Table[string, MountedNode],
             keys: var Table[string, seq[MountedNode]], nodes, bytes: var int,
             depth = 0) =
  inc nodes
  if nodes > MaxNodes or depth > MaxDepth:
    fail("UI exceeds 10000 nodes or depth 64")
  if mounted.identity in index: fail("duplicate node ID: " & mounted.identity)
  index[mounted.identity] = mounted
  let n = mounted.description
  if n.nodeKind == NodeKind.virtualList and n.source == nil:
    fail("virtual list has no source")
  if mounted.lookupKey.len > 0: keys.mgetOrPut(mounted.lookupKey, @[]).add(mounted)
  bytes += 128 + mounted.identity.len + n.label.len + n.hint.len
  for pairs in [n.nodeStyles, n.nodeAttributes]:
    for name, value in pairs: bytes += name.len + value.len + 32
  if n.source != nil:
    bytes += n.source.keyBytes + n.source.len * 16
  if bytes > MaxTreeBytes: fail("UI tree exceeds 16 MiB")
  for child in mounted.descendants: inspect(child, index, keys, nodes, bytes, depth + 1)

proc cacheBytes(context: BuildContext): int =
  var seen: HashSet[pointer]
  proc visit(node: Node, depth: int): int =
    if node == nil: fail("nil cached node")
    if depth > MaxDepth: fail("cached UI exceeds depth 64")
    let address = cast[pointer](node)
    if address in seen: return 0
    seen.incl(address)
    if seen.len > MaxNodes: fail("cache exceeds 10000 nodes")
    result = 128 + node.nodeKey.len + node.label.len + node.hint.len
    for pairs in [node.nodeStyles, node.nodeAttributes]:
      for name, value in pairs: result += name.len + value.len + 32
    if node.source != nil: result += node.source.keyBytes + node.source.len * 16
    for child in node.descendants:
      result += visit(child, depth + 1)
      if result > MaxTreeBytes: fail("subtree cache exceeds 16 MiB")
  for key, entry in context.candidate:
    result += key.len + entry.revision.len + 64 + visit(entry.node, 0)
    if result > MaxTreeBytes: fail("subtree cache exceeds 16 MiB")

proc toJson*(snapshot: Snapshot): JsonNode

proc dump(runtime: Runtime) =
  if runtime.diagnostics != nil and runtime.diagnostics.dumpFile.len > 0:
    runtime.diagnostics.snapshot(runtime.current.toJson())

template inExecutionScope(runtime: Runtime, body: untyped) =
  if runtime.app.executionScope == nil:
    body
  else:
    runtime.app.executionScope(proc() = body)

proc refreshImpl(runtime: Runtime): bool =
  if runtime.inUpdate: fail("reentrant runtime update")
  runtime.inUpdate = true
  let ctx = runtime.context
  ctx.candidate.clear()
  ctx.hits = 0
  ctx.misses = 0
  ctx.building = true
  try:
    let root = mount(runtime.app.render(ctx))
    var index: Table[string, MountedNode]
    var keys: Table[string, seq[MountedNode]]
    var count, bytes: int
    inspect(root, index, keys, count, bytes)
    let descriptionBytes = ctx.cacheBytes()
    if bytes + descriptionBytes > MaxTreeBytes:
      fail("UI and subtree cache exceed 16 MiB")
    var rowCaches: Table[string, RowCache]
    var cachedItems, cachedBytes: int
    for id, cache in runtime.rowCaches:
      if id in index and index[id].description.source == cache.source:
        rowCaches[id] = cache
        for entry in cache.rows.values:
          inc cachedItems
          cachedBytes += entry.bytes
    let snapshot = Snapshot(title: runtime.app.title, width: runtime.app.width,
      height: runtime.app.height, root: root)
    if runtime.validator != nil: runtime.validator(snapshot)
    # Stage lazy renderer content in an isolated candidate. Preparation may
    # materialize lists and fail without changing the published event index.
    if runtime.preparer != nil:
      let candidate = Runtime(app: runtime.app, current: snapshot,
        index: move(index), keys: move(keys), rowCaches: move(rowCaches),
        counters: runtime.counters, rowClock: runtime.rowClock, validator: runtime.validator,
        descriptionBytes: descriptionBytes)
      candidate.counters.cachedItems = cachedItems
      candidate.counters.cachedRowBytes = cachedBytes
      candidate.counters.mountedNodes = count
      candidate.counters.treeBytes = bytes
      runtime.preparer(candidate)
      runtime.current = candidate.current
      runtime.index = move(candidate.index)
      runtime.keys = move(candidate.keys)
      runtime.rowCaches = move(candidate.rowCaches)
      runtime.rowClock = candidate.rowClock
      runtime.counters = candidate.counters
    else:
      runtime.current = snapshot
      runtime.index = move(index)
      runtime.keys = move(keys)
      runtime.rowCaches = move(rowCaches)
      runtime.counters.cachedItems = cachedItems
      runtime.counters.cachedRowBytes = cachedBytes
      runtime.counters.mountedNodes = count
      runtime.counters.treeBytes = bytes
    runtime.descriptionBytes = descriptionBytes
    ctx.previous = move(ctx.candidate)
    inc runtime.counters.renders
    runtime.counters.builtNodes += uint64(count)
    runtime.counters.cacheHits += uint64(ctx.hits)
    runtime.counters.cacheMisses += uint64(ctx.misses)
    runtime.counters.cachedSubtrees = ctx.previous.len
    if runtime.diagnostics != nil:
      runtime.diagnostics.record("render", "ok", %*{"nodes": runtime.counters.mountedNodes})
      runtime.dump()
    result = true
  except CatchableError as error:
    if runtime.diagnostics != nil: runtime.diagnostics.record("render", "error", %*{"message": error.msg})
    raise
  finally:
    ctx.building = false
    ctx.candidate.clear()
    runtime.inUpdate = false

proc refresh*(runtime: Runtime): bool =
  var completed: bool
  inExecutionScope(runtime): completed = runtime.refreshImpl()
  completed

proc newRuntime*(app: Application, validator: SnapshotValidator = nil,
                 diagnostics: Diagnostics = nil): Runtime =
  if app.render == nil: fail("application needs a render function")
  if app.width notin 1..16_384 or app.height notin 1..16_384:
    fail("invalid window dimensions")
  validString(app.title)
  result = Runtime(app: app, context: BuildContext(), validator: validator, diagnostics: diagnostics)
  discard result.refresh()

proc snapshot*(runtime: Runtime): Snapshot = runtime.current
proc stats*(runtime: Runtime): PerformanceStats = runtime.counters

proc setDiagnostics*(runtime: Runtime, diagnostics: Diagnostics) =
  ## Desktop attaches after its initial tree and lazy viewports are validated.
  runtime.diagnostics = diagnostics
  if diagnostics != nil:
    diagnostics.record("render", "ok", %*{"nodes": runtime.counters.mountedNodes})
    runtime.dump()

proc diagnostic*(runtime: Runtime, phase, status: string, details: JsonNode) =
  runtime.diagnostics.record(phase, status, details)

proc setValidatorImpl(runtime: Runtime, validator: SnapshotValidator) =
  ## A renderer can validate its constraints before a runtime transaction
  ## publishes state. Validate the current snapshot before attaching it.
  if runtime.inUpdate: fail("cannot replace validator during update")
  if validator != nil: validator(runtime.current)
  runtime.validator = validator

proc setValidator*(runtime: Runtime, validator: SnapshotValidator) =
  inExecutionScope(runtime): runtime.setValidatorImpl(validator)

proc prepareSnapshotImpl(runtime: Runtime, preparer: RuntimePreparer) =
  if runtime.inUpdate: fail("cannot replace preparer during update")
  if preparer != nil:
    let candidate = Runtime(app: runtime.app, current: runtime.current,
      index: runtime.index, keys: runtime.keys, rowCaches: runtime.rowCaches,
      counters: runtime.counters, rowClock: runtime.rowClock, validator: runtime.validator,
      descriptionBytes: runtime.descriptionBytes)
    runtime.inUpdate = true
    try:
      preparer(candidate)
      runtime.current = candidate.current
      runtime.index = move(candidate.index)
      runtime.keys = move(candidate.keys)
      runtime.rowCaches = move(candidate.rowCaches)
      runtime.counters = candidate.counters
      runtime.rowClock = candidate.rowClock
      runtime.dump()
    finally: runtime.inUpdate = false

proc prepareSnapshot(runtime: Runtime, preparer: RuntimePreparer) =
  inExecutionScope(runtime): runtime.prepareSnapshotImpl(preparer)

proc prepare*(runtime: Runtime) =
  ## Reprepare a viewport without rendering business state, atomically.
  runtime.prepareSnapshot(runtime.preparer)

proc setPreparer*(runtime: Runtime, preparer: RuntimePreparer) =
  ## Prepare lazy content before publication. Never mutate visible controls
  ## or business state; temporary measurement controls may be constructed.
  runtime.prepareSnapshot(preparer)
  runtime.preparer = preparer

proc find*(runtime: Runtime, key: string): MountedNode =
  if key in runtime.index: return runtime.index[key]
  if key notin runtime.keys: fail("node key not found: " & key)
  if runtime.keys[key].len != 1: fail("ambiguous key: " & key & "; use full node ID")
  runtime.keys[key][0]

proc dispatchImpl(runtime: Runtime, key: string, event: Event): bool =
  if runtime.inUpdate: fail("reentrant event dispatch")
  let n = runtime.find(key).description
  if n.inactive: return false
  let callback = n.handlers[event.kind]
  if callback == nil: fail("node has no " & $event.kind & " handler: " & key)
  try:
    runtime.inUpdate = true
    try:
      callback(event)
      inc runtime.counters.dispatches
    finally:
      runtime.inUpdate = false
    result = runtime.refresh()
    if runtime.diagnostics != nil:
      runtime.diagnostics.record("event", "ok", %*{"key": key, "kind": $event.kind})
  except CatchableError as error:
    if runtime.diagnostics != nil:
      runtime.diagnostics.record("event", "error", %*{"key": key, "kind": $event.kind, "message": error.msg})
    raise

proc dispatch*(runtime: Runtime, key: string, event: Event): bool =
  var completed: bool
  inExecutionScope(runtime): completed = runtime.dispatchImpl(key, event)
  completed

proc materializeImpl(runtime: Runtime, key: string, first, finish: int,
                  protected: seq[int] = @[]): seq[MountedNode] =
  ## A complete list viewport is committed atomically. Only visible/protected
  ## rows are mounted; up to 128 rows stay warm, without live event handlers.
  if runtime.inUpdate: fail("reentrant list request")
  let target = runtime.find(key)
  let source = target.description.source
  if source == nil: fail("node is not a virtual list")
  if first < 0 or first > finish or finish > source.len or finish - first > MaxNodes:
    fail("list range out of bounds")
  var active: HashSet[int]
  for i in protected:
    if i < 0 or i >= source.len: fail("protected item out of bounds")
    active.incl(i)
  for i in first..<finish: active.incl(i)
  if active.len > MaxNodes: fail("too many active list rows")
  runtime.inUpdate = true
  try:
    var cache = runtime.rowCaches.getOrDefault(target.identity)
    if cache.source != source: cache = RowCache(source: source)
    var built, hits: uint64
    var descendants: seq[MountedNode]
    var activeOrder: seq[int]
    for i in active: activeOrder.add(i)
    activeOrder.sort()
    var mountedRows: Table[int, MountedNode]
    for child in target.descendants:
      mountedRows[child.itemIndex] = child
    for i in activeOrder:
      inc runtime.rowClock
      var entry = cache.rows.getOrDefault(i)
      if i in mountedRows and entry.node != mountedRows[i]:
        entry.node = mountedRows[i]
        var rowIndex: Table[string, MountedNode]
        var rowKeys: Table[string, seq[MountedNode]]
        var nodes, bytes: int
        inspect(entry.node, rowIndex, rowKeys, nodes, bytes)
        entry.bytes = bytes
      if entry.node == nil:
        var count = 0
        entry.node = mountImpl(source.buildRow(i), target.identity, i, 0,
          source.itemKey(i), true, count)
        entry.node.itemIndex = i
        var rowIndex: Table[string, MountedNode]
        var rowKeys: Table[string, seq[MountedNode]]
        var nodes, bytes: int
        inspect(entry.node, rowIndex, rowKeys, nodes, bytes)
        entry.bytes = bytes
        inc built
      else:
        inc hits
      entry.used = runtime.rowClock
      cache.rows[i] = entry
      descendants.add(entry.node)
    proc replace(node: MountedNode): MountedNode =
      if node == target:
        return MountedNode(description: node.description, identity: node.identity,
          lookupKey: node.lookupKey, descendants: descendants, itemIndex: node.itemIndex)
      var changed = false
      var children: seq[MountedNode]
      for child in node.descendants:
        let next = replace(child)
        children.add(next)
        if next != child: changed = true
      if changed:
        return MountedNode(description: node.description, identity: node.identity,
          lookupKey: node.lookupKey, descendants: children, itemIndex: node.itemIndex)
      node
    let root = replace(runtime.current.root)
    if runtime.validator != nil:
      var snapshot = runtime.current
      snapshot.root = root
      runtime.validator(snapshot)
    var index: Table[string, MountedNode]
    var keys: Table[string, seq[MountedNode]]
    var count, bytes: int
    inspect(root, index, keys, count, bytes)
    if bytes + runtime.descriptionBytes > MaxTreeBytes:
      fail("UI and subtree cache exceed 16 MiB")
    var cachedBytes = 0
    for entry in cache.rows.values: cachedBytes += entry.bytes
    var otherBytes, otherItems: int
    var rowCaches: Table[string, RowCache]
    for id, existing in runtime.rowCaches:
      if id != target.identity and id in index and index[id].description.source == existing.source:
        rowCaches[id] = existing
        for entry in existing.rows.values:
          otherBytes += entry.bytes
          inc otherItems
    while cache.rows.len > 128 or otherBytes + cachedBytes > MaxTreeBytes:
      var oldest = high(uint64)
      var victim = -1
      for i, entry in cache.rows:
        if i notin active and entry.used < oldest:
          oldest = entry.used
          victim = i
      # Large viewports may contain more than 128 rows. Their mounted nodes
      # stay alive even when excluded from the separate warm-row cache.
      if victim == -1:
        for i, entry in cache.rows:
          if entry.used < oldest:
            oldest = entry.used
            victim = i
      if victim == -1: fail("list cache exceeds byte budget")
      cachedBytes -= cache.rows[victim].bytes
      cache.rows.del(victim)
    runtime.current.root = root
    runtime.index = move(index)
    runtime.keys = move(keys)
    rowCaches[target.identity] = move(cache)
    runtime.rowCaches = move(rowCaches)
    runtime.counters.builtItems += built
    runtime.counters.rowCacheHits += hits
    runtime.counters.mountedNodes = count
    runtime.counters.treeBytes = bytes
    runtime.counters.cachedItems = otherItems + runtime.rowCaches[target.identity].rows.len
    runtime.counters.cachedRowBytes = otherBytes + cachedBytes
    for mounted in descendants:
      if mounted.itemIndex >= first and mounted.itemIndex < finish: result.add(mounted)
    runtime.dump()
  finally:
    runtime.inUpdate = false

proc materialize*(runtime: Runtime, key: string, first, finish: int,
                  protected: seq[int] = @[]): seq[MountedNode] =
  var rows: seq[MountedNode]
  inExecutionScope(runtime): rows = runtime.materializeImpl(key, first, finish, protected)
  rows

proc kindName*(kind: NodeKind): string =
  case kind
  of toggle: "switch"
  of virtualList: "virtual_list"
  else: $kind

proc toJson*(root: MountedNode): JsonNode =
  let n = root.description
  var children = newJArray()
  for child in root.descendants:
    let item = child.toJson()
    if n.source != nil and child.itemIndex >= 0 and child.itemIndex < n.source.len:
      item["item_key"] = %n.source.itemKey(child.itemIndex)
    children.add(item)
  var styles, attributes = newJObject()
  for key, value in n.nodeStyles: styles[key] = %value
  for key, value in n.nodeAttributes: attributes[key] = %value
  var events = newJObject()
  for event in EventKind: events[$event] = %(n.handlers[event] != nil)
  result = %*{"kind": n.nodeKind.kindName, "id": root.identity,
    "text": n.label, "placeholder": n.hint, "disabled": n.inactive,
    "styles": styles, "attributes": attributes, "events": events,
    "children": children}
  if root.itemIndex >= 0: result["list_index"] = %root.itemIndex
  if n.source != nil:
    result["list"] = %*{"generation": n.source.generation, "count": n.source.len, "row_height": n.source.uniformHeight,
      "estimated_height": n.source.estimate, "overscan": n.source.extraRows}

proc toJson*(snapshot: Snapshot): JsonNode =
  %*{"title": snapshot.title, "width": snapshot.width, "height": snapshot.height,
     "root": snapshot.root.toJson()}
