## ABI5 adapter contract. The native seam below records platform operations;
## real View/system-back coverage belongs to the Android device fixture.
import std/[unittest, tables, options]
import leaf/[core, backend, backend_session, native_layout, components,
  component_description, widgets, managed_runtime, mobile_host, navigation_protocol]
import leaf/backends/android/backend as android_backend

type
  Model = ref object
    router: ComponentRouter
    factories: int
  Native = ref object
    platform: AndroidPlatform
    staged: AndroidFrame
    visible: Table[NodeHandle, MountedEntity]
    restores, stages: int
    failApply: bool

proc install(n: Native, op: UpdateOp) =
  case op.kind
  of opCreate:
    n.visible[op.handle] = MountedEntity(handle: op.handle, parent: op.parent,
      index: op.index, nodeId: op.nodeId, kind: op.nodeKind, props: op.props,
      navigation: op.navigation)
  of opUpdate:
    n.visible[op.handle].props = op.props
    n.visible[op.handle].navigation = op.navigation
  of opMove:
    n.visible[op.handle].parent = op.parent
    n.visible[op.handle].index = op.index
  of opRemove: n.visible.del(op.handle)

proc native(enabled = true): Native =
  let n = Native()
  n.platform.withNavigation = enabled
  n.platform.measure = proc(entity: MountedEntity, available: DipSize): DipSize =
    DipSize(width: min(100.0, available.width), height: 32)
  n.platform.stage = proc(frame: AndroidFrame) =
    inc n.stages
    n.staged = frame
  n.platform.apply = proc() =
    for op in n.staged.ops:
      n.install(op)
      if n.failApply: fail("navigation native apply 1234")
  n.platform.discardStage = proc() = n.staged = AndroidFrame()
  n.platform.restore = proc(frame: AndroidFrame) =
    inc n.restores
    n.visible.clear()
    for op in frame.ops: n.install(op)
  n.platform.rebind = proc(session, mount: uint64) = discard
  n.platform.dispose = proc() = n.visible.clear()
  n

proc app(model: Model): ApplicationFactory =
  result = proc(): Application =
    inc model.factories
    let Root = defineComponent[int, int]("AndroidNavigation",
      proc(ctx: MountContext, props: int): int =
        model.router = newComponentRouter(ctx, @[
          Route(name: "home", path: "/", page: "home", view: "main"),
          Route(name: "detail", path: "/detail", page: "detail", view: "main")], @[
          ComponentPageDefinition(name: "home", views: @["main"],
            build: proc(view: string): UiDescription = host(text("首页 中文😀", key = "content"))),
          ComponentPageDefinition(name: "detail", views: @["main"],
            build: proc(view: string): UiDescription = host(text("详情", key = "content")))])
        0,
      proc(ctx: ComponentContext, props, state: int): UiDescription =
        renderNavigation(ctx, model.router, key = "navigation"))
    componentApplication(component(Root, 0), "Navigation", 400, 600)

proc nav(n: Native): MountedEntity =
  for entity in n.visible.values:
    if entity.kind == NodeKind.navigation: return entity
  fail("navigation container is missing")

