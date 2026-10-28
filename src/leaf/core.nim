## Immutable UI descriptions. Application state belongs to native Nim objects;
## callbacks are published only after a complete, validated render succeeds.
import std/[tables, sets, json, math, unicode, algorithm, options]
import ./diagnostics
import ./task_contracts
import ./navigation_protocol
import ./native_theme
import ./graphics
import ./canvas_input
import ./animation_binding
from ./animation import MotionPolicy

const
  MaxNodes* = 10_000
  MaxDepth* = 64
  MaxStringBytes* = 1_048_576
  MaxTreeBytes* = 16_777_216
  MaxListItems* = 100_000

type
  UiError* = object of CatchableError
  NodeKind* = enum
    column, row, text, button, input, checkbox, toggle, progress, tag,
    separator, spinner, virtualList, navigation, canvasHost
  EventKind* = enum
    click, change, submit, back, canvasInput
  CompositionPhase* = enum
    ## Additive native IME/editing phase metadata. `compositionNone` is the
    ## default so existing events and JSON are unchanged.
    compositionNone, compositionStart, compositionUpdate, compositionResult,
    compositionEnd
  Event* = object
    kind*: EventKind
    value*: string
    checked*: bool
    composition*: CompositionPhase
    navigationRequestId*: uint64
    canvas*: CanvasDelivery
  Callback* = proc(event: Event) {.closure.}
  Styles* = Table[string, string]
  Node* = ref object
    nodeKind: NodeKind
    nodeKey, label, hint: string
    inactive: bool
    nodeStyles, nodeAttributes: Styles
    descendants: seq[Node]
    handlers: array[EventKind, Callback]
    navigation: Option[HostNavigationProps]
    canvas: Option[CanvasFrame]
    source: ListSource
  RowBuilder* = proc(index: int): Node {.closure.}
  ListSource* = ref object
    generation: uint64
    itemKeys: seq[string]
    keyBytes: int
    builder: RowBuilder
    uniformHeight, estimate: float64
    extraRows: int
  MountedNode* = ref object
    description: Node
    identity, lookupKey: string
    descendants: seq[MountedNode]
    itemIndex: int
  Snapshot* = object
    title*: string
    width*, height*: int
    root*: MountedNode
  SnapshotValidator* = proc(snapshot: Snapshot) {.closure.}

type
  ExecutionScope* = proc(body: proc() {.closure.}) {.closure.}
  Application* = object
    title*: string
    width*, height*: int
    nativeTheme*: NativeTheme
    motionPolicy*:MotionPolicy
    canvasRenderer*: CanvasRenderer
    executionScope*: ExecutionScope
    driverFactory: proc(owner:Runtime):RuntimeDriver {.closure.}
  RuntimeDriver* = ref object of RootObj
  PerformanceStats* = object
    renders*, builtNodes*, cacheHits*, cacheMisses*, dispatches*: uint64
    builtItems*, rowCacheHits*: uint64
    cachedSubtrees*, mountedNodes*, treeBytes*: int
    cachedItems*, cachedRowBytes*: int
  Runtime* = ref object
    executionId:uint64
    app: Application
    driver:RuntimeDriver
    inUpdate: bool
    taskBody: bool
    closed, cleanupBusy, cleanupBody: bool
    when compileOption("threads"): uiThreadId: int
    batchDepth:int
    dispatches: uint64
    validator: SnapshotValidator
    preparer: RuntimePreparer
    committer: RuntimeCommitter
    committerLifecycle: RuntimeInstallLifecycle
    committerOwner: uint64
    preparerOwner: uint64
    hookCounter: uint64
    revision: uint64
    proposed: uint64
    stagingChanged: bool
    eventsFrozen: bool
    frozenReason: string
    isCandidate: bool
    hookInstallation: bool
    descriptionBytes: int
    diagnostics: Diagnostics
  RuntimeCleanupError* = object of UiError
    ## Caller retains the owner until an ordinary close succeeds.
    cleanupRuntime*: Runtime
    exitStatus*: Option[int]
  RuntimePreparer* = proc(candidate: Runtime) {.closure.}
  RuntimeCommitter* = proc(accepted: Runtime, candidate: Runtime) {.closure.}
  RuntimeInstallLifecycle* = object
    ## Optional Native installation lifecycle, owned by the installed committer.
    ## confirm publishes only framework metadata after successful scope exit.
    ## abort(true) runs inside the application scope to restore Native state;
    ## abort(false) may only fault/freeze metadata if that scope refused entry.
    ## Neither callback renders or invokes business callbacks.
    confirm*: proc() {.closure.}
    abort*: proc(scoped: bool) {.closure.}

# Runtime domains are UI-thread local. A nested operation cannot switch owners
# while application code is executing in another runtime's scope.
var nextRuntimeId {.threadvar.}:uint64
var executingRuntimeId {.threadvar.}:uint64
proc withNativeTheme*(app: Application, theme: NativeTheme): Application =
  ## Copy configuration; does not mutate the original or change headless behavior.
  result = app
  result.nativeTheme = theme

proc withMotionPolicy*(app:Application,policy:MotionPolicy):Application=
  result=app
  result.motionPolicy=policy
proc reducedMotionInternal*(runtime:Runtime):bool=runtime.app.motionPolicy==MotionPolicy.reduced

proc runtimeIdentity*(runtime:Runtime):uint64=runtime.executionId
proc executionRuntimeIdentity*():uint64=executingRuntimeId

