## Immutable host/component descriptions. Erased models remain in Nim; neither
## component definitions nor callbacks are part of the host wire protocol.
import std/[options,tables,sets,macros,unicode]
import ./[core,component_state,task_service,animation_binding]
export component_state.State,component_state.StateWriteResult,
  component_state.StateEqual,component_state.StateSnapshot

type
  DescriptionKind* {.pure.} = enum host,component,pageOutlet
  PageRetention* {.pure.} = enum retainState, disposeOnLeave
  PageOutletSpec* = object
    routerId*: uint64
    page*,view*: string
    retention*: PageRetention
    configurationBytes*: int
    build*: proc():UiDescription {.closure.}
  MountContext* = ref object
    store:StateStore
    owner:uint64
    ownedBytes:int
    sealed:bool
    registration:OwnerRegistration
    animations:seq[AnimationBinding]
    reducedMotion:bool
  ComponentContext* = ref object
    store:StateStore
    attempt:StateAttempt
    owner:uint64
    invalidateOwner:proc(owner:uint64) {.closure.}
  ComponentDef*[P,M] = object
    identity,name:string
    initialize:proc(ctx:MountContext,props:P):M {.closure.}
    compute:proc(ctx:ComponentContext,props:P,model:M):UiDescription {.closure.}
    compare:StateEqual[P]
  StateValueConfig*[T] = object
    initial:T
    equal:StateEqual[T]
    snapshot:StateSnapshot[T]
  ComponentModel* = ref object of RootObj
  ModelBox[M] = ref object of ComponentModel
    value:M
  PropsBase = ref object of RootObj
  PropsBox[P] = ref object of PropsBase
    value:P
  ErasedComponent* = ref object
    identity,name:string
    version:Option[uint64]
    props:PropsBase
    initialize:proc(ctx:MountContext):ComponentModel {.closure.}
    compute:proc(ctx:ComponentContext,model:ComponentModel):UiDescription {.closure.}
    compare:proc(previous:ErasedComponent):bool {.closure.}
  UiDescription* = ref object
    descriptionKind:DescriptionKind
    node:Node
    nested:seq[UiDescription]
    instance:ErasedComponent
    instanceKey:string
    rowFactory:proc(index:int):UiDescription {.closure.}
    outlet:PageOutletSpec

var componentDeclarations {.compileTime.}:Table[string,string]
macro componentIdentity(name:static[string],file:static[string],line,column:static[int],P,M:typedesc):untyped=
  let id=file & "::" & name
  let declaration = $line & ":" & $column & ":" & P.getTypeInst.repr & ":" & M.getTypeInst.repr
  if componentDeclarations.hasKey(id) and componentDeclarations[id]!=declaration:
    error("duplicate component definition name in the same module: " & name)
  componentDeclarations[id]=declaration
  newLit(id)
proc makeComponentDef[P,M](identity,name:string,
    init:proc(ctx:MountContext,props:P):M {.closure.},
    render:proc(ctx:ComponentContext,props:P,model:M):UiDescription {.closure.}):ComponentDef[P,M]=
  if init==nil or render==nil:fail("component needs init and render functions")
  ComponentDef[P,M](identity:identity,name:name,initialize:init,compute:render)
template defineComponent*[P,M](name:static[string],init,render:untyped):untyped=
  block:
    const origin=instantiationInfo(fullPaths=true)
    const identity=componentIdentity(name,origin.filename,origin.line,origin.column,P,M)
    makeComponentDef[P,M](identity,name,init,render)
proc typeId*[P,M](definition:ComponentDef[P,M]):string=definition.identity
proc typeId*(definition:ErasedComponent):string=definition.identity
proc revision*(definition:ErasedComponent):Option[uint64]=definition.version
proc kind*(description:UiDescription):DescriptionKind=description.descriptionKind
proc key*(description:UiDescription):string=
  case description.descriptionKind
  of DescriptionKind.component,DescriptionKind.pageOutlet:description.instanceKey
  of DescriptionKind.host:description.node.key
proc hostNode*(description:UiDescription):Node=
  if description==nil or description.descriptionKind!=DescriptionKind.host:fail("description is not a host")
  description.node
proc children*(description:UiDescription):seq[UiDescription]=description.nested
proc erased*(description:UiDescription):ErasedComponent=
  if description==nil or description.descriptionKind!=DescriptionKind.component:fail("description is not a component")
  description.instance
proc newMountContext*(store:StateStore,owner:uint64,registration:OwnerRegistration=nil,reducedMotion=false):MountContext=
  if registration!=nil:registration.requireOwnerRegistrationInternal(store,owner)
  MountContext(store:store,owner:owner,registration:registration,reducedMotion:reducedMotion)
