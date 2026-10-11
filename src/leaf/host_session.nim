## One owner-bound, synchronous commit consumer. prepare/apply may fail;
## accept/discard publish metadata only and may not invoke application code.
import std/options
import ./[core, backend, host_reconcile]
export host_reconcile

type
  HostConsumer* = ref object
    sessionId*: uint64
    prepare*: proc(batch:HostBatch) {.closure.}
    apply*: proc() {.closure.}
    accept*: proc(revision:uint64) {.closure,raises:[].}
    discardPrepared*: proc() {.closure,raises:[].}
    lease: uint64
  HostSession* = ref object
    runtime*: Runtime
    reconciler: HostReconciler
    consumer: HostConsumer
    token,lease,lastSequence:uint64
    pending:HostCandidate
    closing,disposed:bool
var nextLease:uint64
proc revision*(session:HostSession):uint64=session.reconciler.revision
proc sessionId*(session:HostSession):uint64=session.consumer.sessionId
proc handleFor*(session:HostSession,id:string):NodeHandle=session.reconciler.handleFor(id)
proc record*(session:HostSession,handle:NodeHandle):Option[HostRecord]=session.reconciler.record(handle)
proc alive(session:HostSession):bool =
  not session.disposed and not session.closing and session.consumer.lease==session.lease
proc requestClose*(session:HostSession)=session.closing=true
proc dropPending(session:HostSession) {.raises:[].} =
  if session.pending!=nil:
    session.consumer.discardPrepared()
    session.pending=nil
proc acceptPending(session:HostSession) {.raises:[].} =
  let candidate=session.pending
  session.consumer.accept(candidate.batch.nextRevision)
  session.reconciler.publish(candidate)
  session.pending=nil
proc commit(session:HostSession,accepted,candidate:Runtime)=
  if not session.alive:fail("host session is closing")
  let revision=if candidate.proposedRevision!=0:candidate.proposedRevision else:candidate.acceptedRevision
  let plan=session.reconciler.planSnapshot(candidate.snapshot,revision,gpuiCompatible)
  session.reconciler.validate(plan)
  session.pending=plan
  try:
    session.consumer.prepare(plan.batch)
    if not session.alive:fail("host session closed after prepare")
    session.consumer.apply()
    if not session.alive:fail("host session closed after apply")
  except CatchableError:
    session.dropPending()
    raise
  if not candidate.installingHook:session.acceptPending()
proc close*(session:HostSession)=
  if session==nil or session.disposed:return
  if session.runtime.installingUpdate:fail("cannot close host during update; retry at a safe boundary")
  session.closing=true
  session.runtime.clearCommitter(session.token)
  session.dropPending()
  if session.consumer.lease==session.lease:session.consumer.lease=0
  session.disposed=true
proc retire*(session:HostSession) {.raises:[].} =
  ## Terminal renderer lifetime has ended; release only framework ownership.
  if session==nil or session.disposed:return
  session.closing=true
  session.runtime.retireCommitterOwner(session.token)
  session.dropPending()
  if session.consumer.lease==session.lease:session.consumer.lease=0
  session.disposed=true
proc attachHostSession*(runtime:Runtime,consumer:HostConsumer):HostSession=
  if runtime==nil or consumer==nil or consumer.sessionId==0 or consumer.prepare==nil or
      consumer.apply==nil or consumer.accept==nil or consumer.discardPrepared==nil:
    fail("incomplete host consumer")
  if consumer.lease!=0:fail("host consumer already owned")
  if runtime.committerOwner!=0:fail("runtime committer already installed")
  inc nextLease
  let session=HostSession(runtime:runtime,consumer:consumer,lease:nextLease,
    reconciler:newHostReconciler(consumer.sessionId))
  consumer.lease=session.lease
  try:
    session.token=runtime.installCommitter(proc(accepted,candidate:Runtime)=session.commit(accepted,candidate),
      RuntimeInstallLifecycle(
        confirm:proc()=
          if not session.alive:fail("host session closed during installation")
          session.acceptPending(),
        abort:proc(scoped:bool)=session.dropPending()))
  except CatchableError:
    session.dropPending()
    if consumer.lease==session.lease:consumer.lease=0
    session.disposed=true
    raise
  session
proc dispatch*(session:HostSession,handle:NodeHandle,sequence,observedRevision,generation,binding:uint64,event:Event):bool=
  if not session.alive or generation!=1 or binding!=1 or sequence<=session.lastSequence or
      observedRevision>session.runtime.acceptedRevision:return false
  let record=session.record(handle)
  if record.isNone:return false
  session.lastSequence=sequence
  session.runtime.dispatch(record.get.nodeId,event)
