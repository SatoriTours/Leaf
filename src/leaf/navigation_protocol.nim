## Pure navigation metadata and native facts. No callbacks, route strings,
## Runtime, platform pointer, or second history stack crosses this boundary.
## Animation completion deliberately has a different type from a back request.
type
  HostNavigationProps* = object
    routerId*, historyRevision*, currentEntryId*, previousEntryId*: uint64
    depth*: int
  NavigationContext* = object
    ## The consumer supplies these facts from its accepted entity/binding.
    sessionId*, mountGeneration*, handle*, bindingGeneration*: uint64
    acceptedRevision*: uint64
    navigation*: HostNavigationProps
  NavigationBackPhase* {.pure.} = enum begin, cancel, confirm
  NavigationBackFact* = object
    sessionId*, mountGeneration*, handle*, bindingGeneration*: uint64
    observedRevision*, sequence*, requestId*: uint64
    navigation*: HostNavigationProps
    phase*: NavigationBackPhase
  NavigationAnimationCompletion* = object
    ## Display acknowledgement only. It cannot be passed to a back queue.
    sessionId*, mountGeneration*, handle*, bindingGeneration*: uint64
    historyRevision*, currentEntryId*, requestId*: uint64

proc invalidReason*(props: HostNavigationProps, depthLimit: int): string =
  if props.routerId == 0: return "navigation router identity must be nonzero"
  if props.historyRevision == 0: return "navigation revision must be nonzero"
  if props.currentEntryId == 0: return "navigation current entry must be nonzero"
  if props.depth < 1 or props.depth > depthLimit:
    return "navigation depth exceeds its history budget"
  if props.depth == 1:
    if props.previousEntryId != 0: return "root navigation cannot have a previous entry"
  elif props.previousEntryId == 0 or props.previousEntryId >= props.currentEntryId:
    return "navigation previous entry must precede current entry"
  ""

proc invalidReason*(context: NavigationContext, depthLimit: int): string =
  if context.sessionId == 0 or context.mountGeneration == 0 or
      context.handle == 0 or context.bindingGeneration == 0 or
      context.acceptedRevision == 0:
    return "navigation context has missing accepted identity"
  context.navigation.invalidReason(depthLimit)

proc backFactReason*(fact: NavigationBackFact, context: NavigationContext,
    depthLimit: int): string =
  let reason = context.invalidReason(depthLimit)
  if reason.len != 0: return reason
  if fact.sessionId != context.sessionId or
      fact.mountGeneration != context.mountGeneration or
      fact.handle != context.handle or
      fact.bindingGeneration != context.bindingGeneration:
    return "navigation fact belongs to another session, mount or binding"
  if fact.sequence == 0 or fact.requestId == 0:
    return "navigation fact requires sequence and request identities"
  if fact.observedRevision == 0 or fact.observedRevision > context.acceptedRevision:
    return "navigation fact observes an unaccepted revision"
  if fact.navigation != context.navigation:
    return "navigation fact belongs to another accepted history"
  if context.navigation.depth == 1: return "root back belongs to the host"
  ""