proc lifecycleRegistrationInternal*(ctx:MountContext):OwnerRegistration=
  if ctx==nil:fail("missing mount context")
  if ctx.sealed:fail("mount context is already closed")
  ctx.registration.requireOwnerRegistrationInternal(ctx.store,ctx.owner)
  ctx.registration
proc newComponentContext*(store:StateStore,attempt:StateAttempt,owner:uint64,
    invalidateOwner:proc(owner:uint64) {.closure.}=nil):ComponentContext=
  ComponentContext(store:store,attempt:attempt,owner:owner,invalidateOwner:invalidateOwner)
proc accountOwnedDescriptionBytes*(ctx: MountContext, bytes: int) =
  ## Initialization-only charge for configuration/description bytes owned by the
  ## component being mounted. Subtraction keeps the check overflow-free. A
  ## context closed when its initializer returned can never charge again, even
  ## while another owner's initialization keeps the store phase open.
  if ctx == nil: fail("missing mount context")
  if ctx.sealed: fail("mount context is already closed")
  requireInitializing(ctx.store)
  if bytes < 0: fail("owned description bytes cannot be negative")
  if bytes > MaxTreeBytes - ctx.ownedBytes:
    fail("owned description bytes exceed 16 MiB")
  ctx.ownedBytes += bytes
proc sealMountContext*(ctx: MountContext) =
  ## Runtime-internal: close this initialization frame on both the success and
  ## the exception exit of the initializer.
  if ctx != nil:
    ctx.sealed = true
    sealOwnerRegistration(ctx.registration)
proc ownedDescriptionBytes*(ctx: MountContext): int =
  ## Read-only accumulated owner cost, usable after initialization returns.
  if ctx == nil: return 0
  ctx.ownedBytes
proc reducedMotionInternal*(ctx:MountContext):bool=ctx!=nil and ctx.reducedMotion
proc animationBindingsInternal*(ctx:MountContext):seq[AnimationBinding]=
  if ctx!=nil:result=ctx.animations
proc registerAnimationInternal*(ctx:MountContext,binding:AnimationBinding)=
  ctx.accountOwnedDescriptionBytes(512)
  if ctx.animations.len>=MaxNodes:fail("component exceeds animation binding limit")
  ctx.animations.add(binding)
proc ownsAnimationStateInternal*[T](ctx:MountContext,state:State[T]):bool=
  ctx!=nil and stateOwnerMatches(state,ctx.store,ctx.owner)
proc ownsState*[T](ctx: ComponentContext, state: State[T]): bool =
  ## Internal context/owner validation; excluded from the components aggregate.
  if ctx == nil: return false
  stateOwnerMatches(state, ctx.store, ctx.owner)
proc validOutletString(value, what: string) =
  if value.len > MaxStringBytes: fail(what & " exceeds 1 MiB")
  if validateUtf8(value) != -1: fail(what & " is not valid UTF-8")
proc pageOutlet*(spec: PageOutletSpec, key = ""): UiDescription =
  ## Low-level outlet entry; not part of the components aggregate.
  if spec.routerId == 0: fail("page outlet requires a nonzero router identity")
  validOutletString(spec.page, "page outlet page")
  if spec.page.len == 0: fail("page outlet requires a page name")
  validOutletString(spec.view, "page outlet view")
  if spec.view.len == 0: fail("page outlet requires a view name")
  if spec.configurationBytes < 0: fail("page outlet configuration bytes cannot be negative")
  if spec.configurationBytes > MaxTreeBytes: fail("page outlet configuration bytes exceed 16 MiB")
  if spec.build == nil: fail("page outlet requires a page build")
  if key.len > 0: validOutletString(key, "page outlet key")
  UiDescription(descriptionKind: DescriptionKind.pageOutlet, outlet: spec, instanceKey: key)
proc outletSpec*(description: UiDescription): PageOutletSpec =
  if description == nil or description.descriptionKind != DescriptionKind.pageOutlet:
    fail("description is not a page outlet")
  description.outlet
proc state*[T](ctx:MountContext,initial:T,equal:StateEqual[T]=nil,snapshot:StateSnapshot[T]=nil):State[T]=
  if ctx==nil or ctx.store.phase!=StatePhase.initializing:fail("State slots require mount initialization")
  ctx.store.allocateState(ctx.owner,initial,equal,snapshot)
proc stateValue*[T](initial:T,snapshot:StateSnapshot[T]=nil,
    equal:StateEqual[T]=nil):StateValueConfig[T]=
  ## Explicit ownership policy for managed variables with mutable values.
  StateValueConfig[T](initial:initial,snapshot:snapshot,equal:equal)

proc managedStateInternal*[T](ctx:MountContext,initial:T):State[T]=
  if ctx==nil or ctx.store.phase!=StatePhase.initializing:
    fail("managed variables require mount initialization")
  when compiles(initial==initial):
    ctx.store.allocateManagedState(ctx.owner,initial,equal=proc(a,b:T):bool=a==b)
  else:
    ctx.store.allocateManagedState(ctx.owner,initial)