# Internal driver seam: core owns scopes, revisions and backend gate ownership.
method stage*(driver:RuntimeDriver,forceRoot:bool):RuntimeDriver {.base.}=nil
method stageViewport*(driver:RuntimeDriver,key:string,first,finish:int,protected:seq[int]):RuntimeDriver {.base.}=nil
method invokeAccepted*(driver:RuntimeDriver,key:string,event:Event):bool {.base.}=false
method exportSnapshot*(driver:RuntimeDriver):Snapshot {.base.}=default(Snapshot)
method find*(driver:RuntimeDriver,key:string):MountedNode {.base.}=nil
method stats*(driver:RuntimeDriver):PerformanceStats {.base.}=default(PerformanceStats)
method publish*(driver:RuntimeDriver) {.base,raises:[].}=discard
method finishCommit*(driver:RuntimeDriver) {.base,raises:[].}=discard
method validateCommit*(driver:RuntimeDriver) {.base.}=discard
method reject*(driver:RuntimeDriver) {.base,raises:[].}=discard
method animationPumpPendingDriverInternal*(driver:RuntimeDriver):bool {.base.}=false
method pumpAnimationsDriverInternal*(driver:RuntimeDriver,monotonicMs:float64,visible:bool):AnimationPumpReport {.base.}=default(AnimationPumpReport)
method taskPumpPendingDriverInternal*(driver:RuntimeDriver):bool {.base.}=false
method pumpDeferred*(driver:RuntimeDriver):TaskPumpReport {.base.}=
  newTaskPumpReportInternal(0,0,0,0,false)
method configureTaskPumpDriverInternal*(driver:RuntimeDriver,supported:bool) {.base.}=discard
method retireTaskPoolDriverInternal*(driver:RuntimeDriver) {.base.}=discard
method finalizeTaskPoolDriverInternal*(driver:RuntimeDriver) {.base.}=discard
method requireCloseAccessInternal*(driver:RuntimeDriver) {.base.}=discard
method prepareCloseDeferredInternal*(driver:RuntimeDriver) {.base.}=discard
method invalidateCloseStateInternal*(driver:RuntimeDriver) {.base.}=discard
method retireDeferred*(driver:RuntimeDriver) {.base,raises:[].}=discard
method closeDeferred*(driver:RuntimeDriver) {.base.}=discard
method deferredRetiredInternal*(driver:RuntimeDriver):bool {.base.}=false
proc runtimeDriver*(runtime:Runtime):RuntimeDriver=runtime.driver
proc withCanvasRenderer*(app: Application, renderer: CanvasRenderer): Application =
  result = app
  result.canvasRenderer = renderer
proc applicationConfig*(runtime:Runtime):tuple[title:string,width,height:int]=
  (runtime.app.title,runtime.app.width,runtime.app.height)
proc newDriverApplication*(title:string,width,height:int,
    factory:proc(owner:Runtime):RuntimeDriver {.closure.},executionScope:ExecutionScope=nil):Application=
  Application(title:title,width:width,height:height,driverFactory:factory,executionScope:executionScope)
proc mountedDescription*(node:Node,id:string,children:seq[MountedNode]= @[],itemIndex= -1):MountedNode=
  MountedNode(description:node,identity:id,lookupKey:node.nodeKey,descendants:children,itemIndex:itemIndex)

proc fail*(message: string) {.noreturn.} =
  raise newException(UiError, message)

proc validString(value: string) =
  if value.len > MaxStringBytes: fail("string exceeds 1 MiB")
  if validateUtf8(value) != -1: fail("UI text is not valid UTF-8")

proc style*(pairs: openArray[(string, string)]): Styles =
  for (key, value) in pairs:
    validString(key)
    validString(value)
    result[key] = value

proc kind*(node: Node): NodeKind = node.nodeKind
proc key*(node: Node): string = node.nodeKey
proc text*(node: Node): string = node.label
proc placeholder*(node: Node): string = node.hint
proc disabled*(node: Node): bool = node.inactive
proc styles*(node: Node): Styles = node.nodeStyles
proc attributes*(node: Node): Styles = node.nodeAttributes
proc children*(node: Node): seq[Node] = node.descendants
proc listSource*(node: Node): ListSource = node.source
proc navigationProps*(node: Node): Option[HostNavigationProps] = node.navigation
proc canvasFrame*(node: Node): Option[CanvasFrame] = node.canvas
proc withCanvasPresentationInternal*(node:Node,frame:CanvasFrame):Node=
  result=Node()
  result[]=node[]
  result.canvas=some(frame)
proc handler*(node: Node, event: EventKind): Callback = node.handlers[event]

proc node*(mounted: MountedNode): Node = mounted.description
proc id*(mounted: MountedNode): string = mounted.identity
proc children*(mounted: MountedNode): seq[MountedNode] = mounted.descendants
proc listIndex*(mounted: MountedNode): int = mounted.itemIndex
var listGeneration: uint64

proc generation*(source: ListSource): uint64 = source.generation
proc len*(source: ListSource): int = source.itemKeys.len
when defined(leafProtocolProbes):
  var sourceKeyReadCalls*:uint64
proc itemKey*(source: ListSource, index: int): string =
  when defined(leafProtocolProbes):inc sourceKeyReadCalls
  source.itemKeys[index]
proc rowHeight*(source: ListSource): float64 = source.uniformHeight
proc estimatedHeight*(source: ListSource): float64 = source.estimate
proc overscan*(source: ListSource): int = source.extraRows
proc buildRow*(source: ListSource, index: int): Node = source.builder(index)

