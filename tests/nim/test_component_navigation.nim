import std/unittest
import leaf/[core, widgets, components, host_session, managed_runtime]

type Fault = enum noFault, pageBuild, validation, preparation, nativeApply
var router: ComponentRouter
var pageStates: array[3, State[int]]
var initializations, renders: array[3, int]
var fault: Fault
var visible = true
var candidateNames: seq[string]
var foreignOperation: int
var foreignProposal: NavigationBackProposal

let addresses = @[
  Route(name: "home", path: "/", page: "home", view: "main"),
  Route(name: "detail", path: "/detail", page: "detail", view: "main"),
  Route(name: "third", path: "/third", page: "third", view: "main")]

let Page = defineComponent[int, State[int]]("HistoryPage",
  proc(ctx: MountContext, index: int): State[int] =
    inc initializations[index]
    result = ctx.state(0)
    pageStates[index] = result,
  proc(ctx: ComponentContext, index: int, value: State[int]): UiDescription =
    inc renders[index]
    if fault == pageBuild and index != 0: fail("candidate page build")
    host(text($index & ":" & $ctx.value(value), key = "value")))

let pages = @[
  ComponentPageDefinition(name: "home", views: @["main"],
    build: proc(view: string): UiDescription = component(Page, 0)),
  ComponentPageDefinition(name: "detail", views: @["main"],
    build: proc(view: string): UiDescription = component(Page, 1)),
  ComponentPageDefinition(name: "third", views: @["main"],
    build: proc(view: string): UiDescription = component(Page, 2))]

let Navigation = defineComponent[int, int]("HistoryController",
  proc(ctx: MountContext, value: int): int =
    router = newComponentRouter(ctx, addresses, pages)
    value,
  proc(ctx: ComponentContext, value, model: int): UiDescription =
    candidateNames.setLen(0)
    for route in ctx.history(router): candidateNames.add(route.name)
    renderPage(ctx, router))

let Root = defineComponent[int, int]("HistoryRoot",
  proc(ctx: MountContext, value: int): int = value,
  proc(ctx: ComponentContext, value, model: int): UiDescription =
    if visible: component(Navigation, 0)
    else: host(text("removed", key = "removed")))

let Foreign = defineComponent[int, int]("ForeignHistoryCaller",
  proc(ctx: MountContext, value: int): int = value,
  proc(ctx: ComponentContext, value, model: int): UiDescription =
    host(button("foreign", key = "foreign", onClick = proc(event: Event) =
      case foreignOperation
      of 0: discard router.backProposal(61)
      of 1: discard router.cancelBack(60)
      else: discard router.confirmBack(foreignProposal))))

proc names(): seq[string] =
  for route in router.history: result.add(route.name)

proc fixture(): tuple[rt: Runtime, session: HostSession] =
  router = default(ComponentRouter)
  pageStates = default(array[3, State[int]])
  initializations = default(array[3, int])
  renders = default(array[3, int])
  fault = noFault
  visible = true
  candidateNames.setLen(0)
  let rt = newRuntime(componentApplication(component(Root, 0), "history"))
  rt.setValidator(proc(snapshot: Snapshot) =
    if fault == validation: fail("navigation validation"))
  let session = attachHostSession(rt, HostConsumer(sessionId: 301,
    prepare: proc(batch: HostBatch) =
      if fault == preparation: fail("navigation prepare"),
    apply: proc() =
      if fault == nativeApply: fail("navigation apply"),
    accept: proc(revision: uint64) {.raises: [].} = discard,
    discardPrepared: proc() {.raises: [].} = discard))
  (rt, session)