proc managedStateInternal*[T](ctx:MountContext,config:StateValueConfig[T]):State[T]=
  if ctx==nil or ctx.store.phase!=StatePhase.initializing:
    fail("managed variables require mount initialization")
  ctx.store.allocateManagedState(ctx.owner,config.initial,config.equal,config.snapshot)

proc componentInstanceInternal*[P,M](definition:ComponentDef[P,M],props:P,key="",
    revision:Option[uint64]=none(uint64)):UiDescription

proc set*[T](state:State[T],value:T):StateWriteResult {.discardable.}=state.queueSet(value)
proc update*[T](state:State[T],f:proc(previous:T):T {.closure.}):StateWriteResult {.discardable.}=state.queueUpdate(f)
proc read*[T](state:State[T]):T=state.readAccepted()
proc value*[T](ctx:ComponentContext,state:State[T]):T=
  if ctx==nil or ctx.store.phase!=StatePhase.rendering:fail("candidate State reads require render context")
  ctx.attempt.readCandidate(state)
proc invalidate*(ctx:ComponentContext)=
  if ctx==nil or ctx.invalidateOwner==nil:fail("component has no active runtime")
  ctx.store.requireIdle()
  ctx.invalidateOwner(ctx.owner)
proc component*[P,M](definition:ComponentDef[P,M],props:P,key="",
    revision:Option[uint64]=none(uint64)):UiDescription=
  let erased=ErasedComponent(identity:definition.identity,name:definition.name,version:revision,props:PropsBox[P](value:props))
  erased.initialize=proc(ctx:MountContext):ComponentModel=ModelBox[M](value:definition.initialize(ctx,props))
  erased.compute=proc(ctx:ComponentContext,model:ComponentModel):UiDescription=
    if not (model of ModelBox[M]):fail("component model type mismatch")
    definition.compute(ctx,props,ModelBox[M](model).value)
  erased.compare=proc(previous:ErasedComponent):bool=
    if previous==nil or previous.identity!=definition.identity:return false
    if revision.isSome or previous.version.isSome:
      return revision.isSome and previous.version.isSome and revision==previous.version
    if definition.compare==nil or not (previous.props of PropsBox[P]):return false
    definition.compare(PropsBox[P](previous.props).value,props)
  UiDescription(descriptionKind:DescriptionKind.component,instance:erased,instanceKey:key)
proc componentInstanceInternal*[P,M](definition:ComponentDef[P,M],props:P,key="",
    revision:Option[uint64]=none(uint64)):UiDescription=
  component(definition,props,key,revision)

proc memo*[P,M](definition:ComponentDef[P,M],compare:StateEqual[P]):ComponentDef[P,M]=
  if compare==nil:fail("memo needs a safe props comparator")
  result=definition
  result.compare=compare
proc equalProps*(definition,previous:ErasedComponent):bool=definition.compare(previous)
proc instantiate*(definition:ErasedComponent,ctx:MountContext):ComponentModel=definition.initialize(ctx)
proc render*(definition:ErasedComponent,ctx:ComponentContext,model:ComponentModel):UiDescription=
  result=definition.compute(ctx,model)
  if result==nil:fail("component must return one root description")
proc hostShell*(node:Node,children:seq[UiDescription]):UiDescription=
  if node==nil:fail("nil host description")
  var keys:HashSet[string]
  for child in children:
    if child==nil:fail("nil child description")
    let key=child.key
    if key.len>0:
      if key in keys:fail("duplicate sibling key: " & key)
      keys.incl(key)
  UiDescription(descriptionKind:DescriptionKind.host,node:node,nested:children)
proc host*(node:Node):UiDescription=
  if node==nil:fail("nil host description")
  var children:seq[UiDescription]
  for child in node.children:children.add(host(child))
  hostShell(node,children)
proc toDescription*(node:Node):UiDescription=host(node)
proc toDescription*(description:UiDescription):UiDescription=description

proc componentList*(key:string,keys:seq[string],builder:proc(index:int):UiDescription {.closure.},
    rowHeight=0.0,estimatedHeight=40.0,overscan=2,styles:Styles=default(Styles)):UiDescription=
  if builder==nil:fail("component list needs a builder")
  let node=virtualList(key,keys,proc(index:int):Node=fail("managed rows require a Runtime viewport"),
    rowHeight,estimatedHeight,overscan,styles)
  result=hostShell(node,@[])
  result.rowFactory=builder
proc buildDescriptionRow*(description:UiDescription,index:int):UiDescription=
  if description.rowFactory!=nil:description.rowFactory(index)
  else:host(description.hostNode.listSource.buildRow(index))
proc hostOnly*(description:UiDescription):UiDescription=
  result=hostShell(description.hostNode,@[])
  result.rowFactory=description.rowFactory