proc ui*(kind: NodeKind, key = "", text = "", placeholder = "",
         children: seq[Node] = @[], styles: Styles = default(Styles),
         attributes: Styles = default(Styles), disabled = false,
         onClick: Callback = nil, onChange: Callback = nil,
         onSubmit: Callback = nil, onBack: Callback = nil, onCanvasInput: Callback = nil,
         navigation: Option[HostNavigationProps] = none(HostNavigationProps),
         canvas: Option[CanvasFrame] = none(CanvasFrame)): Node =
  for value in [key, text, placeholder]: validString(value)
  for pairs in [styles, attributes]:
    for name, value in pairs:
      validString(name)
      validString(value)
  if kind notin {column, row, virtualList, NodeKind.navigation} and children.len != 0:
    fail("leaf controls cannot have children")
  if onClick != nil and kind != button: fail("click requires a button")
  if onChange != nil and kind notin {input, checkbox, toggle}:
    fail("change requires an input, checkbox or switch")
  if onSubmit != nil and kind != input: fail("submit requires an input")
  if onBack != nil and kind != NodeKind.navigation: fail("back requires a navigation host")
  if onCanvasInput != nil and kind != NodeKind.canvasHost: fail("Canvas input requires a Canvas host")
  if (kind == NodeKind.navigation) != navigation.isSome:
    fail("navigation metadata must belong to a navigation host")
  if navigation.isSome:
    let reason = navigation.get.invalidReason(MaxNodes)
    if reason.len != 0: fail(reason)
  if (kind == NodeKind.canvasHost) != canvas.isSome:
    fail("Canvas frame must belong to a Canvas host")
  if canvas.isSome and canvas.get.isNil: fail("Canvas frame is missing")
  Node(nodeKind: kind, nodeKey: key, label: text, hint: placeholder,
    descendants: children, nodeStyles: styles, nodeAttributes: attributes,
    inactive: disabled, handlers: [onClick, onChange, onSubmit, onBack, onCanvasInput],
    navigation: navigation, canvas: canvas)

proc virtualList*(key: string, keys: seq[string], builder: RowBuilder,
                  rowHeight = 0.0, estimatedHeight = 100.0, overscan = 2,
                  styles: Styles = default(Styles)): Node =
  if key.len == 0 or builder == nil: fail("virtual list needs a key and builder")
  if keys.len > MaxListItems: fail("list exceeds 100000 items")
  if classify(estimatedHeight) in {fcNan, fcInf, fcNegInf} or
      estimatedHeight <= 0 or estimatedHeight > 1_000_000:
    fail("estimated height must be finite and positive")
  if classify(rowHeight) in {fcNan, fcInf, fcNegInf} or
      rowHeight < 0 or rowHeight > 1_000_000:
    fail("row height must be zero or finite and positive")
  if overscan < 0 or overscan > 32: fail("invalid list overscan")
  var seen: HashSet[string]
  var bytes = 0
  for item in keys:
    validString(item)
    bytes += item.len
    if bytes > MaxTreeBytes: fail("list keys exceed 16 MiB")
    if item in seen: fail("duplicate list key: " & item)
    seen.incl(item)
  result = ui(NodeKind.virtualList, key = key, styles = styles)
  inc listGeneration
  result.source = ListSource(generation: listGeneration, itemKeys: keys, builder: builder,
    keyBytes: bytes, uniformHeight: rowHeight, estimate: estimatedHeight, extraRows: overscan)

proc segment(key: string, index: int): string =
  if key.len == 0: "i:" & $index else: "k:" & $key.len & ":" & key

proc mountImpl(node: Node, parent: string, index, depth: int,
               forcedKey: string, forceKey: bool, count: var int): MountedNode =
  if node == nil: fail("render returned nil node")
  inc count
  if count > MaxNodes or depth > MaxDepth: fail("UI exceeds 10000 nodes or depth 64")
  let key = if forceKey: forcedKey else: node.nodeKey
  let part = segment(key, index)
  result = MountedNode(description: node,
    identity: (if parent.len == 0: part else: parent & "/" & part), lookupKey: key, itemIndex: -1)
  if result.identity.len > MaxStringBytes: fail("node ID exceeds 1 MiB")
  for i, child in node.descendants:
    result.descendants.add(mountImpl(child, result.identity, i, depth + 1, "", false, count))

proc mount*(node: Node, parent = "", index = 0, depth = 0): MountedNode =
  var count = 0
  mountImpl(node, parent, index, depth, "", false, count)

proc toJson*(snapshot: Snapshot): JsonNode
proc snapshot*(runtime:Runtime):Snapshot

proc dump(runtime: Runtime) =
  if runtime.diagnostics != nil and runtime.diagnostics.dumpFile.len > 0:
    runtime.diagnostics.snapshot(runtime.snapshot.toJson())

template inExecutionScope(runtime: Runtime, body: untyped) =
  block:
    let priorRuntime=executingRuntimeId
    if priorRuntime!=0 and priorRuntime!=runtime.executionId:
      fail("cannot enter another Runtime during an active UI task")
    executingRuntimeId=runtime.executionId
    try:
      if runtime.app.executionScope == nil:
        body
      else:
        runtime.app.executionScope(proc() = body)
    finally:executingRuntimeId=priorRuntime

proc acceptedRevision*(runtime: Runtime): uint64 = runtime.revision

proc installingUpdate*(runtime: Runtime): bool = runtime.inUpdate
proc taskBodyInternal*(runtime:Runtime):bool=runtime.taskBody
proc runtimeCleanupBodyInternal*(runtime:Runtime):bool=
  runtime.closed and runtime.cleanupBusy and runtime.cleanupBody
