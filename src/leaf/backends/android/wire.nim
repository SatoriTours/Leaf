## Internal LAV1/LAV2/LAV3/LAV4/LAV5 incremental Views transport, little endian. Every string is
## explicit-length UTF-8; Android copies borrowed bytes within the callback.
## No business tree, callback, pointer or Nim reference is serialized.
## Both headers: magic, u64 session/mount/revision, u32 op/box counts. V2 adds
## value/placeholder strings to each op and a tail of per-handle editor writes:
## u32 count; each u64 handle/binding,u32 effects; each effect u32 kind,string,
## u32 checked/anchor/caret/force. V1 remains byte-compatible for basic clients.
## V3 retains V2 and adds u32 checked/f64 progress after each op's value/hint.
## V4 retains V3, then each op adds optional typed list and row descriptions.
## After editor writes: u32 list count; each u64 handle/source/token,
## f64 offset/total/viewportHeight,u32 first/finish/protectedCount,protected u32s.
## V5 retains V4, adds hasBack/hasNavigation after each list/row sidecar,
## then u64 router/history/current/previous, u32 depth, u64 binding.
import std/options
import ../../[core, backend, native_layout, native_edit]
import ./backend as android_backend
import ./list_geometry

const MaxAndroidWireBytes* = 64 * 1024 * 1024
proc u32(outcome: var string, value: uint32) =
  for shift in [0,8,16,24]: outcome.add(char((value shr shift) and 255))
proc u64(outcome: var string, value: uint64) =
  for shift in [0,8,16,24,32,40,48,56]: outcome.add(char((value shr shift) and 255))
proc number(outcome: var string, value: float64) = outcome.u64(cast[uint64](value))
proc utf8(outcome: var string, value: string) =
  if value.len > MaxStringBytes: fail("Android string budget exceeded")
  outcome.u32(uint32(value.len))
  outcome.add(value)

