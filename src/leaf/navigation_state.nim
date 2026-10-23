## Owned, bounded navigation values for ComponentRouter's transactional State.
## These operations prepare values only: they never mutate accepted State or
## drive platform animations. A host must separately fence cancelled requests
## and obsolete sessions/mounts before submitting a back proposal.
import ./[core, navigation_protocol]

type
  NavigationEntry* = object
    id*: uint64
    routeIndex*: int
  NavigationState* = object
    router: uint64
    routeCount: int
    stack: seq[NavigationEntry]
    version, entrySerial, backSerial: uint64
  NavigationBackProposal* = object
    ## All facts belong to the accepted history from which back was proposed.
    ## requestId==0 means no proposal (root or already accepted request).
    routerId*, requestId*, revision*, fromEntryId*, toEntryId*: uint64
    depth*: int

proc requireInitialized(value: NavigationState) =
  if value.router == 0 or value.stack.len == 0:
    fail("navigation history is not initialized")

proc validRoute(value: NavigationState, index: int) =
  value.requireInitialized()
  if index < 0 or index >= value.routeCount:
    fail("navigation route index is out of range")

proc initialNavigation*(routerId: uint64, routeCount, initialRoute: int): NavigationState =
  if routerId == 0: fail("navigation requires a router identity")
  if routeCount <= 0 or routeCount > MaxNodes:
    fail("navigation route count must be in 1..10000")
  if initialRoute < 0 or initialRoute >= routeCount:
    fail("initial navigation route index is out of range")
  NavigationState(router: routerId, routeCount: routeCount,
    stack: @[NavigationEntry(id: 1, routeIndex: initialRoute)],
    version: 1, entrySerial: 1)

proc snapshotNavigation*(value: NavigationState): NavigationState =
  ## Explicit ownership policy for State[NavigationState], including snapshots
  ## passed to updater/equality callbacks and accepted/candidate readers.
  result = value
  result.stack = newSeq[NavigationEntry](value.stack.len)
  for index, entry in value.stack: result.stack[index] = entry

proc depth*(value: NavigationState): int = value.stack.len
proc revision*(value: NavigationState): uint64 = value.version
proc lastBackRequest*(value: NavigationState): uint64 = value.backSerial
proc current*(value: NavigationState): NavigationEntry =
  value.requireInitialized()
  value.stack[^1]

proc entries*(value: NavigationState): seq[NavigationEntry] =
  ## An independently owned export, never the internal mutable sequence.
  result = newSeq[NavigationEntry](value.stack.len)
  for index, entry in value.stack: result[index] = entry

proc changed(value: NavigationState, newEntry: bool): NavigationState =
  if value.version == high(uint64): fail("navigation revision space exhausted")
  if newEntry and value.entrySerial == high(uint64):
    fail("navigation entry identity space exhausted")
  result = snapshotNavigation(value)
  inc result.version
  if newEntry: inc result.entrySerial

proc replaceRoute*(value: NavigationState, index: int): NavigationState =
  value.validRoute(index)
  result = value.changed(newEntry = true)
  result.stack[^1] = NavigationEntry(id: result.entrySerial, routeIndex: index)

proc selectRoute*(value: NavigationState, index: int): NavigationState =
  ## Compatibility navigate selects the current address without growing history.
  value.validRoute(index)
  if value.current.routeIndex == index: return value
  value.replaceRoute(index)

proc pushRoute*(value: NavigationState, index: int): NavigationState =
  value.validRoute(index)
  if value.stack.len >= MaxNodes: fail("navigation history exceeds 10000 entries")
  result = value.changed(newEntry = true)
  result.stack.add(NavigationEntry(id: result.entrySerial, routeIndex: index))

proc popRoute*(value: NavigationState): NavigationState =
  value.requireInitialized()
  if value.stack.len == 1: return value
  result = value.changed(newEntry = false)
  result.stack.setLen(result.stack.len - 1)

proc proposeBack*(value: NavigationState, requestId: uint64): NavigationBackProposal =
  ## Preparing or discarding this value has no effect on accepted history.
  ## At root, the host decides whether to close rather than queuing a pop.
  value.requireInitialized()
  if requestId == 0: fail("navigation back request identity must be nonzero")
  if value.stack.len < 2 or requestId <= value.backSerial: return
  NavigationBackProposal(routerId: value.router, requestId: requestId,
    revision: value.version, fromEntryId: value.stack[^1].id,
    toEntryId: value.stack[^2].id, depth: value.stack.len)

proc acceptBack*(value: NavigationState,
    proposal: NavigationBackProposal): NavigationState =
  ## Matching the version as well as both endpoints prevents a completion from
  ## popping again, or popping a newly selected/pushed/replaced current page.
  value.requireInitialized()
  if proposal.requestId == 0 or proposal.requestId <= value.backSerial or
      proposal.routerId != value.router or proposal.revision != value.version or
      proposal.depth != value.stack.len or value.stack.len < 2 or
      proposal.fromEntryId != value.stack[^1].id or
      proposal.toEntryId != value.stack[^2].id:
    return value
  result = value.popRoute()
  result.backSerial = proposal.requestId

proc hostNavigationProps*(value: NavigationState): HostNavigationProps =
  ## Only the current endpoints cross the native boundary; no history copy.
  value.requireInitialized()
  HostNavigationProps(routerId: value.router, historyRevision: value.version,
    currentEntryId: value.stack[^1].id,
    previousEntryId: (if value.stack.len > 1: value.stack[^2].id else: 0'u64),
    depth: value.stack.len)
