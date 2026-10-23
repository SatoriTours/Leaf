import std/[unittest, tables, options, atomics, os]
import leaf/[core, components, component_description, component_state, widgets,
  managed_runtime, backend, backend_session, mobile_host, task_service, task_worker]
import leaf/backends/headless

var workerStarted, workerFinished: Atomic[bool]
var releaseWorker: Atomic[bool]
proc retainedWork(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  workerStarted.store(true)
  while not releaseWorker.load() and not ctx.cancelled: sleep(1)
  workerFinished.store(true)
  input

proc waitFor(flag: var Atomic[bool]): bool =
  for i in 0..<2000:
    if flag.load(): return true
    sleep(1)

type Fixture = ref object
  factoryCalls, initializations, renders, mounted, disposed: int
  count: State[int]

proc factory(f: Fixture): ApplicationFactory =
  result = proc(): Application =
    inc f.factoryCalls
    let Page = defineComponent[int, State[int]]("MobileCounter",
      proc(ctx: MountContext, props: int): State[int] =
        inc f.initializations
        result = ctx.state(0)
        f.count = result
        ctx.onMount(proc(event: LifecycleContext) = inc f.mounted)
        ctx.onDispose(proc(event: LifecycleContext) = inc f.disposed),
      proc(ctx: ComponentContext, props: int, value: State[int]): UiDescription =
        inc f.renders
        host(column(@[
          text($ctx.value(value), key = "count"),
          button("increment", key = "increment", onClick = proc(event: Event) =
            discard value.update(proc(old: int): int = old + 1))], key = "root")))
    componentApplication(component(Page, 0), "mobile", 400, 600)

proc message(host: MobileHost, mount: MobileMount, sequence: uint64): EventEnvelope =
  let session = host.backendSession(mount)
  EventEnvelope(session: session.sessionId, mountGeneration: session.mountGeneration,
    handle: session.handleFor(host.runtime.find("increment").id), sequence: sequence,
    observedRevision: host.runtime.acceptedRevision, source: sourceUser,
    event: Event(kind: click))

suite "retained mobile managed host":
  test "detach and reattach keep the same Runtime, State and component instances":
    let f = Fixture()
    let owner = newMobileHost(f.factory())
    let runtime = owner.runtime
    let first = newRecordingBackend(fullCapabilities())
    let a = owner.attach(first.backend, 400, 600, 1)
    check owner.resume(a)
    check owner.enqueue(a, owner.message(a, 1))
    check owner.safeTurn(a)
    check f.count.readAccepted() == 1
    let renders = f.renders
    let identity = runtime.runtimeIdentity
    check owner.detach(a)
    check owner.state == mobileDetached
    check first.disposed
    check not runtime.runtimeClosedInternal
    check f.disposed == 0
    let second = newRecordingBackend(fullCapabilities())
    let b = owner.attach(second.backend, 600, 400, 2)
    check owner.resume(b)
    check owner.runtime == runtime and owner.identity == identity
    check f.factoryCalls == 1 and f.initializations == 1 and f.renders == renders
    check a != b and b.generation > a.generation
    let handle = owner.backendSession(b).handleFor(runtime.find("count").id)
    check second.entities[handle].props.accessibility.label.get == "1"
    owner.close()
    check owner.state == mobileClosed
    check runtime.runtimeClosedInternal
    check owner.runtime == nil
    check second.disposed

  test "stale Activity lifecycle and events cannot touch a newer attachment":
    let f = Fixture()
    let owner = newMobileHost(f.factory())
    let a = owner.attach(newRecordingBackend(fullCapabilities()).backend, 400, 600, 1)
    check owner.resume(a)
    let old = owner.message(a, 1)
    check owner.enqueue(a, old)
    check owner.detach(a) # Queued event is dropped, not replayed on new views.
    let b = owner.attach(newRecordingBackend(fullCapabilities()).backend, 600, 400, 1)
    check owner.resume(b)
    check not owner.pause(a)
    check not owner.resume(a)
    check not owner.detach(a)
    check not owner.enqueue(a, old)
    check not owner.enqueue(b, old)
    check not owner.safeTurn(a)
    check owner.backendSession(a) == nil
    check owner.enqueue(b, owner.message(b, 1))
    check owner.safeTurn(b)
    check f.count.readAccepted() == 1
    owner.close()

  test "pause retains the Runtime and defers queued events and lifecycle delivery":
    let f = Fixture()
    let owner = newMobileHost(f.factory())
    let a = owner.attach(newRecordingBackend(fullCapabilities()).backend, 400, 600, 1)
    check not owner.safeTurn(a) # Starts paused until platform resume.
    check f.mounted == 0
    check owner.resume(a)
    check owner.enqueue(a, owner.message(a, 1))
    check owner.pause(a)
    check not owner.safeTurn(a)
    check not owner.enqueue(a, owner.message(a, 2))
    check f.count.readAccepted() == 0 and f.mounted == 0
    check owner.resume(a)
    check owner.safeTurn(a)
    check f.count.readAccepted() == 1 and f.mounted == 1
    owner.close()

  test "failed native teardown retains cleanup owners and blocks a new attachment":
    let f = Fixture()
    let owner = newMobileHost(f.factory())
    let runtime = owner.runtime
    let native = newRecordingBackend(fullCapabilities())
    let a = owner.attach(native.backend, 400, 600, 1)
    native.failDispose = true
    expect UiError: discard owner.detach(a)
    check owner.state == mobileDetaching
    check owner.runtime == runtime and not runtime.runtimeClosedInternal
    check not owner.resume(a)
    check not owner.enqueue(a, owner.message(a, 1))
    let other = newRecordingBackend(fullCapabilities())
    expect UiError: discard owner.attach(other.backend, 400, 600, 1)
    check other.disposeCalls == 0 and other.creates == 0
    native.failDispose = false
    check owner.detach(a)
    let b = owner.attach(other.backend, 400, 600, 1)
    check b.generation > a.generation
    other.failDispose = true
    expect UiError: owner.close()
    check owner.state == mobileClosing
    check not runtime.runtimeClosedInternal
    other.failDispose = false
    owner.close()
    check runtime.runtimeClosedInternal
    owner.close() # Completed terminal close is idempotent.

  test "failed attachment keeps its reserved Session for explicit cleanup":
    let f = Fixture()
    let owner = newMobileHost(f.factory())
    let native = newRecordingBackend(fullCapabilities())
    native.failPrepare = true
    native.failDispose = true
    expect UiError: discard owner.attach(native.backend, 400, 600, 1)
    check owner.state == mobileDetaching
    check not owner.runtime.runtimeClosedInternal
    let failed = owner.currentMount
    check failed.hostIdentity == owner.identity and failed.generation > 0
    check not owner.resume(failed)
    check native.disposeCalls == 1 # No hidden retry after attachBackend's attempt.
    native.failDispose = false
    check owner.detach(failed)
    check native.disposeCalls == 2
    let next = owner.attach(newRecordingBackend(fullCapabilities()).backend, 400, 600, 1)
    check next.generation > failed.generation
    check f.initializations == 1
    owner.close()

  test "foreign owner rejects before lifecycle, business or native calls":
    let f = Fixture()
    var threadId = 17'u64
    let owner = newMobileHost(f.factory(), proc(): uint64 = threadId)
    let native = newRecordingBackend(fullCapabilities())
    let a = owner.attach(native.backend, 400, 600, 1)
    threadId = 18
    expect UiError: discard owner.resume(a)
    expect UiError: discard owner.detach(a)
    expect UiError: owner.close()
    check native.disposeCalls == 0 and f.count.readAccepted() == 0
    threadId = 17
    owner.close()

  test "reentrant terminal close blocks notifications and defers native teardown":
    let f = Fixture()
    let owner = newMobileHost(f.factory())
    let runtime = owner.runtime
    let native = newRecordingBackend(fullCapabilities())
    let a = owner.attach(native.backend, 400, 600, 1)
    check owner.resume(a)
    var caught = false
    native.onSetter = proc(handle: NodeHandle) =
      try: owner.close()
      except UiError: caught = true
      doAssert native.disposeCalls == 0
      doAssert not runtime.runtimeClosedInternal
    check owner.enqueue(a, owner.message(a, 1))
    check owner.safeTurn(a)
    check caught and owner.state == mobileClosing
    check native.disposeCalls == 0
    check not owner.enqueue(a, owner.message(a, 2))
    owner.close()
    check native.disposed and runtime.runtimeClosedInternal

  test "restore generation advances do not invalidate Activity lifecycle identity":
    let f = Fixture()
    let owner = newMobileHost(f.factory())
    let native = newRecordingBackend(fullCapabilities())
    let a = owner.attach(native.backend, 400, 600, 1)
    check owner.resume(a)
    let session = owner.backendSession(a)
    native.failApply = true
    check owner.enqueue(a, owner.message(a, 1))
    check owner.safeTurn(a) # BackendSession consumes the rejected event error.
    check session.mountGeneration > a.generation
    check f.count.readAccepted() == 0
    check owner.pause(a) and owner.resume(a)
    native.failApply = false
    let recovered = owner.message(a, 2)
    check owner.enqueue(a, recovered)
    check owner.safeTurn(a)
    check f.count.readAccepted() == 1
    check owner.detach(a)
    let b = owner.attach(newRecordingBackend(fullCapabilities()).backend, 400, 600, 1)
    check b.generation > recovered.mountGeneration
    check owner.resume(b)
    check not owner.enqueue(b, recovered)
    owner.close()

  test "faulted Runtime cannot deliver tasks or acquire another backend":
    let f = Fixture()
    let owner = newMobileHost(f.factory())
    let native = newRecordingBackend(fullCapabilities())
    let a = owner.attach(native.backend, 400, 600, 1)
    check owner.resume(a)
    native.failApply = true
    native.failRestore = true
    check owner.enqueue(a, owner.message(a, 1))
    check owner.safeTurn(a) # A failed restore freezes future delivery.
    check owner.runtime.eventsFrozen
    check owner.backendSession(a).faulted
    check not owner.safeTurn(a)
    check f.count.readAccepted() == 0 and f.mounted == 0
    check owner.detach(a)
    let other = newRecordingBackend(fullCapabilities())
    expect UiError: discard owner.attach(other.backend, 400, 600, 1)
    check other.prepareCalls == 0 and other.disposeCalls == 0
    owner.close()

  test "invalid attachment context leaves the caller backend untouched":
    let f = Fixture()
    let owner = newMobileHost(f.factory())
    let native = newRecordingBackend(fullCapabilities())
    expect UiError: discard owner.attach(native.backend, 0, 600, 1)
    check owner.state == mobileDetached
    check owner.currentMount == MobileMount()
    check native.prepareCalls == 0 and native.disposeCalls == 0
    let a = owner.attach(native.backend, 400, 600, 1)
    check a.generation == 2
    owner.close()

  test "detached business updates reach new views without touching old native resources":
    let f = Fixture()
    let owner = newMobileHost(f.factory())
    let native = newRecordingBackend(fullCapabilities())
    let a = owner.attach(native.backend, 400, 600, 1)
    check owner.detach(a)
    let calls = native.applyCalls
    owner.runtime.uiTask(proc() = discard f.count.update(proc(old: int): int = old + 7))
    check f.count.readAccepted() == 7
    check native.disposed and native.applyCalls == calls
    let other = newRecordingBackend(fullCapabilities())
    let b = owner.attach(other.backend, 600, 400, 1)
    let handle = owner.backendSession(b).handleFor(owner.runtime.find("count").id)
    check other.entities[handle].props.accessibility.label.get == "7"
    check f.factoryCalls == 1 and f.initializations == 1
    owner.close()

  test "worker result waits through pause and reaches only the reattached views":
    workerStarted.store(false)
    workerFinished.store(false)
    releaseWorker.store(false)
    var scope: TaskScope
    var value: State[string]
    var callbacks = 0
    let Page = defineComponent[int, State[string]]("MobileWorker",
      proc(ctx: MountContext, props: int): State[string] =
        scope = ctx.taskScope(keepWhileRetained)
        result = ctx.state("pending")
        value = result,
      proc(ctx: ComponentContext, props: int, state: State[string]): UiDescription =
        host(text(ctx.value(state), key = "result")))
    let owner = newMobileHost(proc(): Application =
      componentApplication(component(Page, 0), "worker", 400, 600))
    let runtime = owner.runtime
    let service = runtime.taskServiceInternal()
    let old = newRecordingBackend(fullCapabilities())
    let a = owner.attach(old.backend, 400, 600, 1)
    try:
      check owner.resume(a)
      runtime.uiTask(proc() =
        discard startTask(scope, "copy", "copied 中文😀", retainedWork,
          proc(result: string) =
            inc callbacks
            discard value.set(result), maxResultBytes = 64))
      check owner.safeTurn(a)
      require waitFor(workerStarted)
      check owner.pause(a)
      releaseWorker.store(true)
      require waitFor(workerFinished) # Worker reached return; UI has not been pumped.
      check not owner.safeTurn(a)
      check callbacks == 0 and value.readAccepted() == "pending"
      check service.taskWorkerStatsInternal().reservedTasks == 1
      check owner.detach(a)
      let oldCalls = old.applyCalls
      let replacement = newRecordingBackend(fullCapabilities())
      let b = owner.attach(replacement.backend, 600, 400, 1)
      check owner.resume(b)
      for i in 0..<2000:
        discard owner.safeTurn(b)
        if callbacks > 0: break
        sleep(1)
      check callbacks == 1 and value.readAccepted() == "copied 中文😀"
      check old.disposed and old.applyCalls == oldCalls
      let handle = owner.backendSession(b).handleFor(runtime.find("result").id)
      check replacement.entities[handle].props.accessibility.label.get == "copied 中文😀"
      check service.taskWorkerStatsInternal().reservedTasks == 0
    finally:
      releaseWorker.store(true)
      owner.close()

  test "pause during native apply retains the rest of the captured event batch":
    let f = Fixture()
    let owner = newMobileHost(f.factory())
    let native = newRecordingBackend(fullCapabilities())
    let mount = owner.attach(native.backend, 400, 600, 1)
    check owner.resume(mount)
    native.onSetter = proc(handle: NodeHandle) = discard owner.pause(mount)
    check owner.enqueue(mount, owner.message(mount, 1))
    check owner.enqueue(mount, owner.message(mount, 2))
    check owner.safeTurn(mount)
    check f.count.readAccepted() == 1
    check owner.backendSession(mount).queuedEvents == 1
    native.onSetter = nil
    check owner.resume(mount)
    check owner.safeTurn(mount)
    check f.count.readAccepted() == 2
    check owner.backendSession(mount).queuedEvents == 0
    owner.close()

  test "pause during row construction preserves the remaining viewport request":
    var owner: MobileHost
    var mount: MobileMount
    var pauseDuringRows = false
    var firstBuilds, laterBuilds: int
    let lists = column(@[
      virtualList("first-list", @["first"], proc(index: int): Node =
        inc firstBuilds
        if pauseDuringRows: discard owner.pause(mount)
        text("first", key = "row"), rowHeight = 24, overscan = 0),
      virtualList("later-list", @["later"], proc(index: int): Node =
        inc laterBuilds
        text("later", key = "row"), rowHeight = 24, overscan = 0)])
    let Page = defineComponent[int, int]("MobileRows",
      proc(ctx: MountContext, props: int): int = props,
      proc(ctx: ComponentContext, props, model: int): UiDescription = host(lists))
    owner = newMobileHost(proc(): Application =
      componentApplication(component(Page, 0), "rows", 400, 600))
    mount = owner.attach(newRecordingBackend(fullCapabilities()).backend, 400, 600, 1)
    let session = owner.backendSession(mount)
    for key in ["first-list", "later-list"]:
      let list = owner.runtime.find(key)
      check session.queueRows(RowViewportRequest(sessionId: session.sessionId,
        mountGeneration: session.mountGeneration, listHandle: session.handleFor(list.id),
        sourceGeneration: list.node.listSource.generation, first: 0, finish: 1))
    pauseDuringRows = true
    check owner.resume(mount)
    check owner.safeTurn(mount)
    check firstBuilds == 1 and laterBuilds == 0
    check session.pendingRowRequests == 1
    pauseDuringRows = false
    check owner.resume(mount)
    check owner.safeTurn(mount)
    check firstBuilds == 1 and laterBuilds == 1
    check session.pendingRowRequests == 0
    owner.close()

  test "lifecycle pause or close stops later callbacks in the same pump":
    for terminal in [false, true]:
      var owner: MobileHost
      var mount: MobileMount
      var mounted, activated, scopeEntries: int
      let Page = defineComponent[int, int]("MobilePauseDuringDelivery",
        proc(ctx: MountContext, props: int): int =
          ctx.onMount(proc(event: LifecycleContext) =
            if props == 1: inc activated
            else:
              inc mounted
              if terminal:
                try: owner.close()
                except UiError: discard # Deferred to the ordinary host boundary.
              else: discard owner.pause(mount))
          props,
        proc(ctx: ComponentContext, props, model: int): UiDescription = host(text("page")))
      owner = newMobileHost(proc(): Application =
        componentApplication(hostShell(column(@[]), @[
          component(Page, 0, key = "first"), component(Page, 1, key = "later")]),
          "pause", 400, 600, executionScope = proc(body: proc() {.closure.}) =
            inc scopeEntries
            body()))
      mount = owner.attach(newRecordingBackend(fullCapabilities()).backend, 400, 600, 1)
      check owner.resume(mount)
      let entriesBefore = scopeEntries
      check owner.safeTurn(mount)
      check scopeEntries == entriesBefore + 1
      check mounted == 1 and activated == 0
      if not terminal:
        check owner.resume(mount)
        check owner.safeTurn(mount)
        check activated == 1
      owner.close()