proc runtimeClosedInternal*(runtime:Runtime):bool=runtime.closed or
  (runtime.driver!=nil and runtime.driver.deferredRetiredInternal())

proc installingHook*(runtime: Runtime): bool = runtime.hookInstallation

proc committerOwner*(runtime: Runtime): uint64 = runtime.committerOwner

proc preparerOwner*(runtime: Runtime): uint64 = runtime.preparerOwner

proc proposedRevision*(runtime: Runtime): uint64 = runtime.proposed

proc stagingChanged*(runtime: Runtime): bool = runtime.stagingChanged

proc eventsFrozen*(runtime: Runtime): bool = runtime.eventsFrozen

proc freezeEvents*(runtime: Runtime, reason: string) =
  ## Permanently freeze business dispatch after an unrecoverable backend
  ## failure. A1 deliberately provides no automatic thaw.
  runtime.eventsFrozen = true
  runtime.frozenReason = reason

proc safeDump(runtime: Runtime) =
  if runtime.diagnostics == nil: return
  try:
    runtime.dump()
  except CatchableError as error:
    stderr.writeLine("leaf: post-commit dump failed: " & error.msg)

proc candidateFrom(runtime: Runtime): Runtime =
  ## Isolated staging copy of accepted state. Only the managed driver holds
  ## accepted descriptions; the candidate carries no committer so nested
  ## preparation never recurses into the outer gate.
  Runtime(executionId:runtime.executionId,app: runtime.app,
    driver:runtime.driver, validator: runtime.validator,
    revision: runtime.revision, descriptionBytes: runtime.descriptionBytes,
    isCandidate: true)

proc markStaged(runtime: Runtime) =
  ## Record that an isolated staging runtime produced an actual prepared
  ## result. The first visible change allocates the proposed revision; any
  ## later preparation during the same staging never advances it again.
  runtime.stagingChanged = true
  if runtime.proposed == 0:
    runtime.proposed = runtime.revision + 1

proc publishCandidate(runtime: Runtime, candidate: Runtime, proposed: uint64) =
  ## Move accepted state only. The external callback has already run exactly
  ## once; this never renders or re-invokes the committer.
  if candidate.driver!=nil:
    candidate.driver.publish()
    runtime.driver=candidate.driver
  runtime.descriptionBytes = candidate.descriptionBytes
  runtime.revision = proposed

proc finishAccepted(runtime: Runtime) {.raises:[].}=
  ## The publication boundary has completed: release values retired by the
  ## driver. Still inside the caller's reentry guard; never a new failure point.
  if runtime.driver!=nil:runtime.driver.finishCommit()

proc gateAndPublish(runtime: Runtime, candidate: Runtime) =
  ## The single publish boundary. The proposed revision is allocated before
  ## the external callback and stays stable for the whole staging, so nested
  ## candidate preparation cannot advance it. A successful publication
  ## advances the accepted revision by exactly one.
  if candidate.driver!=nil:candidate.driver.validateCommit()
  let proposed = runtime.revision + 1
  candidate.proposed = proposed
  if runtime.committer != nil:
    runtime.committer(runtime, candidate)
  runtime.publishCandidate(candidate, proposed)
  runtime.finishAccepted()

proc postCommitDiagnostics(runtime: Runtime) =
  ## Diagnostics run after acceptance. Their failure must never look like a
  ## rejected commit; Diagnostics reports IO errors on stderr itself.
  if runtime.diagnostics == nil: return
  runtime.diagnostics.record("render", "ok", %*{"nodes": runtime.driver.stats.mountedNodes})
  runtime.safeDump()

proc flushDriverImpl(runtime:Runtime,forceRoot:bool):bool=
  if runtime.runtimeClosedInternal:
    runtime.driver.reject()
    return false
  if runtime.isCandidate or runtime.inUpdate:fail("reentrant runtime update")
  runtime.inUpdate=true
  var staged:RuntimeDriver
  try:
    staged=runtime.driver.stage(forceRoot)
    if staged==nil:return false
    let candidate=runtime.candidateFrom()
    candidate.driver=staged
    candidate.markStaged()
    if runtime.validator!=nil:runtime.validator(staged.exportSnapshot())
    if runtime.preparer!=nil:runtime.preparer(candidate)
    runtime.gateAndPublish(candidate)
    result=true
    runtime.postCommitDiagnostics()
  except CatchableError as error:
    if runtime.diagnostics != nil:
      runtime.diagnostics.record("render", "error", %*{"message": error.msg})
    if staged!=nil:staged.reject()
    else:runtime.driver.reject()
    raise
  finally:runtime.inUpdate=false
proc flush*(runtime:Runtime):bool=
  var completed:bool
  inExecutionScope(runtime):
    completed=runtime.flushDriverImpl(false)
  completed
proc batch*(runtime:Runtime,body:proc() {.closure.})=
  if runtime.runtimeClosedInternal:fail("Runtime is closed")
  if runtime.batchDepth>0:
    inc runtime.batchDepth
    try:body()
    finally:dec runtime.batchDepth
    return
  if runtime.inUpdate or runtime.isCandidate:fail("reentrant runtime batch")
  inExecutionScope(runtime):
    runtime.inUpdate=true
    runtime.batchDepth=1
    runtime.taskBody=true
    try:body()
    except CatchableError:
      if runtime.driver!=nil:runtime.driver.reject()
      raise
    finally:
      runtime.taskBody=false
      runtime.batchDepth=0
      runtime.inUpdate=false
    discard runtime.flushDriverImpl(false)
