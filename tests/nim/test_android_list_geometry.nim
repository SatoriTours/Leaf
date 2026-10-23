## Android list geometry candidates. This module is not yet connected to Views.
import std/[unittest, math]
import leaf/[core, backend]
import leaf/backends/android/list_geometry

proc props(count=20, generation=1'u64, variable=true):HostListProps =
  HostListProps(sourceGeneration:generation,itemCount:count,
    heightMode:(if variable:HostHeightMode.variable else:HostHeightMode.uniform),
    rowHeight:(if variable:0.0 else:24.0),estimate:24,overscan:2)
proc rows(first,finish:int,generation=1'u64):seq[NativeRowBinding] =
  for i in first..<finish:
    result.add(NativeRowBinding(listHandle:NodeHandle(7),sourceGeneration:generation,
      itemIndex:i,itemKey:"key-" & $i))
proc frame(g:AndroidListGeometry,p=props(),r=rows(0,6),
    measured:seq[RowHeightSample] = @[],width=300.0,scale=1.0,epoch=1'u64):AndroidListFrame =
  g.prepareListGeometry(p,width,96,scale,epoch,r,measured)

suite "Android list geometry candidates":
  test "discard preserves accepted heights and exact geometry; publish only candidate":
    let g=newAndroidListGeometry(NodeHandle(7))
    let a=g.frame(measured= @[RowHeightSample(index:1,height:48)])
    check g.acceptedFrame==nil
    check a.total==504 and a.first==0 and a.finish==3
    check g.publishListGeometry()
    check g.acceptedFrame==a
    g.requestOffset(30)
    let b=g.frame(measured= @[RowHeightSample(index:1,height:72)])
    check b.offset==30 and b.total==528
    check a.total==504 and a.prefix(2)==72
    g.discardListGeometry()
    check g.acceptedFrame==a and g.desiredOffset==30
    let retry=g.frame()
    check retry.offset==30 and retry.total==504
    check g.publishListGeometry()
    check g.acceptedFrame==retry
    check not g.publishListGeometry()

  test "measurement prefix preserves stable first-row key and truncates delta on shrink":
    let g=newAndroidListGeometry(NodeHandle(7))
    discard g.frame();check g.publishListGeometry()
    g.requestOffset(82)
    discard g.frame();check g.publishListGeometry()
    check g.acceptedFrame.first==3
    let a=g.frame(measured= @[RowHeightSample(index:1,height:72)])
    check a.offset==130 and a.first==3 and a.prefix(3)-a.offset == -10
    check g.publishListGeometry()
    let b=g.frame(measured= @[RowHeightSample(index:3,height:4)])
    check b.offset==124 and b.prefix(3)==120
    check g.publishListGeometry()

  test "explicit intent wins anchor and a newer intent survives old candidate publication":
    let g=newAndroidListGeometry(NodeHandle(7))
    discard g.frame();check g.publishListGeometry()
    g.requestOffset(82);discard g.frame();check g.publishListGeometry()
    g.requestOffset(154)
    let a=g.frame(measured= @[RowHeightSample(index:1,height:72)])
    check a.offset==154
    g.requestOffset(202)
    check g.publishListGeometry()
    check g.acceptedFrame==a and g.desiredOffset==202
    let b=g.frame(r=rows(4,14))
    check b.offset==202
    check g.publishListGeometry()
    check g.desiredOffset==202

  test "width scale font epoch and source invalidate all old offscreen measurements":
    for change in 0..4:
      let g=newAndroidListGeometry(NodeHandle(7))
      discard g.frame(measured= @[RowHeightSample(index:1,height:72)])
      check g.publishListGeometry()
      let p=props(generation=(if change==3:2'u64 else:1'u64),variable=change!=4)
      let b=g.frame(p=p,r=rows(8,14,p.sourceGeneration),width=(if change==0:280.0 else:300.0),
        scale=(if change==1:2.0 else:1.0),epoch=(if change==2:2'u64 else:1'u64))
      check b.prefix(2)==48 and b.total==480
      check g.acceptedFrame.prefix(2)==96
      g.discardListGeometry()

  test "empty and 100k rows use bare visibility and bounded finite logical reach":
    let g=newAndroidListGeometry(NodeHandle(7))
    let a=g.frame(p=props(count=0),r= @[])
    check a.first==0 and a.finish==0 and a.total==0 and a.offset==0
    check g.publishListGeometry()
    var p=props(count=100000,variable=false);p.rowHeight=1_000_000
    g.requestOffset(1e11)
    let b=g.frame(p=p,r=rows(99998,100000))
    check b.total==1e11 and b.offset==1e11-96
    check b.first==99999 and b.finish==100000
    check b.prefix(100000)==1e11
    check g.publishListGeometry()

  test "bad row identities measurements and contexts cannot mutate accepted frame":
    let g=newAndroidListGeometry(NodeHandle(7))
    let a=g.frame();check g.publishListGeometry()
    expect UiError: discard g.frame(r=rows(0,3,2))
    expect UiError: discard g.frame(r= @[rows(0,1)[0],rows(0,1)[0]])
    expect UiError: discard g.frame(measured= @[RowHeightSample(index:19,height:48)])
    expect UiError: discard g.frame(measured= @[RowHeightSample(index:1,height:NaN)])
    expect UiError: discard g.frame(width=Inf)
    expect UiError: g.requestOffset(NaN)
    check g.acceptedFrame==a and a.total==480
    discard g.frame();check g.publishListGeometry()

  test "candidate owns row identities independently of caller sequence":
    let g=newAndroidListGeometry(NodeHandle(7))
    var owned=rows(0,6)
    g.requestOffset(82)
    discard g.frame(r=owned);check g.publishListGeometry()
    owned[3].itemKey="foreign-key"
    let a=g.frame(measured= @[RowHeightSample(index:1,height:72)])
    check a.offset==130
    g.discardListGeometry()

  when defined(nimAllocStats):
    test "publication allocates and destroys no prepared frames":
      proc counters():tuple[allocs,frees:int] =
        let stats=getAllocStats()
        for name,value in fieldPairs(stats):
          when name=="allocCount": result.allocs=value
          elif name=="deallocCount": result.frees=value
      let g=newAndroidListGeometry(NodeHandle(7))
      for turn in 0..3:
        discard g.frame()
        let before=counters()
        let accepted=g.publishListGeometry()
        let after=counters()
        check accepted
        check after.allocs-before.allocs==0
        check after.frees-before.frees==0

  test "count estimate and uniform height changes reset index instead of reusing old entries":
    for change in 0..1:
      let g=newAndroidListGeometry(NodeHandle(7))
      discard g.frame(measured= @[RowHeightSample(index:1,height:72)])
      check g.publishListGeometry()
      var p=props()
      if change==0: p.itemCount=24
      else: p.estimate=32
      let b=g.frame(p=p,r=rows(8,14))
      check b.prefix(2)==(if change==0:48.0 else:64.0)
      check b.total==(if change==0:576.0 else:640.0)
      g.discardListGeometry()
    let g=newAndroidListGeometry(NodeHandle(7))
    discard g.frame(p=props(variable=false));check g.publishListGeometry()
    var p=props(variable=false);p.rowHeight=48
    let b=g.frame(p=p)
    check b.total==960 and b.prefix(2)==96
    g.discardListGeometry()

  test "zero viewport and absent anchor key keep numeric intent without inventing rows":
    let g=newAndroidListGeometry(NodeHandle(7))
    g.requestOffset(82)
    discard g.frame();check g.publishListGeometry()
    let b=g.frame(r=rows(8,14),measured= @[RowHeightSample(index:8,height:72)])
    check b.offset==82
    g.discardListGeometry()
    let c=g.prepareListGeometry(props(),300,0,1,1,rows(0,6),@[])
    check c.first==0 and c.finish==0 and c.offset==82
    check g.publishListGeometry()
    let d=g.frame()
    check d.offset==82
    g.discardListGeometry()

  test "rowset readiness uses actual typed rows with exactly one Runtime overscan ring":
    let g=newAndroidListGeometry(NodeHandle(7))
    let a=g.frame(r= @[])
    check a.first==0 and a.finish==4 and not a.rowsReady
    check g.publishListGeometry()
    let b=g.frame(r=rows(0,6))
    check b.first==0 and b.finish==4 and b.rowsReady
    g.discardListGeometry()
    let c=g.frame(r=rows(0,5))
    check not c.rowsReady
    g.discardListGeometry()
    let d=g.frame(r=rows(0,7))
    check not d.rowsReady
    g.discardListGeometry()

  test "protected offscreen rows remain in the required set without widening visibility":
    let g=newAndroidListGeometry(NodeHandle(7))
    let r=rows(0,6) & rows(19,20)
    let a=g.prepareListGeometry(props(),300,96,1,1,r,@[],@[19])
    check a.first==0 and a.finish==4 and a.rowsReady
    g.discardListGeometry()
    let b=g.prepareListGeometry(props(),300,96,1,1,rows(0,6),@[],@[19])
    check not b.rowsReady
    g.discardListGeometry()
    expect UiError: discard g.prepareListGeometry(props(),300,96,1,1,r,@[],@[20])
