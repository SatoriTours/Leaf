## Typed State cells with sealed, synchronous update queues. Only accepted
## values escape via read; candidate reads use the caller's snapshot policy.
import std/[tables, sets, macros]
import ./[core, commit_map]

type
  StateWriteResult* {.pure.} = enum queued, disposed
  StatePhase* {.pure.} = enum idle, initializing, rendering, updating, committing
  StateEqual*[T] = proc(a,b:T):bool {.closure.}
  StateSnapshot*[T] = proc(value:T):T {.closure.}
  StateUpdate[T] = proc(value:T):T {.closure.}
  StateStore* = ref object
    runtimeId, nextId, generation:uint64
    threadId:int
    phase:StatePhase
    cells:CommitMap[uint64,CellBase]
    owners:CommitMap[uint64,seq[uint64]]
    queued:seq[uint64]
    queuedSet:HashSet[uint64]
    active:StateAttempt
  State*[T] = object
    store:StateStore
    owner,id,generation:uint64
  StateAttempt* = ref object
    store:StateStore
    generation:uint64
    edits:Table[uint64,CandidateBase]
    dirty:seq[uint64]
  CellBase = ref object of RootObj
    id,owner,generation:uint64
    disposed:bool
    stage:proc(base:CellBase):CandidateBase {.closure.}
    clear:proc(base:CellBase) {.closure,raises:[].}
  StateCell[T] = ref object of CellBase
    accepted:T
    updates:seq[StateUpdate[T]]
    equal:StateEqual[T]
    snapshot:StateSnapshot[T]
  CandidateBase = ref object of RootObj
    owner:uint64
    changed:bool
    publish:proc(base:CandidateBase) {.closure,raises:[].}
    finish:proc(base:CandidateBase) {.closure,raises:[].}
  StateCandidate[T] = ref object of CandidateBase
    cell:StateCell[T]
    value:T
    retired:T
  PreparedOwnerDisposal* = ref object
    ## Prepared owner teardown: cells/registration leave the accepted maps in
    ## publication, but their values and State destructors wait for finish.
    store:StateStore
    owner:uint64
    ids:seq[uint64]
    cells:seq[CellBase]
    cellPatch:PreparedMapPatch[uint64,CellBase]
    ownerPatch:PreparedMapPatch[uint64,seq[uint64]]
    published:bool

proc uiThread(store:StateStore)=
  if store==nil:fail("missing State runtime")
  when compileOption("threads"):
    if store.threadId!=getThreadId():fail("State access requires its UI thread")
proc newStateStore*(runtimeId:uint64):StateStore=
  if runtimeId==0:fail("State runtime identity must be nonzero")
  result=StateStore(runtimeId:runtimeId,nextId:1,
    cells:initCommitMap[uint64,CellBase](runtimeId),
    owners:initCommitMap[uint64,seq[uint64]](runtimeId))
  when compileOption("threads"):result.threadId=getThreadId()
proc setPhase*(store:StateStore,phase:StatePhase)=
  store.uiThread()
  store.phase=phase
proc phase*(store:StateStore):StatePhase=store.phase
proc requireIdle*(store:StateStore)=
  store.uiThread()
  if executionRuntimeIdentity()!=0 and executionRuntimeIdentity()!=store.runtimeId:
    fail("State belongs to another executing Runtime")
  if store.phase!=StatePhase.idle or store.active!=nil:fail("cannot queue during component computation or commit")
proc requireInitializing*(store:StateStore)=
  ## Owner-accounting guard: UI thread and initializing phase. A normal component
  ## initialization runs inside an active StateAttempt, which is allowed here.
  store.uiThread()
  if store.phase!=StatePhase.initializing:
    fail("owned description bytes require component initialization")
proc dirtyOwners*(attempt:StateAttempt):seq[uint64]=attempt.dirty
proc pendingOwners*(store:StateStore):seq[uint64]=
  store.uiThread()
  var seen:HashSet[uint64]
  for id in store.queued:
    let cell=store.cells.getOrDefault(id)
    if cell!=nil and not cell.disposed and cell.owner notin seen:
      seen.incl(cell.owner);result.add(cell.owner)
proc needsSnapshot[T](_:typedesc[T]):bool
macro objectNeedsSnapshot(T:typedesc):untyped =
  var impl=T.getTypeImpl
  if impl.kind==nnkBracketExpr:impl=impl[1].getTypeImpl
  var fields:seq[NimNode]
  proc collect(node:NimNode)=
    if node.kind==nnkIdentDefs:
      fields.add(node[^2])
    elif node.kind==nnkOfInherit:
      for base in node:fields.add(base)
    else:
      for child in node:collect(child)
  collect(impl)
  result=newLit(false)
  for field in fields:
    result=newTree(nnkInfix,ident"or",result,newCall(bindSym"needsSnapshot",newTree(nnkBracketExpr,ident"typedesc",field)))