proc uiTask*(runtime:Runtime,body:proc() {.closure.})=
  ## Backend task boundary. State writes enqueue; flush follows body completion.
  runtime.batch(body)

proc pumpTasks*(runtime:Runtime):TaskPumpReport=
  if runtime==nil:fail("missing Runtime")
  if runtime.isCandidate or runtime.inUpdate or runtime.hookInstallation:
    fail("task pump requires an ordinary UI safe point")
  if executionRuntimeIdentity()!=0 and executionRuntimeIdentity()!=runtime.executionId:
    fail("cannot pump another executing Runtime")
  if runtime.driver==nil:return newTaskPumpReportInternal(0,0,0,0,false)
  runtime.driver.pumpDeferred()

proc animationPumpPending*(runtime:Runtime):bool=
  if runtime==nil:fail("missing Runtime")
  runtime.driver!=nil and not runtime.runtimeClosedInternal and runtime.driver.animationPumpPendingDriverInternal()

proc pumpAnimations*(runtime:Runtime,monotonicMs:float64,visible=true):AnimationPumpReport=
  if runtime==nil:fail("missing Runtime")
  if runtime.isCandidate or runtime.inUpdate or runtime.hookInstallation:
    fail("animation pump requires an ordinary UI safe point")
  if executionRuntimeIdentity()!=0 and executionRuntimeIdentity()!=runtime.executionId:
    fail("cannot pump another executing Runtime")
  if runtime.driver==nil or runtime.runtimeClosedInternal:return
  runtime.driver.pumpAnimationsDriverInternal(monotonicMs,visible)

proc taskPumpPending*(runtime:Runtime):bool=
  if runtime==nil:fail("missing Runtime")
  runtime.driver!=nil and not runtime.runtimeClosedInternal and runtime.driver.taskPumpPendingDriverInternal()

proc configureTaskPumpInternal*(runtime:Runtime,supported:bool)=
  if runtime==nil or runtime.isCandidate or runtime.inUpdate or runtime.hookInstallation or
      executionRuntimeIdentity()!=0:fail("task configuration requires an ordinary UI boundary")
  if runtime.driver!=nil:runtime.driver.configureTaskPumpDriverInternal(supported)
proc retireTaskPoolInternal*(runtime:Runtime)=
  if runtime==nil:fail("missing Runtime")
  if runtime.driver!=nil:runtime.driver.retireTaskPoolDriverInternal()
proc finalizeTaskPoolInternal*(runtime:Runtime)=
  if runtime==nil or runtime.isCandidate or runtime.inUpdate or runtime.hookInstallation or
      executionRuntimeIdentity()!=0:fail("task pool cleanup requires an ordinary UI finally")
  if runtime.driver!=nil:runtime.driver.finalizeTaskPoolDriverInternal()

proc requireCloseUi(runtime:Runtime)=
  if runtime==nil:fail("missing Runtime")
  when compileOption("threads"):
    if runtime.uiThreadId!=getThreadId():fail("Runtime close requires its UI thread")
  if executionRuntimeIdentity()!=0 and executionRuntimeIdentity()!=runtime.executionId:
    fail("cannot close another executing Runtime")
  if runtime.isCandidate:fail("candidate Runtime cannot close")

proc runRuntimeCleanup*(runtime:Runtime,body:proc() {.closure.})=
  runtime.requireCloseUi()
  if not runtime.closed or runtime.inUpdate or executionRuntimeIdentity()!=0:
    fail("cleanup requires a closed Runtime ordinary boundary")
  runtime.inUpdate=true
  try:
    inExecutionScope(runtime):
      runtime.cleanupBody=true
      try:body()
      finally:runtime.cleanupBody=false
  finally:runtime.inUpdate=false

proc closeRuntime*(runtime:Runtime)=
  runtime.requireCloseUi()
  if runtime.closed and runtime.cleanupBusy and runtime.cleanupBody:return
  if executionRuntimeIdentity()!=0 and not runtime.taskBody:
    fail("public close requires its Runtime business body or an ordinary boundary")
  if runtime.hookInstallation or (runtime.inUpdate and not runtime.taskBody):
    fail("cannot close Runtime during protected computation or commit")
  if runtime.driver!=nil:runtime.driver.requireCloseAccessInternal()
  if not runtime.closed:
    if runtime.driver!=nil:runtime.driver.prepareCloseDeferredInternal()
    runtime.closed=true
    if runtime.driver!=nil:
      runtime.driver.retireDeferred()
      runtime.driver.invalidateCloseStateInternal()
  # Legal business callbacks close admission/State immediately, but retain
  # cleanup records and the independent pool pin for an ordinary close/finally.
  if runtime.taskBody or runtime.inUpdate or executionRuntimeIdentity()!=0:return
  runtime.cleanupBusy=true
  try:
    if runtime.driver!=nil:runtime.driver.closeDeferred()
  finally:
    runtime.cleanupBusy=false
    runtime.finalizeTaskPoolInternal()

proc refresh*(runtime: Runtime): bool =
  var completed: bool
  inExecutionScope(runtime):
    completed=runtime.flushDriverImpl(true)
  completed

