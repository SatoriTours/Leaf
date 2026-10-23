## Independent field reader for ABI5/LAV5. Old versions cannot discard the new
## sidecar and accidentally accept a navigation container without its identity.
import std/[unittest, options]
import leaf/[core, backend, navigation_protocol]
import leaf/backends/android/[backend, wire]

type Reader = object
  bytes: string
  at: int
proc u32(r: var Reader): uint32 =
  for shift in [0, 8, 16, 24]:
    result = result or (uint32(ord(r.bytes[r.at])) shl shift)
    inc r.at
proc u64(r: var Reader): uint64 =
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    result = result or (uint64(ord(r.bytes[r.at])) shl shift)
    inc r.at
proc string(r: var Reader): string =
  let n = int(r.u32())
  result = r.bytes[r.at ..< r.at + n]
  r.at += n
proc meta(): HostNavigationProps =
  HostNavigationProps(routerId: 0x100000001'u64, historyRevision: 0x200000002'u64,
    currentEntryId: 0x300000003'u64, previousEntryId: 0x300000001'u64, depth: 3)
proc op(): UpdateOp =
  result = UpdateOp(kind: opUpdate, handle: NodeHandle(19), parent: NodeHandle(7),
    nodeId: "导航😀", nodeKind: NodeKind.navigation, navigation: some(meta()))
  result.props.control.hasBack = true

suite "Android LAV5 navigation transport":
  test "older encoders reject navigation instead of silently dropping identity":
    for level in 1..4:
      var frame = AndroidFrame(withControls: level >= 3, withLists: level >= 4, ops: @[op()])
      if level == 2:
        frame.ops.add(UpdateOp(kind: opCreate, handle: NodeHandle(20), nodeKind: input))
      expect UiError: discard encodeAndroidFrame(frame)

  test "LAV5 preserves complete typed history and native binding above 32 bits":
    var r = Reader(bytes: encodeAndroidFrame(AndroidFrame(withNavigation: true,
      session: 41, mount: 42, revision: 43, ops: @[op()])))
    check r.u32() == 0x3556414c'u32
    check r.u64() == 41 and r.u64() == 42 and r.u64() == 43
    check r.u32() == 1 and r.u32() == 0
    check r.u32() == 1 and r.u64() == 19 and r.u64() == 7
    check r.u32() == 0 and r.u32() == 12
    check r.u32() == 1 and r.u32() == 0
    check r.string() == "导航😀" and r.string() == ""
    check r.string() == "" and r.string() == "" # V2 strings
    check r.u32() == 0 and r.u64() == 0 # V3 checked/progress
    check r.u32() == 0 and r.u32() == 0 # V4 list/row
    check r.u32() == 1 and r.u32() == 1 # V5 hasBack/hasNavigation
    check r.u64() == 0x100000001'u64
    check r.u64() == 0x200000002'u64
    check r.u64() == 0x300000003'u64
    check r.u64() == 0x300000001'u64
    check r.u32() == 3 and r.u64() == 1 # depth, mount-local native binding
    check r.u32() == 0 and r.u32() == 0 # writes and list projections
    check r.at == r.bytes.len

  test "LAV5 refuses malformed history and misplaced sidecars before serialization":
    var bad = op()
    bad.navigation = none(HostNavigationProps)
    expect UiError: discard encodeAndroidFrame(AndroidFrame(withNavigation: true, ops: @[bad]))
    bad = op()
    bad.nodeKind = text
    expect UiError: discard encodeAndroidFrame(AndroidFrame(withNavigation: true, ops: @[bad]))
    for depth in [0, 10001]:
      bad = op()
      var props = meta()
      props.depth = depth
      bad.navigation = some(props)
      expect UiError: discard encodeAndroidFrame(AndroidFrame(withNavigation: true, ops: @[bad]))

  test "detached measurement uses LAV5 and keeps the same navigation identity":
    let entity = MountedEntity(handle: NodeHandle(19), nodeId: "navigation",
      kind: NodeKind.navigation, navigation: some(meta()))
    let bytes = encodeAndroidMeasure(entity, withNavigation = true)
    var r = Reader(bytes: bytes)
    check r.u32() == 0x3556414c'u32
    # The measure frame uses the same per-op schema, not a reduced JSON path.
    check bytes.len > 140
