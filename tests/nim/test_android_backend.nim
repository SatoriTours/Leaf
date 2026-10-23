import std/[unittest, tables, options]
import leaf/[core, components, component_description, component_state, widgets,
  managed_runtime, backend, backend_session, mobile_host, native_layout]
import leaf/backends/android/backend as android_backend

type Native = ref object
  platform: AndroidPlatform
  staged: AndroidFrame
  visible: Table[NodeHandle, MountedEntity]
  boxes: seq[LayoutBox]
  creates, restores, calls: int
  failApply, failRestore, failDispose: bool

proc makeNative(): Native =
  let n = Native()
  n.platform.measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      inc n.calls
      DipSize(width: min(available.width, 100.0), height: 40)
  n.platform.stage = proc(frame: AndroidFrame) =
      inc n.calls
      n.staged = frame
  n.platform.apply = proc() =
      inc n.calls
      for op in n.staged.ops:
        case op.kind
        of opCreate:
          n.visible[op.handle] = MountedEntity(handle: op.handle, parent: op.parent,
            nodeId: op.nodeId, kind: op.nodeKind, props: op.props, index: op.index)
          inc n.creates
        of opUpdate: n.visible[op.handle].props = op.props
        of opMove:
          n.visible[op.handle].parent = op.parent
          n.visible[op.handle].index = op.index
        of opRemove: n.visible.del(op.handle)
        if n.failApply: fail("native apply 1234")
      n.boxes = n.staged.boxes
  n.platform.discardStage = proc() =
      inc n.calls
      n.staged = AndroidFrame()
  n.platform.restore = proc(frame: AndroidFrame) =
      inc n.calls
      inc n.restores
      if n.failRestore: fail("native restore 5678")
      n.visible.clear()
      for op in frame.ops:
        n.visible[op.handle] = MountedEntity(handle: op.handle, parent: op.parent,
          nodeId: op.nodeId, kind: op.nodeKind, props: op.props, index: op.index)
      n.boxes = frame.boxes
  n.platform.rebind = proc(session, mount: uint64) =
      inc n.calls
  n.platform.dispose = proc() =
      inc n.calls
      if n.failDispose: fail("native dispose 9012")
      n.visible.clear()
  n

type Counter = ref object
  count: State[int]
  factories: int
proc factory(c: Counter): ApplicationFactory =
  result = proc(): Application =
    inc c.factories
    let Page = defineComponent[int, State[int]]("AndroidCounter",
      proc(ctx: MountContext, props: int): State[int] =
        result = ctx.state(0)
        c.count = result,
      proc(ctx: ComponentContext, props: int, count: State[int]): UiDescription =
        host(column(@[text("中文😀 " & $ctx.value(count), key="count"),
          button("+1", key="increment", onClick=proc(event: Event) =
            discard count.update(proc(old: int): int = old + 1))], key="root")))
    componentApplication(component(Page, 0), "Android", 400, 600)

proc click(owner: MobileHost, mount: MobileMount, sequence: uint64): bool =
  let s = owner.backendSession(mount)
  if s == nil: return false
  owner.enqueue(mount, EventEnvelope(session: s.sessionId, mountGeneration: s.mountGeneration,
    handle: s.handleFor(owner.runtime.find("increment").id), sequence: sequence,
    observedRevision: owner.runtime.acceptedRevision, bindingGeneration: 1,
    event: Event(kind: core.click)))

suite "Android incremental backend":
  test "real managed updates retain native entities and accepted State across mounts":
    let c = Counter()
    let owner = newMobileHost(c.factory())
    let n = makeNative()
    let native = newAndroidBackend(n.platform, DipSize(width:400, height:600))
    let a = owner.attach(native, 400, 600, 1)
    check n.creates == 3 and n.boxes.len == 3
    let s = owner.backendSession(a)
    let label = s.handleFor(owner.runtime.find("count").id)
    check n.visible[label].props.accessibility.label.get == "中文😀 0"
    check owner.resume(a)
    check owner.click(a, 1)
    check owner.safeTurn(a)
    check c.count.readAccepted() == 1
    check n.visible[label].props.accessibility.label.get == "中文😀 1"
    check n.creates == 3
    check owner.detach(a)
    check n.visible.len == 0
    let other = makeNative()
    let b = owner.attach(newAndroidBackend(other.platform, DipSize(width:600,height:400)), 600,400,1)
    let newLabel = owner.backendSession(b).handleFor(owner.runtime.find("count").id)
    check other.visible[newLabel].props.accessibility.label.get == "中文😀 1"
    check c.factories == 1 and not owner.click(a, 2)
    owner.close()

  test "partial apply failure replays accepted props and advances event identity":
    let c = Counter()
    let owner = newMobileHost(c.factory())
    let n = makeNative()
    let a = owner.attach(newAndroidBackend(n.platform, DipSize(width:400,height:600)),400,600,1)
    check owner.resume(a)
    let s = owner.backendSession(a)
    let oldGeneration = s.mountGeneration
    let label = s.handleFor(owner.runtime.find("count").id)
    n.failApply = true
    check owner.click(a, 1)
    discard owner.safeTurn(a)
    check c.count.readAccepted() == 0 and n.restores == 1
    check n.visible[label].props.accessibility.label.get == "中文😀 0"
    check s.mountGeneration > oldGeneration and not s.faulted
    n.failApply = false
    check owner.click(a, 1) # new event epoch allows a fresh sequence
    discard owner.safeTurn(a)
    check c.count.readAccepted() == 1
    owner.close()

  test "failed restore freezes delivery and failed dispose preserves cleanup owner":
    let c = Counter()
    let owner = newMobileHost(c.factory())
    let n = makeNative()
    let a = owner.attach(newAndroidBackend(n.platform, DipSize(width:400,height:600)),400,600,1)
    check owner.resume(a)
    n.failApply = true; n.failRestore = true
    check owner.click(a, 1)
    discard owner.safeTurn(a)
    check owner.backendSession(a).faulted
    check not owner.safeTurn(a)
    n.failDispose = true
    expect UiError: discard owner.detach(a)
    check owner.state == mobileDetaching
    n.failDispose = false
    check owner.detach(a)
    owner.close()

  test "prepare is invisible and accept invokes no platform callback":
    let n = makeNative()
    let b = newAndroidBackend(n.platform, DipSize(width:400,height:600))
    b.rebind(1, 1)
    let op = UpdateOp(kind:opCreate, handle:NodeHandle(1), nodeId:"root",nodeKind:text)
    let batch = UpdateBatch(revision:1, ops: @[op])
    b.prepare(batch)
    check n.visible.len == 0
    b.apply(batch)
    let calls = n.calls
    var entities = initTable[NodeHandle,MountedEntity]()
    entities[op.handle] = MountedEntity(handle:op.handle, nodeId:op.nodeId,kind:text)
    b.accepted(entities, 1)
    check n.calls == calls
    b.dispose()

  test "unimplemented input and list capabilities fail before native prepare":
    let caps = androidCapabilities()
    check input notin caps.kinds and virtualList notin caps.kinds
    let n = makeNative()
    let b = newAndroidBackend(n.platform, DipSize(width:400,height:600))
    expect UiError:
      b.prepare(UpdateBatch(revision:1,ops: @[UpdateOp(kind:opCreate,
        handle:NodeHandle(1),nodeKind:input)]))
    check n.calls == 0
