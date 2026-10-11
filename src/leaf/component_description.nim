## Immutable host/component descriptions. Erased models remain in Nim; neither
## component definitions nor callbacks are part of the host wire protocol.
import std/[options,tables,sets,macros]
import ./[core,component_state]
export component_state.State,component_state.StateWriteResult,
  component_state.StateEqual,component_state.StateSnapshot

type
  DescriptionKind* {.pure.} = enum host,component
  MountContext* = ref object
    store:StateStore
    owner:uint64
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
  if description.descriptionKind==DescriptionKind.component:description.instanceKey else:description.node.key
proc hostNode*(description:UiDescription):Node=
  if description==nil or description.descriptionKind!=DescriptionKind.host:fail("description is not a host")
  description.node
proc children*(description:UiDescription):seq[UiDescription]=description.nested
proc erased*(description:UiDescription):ErasedComponent=
  if description==nil or description.descriptionKind!=DescriptionKind.component:fail("description is not a component")
  description.instance
proc newMountContext*(store:StateStore,owner:uint64):MountContext=MountContext(store:store,owner:owner)
proc newComponentContext*(store:StateStore,attempt:StateAttempt,owner:uint64,
    invalidateOwner:proc(owner:uint64) {.closure.}=nil):ComponentContext=
  ComponentContext(store:store,attempt:attempt,owner:owner,invalidateOwner:invalidateOwner)
proc state*[T](ctx:MountContext,initial:T,equal:StateEqual[T]=nil,snapshot:StateSnapshot[T]=nil):State[T]=
  if ctx==nil or ctx.store.phase!=StatePhase.initializing:fail("State slots require mount initialization")
  ctx.store.allocateState(ctx.owner,initial,equal,snapshot)
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
    rowHeight=0.0,estimatedHeight=40.0,overscan=2):UiDescription=
  if builder==nil:fail("component list needs a builder")
  let node=core.virtualList(key,keys,proc(index:int):Node=fail("managed rows require a Runtime viewport"),
    rowHeight,estimatedHeight,overscan)
  result=hostShell(node,@[])
  result.rowFactory=builder
proc buildDescriptionRow*(description:UiDescription,index:int):UiDescription=
  if description.rowFactory!=nil:description.rowFactory(index)
  else:host(description.hostNode.listSource.buildRow(index))
proc hostOnly*(description:UiDescription):UiDescription=
  result=hostShell(description.hostNode,@[])
  result.rowFactory=description.rowFactory