proc needsSnapshot[T](_:typedesc[T]):bool=
  when T is string: false
  elif T is ref or T is ptr or T is pointer or T is seq or T is proc or T is cstring: true
  elif T is object:objectNeedsSnapshot(T)
  elif T is tuple:
    var value:T
    for name,field in fieldPairs(value):
      if needsSnapshot(typeof(field)):return true
    false
  elif T is array:
    var value:T
    for field in value:
      if needsSnapshot(typeof(field)):return true
    false
  else:false
proc copied[T](cell:StateCell[T],value:T):T=
  if cell.snapshot==nil:value else:cell.snapshot(value)
proc allocateState*[T](store:StateStore,owner:uint64,initial:T,
    equal:StateEqual[T]=nil,snapshot:StateSnapshot[T]=nil):State[T]=
  store.uiThread()
  if owner==0:fail("State owner must be nonzero")
  if store.phase notin {StatePhase.idle,StatePhase.initializing}:fail("State allocation outside initialization")
  if snapshot==nil and needsSnapshot(T):fail("mutable State requires an explicit snapshot policy")
  if store.nextId==high(uint64):fail("State identity space exhausted")
  let id=store.nextId
  inc store.nextId
  let cell=StateCell[T](id:id,owner:owner,generation:id,equal:equal,snapshot:snapshot)
  cell.accepted=cell.copied(initial)
  cell.clear=proc(base:CellBase) {.raises:[].}=StateCell[T](base).updates.setLen(0)
  cell.stage=proc(base:CellBase):CandidateBase=
    let cell=StateCell[T](base)
    let updates=move(cell.updates)
    var candidate=StateCandidate[T](owner:cell.owner,cell:cell,value:cell.copied(cell.accepted))
    for update in updates:candidate.value=update(candidate.value)
    candidate.changed=cell.equal==nil or not cell.equal(cell.copied(cell.accepted),cell.copied(candidate.value))
    candidate.publish=proc(base:CandidateBase) {.raises:[].}=
      # Publish only swaps values: the replaced accepted value waits in the
      # candidate until the whole Runtime commit is accepted.
      let candidate=StateCandidate[T](base)
      if not candidate.cell.disposed:
        candidate.retired=move(candidate.cell.accepted)
        candidate.cell.accepted=move(candidate.value)
    candidate.finish=proc(base:CandidateBase) {.raises:[].}=
      let candidate=StateCandidate[T](base)
      candidate.retired=default(T)
      candidate.value=default(T)
    candidate
  store.cells.putOutsideCommit(id,cell)
  var owned=store.owners.getOrDefault(owner)
  owned.add(id)
  store.owners.putOutsideCommit(owner,move(owned))
  State[T](store:store,owner:owner,id:id,generation:cell.generation)
proc cellFor[T](state:State[T]):StateCell[T]=
  state.store.uiThread()
  let cell=state.store.cells.getOrDefault(state.id)
  if cell==nil or cell.disposed or cell.owner!=state.owner or cell.generation!=state.generation:return nil
  if not (cell of StateCell[T]):fail("State slot type mismatch")
  StateCell[T](cell)
proc stateAlive*[T](state:State[T]):bool=
  ## Internal validity query: the handle still names a live slot in its store.
  if state.store==nil:return false
  state.cellFor()!=nil
proc requireStateExecution*[T](state:State[T])=
  ## Internal guard for auxiliary controller facts that do not queue State.
  ## They may arrive during a commit, but cannot act for a foreign Runtime.
  if state.store==nil:fail("missing State runtime")
  state.store.uiThread()
  if executionRuntimeIdentity()!=0 and executionRuntimeIdentity()!=state.store.runtimeId:
    fail("State belongs to another executing Runtime")
proc stateOwnerMatches*[T](state:State[T],store:StateStore,owner:uint64):bool=
  ## Internal ownership query for runtime and context validation only.
  if store==nil or owner==0 or state.store==nil:return false
  store.uiThread()
  state.store==store and state.owner==owner and state.cellFor()!=nil
