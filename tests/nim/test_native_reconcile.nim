import std/[unittest, tables, algorithm, options]
import leaf/[core, widgets, styles, backend, reconcile]

proc snapshotOf(node: Node): Snapshot =
  Snapshot(title: "t", width: 640, height: 480, root: mount(node))

proc identity(root: MountedNode, key: string): string =
  if root.node.key == key: return root.id
  for child in root.children:
    let found = identity(child, key)
    if found.len > 0: return found
  ""

proc findHandle(list: seq[NodeHandle], handle: NodeHandle): int =
  for index, item in list:
    if item == handle: return index
  -1

proc childrenOrder(entities: Table[NodeHandle, MountedEntity]):
    Table[NodeHandle, seq[NodeHandle]] =
  for handle, entity in entities:
    result.mgetOrPut(entity.parent, @[]).add(handle)
  var parents: seq[NodeHandle]
  for parent in result.keys: parents.add(parent)
  for parent in parents:
    result[parent].sort(proc(a, b: NodeHandle): int = cmp(entities[a].index, entities[b].index))

proc simulate(entities: Table[NodeHandle, MountedEntity], ops: seq[UpdateOp]):
    Table[NodeHandle, seq[NodeHandle]] =
  result = childrenOrder(entities)
  for op in ops:
    case op.kind
    of opCreate:
      result.mgetOrPut(op.parent, @[]).insert(op.handle, op.index)
    of opRemove:
      let index = findHandle(result.getOrDefault(op.parent), op.handle)
      if index >= 0: result[op.parent].delete(index)
    of opMove:
      let index = findHandle(result.getOrDefault(op.parent), op.handle)
      if index >= 0: result[op.parent].delete(index)
      result.mgetOrPut(op.parent, @[]).insert(op.handle, op.index)
    of opUpdate:
      discard

proc expectedOrder(root: MountedNode, plan: ReconcilePlan):
    Table[NodeHandle, seq[NodeHandle]] =
  var order: Table[NodeHandle, seq[NodeHandle]]
  proc visit(mounted: MountedNode, parent: NodeHandle) =
    let handle = plan.byNodeId[mounted.id]
    order.mgetOrPut(parent, @[]).add(handle)
    for child in mounted.children: visit(child, handle)
  visit(root, NoHandle)
  order

proc sameOrder(a, b: Table[NodeHandle, seq[NodeHandle]]): bool =
  var parents: seq[NodeHandle]
  for parent in a.keys: parents.add(parent)
  for parent in b.keys:
    if findHandle(parents, parent) < 0: parents.add(parent)
  for parent in parents:
    if a.getOrDefault(parent) != b.getOrDefault(parent): return false
  true

proc counts(ops: seq[UpdateOp]): tuple[creates, updates, moves, removes: int] =
  for op in ops:
    case op.kind
    of opCreate: inc result.creates
    of opUpdate: inc result.updates
    of opMove: inc result.moves
    of opRemove: inc result.removes

proc buttons(order: seq[string]): Node =
  var children: seq[Node]
  for key in order:
    children.add(button(key, key = key))
  column(children, key = "root")