proc newRuntime*(app: Application, validator: SnapshotValidator = nil,
                 diagnostics: Diagnostics = nil): Runtime =
  if app.driverFactory==nil:
    fail("application requires componentApplication; raw render applications are not supported")
  if app.width notin 1..16_384 or app.height notin 1..16_384:
    fail("invalid window dimensions")
  validString(app.title)
  if nextRuntimeId==high(uint64):fail("Runtime identity exhausted")
  inc nextRuntimeId
  result = Runtime(executionId:nextRuntimeId,app: app, validator: validator,
    diagnostics: diagnostics)
  when compileOption("threads"): result.uiThreadId=getThreadId()
  result.driver=app.driverFactory(result)
  try:
    discard result.refresh()
  except CatchableError as primary:
    # Rejected candidates have no accepted owner. In particular, do not enter
    # cleanup from a foreign/protected scope that rejected initial refresh.
    if result.acceptedRevision == 0: raise
    if primary of RuntimeCleanupError and
        cast[ref RuntimeCleanupError](primary).cleanupRuntime == result: raise
    try: result.closeRuntime()
    except CatchableError:
      let failure = newException(RuntimeCleanupError, primary.msg)
      failure.parent = primary
      failure.cleanupRuntime = result
      failure.exitStatus = none(int)
      raise failure
    raise

proc snapshot*(runtime: Runtime): Snapshot =
  runtime.driver.exportSnapshot()
proc stats*(runtime: Runtime): PerformanceStats =
  result = runtime.driver.stats()
  result.dispatches = runtime.dispatches

proc setDiagnostics*(runtime: Runtime, diagnostics: Diagnostics) =
  ## Desktop attaches after its initial tree and lazy viewports are validated.
  runtime.diagnostics = diagnostics
  if diagnostics != nil:
    diagnostics.record("render", "ok", %*{"nodes": runtime.driver.stats.mountedNodes})
    runtime.dump()

proc diagnostic*(runtime: Runtime, phase, status: string, details: JsonNode) =
  runtime.diagnostics.record(phase, status, details)

proc setValidatorImpl(runtime: Runtime, validator: SnapshotValidator) =
  ## A renderer can validate its constraints before a runtime transaction
  ## publishes state. Validate the current snapshot before attaching it.
  if runtime.inUpdate: fail("cannot replace validator during update")
  if validator != nil: validator(runtime.snapshot)
  runtime.validator = validator

proc setValidator*(runtime: Runtime, validator: SnapshotValidator) =
  inExecutionScope(runtime): runtime.setValidatorImpl(validator)

proc abortInstallation(runtime: Runtime, lifecycle: RuntimeInstallLifecycle,
                       primary: ref CatchableError) =
  if lifecycle.abort == nil: return
  var entered = false
  try:
    inExecutionScope(runtime):
      entered = true
      lifecycle.abort(true)
  except CatchableError as secondary:
    primary.msg.add("; installation abort failed: " & secondary.msg)
    if not entered:
      # No Native operations or hook removal may bypass a refused scope.
      try: lifecycle.abort(false)
      except CatchableError as failure:
        primary.msg.add("; installation fault notification failed: " & failure.msg)

proc installCommitter*(runtime: Runtime, committer: RuntimeCommitter,
                      lifecycle = default(RuntimeInstallLifecycle)): uint64 =
  ## Stage the accepted description and call the backend inside the application
  ## execution scope, without rendering business state. Publish prepared rows
  ## and the hook only after the scope has successfully exited. Holding the
  ## update guard through scope exit prevents reentrant installation/publication.
  ## A failed install leaves description, revision and hook ownership unchanged.
  if runtime.isCandidate: fail("candidate runtime cannot install a committer")
  if runtime.inUpdate: fail("cannot replace committer during update")
  if committer != nil and runtime.committer != nil:
    fail("committer already installed; unload the existing session first")
  if (lifecycle.confirm == nil) != (lifecycle.abort == nil):
    fail("installation lifecycle requires both confirm and abort")
  var candidate: Runtime
  if committer != nil:
    candidate = runtime.candidateFrom()
    candidate.hookInstallation = true
  var committed = false
  runtime.inUpdate = true
  try:
    try:
      inExecutionScope(runtime):
        if committer != nil:
          committer(nil, candidate)
          committed = true
      if committed and lifecycle.confirm != nil: lifecycle.confirm()
    except CatchableError as error:
      if committed: runtime.abortInstallation(lifecycle, error)
      if candidate!=nil and candidate.driver!=nil and candidate.driver!=runtime.driver:candidate.driver.reject()
      raise error
    # Framework confirmation has completed; publication invokes no business
    # callback and remains protected by the same update guard.
    if committer == nil:
      runtime.committer = nil
      runtime.committerOwner = 0
      runtime.committerLifecycle = default(RuntimeInstallLifecycle)
      return 0
    if candidate.stagingChanged:
      if candidate.driver!=nil:candidate.driver.validateCommit()
      runtime.publishCandidate(candidate, candidate.proposed)
      runtime.finishAccepted()
      runtime.safeDump()
    runtime.committer = committer
    inc runtime.hookCounter
    runtime.committerOwner = runtime.hookCounter
    runtime.committerLifecycle = lifecycle
    result = runtime.committerOwner
  finally:
    runtime.inUpdate = false

proc setCommitter*(runtime: Runtime, committer: RuntimeCommitter) =
  ## Backward-compatible entry point. Use `installCommitter` when the caller
  ## must later uninstall only its own hook.
  discard runtime.installCommitter(committer)