proc writable[T](state:State[T]):StateCell[T]=
  result=state.cellFor()
  if result==nil:return
  if executionRuntimeIdentity()!=0 and executionRuntimeIdentity()!=state.store.runtimeId:
    fail("State belongs to another executing Runtime")
  if state.store.phase!=StatePhase.idle or state.store.active!=nil:
    fail("State writes are forbidden during initialization, render, updater or commit")
proc markQueued[T](state:State[T])=
  if state.id notin state.store.queuedSet:
    state.store.queuedSet.incl(state.id)
    state.store.queued.add(state.id)
proc queueSet*[T](state:State[T],value:T):StateWriteResult=
  let cell=state.writable()
  if cell==nil:return StateWriteResult.disposed
  let captured=cell.copied(value)
  let policy=cell.snapshot
  cell.updates.add(proc(previous:T):T=
    if policy==nil:captured else:policy(captured))
  state.markQueued()
  StateWriteResult.queued
proc queueUpdate*[T](state:State[T],f:proc(previous:T):T {.closure.}):StateWriteResult=
  let cell=state.writable()
  if cell==nil:return StateWriteResult.disposed
  if f==nil:fail("missing State updater")
  cell.updates.add(f)
  state.markQueued()
  StateWriteResult.queued
proc readAccepted*[T](state:State[T]):T=
  let cell=state.cellFor()
  if cell==nil:fail("disposed State handle")
  cell.copied(cell.accepted)
proc validateAttempt*(store:StateStore,attempt:StateAttempt)=
  store.uiThread()
  if attempt==nil or attempt.store!=store:fail("foreign State attempt")
  if attempt.generation!=store.generation or store.active!=attempt:fail("stale State attempt")
proc clearQueued*(store:StateStore) {.raises:[].}=
  for id in store.queued:
    let cell=store.cells.getOrDefault(id)
    if cell!=nil:cell.clear(cell)
  store.queued.setLen(0);store.queuedSet.clear()
proc rejectAttempt*(store:StateStore,attempt:StateAttempt) {.raises:[].}=
  if store.active==attempt:
    store.active=nil
    inc store.generation
proc beginAttempt*(store:StateStore):StateAttempt=
  store.uiThread()
  if store.active!=nil:fail("State attempt already active")
  if store.phase!=StatePhase.idle:fail("cannot begin State attempt during computation")
  let sealed=move(store.queued)
  store.queuedSet.clear()
  let attempt=StateAttempt(store:store,generation:store.generation)
  store.active=attempt
  let previous=store.phase
  store.phase=StatePhase.updating
  try:
    var owners:HashSet[uint64]
    for id in sealed:
      let cell=store.cells.getOrDefault(id)
      if cell==nil or cell.disposed:continue
      let candidate=cell.stage(cell)
      attempt.edits[id]=candidate
      if candidate.changed and candidate.owner notin owners:
        owners.incl(candidate.owner);attempt.dirty.add(candidate.owner)
    result=attempt
  except CatchableError:
    # Consume every sealed owner, including cells not yet evaluated. Retrying a
    # rejected event may never replay an updater or its ordinary side effects.
    for id in sealed:
      let cell=store.cells.getOrDefault(id)
      if cell!=nil:cell.clear(cell)
    store.rejectAttempt(attempt)
    raise
  finally:store.phase=previous
proc readCandidate*[T](attempt:StateAttempt,state:State[T]):T=
  if attempt==nil or attempt.store!=state.store:fail("State belongs to another runtime")
  state.store.validateAttempt(attempt)
  let cell=state.cellFor()
  if cell==nil:fail("disposed State handle")
  let candidate=attempt.edits.getOrDefault(state.id)
  if candidate==nil:return cell.copied(cell.accepted)
  if not (candidate of StateCandidate[T]):fail("State candidate type mismatch")
  cell.copied(StateCandidate[T](candidate).value)
proc publishAttempt*(store:StateStore,attempt:StateAttempt) {.raises:[].}=
  # Validate before external host apply; this publication calls no updater,
  # equality comparator, snapshot policy or application callback.
  for candidate in attempt.edits.values:candidate.publish(candidate)
  store.active=nil
  inc store.generation
proc accept*(store:StateStore,attempt:StateAttempt)=
  store.validateAttempt(attempt)
  store.publishAttempt(attempt)
proc reject*(store:StateStore,attempt:StateAttempt)=
  store.validateAttempt(attempt)
  store.rejectAttempt(attempt)