suite "Backend-neutral incremental reconciliation":
  test "unchanged input keeps handle":
    var label = "A"
    let reconciler = newReconciler()
    proc tree(): Node =
      column(@[text(label, key = "label"), input("x", key = "field")], key = "root")

    let firstMounted = mount(tree())
    let first = reconciler.plan(snapshotOf(tree()), 1)
    reconciler.accept(first)
    let fieldId = identity(firstMounted, "field")
    let inputHandle = first.byNodeId[fieldId]

    label = "B"
    let secondMounted = mount(tree())
    let second = reconciler.plan(snapshotOf(tree()), 2)
    check second.byNodeId[fieldId] == inputHandle
    let delta = counts(second.batch.ops)
    check delta.creates == 0
    check delta.removes == 0
    check delta.updates == 1
    check sameOrder(simulate(first.entities, second.batch.ops),
      expectedOrder(secondMounted, second))
    reconciler.accept(second)

  test "keyed reorder emits move":
    var order = @["a", "b", "c"]
    let reconciler = newReconciler()
    let firstMounted = mount(buttons(order))
    let first = reconciler.plan(snapshotOf(buttons(order)), 1)
    reconciler.accept(first)
    var handles: Table[string, NodeHandle]
    for key in order: handles[key] = first.byNodeId[identity(firstMounted, key)]

    order = @["c", "a", "b"]
    let secondMounted = mount(buttons(order))
    let second = reconciler.plan(snapshotOf(buttons(order)), 2)
    check counts(second.batch.ops).moves > 0
    check counts(second.batch.ops).creates == 0
    check counts(second.batch.ops).removes == 0
    for key in order:
      check second.byNodeId[identity(secondMounted, key)] == handles[key]
    let applied = simulate(first.entities, second.batch.ops)
    check sameOrder(applied, expectedOrder(secondMounted, second))
    let rootHandle = second.byNodeId[identity(secondMounted, "root")]
    check applied[rootHandle].len == 3
    check applied[rootHandle][0] == handles["c"]
    check applied[rootHandle][1] == handles["a"]
    check applied[rootHandle][2] == handles["b"]
    reconciler.accept(second)

  test "reorder with insert and remove keeps sequential indices valid":
    var order = @["a", "b", "c"]
    let reconciler = newReconciler()
    let firstMounted = mount(buttons(order))
    let first = reconciler.plan(snapshotOf(buttons(order)), 1)
    reconciler.accept(first)
    var handles: Table[string, NodeHandle]
    for key in order: handles[key] = first.byNodeId[identity(firstMounted, key)]

    order = @["d", "c", "a"]
    let secondMounted = mount(buttons(order))
    let second = reconciler.plan(snapshotOf(buttons(order)), 2)
    let delta = counts(second.batch.ops)
    check delta.creates == 1
    check delta.removes == 1
    let applied = simulate(first.entities, second.batch.ops)
    check sameOrder(applied, expectedOrder(secondMounted, second))
    let rootHandle = second.byNodeId[identity(secondMounted, "root")]
    check applied[rootHandle] == @[
      second.byNodeId[identity(secondMounted, "d")],
      handles["c"], handles["a"]]
    reconciler.accept(second)

  test "unkeyed nodes match position":
    var value = "x"
    let reconciler = newReconciler()
    proc tree(): Node = column(@[text(value), text("static")], key = "root")

    let firstMounted = mount(tree())
    let first = reconciler.plan(snapshotOf(tree()), 1)
    reconciler.accept(first)
    let firstId = firstMounted.children[0].id
    let firstHandle = first.byNodeId[firstId]

    value = "y"
    let secondMounted = mount(tree())
    let second = reconciler.plan(snapshotOf(tree()), 2)
    check second.byNodeId[secondMounted.children[0].id] == firstHandle
    let delta = counts(second.batch.ops)
    check delta.creates == 0
    check delta.removes == 0

  test "type replacement recreates descendants":
    var useRow = false
    let reconciler = newReconciler()
    proc tree(): Node =
      let field = input("v", key = "field")
      if useRow: row(@[field], key = "panel")
      else: column(@[field], key = "panel")

    let firstMounted = mount(tree())
    let first = reconciler.plan(snapshotOf(tree()), 1)
    reconciler.accept(first)
    let panelId = identity(firstMounted, "panel")
    let fieldId = identity(firstMounted, "field")
    let panelHandle = first.byNodeId[panelId]
    let fieldHandle = first.byNodeId[fieldId]
    # The string identity is unchanged; only the ancestor kind changes.
    check mount(tree()).id == firstMounted.id

    useRow = true
    let secondMounted = mount(tree())
    let second = reconciler.plan(snapshotOf(tree()), 2)
    check second.byNodeId[panelId] != panelHandle
    check second.byNodeId[fieldId] != fieldHandle
    let delta = counts(second.batch.ops)
    check delta.creates == 2
    check delta.removes == 2

  test "cross-parent move recreates entity":
    var firstParent = true
    let reconciler = newReconciler()
    proc tree(): Node =
      if firstParent:
        column(@[
          column(@[input("v", key = "field")], key = "left"),
          column(@[], key = "right")], key = "root")
      else:
        column(@[
          column(@[], key = "left"),
          column(@[input("v", key = "field")], key = "right")], key = "root")

    let firstMounted = mount(tree())
    let first = reconciler.plan(snapshotOf(tree()), 1)
    reconciler.accept(first)
    let oldField = first.byNodeId[identity(firstMounted, "field")]

    firstParent = false
    let secondMounted = mount(tree())
    let second = reconciler.plan(snapshotOf(tree()), 2)
    let newField = second.byNodeId[identity(secondMounted, "field")]
    check newField != oldField
    let delta = counts(second.batch.ops)
    check delta.creates == 1
    check delta.removes == 1
    reconciler.accept(second)

  test "deleted identity never reuses handle":
    var present = true
    let reconciler = newReconciler()
    proc tree(): Node =
      column(if present: @[text("x", key = "note")] else: @[], key = "root")

    let firstMounted = mount(tree())
    let first = reconciler.plan(snapshotOf(tree()), 1)
    reconciler.accept(first)
    let noteId = identity(firstMounted, "note")
    let oldHandle = first.byNodeId[noteId]

    present = false
    let removed = reconciler.plan(snapshotOf(tree()), 2)
    reconciler.accept(removed)

    present = true
    let restoredMounted = mount(tree())
    let restored = reconciler.plan(snapshotOf(tree()), 3)
    let newHandle = restored.byNodeId[identity(restoredMounted, "note")]
    check newHandle != oldHandle
    check newHandle > oldHandle
    check counts(restored.batch.ops).creates == 1

  test "discarded plan does not recycle handles":
    let reconciler = newReconciler()
    proc tree(): Node = column(@[text("A", key = "label")], key = "root")
    let rootId = identity(mount(tree()), "root")
    let discarded = reconciler.plan(snapshotOf(tree()), 1)
    let fresh = reconciler.plan(snapshotOf(tree()), 1)
    check fresh.byNodeId[rootId] != discarded.byNodeId[rootId]
    check fresh.byNodeId[rootId] > discarded.byNodeId[rootId]
    check counts(fresh.batch.ops).creates == 2

  test "rejected plan leaves accepted map untouched":
    let reconciler = newReconciler()
    proc tree(value: string): Node = column(@[text(value, key = "label")], key = "root")

    let first = reconciler.plan(snapshotOf(tree("A")), 1)
    reconciler.accept(first)
    let second = reconciler.plan(snapshotOf(tree("B")), 2)
    let third = reconciler.plan(snapshotOf(tree("C")), 3)
    reconciler.accept(second)
    expect UiError:
      reconciler.accept(third)
    # Accepted state still matches the second candidate: no diff at all.
    let fourth = reconciler.plan(snapshotOf(tree("B")), 3)
    check fourth.batch.ops.len == 0
    reconciler.accept(fourth)
    expect UiError:
      reconciler.accept(first)

  test "capabilities reject required features and strict decoration":
    var capabilities = fullCapabilities()

    capabilities.kinds = capabilities.kinds - {NodeKind.progress}
    expect UiError:
      discard checkCapabilities(mount(progress(50.0)), capabilities, compatible)

    capabilities = fullCapabilities()
    capabilities.layouts = capabilities.layouts - {lfGap}
    expect UiError:
      discard checkCapabilities(mount(column(@[], styles = style({"gap": "8"}))),
        capabilities, compatible)

    capabilities = fullCapabilities()
    capabilities.layouts = capabilities.layouts - {lfMinMax}
    expect UiError:
      discard checkCapabilities(mount(column(@[], styles = style({"min_width": "10"}))),
        capabilities, compatible)

    capabilities = fullCapabilities()
    capabilities.layouts = capabilities.layouts - {lfFlexShrink}
    expect UiError:
      discard checkCapabilities(mount(column(@[], styles = style({"flex_shrink": "1"}))),
        capabilities, compatible)

    capabilities = fullCapabilities()
    capabilities.justifications = capabilities.justifications - {justifyAround}
    expect UiError:
      discard checkCapabilities(mount(row(@[], styles = style({"justify": "around"}))),
        capabilities, compatible)

    capabilities = fullCapabilities()
    capabilities.decorations = capabilities.decorations - {dfBackground, dfRadius}
    let issues = checkCapabilities(mount(column(@[],
      styles = style({"background": "#ffffff", "radius": "4"}))), capabilities, compatible)
    check issues.len == 2
    check issues[0].property == "background"
    check issues[1].property == "radius"

    expect UiError:
      discard checkCapabilities(mount(column(@[],
        styles = style({"background": "#ffffff"}))), capabilities, strict)

    capabilities = fullCapabilities()
    capabilities.variants = capabilities.variants - {variantDanger}
    let variantIssues = checkCapabilities(mount(button("x", variant = "danger")),
      capabilities, compatible)
    check variantIssues.len == 1
    check variantIssues[0].property == "variant"

    let rich = mount(column(@[button("go", key = "go"), input("v", key = "field")],
      key = "root", styles = style({"gap": "8", "padding": "4", "width": "full",
        "justify": "evenly", "min_width": "10", "background": "#ffffff"})))
    check checkCapabilities(rich, fullCapabilities(), strict).len == 0

  test "effective properties drop only undeclared decorations":
    var capabilities = fullCapabilities()
    capabilities.decorations = capabilities.decorations - {dfBackground, dfRadius}
    capabilities.variants = capabilities.variants - {variantDanger}
    let props = normalizeProps(column(@[], styles = style({
      "gap": "8", "background": "#ffffff", "radius": "4"})))
    let effective = effectiveProps(capabilities, props)
    check effective.layout.gap.get == 8.0
    check effective.decoration.background.isNone
    check effective.decoration.radius.isNone
    let buttonProps = normalizeProps(button("x", variant = "danger"))
    check effectiveProps(capabilities, buttonProps).control.variant.isNone
    check effectiveProps(fullCapabilities(), buttonProps).control.variant.get == variantDanger