proc clearCommitterImpl(runtime: Runtime, owner: uint64): bool =
  if owner == 0 or runtime.committerOwner != owner: return false
  if runtime.isCandidate: fail("candidate runtime cannot uninstall a committer")
  if runtime.inUpdate: fail("cannot uninstall committer during update")
  runtime.committer = nil
  runtime.committerOwner = 0
  runtime.committerLifecycle = default(RuntimeInstallLifecycle)
  true

proc clearCommitter*(runtime: Runtime, owner: uint64) =
  ## Uninstall the committer only when it is still the one identified by
  ## `owner`. A stale session can never remove another session's hook. The
  ## actual uninstall runs inside the application execution scope and is
  ## rejected during an update or on a candidate, exactly like installation.
  if owner == 0 or runtime.committerOwner != owner: return
  var cleared: bool
  inExecutionScope(runtime): cleared = runtime.clearCommitterImpl(owner)
  discard cleared

proc retireCommitterOwner*(runtime:Runtime,owner:uint64) {.raises:[].} =
  ## Internal terminal FFI teardown: metadata only, after the external run has
  ## ended. Never calls a scope, native operation, or business callback.
  if owner!=0 and runtime.committerOwner==owner:
    runtime.committer=nil
    runtime.committerOwner=0
    runtime.committerLifecycle=default(RuntimeInstallLifecycle)

proc prepareSnapshotImpl(runtime: Runtime, preparer: RuntimePreparer) =
  if runtime.isCandidate: fail("candidate runtime cannot prepare")
  if runtime.inUpdate: fail("cannot replace preparer during update")
  if preparer == nil: return
  var candidate = runtime.candidateFrom()
  runtime.inUpdate = true
  try:
    preparer(candidate)
    # A no-op preparer must not invoke the backend gate or advance revision.
    if candidate.stagingChanged:
      runtime.gateAndPublish(candidate)
      runtime.safeDump()
  except CatchableError:
    if candidate.driver!=nil and candidate.driver!=runtime.driver:candidate.driver.reject()
    raise
  finally: runtime.inUpdate = false

proc prepareSnapshot(runtime: Runtime, preparer: RuntimePreparer) =
  inExecutionScope(runtime): runtime.prepareSnapshotImpl(preparer)

proc prepare*(runtime: Runtime) =
  ## Reprepare a viewport without rendering business state, atomically.
  runtime.prepareSnapshot(runtime.preparer)

proc installPreparer*(runtime: Runtime, preparer: RuntimePreparer): uint64 =
  ## Prepare and confirm an isolated candidate in the application execution
  ## scope; publish the candidate and hook only after successful scope exit.
  ## A failing replacement retains the previous preparer and accepted state.
  if runtime.isCandidate: fail("candidate runtime cannot prepare")
  if runtime.inUpdate: fail("cannot replace preparer during update")
  var candidate = runtime.candidateFrom()
  candidate.hookInstallation = true
  # Capture this owner's lifecycle; stale clears cannot detach a successor's.
  let lifecycle = runtime.committerLifecycle
  var committed = false
  runtime.inUpdate = true
  try:
    try:
      inExecutionScope(runtime):
        if preparer != nil: preparer(candidate)
        if candidate.stagingChanged:
          candidate.proposed = runtime.revision + 1
          if runtime.committer != nil:
            runtime.committer(runtime, candidate)
            committed = true
      if committed and lifecycle.confirm != nil: lifecycle.confirm()
    except CatchableError as error:
      if committed: runtime.abortInstallation(lifecycle, error)
      if candidate!=nil and candidate.driver!=nil and candidate.driver!=runtime.driver:candidate.driver.reject()
      raise error
    if candidate.stagingChanged:
      if candidate.driver!=nil:candidate.driver.validateCommit()
      runtime.publishCandidate(candidate, candidate.proposed)
      runtime.finishAccepted()
      runtime.safeDump()
    runtime.preparer = preparer
    inc runtime.hookCounter
    runtime.preparerOwner = runtime.hookCounter
    result = runtime.preparerOwner
  finally:
    runtime.inUpdate = false

proc setPreparer*(runtime: Runtime, preparer: RuntimePreparer) =
  ## Prepare lazy content before publication. Never mutate visible controls
  ## or business state; temporary measurement controls may be constructed.
  ## Backward-compatible entry point.
  discard runtime.installPreparer(preparer)

proc clearPreparerImpl(runtime: Runtime, owner: uint64): bool =
  if owner == 0 or runtime.preparerOwner != owner: return false
  if runtime.isCandidate: fail("candidate runtime cannot uninstall a preparer")
  if runtime.inUpdate: fail("cannot uninstall preparer during update")
  runtime.preparer = nil
  runtime.preparerOwner = 0
  true

proc clearPreparer*(runtime: Runtime, owner: uint64) =
  ## Uninstall the preparer only when it is still the one identified by
  ## `owner`. The actual uninstall runs inside the application execution scope
  ## and is rejected during an update or on a candidate.
  if owner == 0 or runtime.preparerOwner != owner: return
  var cleared: bool
  inExecutionScope(runtime): cleared = runtime.clearPreparerImpl(owner)
  discard cleared

proc retirePreparerOwner*(runtime:Runtime,owner:uint64) {.raises:[].} =
  ## Terminal FFI metadata cleanup, paired with retireCommitterOwner.
  if owner!=0 and runtime.preparerOwner==owner:
    runtime.preparer=nil
    runtime.preparerOwner=0

proc find*(runtime: Runtime, key: string): MountedNode =
  runtime.driver.find(key)