proc prepareDisposeOwner*(store:StateStore,owner:uint64):PreparedOwnerDisposal=
  ## Prepare-only: collects the owner's cells and sizes both accepted maps.
  if owner==0:fail("State owner must be nonzero")
  let ids=store.owners.getOrDefault(owner)
  var cells:seq[CellBase]
  for id in ids:
    let cell=store.cells.getOrDefault(id)
    if cell!=nil:cells.add(cell)
  let cellLimit=max(MaxNodes*4,store.cells.len)
  let ownerLimit=max(MaxNodes*2,store.owners.len)
  result=PreparedOwnerDisposal(store:store,owner:owner,ids:ids,cells:cells,
    cellPatch:store.cells.preparePatch(ids,newSeq[(uint64,CellBase)](),cellLimit),
    ownerPatch:store.owners.preparePatch(@[owner],newSeq[(uint64,seq[uint64])](),ownerLimit))

proc prepareDisposeOwners*(store:StateStore,owners:seq[uint64]):PreparedOwnerDisposal=
  ## One prepared teardown for every owner leaving in this commit. A single
  ## patch per accepted map is required because each publication advances the
  ## map generation; separate plans would invalidate each other.
  var ids:seq[uint64]
  var cells:seq[CellBase]
  var ownerRemovals:seq[uint64]
  for owner in owners:
    if owner==0:continue
    ownerRemovals.add(owner)
    for id in store.owners.getOrDefault(owner):
      ids.add(id)
      let cell=store.cells.getOrDefault(id)
      if cell!=nil:cells.add(cell)
  let cellLimit=max(MaxNodes*4,store.cells.len)
  let ownerLimit=max(MaxNodes*2,store.owners.len)
  result=PreparedOwnerDisposal(store:store,owner:(if owners.len>0:owners[0] else:0),
    ids:ids,cells:cells,
    cellPatch:store.cells.preparePatch(ids,newSeq[(uint64,CellBase)](),cellLimit),
    ownerPatch:store.owners.preparePatch(ownerRemovals,newSeq[(uint64,seq[uint64])](),ownerLimit))

proc publishDisposeOwner*(plan:PreparedOwnerDisposal) {.raises:[].}=
  ## Publication phase: mark disposed and move accepted cells/owners out. No
  ## State value destructor or owner-provided update closure runs here.
  if plan==nil or plan.published:return
  for cell in plan.cells:cell.disposed=true
  for id in plan.ids:plan.store.queuedSet.excl(id)
  plan.store.cells.publishValidated(plan.cellPatch)
  plan.store.owners.publishValidated(plan.ownerPatch)
  plan.published=true

proc finishDisposeOwner*(plan:PreparedOwnerDisposal) {.raises:[].}=
  ## Whole commit accepted: release retired cells (including accepted values).
  if plan==nil:return
  for cell in plan.cells:cell.clear(cell)
  finishPublished(plan.cellPatch)
  finishPublished(plan.ownerPatch)
  plan.cells.setLen(0)
  plan.ids.setLen(0)

proc validateDisposeOwner*(plan:PreparedOwnerDisposal)=
  ## Apply-time validation for a prepared owner teardown.
  if plan==nil or plan.published:return
  if plan.cellPatch!=nil:plan.store.cells.validatePrepared(plan.cellPatch)
  if plan.ownerPatch!=nil:plan.store.owners.validatePrepared(plan.ownerPatch)

proc discardDisposeOwner*(plan:PreparedOwnerDisposal) {.raises:[].}=
  if plan==nil or plan.published:return
  discardPrepared(plan.cellPatch)
  discardPrepared(plan.ownerPatch)

proc disposeOwner*(store:StateStore,owner:uint64) {.raises:[].}=
  ## Teardown/rollback entry point. The prepared path is used when sizing
  ## succeeds; the direct fallback only exists because this seam predates
  ## patch preparation and must stay non-raising for rollback callers.
  var plan:PreparedOwnerDisposal
  try:
    plan=store.prepareDisposeOwner(owner)
  except UiError:
    plan=nil
  if plan!=nil:
    publishDisposeOwner(plan)
    finishDisposeOwner(plan)
  else:
    for id in store.owners.getOrDefault(owner):
      let cell=store.cells.getOrDefault(id)
      if cell!=nil:
        cell.disposed=true
        cell.clear(cell)
      store.cells.removeOutsideCommit(id)
      store.queuedSet.excl(id)
    store.owners.removeOutsideCommit(owner)

proc finishAttempt*(store:StateStore,attempt:StateAttempt) {.raises:[].}=
  ## Accepted commit boundary: release the values replaced by publication.
  if attempt==nil:return
  for candidate in attempt.edits.values:candidate.finish(candidate)
  attempt.edits.clear()
