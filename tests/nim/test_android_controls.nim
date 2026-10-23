import std/[unittest, tables, options]
import leaf/[core, styles, backend, native_layout, native_edit, components,
  component_description, component_state, widgets, mobile_host, backend_session,
  managed_runtime]
import leaf/backends/android/backend as android_backend

type Native = ref object
  platform: AndroidPlatform
  staged: AndroidFrame
  checks: Table[NodeHandle,bool]
  writes, selectionQueries: int
  failEffects,failApply: bool
  afterEffects: proc(handle:NodeHandle) {.closure.}

proc makeNative(): Native =
  let n=Native()
  n.platform.withControls=true
  n.platform.measure=proc(entity:MountedEntity,size:DipSize):DipSize =
    DipSize(width:200,height:40)
  proc install(write:AndroidEditorWrite) =
    for effect in write.effects:
      inc n.writes
      if n.failEffects: fail("checked setter 1234")
      if effect.kind==setChecked: n.checks[write.handle]=effect.value.checked
    if n.afterEffects!=nil: n.afterEffects(write.handle)
  n.platform.stage=proc(frame:AndroidFrame) = n.staged=frame
  n.platform.apply=proc() =
    for write in n.staged.editorWrites: install(write)
    if n.failApply: fail("controls apply 5678")
  n.platform.editEffects=install
  n.platform.editorSelection=proc(handle:NodeHandle):Selection16 =
    inc n.selectionQueries
    Selection16()
  n.platform.discardStage=proc() = discard
  n.platform.restore=proc(frame:AndroidFrame) =
    n.checks.clear()
    for write in frame.editorWrites: install(write)
  n.platform.rebind=proc(session,mount:uint64) = discard
  n.platform.dispose=proc() = n.checks.clear()
  n

type Model=ref object
  accepted: State[bool]
  calls: int
  acceptChange: bool

proc app(model:Model):ApplicationFactory =
  result=proc():Application =
    let Page=defineComponent[int,State[bool]]("AndroidChecks",
      proc(ctx:MountContext,p:int):State[bool] =
        result=ctx.state(false)
        model.accepted=result,
      proc(ctx:ComponentContext,p:int,state:State[bool]):UiDescription =
        host(column(@[
          checkbox("选择 中文😀",ctx.value(state),key="check",onChange=proc(e:Event) =
            inc model.calls
            if model.acceptChange: discard state.set(e.checked)),
          switch("开关",ctx.value(state),key="toggle",onChange=proc(e:Event) =
            inc model.calls
            if model.acceptChange: discard state.set(e.checked)),
          progress(42.5,key="progress"), tag("标签",key="tag"),
          separator(key="separator"), spinner(key="spinner")],key="root")))
    componentApplication(component(Page,0),"Controls",400,600)

proc fact(a:AndroidAdapter,h:MobileHost,m:MobileMount,id:string,seq:uint64,value:bool):bool =
  let s=h.backendSession(m)
  let key=s.handleFor(h.runtime.find(id).id)
  let event=Event(kind:change,checked:value)
  if not a.canObserveInput(key,seq,event,Selection16()): return false
  result=h.enqueue(m,EventEnvelope(session:s.sessionId,mountGeneration:s.mountGeneration,
    handle:key,sequence:seq,observedRevision:h.runtime.acceptedRevision,
    bindingGeneration:1,event:event))
  if result: check a.observeInput(key,seq,event,Selection16())