proc encodeAndroidFrame*(frame: AndroidFrame): string =
  if frame.ops.len > MaxNodes * 4 + 64 or frame.boxes.len > MaxNodes:
    fail("Android frame operation budget exceeded")
  for op in frame.ops:
    if not frame.withNavigation and (op.nodeKind==NodeKind.navigation or
        op.navigation.isSome or op.props.control.hasBack):
      fail("Android navigation requires LAV5")
    if frame.withNavigation:
      if (op.nodeKind==NodeKind.navigation)!=op.navigation.isSome or
          (op.props.control.hasBack and op.nodeKind!=NodeKind.navigation):
        fail("Android navigation metadata does not match its kind")
      if op.navigation.isSome:
        let reason=op.navigation.get.invalidReason(MaxNodes)
        if reason.len!=0:fail(reason)
  let lists=frame.withLists or frame.withNavigation
  if not lists:
    if frame.listProjections.len!=0:fail("Android list projection requires LAV4")
    for op in frame.ops:
      if op.list.isSome or op.row.isSome:fail("Android typed list metadata requires LAV4")
  let controls=frame.withControls or lists
  var editors=frame.editorWrites.len>0 or controls
  for op in frame.ops:
    if op.nodeKind==input: editors=true
  result.u32(if frame.withNavigation: 0x3556414c'u32 elif lists: 0x3456414c'u32 elif controls: 0x3356414c'u32
    elif editors: 0x3256414c'u32 else: 0x3156414c'u32)
  result.u64(frame.session); result.u64(frame.mount); result.u64(frame.revision)
  result.u32(uint32(frame.ops.len)); result.u32(uint32(frame.boxes.len))
  for op in frame.ops:
    result.u32(uint32(ord(op.kind)))
    result.u64(op.handle.raw); result.u64(op.parent.raw)
    result.u32(uint32(op.index)); result.u32(uint32(ord(op.nodeKind)))
    result.u32(if op.props.control.enabled.get(true): 1 else: 0)
    result.u32(if op.props.control.hasClick: 1 else: 0)
    result.utf8(op.nodeId)
    result.utf8(op.props.control.label.get(op.props.accessibility.label.get("")))
    if editors:
      result.utf8(op.props.control.value.get(""))
      result.utf8(op.props.control.placeholder.get(""))
    if controls:
      result.u32(if op.props.control.checked.get(false): 1 else: 0)
      result.number(op.props.control.progress.get(0.0))
    if lists:
      result.u32(if op.list.isSome:1 else:0)
      if op.list.isSome:
        let meta=op.list.get
        let reason=meta.invalidReason(MaxListItems)
        if reason.len!=0:fail(reason)
        result.u64(meta.sourceGeneration)
        result.u32(uint32(meta.itemCount));result.u32(uint32(ord(meta.heightMode)))
        result.number(meta.rowHeight);result.number(meta.estimate)
        result.u32(uint32(meta.overscan))
      result.u32(if op.row.isSome:1 else:0)
      if op.row.isSome:
        let row=op.row.get
        result.u64(row.listHandle.raw);result.u64(row.sourceGeneration)
        result.u32(uint32(row.itemIndex));result.utf8(row.itemKey)
    if frame.withNavigation:
      result.u32(if op.props.control.hasBack:1 else:0)
      result.u32(if op.navigation.isSome:1 else:0)
      if op.navigation.isSome:
        let nav=op.navigation.get
        result.u64(nav.routerId);result.u64(nav.historyRevision)
        result.u64(nav.currentEntryId);result.u64(nav.previousEntryId)
        result.u32(uint32(nav.depth));result.u64(1) # Native binding in this mount.
    if result.len > MaxAndroidWireBytes: fail("Android wire budget exceeded")
  for box in frame.boxes:
    result.u64(box.handle.raw)
    for value in [box.rect.x,box.rect.y,box.rect.width,box.rect.height,
        box.clip.x,box.clip.y,box.clip.width,box.clip.height]: result.number(value)
  if editors:
    if frame.editorWrites.len>MaxNodes: fail("Android editor write budget exceeded")
    result.u32(uint32(frame.editorWrites.len))
    for write in frame.editorWrites:
      if write.effects.len>3: fail("Android editor effect budget exceeded")
      result.u64(write.handle.raw); result.u64(write.binding)
      result.u32(uint32(write.effects.len))
      for effect in write.effects:
        result.u32(uint32(ord(effect.kind)))
        result.utf8(effect.value.text)
        result.u32(if effect.value.checked: 1 else: 0)
        result.u32(uint32(effect.selection.anchor)); result.u32(uint32(effect.selection.caret))
        result.u32(if effect.force: 1 else: 0)
      if result.len>MaxAndroidWireBytes: fail("Android wire budget exceeded")
  if lists:
    if frame.listProjections.len>MaxNodes:fail("Android list projection budget exceeded")
    result.u32(uint32(frame.listProjections.len))
    for projection in frame.listProjections:
      if projection.geometry==nil or projection.protected.len>MaxNodes:
        fail("Android list projection is invalid")
      result.u64(projection.handle.raw);result.u64(projection.metadata.sourceGeneration)
      result.u64(projection.token)
      result.number(projection.geometry.offset);result.number(projection.geometry.total)
      result.number(projection.viewport.height)
      result.u32(uint32(projection.geometry.first));result.u32(uint32(projection.geometry.finish))
      result.u32(uint32(projection.protected.len))
      for index in projection.protected:result.u32(uint32(index))
      if result.len>MaxAndroidWireBytes:fail("Android wire budget exceeded")
  if result.len > MaxAndroidWireBytes: fail("Android wire budget exceeded")

proc encodeAndroidMeasure*(entity: MountedEntity,withControls=false,withLists=false,withNavigation=false): string =
  encodeAndroidFrame(AndroidFrame(withControls:withControls,withLists:withLists,withNavigation:withNavigation,
    ops: @[UpdateOp(kind:opCreate,handle:entity.handle,parent:entity.parent,
      index:entity.index,nodeId:entity.nodeId,nodeKind:entity.kind,props:entity.props,
      list:entity.list,row:entity.row,navigation:entity.navigation)]))