proc dispatchImpl(runtime: Runtime, key: string, event: Event): bool =
  if runtime.runtimeClosedInternal:fail("Runtime is closed")
  if runtime.eventsFrozen:
    fail("business events are frozen: " & runtime.frozenReason)
  if runtime.isCandidate: fail("candidate runtime cannot dispatch business events")
  if runtime.inUpdate: fail("reentrant event dispatch")
  if runtime.driver!=nil:
    try:
      runtime.inUpdate=true
      runtime.taskBody=true
      let invoked=runtime.driver.invokeAccepted(key,event)
      runtime.taskBody=false
      runtime.inUpdate=false
      if runtime.runtimeClosedInternal:
        runtime.driver.reject()
        return false
      if not invoked:return false
      result = runtime.flushDriverImpl(false)
      inc runtime.dispatches
      if runtime.diagnostics != nil:
        runtime.diagnostics.record("event", "ok", %*{"key": key, "kind": $event.kind})
      return result
    except CatchableError:
      runtime.driver.reject()
      raise
    finally:
      runtime.taskBody=false
      runtime.inUpdate=false
  fail("runtime has no managed driver")

proc dispatch*(runtime: Runtime, key: string, event: Event): bool =
  var completed: bool
  inExecutionScope(runtime): completed = runtime.dispatchImpl(key, event)
  completed

proc materializeInto(runtime: Runtime, key: string, first, finish: int,
                  protected: seq[int]): seq[MountedNode] =
  ## Apply a complete list viewport to a staging runtime. Only visible/protected
  ## rows are mounted; up to 128 rows stay warm, without live event handlers.
  if runtime.driver!=nil:
    if runtime.inUpdate:fail("reentrant list request")
    if runtime.isCandidate:
      runtime.driver=runtime.driver.stageViewport(key,first,finish,protected)
      runtime.markStaged()
      for row in runtime.driver.find(key).children:
        if row.listIndex>=first and row.listIndex<finish:result.add(row)
      return
    runtime.inUpdate=true
    var staged:RuntimeDriver
    try:
      staged=runtime.driver.stageViewport(key,first,finish,protected)
      let candidate=runtime.candidateFrom()
      candidate.driver=staged
      candidate.markStaged()
      if runtime.validator!=nil:runtime.validator(staged.exportSnapshot())
      for row in staged.find(key).children:
        if row.listIndex>=first and row.listIndex<finish:result.add(row)
      runtime.gateAndPublish(candidate)
    except CatchableError:
      if staged!=nil:staged.reject()
      raise
    finally:runtime.inUpdate=false
    return
  fail("runtime has no managed driver")

proc materializeImpl(runtime: Runtime, key: string, first, finish: int,
                  protected: seq[int] = @[]): seq[MountedNode] =
  ## The accepted viewport travels through the same commit gate as refresh and
  ## prepare; a rejected list candidate leaves accepted rows and stats intact.
  ## Preparing an isolated candidate is allowed and only stages its own state.
  if runtime.runtimeClosedInternal: fail("Runtime is closed")
  if runtime.inUpdate: fail("reentrant list request")
  if runtime.isCandidate:
    result = materializeInto(runtime, key, first, finish, protected)
    runtime.markStaged()
    return
  var candidate = runtime.candidateFrom()
  runtime.inUpdate = true
  try:
    result = materializeInto(candidate, key, first, finish, protected)
    runtime.gateAndPublish(candidate)
    runtime.safeDump()
  except CatchableError:
    if candidate.driver != nil and candidate.driver != runtime.driver:
      candidate.driver.reject()
    raise
  finally:
    runtime.inUpdate = false

proc materialize*(runtime: Runtime, key: string, first, finish: int,
                  protected: seq[int] = @[]): seq[MountedNode] =
  var rows: seq[MountedNode]
  inExecutionScope(runtime): rows = runtime.materializeImpl(key, first, finish, protected)
  rows

proc kindName*(kind: NodeKind): string =
  case kind
  of toggle: "switch"
  of virtualList: "virtual_list"
  of canvasHost: "canvas"
  else: $kind

proc toJson*(root: MountedNode): JsonNode =
  let n = root.description
  var children = newJArray()
  for child in root.descendants:
    let item = child.toJson()
    if n.source != nil and child.itemIndex >= 0 and child.itemIndex < n.source.len:
      item["item_key"] = %n.source.itemKey(child.itemIndex)
    children.add(item)
  var styles, attributes = newJObject()
  for key, value in n.nodeStyles: styles[key] = %value
  for key, value in n.nodeAttributes: attributes[key] = %value
  var events = newJObject()
  for event in EventKind:
    if event in {click, change, submit} or n.handlers[event] != nil:
      events[$event] = %(n.handlers[event] != nil)
  result = %*{"kind": n.nodeKind.kindName, "id": root.identity,
    "text": n.label, "placeholder": n.hint, "disabled": n.inactive,
    "styles": styles, "attributes": attributes, "events": events,
    "children": children}
  if root.itemIndex >= 0: result["list_index"] = %root.itemIndex
  if n.source != nil:
    result["list"] = %*{"generation": n.source.generation, "count": n.source.len, "row_height": n.source.uniformHeight,
      "estimated_height": n.source.estimate, "overscan": n.source.extraRows}

when defined(leafProtocolProbes):
  var snapshotJsonCalls*:uint64

proc toJson*(snapshot: Snapshot): JsonNode =
  when defined(leafProtocolProbes):inc snapshotJsonCalls
  %*{"title": snapshot.title, "width": snapshot.width, "height": snapshot.height,
     "root": snapshot.root.toJson()}
