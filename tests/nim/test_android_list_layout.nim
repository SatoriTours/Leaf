## List layout preparation uses the real shared layout engine and typed rows.
import std/[unittest, tables, options]
import leaf/[core, styles, backend, native_layout]
import leaf/backends/android/[list_geometry, list_layout]

proc metadata(count=100,generation=1'u64,variable=false):HostListProps =
  HostListProps(sourceGeneration:generation,itemCount:count,
    heightMode:(if variable:HostHeightMode.variable else:HostHeightMode.uniform),
    rowHeight:(if variable:0.0 else:24.0),estimate:24,overscan:0)
proc tree(indices:seq[int],p=metadata()):Table[NodeHandle,MountedEntity] =
  result[NodeHandle(1)]=MountedEntity(handle:NodeHandle(1),kind:virtualList,
    nodeId:"list",list:some(p))
  for slot,index in indices:
    let h=NodeHandle(uint64(10+slot))
    result[h]=MountedEntity(handle:h,parent:NodeHandle(1),kind:column,index:slot,
      nodeId:"row-" & $index,row:some(NativeRowBinding(listHandle:NodeHandle(1),
        sourceGeneration:p.sourceGeneration,itemIndex:index,itemKey:"item-" & $index)))
    let child=NodeHandle(uint64(100+slot))
    result[child]=MountedEntity(handle:child,parent:h,kind:text,nodeId:"text-" & $index)
proc measure(entity:MountedEntity,size:DipSize):DipSize =
  DipSize(width:size.width,height:24)
proc box(plan:AndroidListLayout,handle:uint64):LayoutBox =
  for b in plan.boxes:
    if b.handle==NodeHandle(handle):return b
  raise newException(AssertionDefect,"missing box " & $handle)
proc prepare(l:AndroidLists,entities:Table[NodeHandle,MountedEntity],
    m:MeasureProc=measure):AndroidListLayout =
  l.prepareListLayout(entities,DipSize(width:300,height:96),m,1,1)

suite "Android typed list layout":
  test "non-contiguous rows use logical indexes and their real subtrees":
    let l=newAndroidLists()
    let p=l.prepare(tree(@[0,3]))
    check p.boxes.len==5 and p.projections.len==1
    check p.box(10).rect.y==0 and p.box(11).rect.y==72
    check p.box(101).rect.y==72 and p.box(101).clip.height==24
    check p.projections[0].metadata.itemCount==100
    check p.projections[0].geometry.first==0 and p.projections[0].geometry.finish==4
    check not p.projections[0].geometry.rowsReady
    check l.acceptedListLayout==nil
    check l.publishListLayout()
    check l.acceptedListLayout==p

  test "native viewport facts are bare once acknowledged and new intent creates a new fact":
    let l=newAndroidLists()
    discard l.prepare(tree(@[]));check l.publishListLayout()
    let facts=l.pendingListViewports()
    check facts.len==1
    check facts[0].first==0 and facts[0].finish==4
    check l.markListViewportQueued(facts[0].handle,facts[0].token)
    check l.pendingListViewports().len==0
    check not l.requestListOffset(NodeHandle(1),2,120)
    check l.requestListOffset(NodeHandle(1),1,120)
    check l.listProjectionNeeded
    let p=l.prepare(tree(@[]))
    check p.projections[0].geometry.offset==120
    check l.publishListLayout()
    check not l.listProjectionNeeded
    check not l.markListViewportQueued(facts[0].handle,facts[0].token)
    let next=l.pendingListViewports()
    check next.len==1 and next[0].first==5 and next[0].finish==9

  test "all candidate geometries discard together when a later subtree measure fails":
    let l=newAndroidLists()
    var t=tree(@[0,1],metadata(variable=true))
    discard l.prepare(t);check l.publishListLayout()
    let old=l.acceptedListLayout
    check l.requestListOffset(NodeHandle(1),1,10)
    var visits=0
    let bad:MeasureProc=proc(e:MountedEntity,size:DipSize):DipSize =
      inc visits
      if e.nodeId=="text-1":fail("measure second row 1234")
      DipSize(width:size.width,height:48)
    expect UiError:discard l.prepare(t,bad)
    check visits>0 and l.acceptedListLayout==old
    check old.projections[0].geometry.total==2400
    let retry=l.prepare(t)
    check retry.projections[0].geometry.offset==10
    l.discardListLayout()
    check l.acceptedListLayout==old

  test "metadata-only source change survives and cannot use old source intent":
    let l=newAndroidLists()
    discard l.prepare(tree(@[0,1]));check l.publishListLayout()
    let p=l.prepare(tree(@[0,1],metadata(count=5,generation=2)))
    check p.projections[0].metadata.sourceGeneration==2
    check p.projections[0].metadata.itemCount==5
    check l.publishListLayout()
    check not l.requestListOffset(NodeHandle(1),1,24)
    check l.requestListOffset(NodeHandle(1),2,24)

  test "newer intent during prepare survives publication and discarded attempts":
    let l=newAndroidLists()
    discard l.prepare(tree(@[]));check l.publishListLayout()
    check l.requestListOffset(NodeHandle(1),1,120)
    let p=l.prepare(tree(@[]))
    check l.requestListOffset(NodeHandle(1),1,240)
    check l.publishListLayout()
    check p.projections[0].geometry.offset==120
    check l.listProjectionNeeded
    let next=l.prepare(tree(@[]))
    check next.projections[0].geometry.offset==240
    l.discardListLayout()
    check l.listProjectionNeeded and l.acceptedListLayout==p
    discard l.prepare(tree(@[]));check l.publishListLayout()
    check not l.listProjectionNeeded

  test "a second list failure discards a previously prepared first list":
    let l=newAndroidLists()
    var t=tree(@[0,1],metadata(variable=true))
    t[NodeHandle(1)].parent=NodeHandle(500)
    t[NodeHandle(1)].props.layout=LayoutProps(
      width:some(Dimension(kind:dkFill)),height:some(Dimension(kind:dkFixed,value:96)))
    t[NodeHandle(500)]=MountedEntity(handle:NodeHandle(500),kind:column)
    t[NodeHandle(2)]=MountedEntity(handle:NodeHandle(2),parent:NodeHandle(500),
      kind:virtualList,index:1,list:some(metadata(variable=true)),
      props:NormalizedProps(layout:t[NodeHandle(1)].props.layout))
    t[NodeHandle(12)]=MountedEntity(handle:NodeHandle(12),parent:NodeHandle(2),
      kind:column,row:some(NativeRowBinding(listHandle:NodeHandle(2),
        sourceGeneration:1,itemIndex:0,itemKey:"other-0")))
    t[NodeHandle(102)]=MountedEntity(handle:NodeHandle(102),parent:NodeHandle(12),
      kind:text,nodeId:"second-list-text")
    let size=DipSize(width:300,height:192)
    discard l.prepareListLayout(t,size,measure,1,1);check l.publishListLayout()
    let old=l.acceptedListLayout
    check old.projections.len==2 and old.box(12).rect.y==96
    let bad:MeasureProc=proc(e:MountedEntity,s:DipSize):DipSize =
      if e.nodeId=="second-list-text":fail("second list 1234")
      DipSize(width:s.width,height:48)
    expect UiError:discard l.prepareListLayout(t,size,bad,1,1)
    check l.acceptedListLayout==old
    let retry=l.prepareListLayout(t,size,measure,1,1)
    check retry.projections.len==2
    check l.publishListLayout()

  test "nested list viewports and subtree clips follow shared parent placement":
    let l=newAndroidLists()
    var t=tree(@[3])
    t[NodeHandle(100)].kind=virtualList
    t[NodeHandle(100)].list=some(metadata(count=5))
    t[NodeHandle(100)].props.layout=LayoutProps(
      width:some(Dimension(kind:dkFill)),height:some(Dimension(kind:dkFixed,value:24)))
    t[NodeHandle(200)]=MountedEntity(handle:NodeHandle(200),parent:NodeHandle(100),
      kind:text,row:some(NativeRowBinding(listHandle:NodeHandle(100),
        sourceGeneration:1,itemIndex:0,itemKey:"nested-0")))
    let p=l.prepare(t)
    check p.boxes.len==4 and p.projections.len==2
    check p.box(100).rect.y==72 and p.box(100).rect.height==24
    check p.box(200).rect.y==72 and p.box(200).clip.height==24
    check l.publishListLayout()

  when defined(nimAllocStats):
    test "layout publication neither allocates nor destroys candidate storage":
      proc counters():tuple[allocs,frees:int] =
        let stats=getAllocStats()
        for name,value in fieldPairs(stats):
          when name=="allocCount":result.allocs=value
          elif name=="deallocCount":result.frees=value
      let l=newAndroidLists()
      for turn in 0..3:
        discard l.prepare(tree(@[0,1,2,3]))
        let before=counters()
        let published=l.publishListLayout()
        let after=counters()
        check published
        check after.allocs-before.allocs==0 and after.frees-before.frees==0
  test "typed identity violations are refused before any partial layout is accepted":
    let l=newAndroidLists()
    discard l.prepare(tree(@[0,1]));check l.publishListLayout()
    let old=l.acceptedListLayout
    var t=tree(@[0,1])
    t[NodeHandle(11)].row=some(t[NodeHandle(10)].row.get)
    expect UiError:discard l.prepare(t)
    t=tree(@[0,1]);t[NodeHandle(11)].parent=NodeHandle(10)
    expect UiError:discard l.prepare(t)
    check l.acceptedListLayout==old
    discard l.prepare(tree(@[0,1]));check l.publishListLayout()

  test "a valid collapsed width stays finite and restores using a fresh context":
    let l=newAndroidLists()
    var t=tree(@[0],metadata(variable=true))
    t[NodeHandle(1)].props.layout.width=some(Dimension(kind:dkFixed,value:0))
    let collapsed=l.prepare(t)
    check collapsed.box(10).rect.width==0
    check collapsed.projections[0].geometry.total==2400
    check l.publishListLayout()
    t[NodeHandle(1)].props.layout.width=none(Dimension)
    let expanded=l.prepare(t)
    check expanded.box(10).rect.width==300
    check l.publishListLayout()
