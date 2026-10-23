import std/[unittest, tables, options]
import leaf/[core, styles, backend, native_layout, native_edit, mobile_host, backend_session,
  components, component_description, component_state, widgets, managed_runtime]
import leaf/backends/android/[backend, editors]

type Native = ref object
  platform: AndroidPlatform
  staged: AndroidFrame
  text: Table[NodeHandle,string]
  writes: int
  caret: int
  readCaret: int
  failEffects, failApply: bool
proc makeNative(): Native =
  let n=Native()
  proc install(write:AndroidEditorWrite) =
    for effect in write.effects:
      inc n.writes
      if n.failEffects: fail("editor setter 1234")
      if effect.kind==setText:
        n.text[write.handle]=effect.value.text
        n.caret=effect.selection.caret
  n.platform.measure=proc(entity:MountedEntity,size:DipSize):DipSize = DipSize(width:200,height:40)
  n.platform.stage=proc(frame:AndroidFrame) = n.staged=frame
  n.platform.apply=proc() =
    for write in n.staged.editorWrites: install(write)
    if n.failApply: fail("apply 5678")
  n.platform.editEffects=install
  n.platform.editorSelection=proc(handle:NodeHandle):Selection16 = Selection16(anchor:n.readCaret,caret:n.readCaret)
  n.platform.discardStage=proc() = discard
  n.platform.restore=proc(frame:AndroidFrame) =
    n.text.clear()
    for write in frame.editorWrites: install(write)
  n.platform.rebind=proc(session,mount:uint64) = discard
  n.platform.dispose=proc() = n.text.clear()
  n
proc batch(value:string,revision:uint64,create=false,token=none(uint64)):UpdateBatch =
  var props:NormalizedProps
  props.control.value=some(value)
  props.control.resetToken=token
  UpdateBatch(revision:revision,ops: @[UpdateOp(kind:(if create:opCreate else:opUpdate),
    handle:NodeHandle(1),nodeId:"editor",nodeKind:input,props:props)])
proc accept(b:Backend,revision:uint64) = b.accepted(initTable[NodeHandle,MountedEntity](),revision)

type StateBox=ref object
  value:State[string]
  calls:int
proc app(box:StateBox):ApplicationFactory =
  result=proc():Application =
    let Page=defineComponent[int,State[string]]("EditorPage",
      proc(ctx:MountContext,p:int):State[string] =
        result=ctx.state("seed")
        box.value=result,
      proc(ctx:ComponentContext,p:int,state:State[string]):UiDescription =
        host(input(ctx.value(state),key="editor",onChange=proc(e:Event) =
          inc box.calls
          if e.value!="reject": discard state.set(e.value))))
    componentApplication(component(Page,0),"Editors",400,600)
proc queue(a:AndroidAdapter,h:MobileHost,m:MobileMount,seq:uint64,value:string):bool =
  let s=h.backendSession(m)
  let handle=s.handleFor(h.runtime.find("editor").id)
  let e=Event(kind:change,value:value)
  let selection=Selection16(caret:value.len)
  if not a.canObserveInput(handle,seq,e,selection): return false
  result=h.enqueue(m,EventEnvelope(session:s.sessionId,mountGeneration:s.mountGeneration,
    handle:handle,sequence:seq,observedRevision:h.runtime.acceptedRevision,
    bindingGeneration:1,event:e))
  if result: check a.observeInput(handle,seq,e,selection)

suite "Android editor backend integration":
  test "preparation is invisible, acceptance has no platform calls, and settle rejects no-diff edits":
    let n=makeNative()
    let a=newAndroidAdapter(n.platform,DipSize(width:400,height:600))
    let b=a.protocol
    let first=batch("seed",1,true)
    b.prepare(first)
    check n.text.len==0
    b.apply(first)
    let writes=n.writes
    b.accept(1)
    check n.writes==writes and n.text[NodeHandle(1)]=="seed"
    let e=Event(kind:change,value:"reject")
    check a.observeInput(NodeHandle(1),1,e,Selection16(caret:6))
    n.text[NodeHandle(1)]="reject" # genuine native user fact
    b.settle(EventSettlement(handle:NodeHandle(1),sequence:1,bindingGeneration:1))
    check n.text[NodeHandle(1)]=="seed"
    b.dispose()

  test "ordinary reset failure leaves old bindings invalid until explicit cleanup":
    let n=makeNative()
    let a=newAndroidAdapter(n.platform,DipSize(width:400,height:600))
    let b=a.protocol
    let first=batch("seed",1,true)
    b.prepare(first); b.apply(first); b.accept(1)
    let reset=batch("reset",2,token=some(1'u64))
    b.prepare(reset); b.apply(reset)
    let writes=n.writes
    b.accept(2)
    check n.writes==writes
    check not b.bindingValid(NodeHandle(1),1)
    n.failEffects=true
    expect UiError: a.flushEditorEffects()
    check not b.bindingValid(NodeHandle(1),1)
    n.failEffects=false
    a.flushEditorEffects()
    check n.text[NodeHandle(1)]=="reset"
    check b.bindingValid(NodeHandle(1),2) and not b.bindingValid(NodeHandle(1),1)
    b.dispose()

  test "real Runtime no-op rejection and queued edits settle only the newest observation":
    let n=makeNative(); let box=StateBox(); let h=newMobileHost(box.app())
    let a=newAndroidAdapter(n.platform,DipSize(width:400,height:600))
    let m=h.attach(a.protocol,400,600,1)
    check h.resume(m)
    let handle=h.backendSession(m).handleFor(h.runtime.find("editor").id)
    n.text[handle]="reject"
    check a.queue(h,m,1,"reject")
    check h.safeTurn(m)
    check box.calls==1 and box.value.readAccepted()=="seed" and n.text[handle]=="seed"
    n.text[handle]="ab"
    check a.queue(h,m,2,"a") and a.queue(h,m,3,"ab")
    check h.safeTurn(m)
    check box.calls==3 and box.value.readAccepted()=="ab" and n.text[handle]=="ab"
    h.close()

  test "a settle setter failure faults the Session and freezes business delivery":
    let n=makeNative(); let box=StateBox(); let h=newMobileHost(box.app())
    let a=newAndroidAdapter(n.platform,DipSize(width:400,height:600))
    let m=h.attach(a.protocol,400,600,1)
    check h.resume(m)
    check a.queue(h,m,1,"reject")
    n.failEffects=true
    discard h.safeTurn(m)
    check h.backendSession(m).faulted and h.runtime.eventsFrozen
    check box.calls==1 and not h.safeTurn(m)
    n.failEffects=false
    h.close()

  test "a model write preserves the current native caret even without a text change event":
    let n=makeNative()
    let a=newAndroidAdapter(n.platform,DipSize(width:400,height:600))
    let b=a.protocol
    let first=batch("seed",1,true)
    b.prepare(first); b.apply(first); b.accept(1)
    n.readCaret=2
    let changed=batch("MODEL",2)
    b.prepare(changed); b.apply(changed); b.accept(2)
    check n.text[NodeHandle(1)]=="MODEL" and n.caret==2
    b.dispose()
