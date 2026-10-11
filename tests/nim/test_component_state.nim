import std/unittest
import leaf/[core, component_state]
type Shared = ref object
  value:int
proc clone(value:Shared):Shared=Shared(value:value.value)
proc increment(value:int):int=value+1
suite "transactional component State":
  test "set replaces, update folds, accepted read is isolated":
    let store=newStateStore(1)
    let s=store.allocateState(10,0)
    for i in 0..<3:check s.queueSet(1)==StateWriteResult.queued
    let first=store.beginAttempt()
    check s.readAccepted()==0
    check first.readCandidate(s)==1
    store.accept(first)
    check s.readAccepted()==1
    let other=store.allocateState(11,0)
    for i in 0..<3:discard other.queueUpdate(increment)
    let candidate=store.beginAttempt()
    check other.readAccepted()==0
    check candidate.readCandidate(other)==3
    store.reject(candidate)
    check other.readAccepted()==0
    let retry=store.beginAttempt()
    check retry.readCandidate(other)==0
    store.accept(retry)
  test "failed updater consumes the whole sealed batch without replay":
    let store=newStateStore(1)
    let first=store.allocateState(1,0)
    let second=store.allocateState(2,0)
    discard first.queueUpdate(increment)
    discard second.queueUpdate(proc(value:int):int=raise newException(UiError,"updater failed"))
    expect UiError:discard store.beginAttempt()
    check first.readAccepted()==0
    check second.readAccepted()==0
    let next=store.beginAttempt()
    check next.readCandidate(first)==0
    check next.readCandidate(second)==0
    store.accept(next)
  test "disposed identities do not resurrect and cross runtime reads fail":
    let store=newStateStore(1)
    let other=newStateStore(2)
    let old=store.allocateState(1,0)
    store.disposeOwner(1)
    let fresh=store.allocateState(1,10)
    check old.queueSet(5)==StateWriteResult.disposed
    check fresh.readAccepted()==10
    let candidate=other.beginAttempt()
    expect UiError:discard candidate.readCandidate(fresh)
    other.reject(candidate)
  test "initialization, render and updater writes are rejected":
    let store=newStateStore(1)
    let s=store.allocateState(1,0)
    for phase in [StatePhase.initializing,StatePhase.rendering,StatePhase.updating,StatePhase.committing]:
      store.setPhase(phase)
      expect UiError:discard s.queueSet(1)
    store.setPhase(StatePhase.idle)
    discard s.queueUpdate(proc(value:int):int=
      discard s.queueSet(7)
      value+1)
    expect UiError:discard store.beginAttempt()
    check s.readAccepted()==0
  test "mutable references require explicit snapshots and never leak":
    let store=newStateStore(1)
    expect UiError:discard store.allocateState(1,Shared(value:0))
    let original=Shared(value:0)
    let s=store.allocateState(1,original,snapshot=clone)
    original.value=99
    check s.readAccepted().value==0
    discard s.queueUpdate(proc(value:Shared):Shared=
      value.value=4
      value)
    let candidate=store.beginAttempt()
    check candidate.readCandidate(s).value==4
    check s.readAccepted().value==0
    var escaped=candidate.readCandidate(s)
    escaped.value=100
    check candidate.readCandidate(s).value==4
    store.reject(candidate)
    check s.readAccepted().value==0
  test "equal scalar skips owner invalidation, missing equal stays conservative":
    let store=newStateStore(1)
    let s=store.allocateState(1,0,equal=proc(a,b:int):bool=a==b)
    discard s.queueSet(0)
    let candidate=store.beginAttempt()
    check candidate.dirtyOwners.len==0
    store.accept(candidate)
    let conservative=store.allocateState(2,0)
    discard conservative.queueSet(0)
    let next=store.beginAttempt()
    check next.dirtyOwners== @[2'u64]
    store.accept(next)
  test "equality policy receives isolated snapshots too":
    let store=newStateStore(1)
    let s=store.allocateState(1,Shared(value:0),snapshot=clone,
      equal=proc(a,b:Shared):bool=
        a.value=99
        b.value=100
        false)
    discard s.queueSet(Shared(value:3))
    let candidate=store.beginAttempt()
    check s.readAccepted().value==0
    check candidate.readCandidate(s).value==3
    store.reject(candidate)
  test "inactive variant branches cannot hide mutable reference types":
    type Variant=object
      case hasReference:bool
      of false:number:int
      of true:shared:Shared
    let store=newStateStore(1)
    expect UiError:discard store.allocateState(1,Variant(hasReference:false,number:0))
  test "value objects including variant strings remain safe by default":
    type Value=object
      case textMode:bool
      of true:label:string
      of false:number:int
    let store=newStateStore(1)
    let s=store.allocateState(1,Value(textMode:true,label:"中文"))
    discard s.queueSet(Value(textMode:false,number:3))
    let candidate=store.beginAttempt()
    check s.readAccepted().label=="中文"
    store.accept(candidate)
    check s.readAccepted().number==3
when compileOption("threads"):
  type ThreadArgs=object
    state:ptr State[int]
    rejected:ptr bool
  proc foreignWrite(args:ThreadArgs) {.thread.}=
    try:discard args.state[].queueSet(1)
    except UiError:args.rejected[]=true
  suite "State UI thread affinity":
    test "non UI thread cannot queue updates":
      let store=newStateStore(1)
      var state=store.allocateState(1,0)
      var rejected=false
      var thread:Thread[ThreadArgs]
      createThread(thread,foreignWrite,ThreadArgs(state:addr state,rejected:addr rejected))
      joinThread(thread)
      check rejected
      check state.readAccepted()==0
