## Typed protection facts only. No Android Views, JNI or real IME is claimed.
import std/[unittest, tables, options]
import leaf/[core, backend]
import leaf/backends/android/list_protection

proc meta(source=1'u64):HostListProps =
  HostListProps(sourceGeneration:source,itemCount:100,
    heightMode:HostHeightMode.uniform,rowHeight:24,estimate:24,overscan:0)

proc tree():Table[NodeHandle,MountedEntity] =
  result[NodeHandle(1)]=MountedEntity(handle:NodeHandle(1),kind:virtualList,
    list:some(meta()))
  for slot,index in [7,2]:
    let root=NodeHandle(uint64(10+slot))
    result[root]=MountedEntity(handle:root,parent:NodeHandle(1),kind:column,
      row:some(NativeRowBinding(listHandle:NodeHandle(1),sourceGeneration:1,
        itemIndex:index,itemKey:"key-" & $index)))
    let control=NodeHandle(uint64(100+slot))
    result[control]=MountedEntity(handle:control,parent:root,kind:input)
  result[NodeHandle(102)]=MountedEntity(handle:NodeHandle(102),
    parent:NodeHandle(10),kind:input)

proc nested():Table[NodeHandle,MountedEntity] =
  result=tree()
  result[NodeHandle(3)]=MountedEntity(handle:NodeHandle(3),parent:NodeHandle(10),
    kind:virtualList,list:some(meta(2)))
  result[NodeHandle(30)]=MountedEntity(handle:NodeHandle(30),parent:NodeHandle(3),
    kind:column,row:some(NativeRowBinding(listHandle:NodeHandle(3),
      sourceGeneration:2,itemIndex:42,itemKey:"nested-42")))
  result[NodeHandle(300)]=MountedEntity(handle:NodeHandle(300),
    parent:NodeHandle(30),kind:input)

proc bindingOne(handle:NodeHandle,generation:uint64):bool = generation==1
proc fact(handle=100'u64,sequence=1'u64,mount=1'u64,binding=1'u64,
    reasons: set[AndroidProtectionReason]={rowFocused}):AndroidProtectionFact =
  AndroidProtectionFact(handle:NodeHandle(handle),mount:mount,binding:binding,
    sequence:sequence,reasons:reasons)

suite "Android typed row protection facts":
  test "a focused descendant protects its logical row without changing entities":
    let p=newAndroidRowProtection()
    let entities=tree()
    check p.recordProtection(fact(),1,entities,bindingOne)
    let rows=p.snapshotProtectedRows(1,entities,bindingOne)
    check rows.len==1 and rows[NodeHandle(1)] == @[7]
    check entities.len==6 and p.protectionFactCount==1

  test "nested input protects every ancestor typed row":
    let p=newAndroidRowProtection()
    let entities=nested()
    check p.recordProtection(fact(handle=300,reasons={rowComposing}),1,
      entities,bindingOne)
    let rows=p.snapshotProtectedRows(1,entities,bindingOne)
    check rows.len==2
    check rows[NodeHandle(1)] == @[7]
    check rows[NodeHandle(3)] == @[42]

  test "reason masks replace one control while sibling protections are unioned":
    let p=newAndroidRowProtection()
    let entities=tree()
    check p.recordProtection(fact(reasons={rowFocused,rowComposing}),1,
      entities,bindingOne)
    check p.recordProtection(fact(handle=102),1,entities,bindingOne)
    check p.recordProtection(fact(handle=101),1,entities,bindingOne)
    check p.recordProtection(fact(sequence=2,reasons={rowComposing}),1,
      entities,bindingOne)
    check p.snapshotProtectedRows(1,entities,bindingOne)[NodeHandle(1)] == @[2,7]
    check p.recordProtection(fact(sequence=3,reasons={}),1,entities,bindingOne)
    check p.snapshotProtectedRows(1,entities,bindingOne)[NodeHandle(1)] == @[2,7]
    check p.recordProtection(fact(handle=102,sequence=2,reasons={}),1,
      entities,bindingOne)
    check p.snapshotProtectedRows(1,entities,bindingOne)[NodeHandle(1)] == @[2]

  test "release retains the sequence fence and invalid facts consume nothing":
    let p=newAndroidRowProtection()
    let entities=tree()
    check p.recordProtection(fact(sequence=4),1,entities,bindingOne)
    check p.recordProtection(fact(sequence=5,reasons={}),1,entities,bindingOne)
    check not p.recordProtection(fact(sequence=5),1,entities,bindingOne)
    check not p.recordProtection(fact(sequence=0),1,entities,bindingOne)
    check not p.recordProtection(fact(sequence=100,mount=2),1,entities,bindingOne)
    check not p.recordProtection(fact(sequence=100,binding=2),1,entities,bindingOne)
    check not p.recordProtection(fact(sequence=100,binding=0),1,entities,bindingOne)
    check p.snapshotProtectedRows(1,entities,bindingOne).len==0
    check p.recordProtection(fact(sequence=6),1,entities,bindingOne)
    check p.snapshotProtectedRows(1,entities,bindingOne)[NodeHandle(1)] == @[7]

  test "mount or binding replacement cannot inherit an old protection":
    let p=newAndroidRowProtection()
    let entities=tree()
    var binding=1'u64
    let valid:AndroidProtectionBinding=proc(h:NodeHandle,b:uint64):bool =
      b==binding
    check p.recordProtection(fact(sequence=9),1,entities,valid)
    check p.snapshotProtectedRows(2,entities,valid).len==0
    binding=2
    check p.snapshotProtectedRows(1,entities,valid).len==0
    check not p.recordProtection(fact(sequence=10),1,entities,valid)
    check p.recordProtection(fact(sequence=1,binding=2),1,entities,valid)
    check p.snapshotProtectedRows(1,entities,valid)[NodeHandle(1)] == @[7]
    check p.recordProtection(fact(sequence=1,mount=2,binding=2),2,entities,valid)
    check not p.recordProtection(fact(sequence=20,binding=2),2,entities,valid)
    check p.protectionFactCount==1

  test "source key index or ancestor changes invalidate the captured identity":
    for mode in 0..4:
      let p=newAndroidRowProtection()
      var entities=nested()
      check p.recordProtection(fact(handle=300),1,entities,bindingOne)
      case mode
      of 0:
        var m=entities[NodeHandle(1)].list.get
        m.sourceGeneration=3
        entities[NodeHandle(1)].list=some(m)
        var row=entities[NodeHandle(10)].row.get
        row.sourceGeneration=3
        entities[NodeHandle(10)].row=some(row)
      of 1:
        var row=entities[NodeHandle(10)].row.get
        row.itemKey="replacement"
        entities[NodeHandle(10)].row=some(row)
      of 2:
        var row=entities[NodeHandle(30)].row.get
        row.itemIndex=43
        entities[NodeHandle(30)].row=some(row)
      of 3:entities[NodeHandle(300)].parent=NodeHandle(10)
      else:entities.del(NodeHandle(300))
      check p.snapshotProtectedRows(1,entities,bindingOne).len==0
      p.reconcileProtection(1,entities,bindingOne)
      check p.protectionFactCount==0

  test "malformed ancestor chains are refused before recording a fact":
    for mode in 0..5:
      let p=newAndroidRowProtection()
      var entities=tree()
      case mode
      of 0:entities[NodeHandle(100)].parent=NodeHandle(999)
      of 1:entities[NodeHandle(10)].parent=NodeHandle(100)
      of 2:entities[NodeHandle(10)].row=none(NativeRowBinding)
      of 3:entities[NodeHandle(1)].list=none(HostListProps)
      of 4:
        var row=entities[NodeHandle(10)].row.get
        row.sourceGeneration=2
        entities[NodeHandle(10)].row=some(row)
      else:entities[NodeHandle(100)].handle=NodeHandle(999)
      check not p.recordProtection(fact(),1,entities,bindingOne)
      check p.protectionFactCount==0

  test "composition requires an input and a non-row control never pins a row":
    let p=newAndroidRowProtection()
    var entities=tree()
    entities[NodeHandle(100)].kind=button
    check not p.recordProtection(fact(reasons={rowComposing}),1,entities,bindingOne)
    check p.recordProtection(fact(),1,entities,bindingOne)
    check not p.recordProtection(fact(handle=1),1,entities,bindingOne)
    check not p.recordProtection(fact(handle=0),1,entities,bindingOne)
    check not p.recordProtection(fact(),0,entities,bindingOne)
    check not p.recordProtection(fact(),1,entities,nil)

  test "snapshots own their arrays and pruning removes old handles":
    let p=newAndroidRowProtection()
    var entities=tree()
    check p.recordProtection(fact(),1,entities,bindingOne)
    var rows=p.snapshotProtectedRows(1,entities,bindingOne)
    rows[NodeHandle(1)][0]=99
    check p.snapshotProtectedRows(1,entities,bindingOne)[NodeHandle(1)] == @[7]
    entities.del(NodeHandle(100))
    check p.snapshotProtectedRows(1,entities,bindingOne).len==0
    p.reconcileProtection(1,entities,bindingOne)
    check p.protectionFactCount==0

  test "captured identity owns row keys independently of the caller":
    let p=newAndroidRowProtection()
    var entities=tree()
    check p.recordProtection(fact(),1,entities,bindingOne)
    entities[NodeHandle(10)].row.get.itemKey[0]='X'
    check p.snapshotProtectedRows(1,entities,bindingOne).len==0

  test "accepted entity budget bounds facts without a removed-handle history":
    let p=newAndroidRowProtection()
    for step in 0..<128:
      var entities=tree()
      let handle=NodeHandle(uint64(1000+step))
      entities[handle]=MountedEntity(handle:handle,parent:NodeHandle(10),kind:input)
      check p.recordProtection(fact(handle=handle.raw),1,entities,bindingOne)
      check p.protectionFactCount==1
    var over=tree()
    for i in 1000..1000+MaxNodes:
      let h=NodeHandle(uint64(i))
      over[h]=MountedEntity(handle:h,kind:text)
    check not p.recordProtection(fact(),1,over,bindingOne)