suite "ComponentRouter transactional history":
  test "navigate selects without pushing and same address does not render":
    let (rt, session) = fixture()
    defer: session.close()
    check names() == @["home"]
    check not router.canPop
    discard router.navigate("detail")
    check names() == @["home"]
    check rt.flush()
    check names() == @["detail"]
    let before = renders
    discard router.navigate("/detail")
    check rt.flush()
    check renders == before
    discard router.pop()
    check rt.flush()
    check names() == @["detail"]

  test "queued operations fold in order and expose only final candidate history":
    let (rt, session) = fixture()
    defer: session.close()
    discard router.push("detail")
    discard router.push("third")
    discard router.replace("detail")
    discard router.pop()
    check names() == @["home"]
    check rt.flush()
    check names() == @["home", "detail"]
    check candidateNames == names()
    check initializations == [1, 1, 0]
    check router.canPop

  test "push and pop retain existing page State without reinitialization":
    let (rt, session) = fixture()
    defer: session.close()
    discard pageStates[0].set(7)
    check rt.flush()
    discard router.push("detail")
    check rt.flush()
    discard pageStates[1].set(9)
    check rt.flush()
    discard router.push("third")
    check rt.flush()
    discard router.pop()
    check rt.flush()
    check rt.find("value").node.text == "1:9"
    discard router.pop()
    check rt.flush()
    check rt.find("value").node.text == "0:7"
    check initializations == [1, 1, 1]

  test "candidate failures leave accepted history and retained page State intact":
    for mode in [pageBuild, validation, preparation, nativeApply]:
      let (rt, session) = fixture()
      discard pageStates[0].set(7)
      check rt.flush()
      let before = rt.acceptedRevision
      fault = mode
      discard router.push("detail")
      expect UiError: discard rt.flush()
      check names() == @["home"]
      check currentRoute(router).name == "home"
      check rt.acceptedRevision == before
      check rt.find("value").node.text == "0:7"
      check pageStates[0].read() == 7
      check pageStates[1].set(10) == StateWriteResult.disposed
      fault = noFault
      check not rt.flush()
      check names() == @["home"]
      discard router.push("detail")
      check rt.flush()
      check names() == @["home", "detail"]
      session.close()

  test "back proposal is read only, stale after navigation and accepted once":
    let (rt, session) = fixture()
    defer: session.close()
    discard router.push("detail")
    discard router.push("third")
    check rt.flush()
    let stale = router.backProposal(10)
    discard router.replace("home")
    check rt.flush()
    check not router.confirmBack(stale)
    check not rt.flush()
    check names() == @["home", "detail", "home"]
    let proposal = router.backProposal(11)
    check names().len == 3
    check router.confirmBack(proposal)
    check not router.confirmBack(proposal)
    check rt.flush()
    check names() == @["home", "detail"]
    check not router.confirmBack(proposal)
    check not rt.flush()
    check names() == @["home", "detail"]
    let cancelled = router.backProposal(12)
    check router.cancelBack(cancelled.requestId)
    check not router.confirmBack(cancelled)
    check router.backProposal(12).requestId == 0
    check not rt.flush()
    check names() == @["home", "detail"]

  test "failed back consumes the external request but leaves accepted history intact":
    let (rt, session) = fixture()
    defer: session.close()
    discard router.push("detail")
    discard router.push("third")
    check rt.flush()
    let proposal = router.backProposal(21)
    fault = nativeApply
    check router.confirmBack(proposal)
    expect UiError: discard rt.flush()
    check names() == @["home", "detail", "third"]
    fault = noFault
    check not rt.flush()
    check not router.confirmBack(proposal)
    check not rt.flush()
    check router.confirmBack(router.backProposal(22))
    check rt.flush()
    check names() == @["home", "detail"]

  test "unknown routes are rejected before queueing and disposal stays terminal":
    let (rt, session) = fixture()
    defer: session.close()
    expect UiError: discard router.push("unknown")
    expect UiError: discard router.replace("unknown")
    check not rt.flush()
    discard router.push("detail")
    check rt.flush()
    let proposal = router.backProposal(31)
    visible = false
    rt.invalidateRoot()
    check rt.flush()
    check router.push("unknown") == StateWriteResult.disposed
    check router.replace("unknown") == StateWriteResult.disposed
    check router.pop() == StateWriteResult.disposed
    check not router.confirmBack(proposal)
    check not router.cancelBack(proposal.requestId)
    check pageStates[0].set(1) == StateWriteResult.disposed
    check pageStates[1].set(1) == StateWriteResult.disposed

  test "forged completion cannot consume a legitimate pending request":
    let (rt, session) = fixture()
    defer: session.close()
    discard router.push("detail")
    check rt.flush()
    let proposal = router.backProposal(41)
    var forged = proposal
    inc forged.toEntryId
    check not router.confirmBack(forged)
    check not rt.flush()
    check router.confirmBack(proposal)
    check rt.flush()
    check names() == @["home"]

  test "router copies share cancellation and a later request remains independent":
    let (rt, session) = fixture()
    defer: session.close()
    discard router.push("detail")
    check rt.flush()
    let alias = router
    let cancelled = alias.backProposal(51)
    check router.cancelBack(51)
    check not alias.cancelBack(51)
    check not alias.confirmBack(cancelled)
    let later = router.backProposal(52)
    check not alias.confirmBack(cancelled)
    check alias.confirmBack(later)
    check rt.flush()
    check names() == @["home"]

  test "pending back requests are bounded and cancellation frees capacity":
    let (rt, session) = fixture()
    defer: session.close()
    discard router.push("detail")
    check rt.flush()
    for request in 1..MaxNodes:
      check router.backProposal(uint64(request)).requestId == uint64(request)
    expect UiError: discard router.backProposal(uint64(MaxNodes + 1))
    check router.cancelBack(1)
    let next = router.backProposal(uint64(MaxNodes + 1))
    check next.requestId == uint64(MaxNodes + 1)
    check router.confirmBack(next)
    check rt.flush()
    check names() == @["home"]
    # The accepted revision changed, invalidating every older pending gesture.
    check not router.confirmBack(default(NavigationBackProposal))
    check not router.cancelBack(2)

  test "another executing Runtime cannot alter the request lifecycle":
    let (rt, session) = fixture()
    defer: session.close()
    discard router.push("detail")
    check rt.flush()
    foreignProposal = router.backProposal(60)
    let other = newRuntime(componentApplication(component(Foreign, 0), "foreign"))
    let otherSession = attachHostSession(other, HostConsumer(sessionId: 302,
      prepare: proc(batch: HostBatch) = discard,
      apply: proc() = discard,
      accept: proc(revision: uint64) {.raises: [].} = discard,
      discardPrepared: proc() {.raises: [].} = discard))
    defer: otherSession.close()
    for operation in 0..2:
      foreignOperation = operation
      expect UiError: discard other.dispatch("foreign", Event(kind: click))
      check not rt.flush()
    # Neither the foreign offer nor cancellation consumed the owner's facts.
    let next = router.backProposal(61)
    check next.requestId == 61
    check router.cancelBack(61)
    check router.confirmBack(foreignProposal)
    check rt.flush()
    check names() == @["home"]