suite "Android remaining native controls":
  test "old capability levels remain explicit and lists remain unavailable":
    check androidCapabilities().kinds=={column,row,text,button}
    check androidCapabilities(true).kinds=={column,row,text,button,input}
    let full=androidCapabilities(true,true)
    check full.kinds=={column,row,text,button,input,checkbox,toggle,progress,tag,separator,spinner}
    check virtualList notin full.kinds

  test "rejected native check restores accepted value without a model revision":
    let model=Model()
    let h=newMobileHost(model.app())
    let n=makeNative()
    let a=newAndroidAdapter(n.platform,DipSize(width:400,height:600))
    let m=h.attach(a.protocol,400,600,1)
    check h.resume(m)
    let key=h.backendSession(m).handleFor(h.runtime.find("check").id)
    let revision=h.runtime.acceptedRevision
    n.checks[key]=true
    check a.fact(h,m,"check",1,true)
    check model.calls==0
    check h.safeTurn(m)
    check model.calls==1 and not n.checks[key]
    check not model.accepted.readAccepted()
    check h.runtime.acceptedRevision==revision
    check n.selectionQueries==0
    h.close()

  test "accepted check updates the sibling switch without setter callbacks":
    let model=Model(acceptChange:true)
    let h=newMobileHost(model.app())
    let n=makeNative()
    let a=newAndroidAdapter(n.platform,DipSize(width:400,height:600))
    let m=h.attach(a.protocol,400,600,1)
    check h.resume(m)
    let s=h.backendSession(m)
    let c=s.handleFor(h.runtime.find("check").id)
    let t=s.handleFor(h.runtime.find("toggle").id)
    n.checks[c]=true
    check a.fact(h,m,"check",1,true)
    check h.safeTurn(m)
    check model.accepted.readAccepted() and n.checks[c] and n.checks[t]
    check model.calls==1 and n.selectionQueries==0
    # Stale global sequence must not poison a different control's native facts.
    check not a.fact(h,m,"toggle",1,false)
    n.checks[t]=false
    check a.fact(h,m,"toggle",2,false)
    check h.safeTurn(m)
    check not model.accepted.readAccepted() and not n.checks[c] and not n.checks[t]
    check model.calls==2
    check h.pause(m)
    check not a.fact(h,m,"check",3,true)
    check h.resume(m)
    n.checks[c]=true
    check a.fact(h,m,"check",3,true)
    check h.safeTurn(m)
    check model.calls==3 and model.accepted.readAccepted()
    h.close()

  test "ordinary checked effect failure freezes delivery and retains cleanup owner":
    let model=Model()
    let h=newMobileHost(model.app())
    let n=makeNative()
    let a=newAndroidAdapter(n.platform,DipSize(width:400,height:600))
    let m=h.attach(a.protocol,400,600,1)
    check h.resume(m)
    let key=h.backendSession(m).handleFor(h.runtime.find("check").id)
    n.checks[key]=true
    check a.fact(h,m,"check",1,true)
    n.failEffects=true
    discard h.safeTurn(m)
    check h.backendSession(m).faulted
    check not a.fact(h,m,"check",2,false)
    check not h.safeTurn(m)
    n.failEffects=false
    h.close()
    check n.checks.len==0

  test "a genuine sibling fact during settle survives to the next ordinary turn":
    let model=Model(acceptChange:true)
    let h=newMobileHost(model.app())
    let n=makeNative()
    let a=newAndroidAdapter(n.platform,DipSize(width:400,height:600))
    let m=h.attach(a.protocol,400,600,1)
    check h.resume(m)
    let key=h.backendSession(m).handleFor(h.runtime.find("check").id)
    # Reject this first fact without a state update. Its correction is an
    # ordinary native setter during which another control can report a fact.
    model.acceptChange=false
    var injected=false
    let sibling=h.backendSession(m).handleFor(h.runtime.find("toggle").id)
    n.afterEffects=proc(handle:NodeHandle) =
      if handle==key and not injected:
        injected=true
        model.acceptChange=true
        n.checks[sibling]=true
        check a.fact(h,m,"toggle",2,true)
    n.checks[key]=true
    check a.fact(h,m,"check",1,true)
    check h.safeTurn(m)
    check injected and not n.checks[key] and model.calls==1
    check h.safeTurn(m)
    check injected and model.calls==2 and model.accepted.readAccepted()
    h.close()

  test "failed candidate checked writes replay accepted controls before retry":
    let model=Model(acceptChange:true)
    let h=newMobileHost(model.app())
    let n=makeNative()
    let a=newAndroidAdapter(n.platform,DipSize(width:400,height:600))
    let m=h.attach(a.protocol,400,600,1)
    check h.resume(m)
    let s=h.backendSession(m)
    let c=s.handleFor(h.runtime.find("check").id)
    let t=s.handleFor(h.runtime.find("toggle").id)
    let revision=h.runtime.acceptedRevision
    let generation=s.mountGeneration
    n.checks[c]=true
    check a.fact(h,m,"check",1,true)
    n.failApply=true
    discard h.safeTurn(m)
    check not model.accepted.readAccepted() and h.runtime.acceptedRevision==revision
    check not n.checks[c] and not n.checks[t] and not s.faulted
    check s.mountGeneration>generation
    n.failApply=false
    n.checks[c]=true
    check a.fact(h,m,"check",1,true)
    check h.safeTurn(m)
    check model.accepted.readAccepted() and n.checks[c] and n.checks[t]
    h.close()