proc fact(owner: MobileHost, mount: MobileMount, n: Native,
    sequence: uint64, phase: NavigationBackPhase, request = 1'u64): NavigationBackFact =
  let session = owner.backendSession(mount)
  NavigationBackFact(sessionId: session.sessionId, mountGeneration: session.mountGeneration,
    handle: n.nav().handle.raw, bindingGeneration: 1,
    observedRevision: owner.runtime.acceptedRevision, sequence: sequence,
    requestId: request, navigation: n.nav().navigation.get, phase: phase)

suite "Android typed navigation adapter":
  test "navigation requires explicit capability without expanding old ABI levels":
    check NodeKind.navigation notin androidCapabilities().kinds
    check NodeKind.navigation notin androidCapabilities(true, true, true).kinds
    check NodeKind.navigation in androidCapabilities(withNavigation = true).kinds
    let model = Model()
    let owner = newMobileHost(model.app())
    let n = native(false)
    expect UiError:
      discard owner.attach(newAndroidBackend(n.platform, DipSize(width: 400, height: 600)), 400, 600, 1)
    check n.stages == 0
    owner.close()

  test "history-only update carries metadata and retains native container identity":
    let model = Model()
    let owner = newMobileHost(model.app())
    let n = native()
    let backend = newAndroidBackend(n.platform, DipSize(width: 400, height: 600))
    discard owner.attach(backend, 400, 600, 1)
    let before = n.nav()
    check before.navigation.isSome and before.navigation.get.depth == 1
    discard model.router.push("home")
    check owner.runtime.flush()
    let after = n.nav()
    check after.handle == before.handle
    check after.navigation.get.depth == 2
    check after.navigation.get.previousEntryId == before.navigation.get.currentEntryId
    var updates = 0
    for op in n.staged.ops:
      if op.handle == after.handle and op.kind == opUpdate:
        inc updates
        check op.navigation == after.navigation
    check updates == 1 and n.staged.withNavigation
    check backend.bindingValid(after.handle, 1)
    check not backend.bindingValid(after.handle, 0)
    owner.close()

  test "begin and confirm enter the ordinary resumed turn exactly once":
    let model = Model()
    let owner = newMobileHost(model.app())
    let n = native()
    let mount = owner.attach(newAndroidBackend(n.platform, DipSize(width: 400, height: 600)), 400, 600, 1)
    check owner.resume(mount)
    discard model.router.push("detail")
    check owner.runtime.flush()
    check owner.queueNavigation(mount, owner.fact(mount, n, 1, NavigationBackPhase.begin))
    let confirmed = owner.fact(mount, n, 2, NavigationBackPhase.confirm)
    check owner.queueNavigation(mount, confirmed)
    check model.router.history.len == 2
    check owner.safeTurn(mount)
    check model.router.history.len == 1 and n.nav().navigation.get.depth == 1
    check not owner.queueNavigation(mount, confirmed)
    owner.close()

  test "pause refuses new facts and cancellation releases an already queued back":
    let model = Model()
    let owner = newMobileHost(model.app())
    let n = native()
    let mount = owner.attach(newAndroidBackend(n.platform, DipSize(width: 400, height: 600)), 400, 600, 1)
    check owner.resume(mount)
    discard model.router.push("detail")
    check owner.runtime.flush()
    check owner.queueNavigation(mount, owner.fact(mount, n, 1, NavigationBackPhase.begin))
    check owner.queueNavigation(mount, owner.fact(mount, n, 2, NavigationBackPhase.confirm))
    check owner.queueNavigation(mount, owner.fact(mount, n, 3, NavigationBackPhase.cancel))
    check owner.pause(mount)
    check not owner.queueNavigation(mount, owner.fact(mount, n, 4, NavigationBackPhase.begin, 2))
    check not owner.safeTurn(mount)
    check owner.resume(mount) and owner.safeTurn(mount)
    check model.router.history.len == 2
    owner.close()

  test "native failure restores complete accepted metadata and needs a fresh request":
    let model = Model()
    let owner = newMobileHost(model.app())
    let n = native()
    let mount = owner.attach(newAndroidBackend(n.platform, DipSize(width: 400, height: 600)), 400, 600, 1)
    check owner.resume(mount)
    discard model.router.push("detail")
    check owner.runtime.flush()
    let before = n.nav().navigation
    let oldMount = owner.backendSession(mount).mountGeneration
    n.failApply = true
    check owner.queueNavigation(mount, owner.fact(mount, n, 1, NavigationBackPhase.begin))
    check owner.queueNavigation(mount, owner.fact(mount, n, 2, NavigationBackPhase.confirm))
    discard owner.safeTurn(mount)
    check n.restores == 1 and n.nav().navigation == before
    check model.router.history.len == 2
    check owner.backendSession(mount).mountGeneration > oldMount
    n.failApply = false
    check owner.safeTurn(mount)
    check model.router.history.len == 2
    check owner.queueNavigation(mount, owner.fact(mount, n, 1, NavigationBackPhase.begin, 2))
    check owner.queueNavigation(mount, owner.fact(mount, n, 2, NavigationBackPhase.confirm, 2))
    check owner.safeTurn(mount)
    check model.router.history.len == 1
    owner.close()

  test "detach retains business history while old mount facts cannot reach new Views":
    let model = Model()
    let owner = newMobileHost(model.app())
    let first = native()
    let old = owner.attach(newAndroidBackend(first.platform, DipSize(width: 400, height: 600)), 400, 600, 1)
    check owner.resume(old)
    discard model.router.push("detail")
    check owner.runtime.flush()
    let stale = owner.fact(old, first, 1, NavigationBackPhase.begin)
    check owner.detach(old)
    let second = native()
    let current = owner.attach(newAndroidBackend(second.platform, DipSize(width: 600, height: 400)), 600, 400, 1)
    check owner.resume(current)
    check model.factories == 1 and second.nav().navigation.get.depth == 2
    check not owner.queueNavigation(old, stale)
    check not owner.queueNavigation(current, stale)
    check owner.queueNavigation(current, owner.fact(current, second, 1, NavigationBackPhase.begin))
    check owner.queueNavigation(current, owner.fact(current, second, 2, NavigationBackPhase.confirm))
    check owner.safeTurn(current)
    check model.router.history.len == 1
    owner.close()
