## Bounded UI-thread facts for a single native session/mount. This queue never
## calls business code, mutates history, publishes State, or drives animation.
## The adapter must supply accepted context and lifecycle/thread guards; after
## claiming a fact it must revalidate context immediately before UI delivery.
import std/options
import ./[core, navigation_protocol]

const MaxNativeNavigationRequests* = 256

type
  PendingBack = object
    fact: NavigationBackFact
    ready: bool
  NativeNavigation* = ref object
    session, mount, lastSequence, lastOffered: uint64
    capacity: int
    closed: bool
    requests: seq[PendingBack]

proc newNativeNavigation*(session, mount: uint64,
    capacity = MaxNativeNavigationRequests): NativeNavigation =
  if session == 0 or mount == 0: fail("native navigation requires a session and mount")
  if capacity < 1 or capacity > MaxNativeNavigationRequests:
    fail("native navigation request budget is outside 1..256")
  NativeNavigation(session: session, mount: mount, capacity: capacity)

proc pending*(queue: NativeNavigation): int =
  if queue == nil: 0 else: queue.requests.len

proc retire*(queue: NativeNavigation, handle: uint64) =
  ## Accepted removal/rebinding invalidates all requests for this container.
  if queue == nil: return
  var index = queue.requests.len
  while index > 0:
    dec index
    if queue.requests[index].fact.handle == handle: queue.requests.delete(index)

proc close*(queue: NativeNavigation) =
  if queue == nil: return
  queue.closed = true
  queue.requests.setLen(0)

proc sameRequest(a, b: NavigationBackFact): bool =
  a.sessionId == b.sessionId and a.mountGeneration == b.mountGeneration and
    a.handle == b.handle and a.bindingGeneration == b.bindingGeneration and
    a.requestId == b.requestId and a.navigation == b.navigation

proc record*(queue: NativeNavigation, context: NavigationContext,
    fact: NavigationBackFact): bool =
  if queue == nil or queue.closed or context.sessionId != queue.session or
      context.mountGeneration != queue.mount: return false
  if fact.backFactReason(context, MaxNodes).len != 0: return false
  if fact.sequence <= queue.lastSequence: return false
  case fact.phase
  of NavigationBackPhase.begin:
    if fact.requestId <= queue.lastOffered or queue.requests.len >= queue.capacity:
      return false
    queue.requests.add(PendingBack(fact: fact))
    queue.lastOffered = fact.requestId
  of NavigationBackPhase.cancel, NavigationBackPhase.confirm:
    var found = -1
    for index, request in queue.requests:
      if request.fact.sameRequest(fact):
        found = index
        break
    if found < 0: return false
    if fact.phase == NavigationBackPhase.cancel:
      queue.requests.delete(found)
    else:
      if queue.requests[found].ready: return false
      queue.requests[found] = PendingBack(fact: fact, ready: true)
  queue.lastSequence = fact.sequence
  true

proc nextReady*(queue: NativeNavigation): Option[NavigationBackFact] =
  ## Claim before invoking business. Consumer failure consumes this request;
  ## there is no idle retry. A new user request must have a newer identity.
  if queue == nil or queue.closed: return
  for index, request in queue.requests:
    if request.ready:
      result = some(request.fact)
      queue.requests.delete(index)
      return

proc claim*(queue: NativeNavigation, requestId: uint64): Option[NavigationBackFact] =
  ## BackendSession delivers the confirmation in its ordinary event order.
  ## Looking up that exact request prevents this separate fact ledger from
  ## changing the order of confirmations relative to clicks/input events.
  if queue == nil or queue.closed or requestId == 0: return
  for index, request in queue.requests:
    if request.fact.requestId == requestId and request.ready:
      result = some(request.fact)
      queue.requests.delete(index)
      return

proc facts*(queue: NativeNavigation): seq[NavigationBackFact] =
  ## Bounded owned snapshot for ordinary-turn retirement of stale bindings.
  ## Never called during accepted publication.
  if queue == nil or queue.closed: return
  for request in queue.requests: result.add(request.fact)
