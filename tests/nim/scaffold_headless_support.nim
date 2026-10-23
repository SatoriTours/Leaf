import std/os

proc writeHeadlessRows*(app: string) =
  # Native templates use lazy lists; this fixture supplies their small viewport.
  writeFile(app / "tests/headless_rows.nim", """
import leaf
proc realizeRows*(rt: Runtime) =
  var lists: seq[tuple[key: string, count: int]]
  proc collect(node: MountedNode) =
    if node.node.kind == virtualList:
      lists.add((node.node.key, node.node.listSource.len))
    for child in node.children: collect(child)
  collect(rt.snapshot.root)
  for list in lists:
    discard rt.materialize(list.key, 0, list.count)
proc dispatchFixture*(rt: Runtime, key: string, event: Event): bool =
  result = rt.dispatch(key, event)
  rt.realizeRows()
""")
