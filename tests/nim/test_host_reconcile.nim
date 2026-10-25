import std/[unittest, sequtils, sets, options, tables]
import leaf/[core, widgets, backend, host_protocol, host_reconcile]
proc snap(node: Node): Snapshot = Snapshot(title: "t", width: 640, height: 480, root: mount(node))
proc tree(n: int, reverse = false): Node =
  var children: seq[Node]
  for i in 0..<n:
    let index = if reverse: n-1-i else: i
    children.add(text($index,key = $index))
  column(children,key = "root")
suite "typed host reconciliation":
  test "same identity retains handle and removed property resets":
    let r = newHostReconciler(7)
    let first = r.planSnapshot(snap(text("a",key="value",styles=style({"color":"#ffffff"}))),1,hostCompatible)
    r.accept(first)
    let second = r.planSnapshot(snap(text("b",key="value")),2,hostCompatible)
    let updates = second.batch.ops.filterIt(it.kind == HostOpKind.update)
    check updates.len == 1
    check updates[0].handle == first.batch.ops.filterIt(it.kind == HostOpKind.create)[0].handle
    check updates[0].props.normalized.decoration.color.isNone
    r.accept(second)
  test "ancestor replacement rebuilds descendants":
    let r = newHostReconciler(1)
    let first = r.planSnapshot(snap(column(@[input("v",key="field")],key="panel")),1,hostCompatible)
    r.accept(first)
    let second = r.planSnapshot(snap(row(@[input("v",key="field")],key="panel")),2,hostCompatible)
    check second.batch.ops.countIt(it.kind == HostOpKind.create) == 2
    check second.batch.ops.countIt(it.kind == HostOpKind.remove) == 2
  test "discard and foreign candidates cannot publish":
    let r = newHostReconciler(1)
    let other = newHostReconciler(1)
    let candidate = r.planSnapshot(snap(text("a")),1,hostCompatible)
    expect UiError: other.accept(candidate)
    r.discard(candidate)
    expect UiError: r.accept(candidate)
    let fresh = r.planSnapshot(snap(text("a")),1,hostCompatible)
    check fresh.batch.ops[0].handle != candidate.batch.ops[0].handle
    r.accept(fresh)
    expect UiError: r.accept(fresh)
  test "5000 reversed keys use one final order and retain all handles":
    let r = newHostReconciler(1)
    let first = r.planSnapshot(snap(tree(5000)),1,hostCompatible)
    r.accept(first)
    let candidate = r.planSnapshot(snap(tree(5000,true)),2,hostCompatible)
    check candidate.batch.ops.countIt(it.kind == HostOpKind.setChildren) == 1
    check candidate.batch.ops.countIt(it.kind in {HostOpKind.create,HostOpKind.remove}) == 0
    let before = first.batch.ops.filterIt(it.kind == HostOpKind.setChildren and it.children.len==5000)[0].children.toHashSet
    let after = candidate.batch.ops.filterIt(it.kind == HostOpKind.setChildren)[0].children.toHashSet
    check before == after
  test "delta visits only affected hosts and advances even without operations":
    for size in [100,5000]:
      let r = newHostReconciler(1)
      let first = r.planSnapshot(snap(tree(size)),1,hostCompatible)
      r.accept(first)
      let create = first.batch.ops.filterIt(it.kind == HostOpKind.create and it.nodeKind == NodeKind.text)[0]
      let next = r.planDelta(HostChanges(upserts: @[HostRecord(handle:create.handle,parent:create.parent,
        nodeId:create.nodeId,kind:create.nodeKind,props:normalizeHostProps(text("changed"),hostCompatible))]),2)
      check next.batch.ops.len == 1
      check next.stats.visitedHosts <= 4
      r.validate(next)
      r.publish(next)
      let empty = r.planDelta(HostChanges(),3)
      check empty.batch.ops.len == 0
      r.accept(empty)
      check r.revision == 3
  test "malformed delta leaves accepted records intact":
    let r = newHostReconciler(1)
    let first = r.planSnapshot(snap(tree(2)),1,hostCompatible)
    r.accept(first)
    let parent=first.batch.ops.filterIt(it.kind == HostOpKind.create and it.parent == NoHandle)[0].handle
    expect UiError:
      discard r.planDelta(HostChanges(children: @[HostChildren(parent:parent,children: @[NodeHandle(999)])]),2)
    check r.revision == 1

  test "typed root depth matches legal legacy depth64":
    var node=text("leaf")
    for i in 0..<64:node=column(@[node])
    let r=newHostReconciler(22)
    let accepted=r.planSnapshot(snap(node),1,hostCompatible)
    r.accept(accepted)
    check r.revision==1
