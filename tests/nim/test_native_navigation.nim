import std/[unittest, options]
import leaf/[core, navigation_protocol, native_navigation]

proc page(depth = 3, revision = 7'u64): HostNavigationProps =
  HostNavigationProps(routerId: 41, historyRevision: revision,
    currentEntryId: 9, previousEntryId: (if depth > 1: 6'u64 else: 0'u64), depth: depth)

proc context(revision = 12'u64): NavigationContext =
  NavigationContext(sessionId: 101, mountGeneration: 2, handle: 55,
    bindingGeneration: 4, acceptedRevision: revision, navigation: page())

proc fact(request = 1'u64, sequence = 1'u64,
    phase = NavigationBackPhase.begin): NavigationBackFact =
  NavigationBackFact(sessionId: 101, mountGeneration: 2, handle: 55,
    bindingGeneration: 4, observedRevision: 12, sequence: sequence,
    requestId: request, phase: phase, navigation: page())

suite "native navigation request boundary":
  test "metadata describes a bounded stack and root has no previous entry":
    check page().invalidReason(10000) == ""
    check page(1).invalidReason(10000) == ""
    for field in 0..6:
      var invalid = page()
      case field
      of 0: invalid.routerId = 0
      of 1: invalid.historyRevision = 0
      of 2: invalid.currentEntryId = 0
      of 3: invalid.previousEntryId = 0
      of 4: invalid.previousEntryId = invalid.currentEntryId
      of 5: invalid.depth = 0
      else: invalid.depth = 10001
      check invalid.invalidReason(10000).len > 0
    var invalidRoot = page(1)
    invalidRoot.previousEntryId = 2
    check invalidRoot.invalidReason(10000).len > 0

  test "request phase notifications record facts without invoking business":
    let queue = newNativeNavigation(101, 2)
    check queue.record(context(), fact())
    check queue.pending == 1
    check queue.nextReady().isNone
    check queue.record(context(), fact(sequence = 2, phase = NavigationBackPhase.confirm))
    let ready = queue.nextReady().get
    check ready.requestId == 1
    check ready.phase == NavigationBackPhase.confirm
    check ready.navigation == page()
    check queue.pending == 0
    check queue.nextReady().isNone

  test "cancel before claim fences even an already recorded confirmation":
    let queue = newNativeNavigation(101, 2)
    check queue.record(context(), fact())
    check queue.record(context(), fact(sequence = 2, phase = NavigationBackPhase.confirm))
    check queue.record(context(), fact(sequence = 3, phase = NavigationBackPhase.cancel))
    check queue.pending == 0
    check not queue.record(context(), fact(sequence = 4, phase = NavigationBackPhase.confirm))
    check not queue.record(context(), fact(sequence = 5))
    check queue.nextReady().isNone

  test "all session mount binding and accepted navigation identities are checked":
    for field in 0..12:
      let queue = newNativeNavigation(101, 2)
      var stale = fact()
      case field
      of 0: stale.sessionId = 102
      of 1: stale.mountGeneration = 3
      of 2: stale.handle = 56
      of 3: stale.bindingGeneration = 5
      of 4: stale.observedRevision = 13
      of 5: stale.observedRevision = 0
      of 6: stale.navigation.routerId = 42
      of 7: stale.navigation.historyRevision = 8
      of 8: stale.navigation.currentEntryId = 10
      of 9: stale.navigation.previousEntryId = 5
      of 10: stale.navigation.depth = 4
      of 11: stale.requestId = 0
      else: stale.sequence = 0
      check not queue.record(context(), stale)
      check queue.pending == 0
      # Rejection cannot consume the valid sequence/request identity.
      check queue.record(context(), fact())

  test "a foreign context cannot make an old queue valid after reattachment":
    let old = newNativeNavigation(101, 2)
    var nextContext = context()
    var nextFact = fact()
    nextContext.mountGeneration = 3
    nextFact.mountGeneration = 3
    check not old.record(nextContext, nextFact)
    let fresh = newNativeNavigation(101, 3)
    check fresh.record(nextContext, nextFact)

  test "unrelated accepted revisions preserve the same navigation request":
    let queue = newNativeNavigation(101, 2)
    check queue.record(context(), fact())
    var completion = fact(sequence = 2, phase = NavigationBackPhase.confirm)
    completion.observedRevision = 13
    check queue.record(context(14), completion)
    let ready = queue.nextReady().get
    check ready.observedRevision == 13
    check ready.backFactReason(context(15), 10000) == ""
    var changed = context(15)
    changed.navigation = page(revision = 8)
    check ready.backFactReason(changed, 10000).len > 0

  test "stale navigation after begin cannot confirm a different history":
    let queue = newNativeNavigation(101, 2)
    check queue.record(context(), fact())
    var changed = context()
    changed.navigation = page(revision = 8)
    var forged = fact(sequence = 2, phase = NavigationBackPhase.confirm)
    forged.navigation = changed.navigation
    check not queue.record(changed, forged)
    check not queue.record(changed, fact(sequence = 2, phase = NavigationBackPhase.confirm))
    check queue.nextReady().isNone

  test "duplicates and completion without begin never enqueue a pop":
    let queue = newNativeNavigation(101, 2)
    check not queue.record(context(), fact(phase = NavigationBackPhase.confirm))
    check queue.record(context(), fact())
    check not queue.record(context(), fact())
    check queue.record(context(), fact(sequence = 2, phase = NavigationBackPhase.confirm))
    check not queue.record(context(), fact(sequence = 3, phase = NavigationBackPhase.confirm))
    discard queue.nextReady()
    check not queue.record(context(), fact(sequence = 3, phase = NavigationBackPhase.confirm))
    check queue.nextReady().isNone

  test "bounded request capacity rejects before consuming ids and cancel frees it":
    let queue = newNativeNavigation(101, 2, capacity = 2)
    check queue.record(context(), fact(1, 1))
    check queue.record(context(), fact(2, 2))
    check not queue.record(context(), fact(3, 3))
    check queue.record(context(), fact(1, 3, NavigationBackPhase.cancel))
    check queue.record(context(), fact(3, 4))
    check queue.pending == 2

  test "ready requests retain begin order and claiming consumes once":
    let queue = newNativeNavigation(101, 2)
    check queue.record(context(), fact(1, 1))
    check queue.record(context(), fact(2, 2))
    check queue.record(context(), fact(2, 3, NavigationBackPhase.confirm))
    check queue.record(context(), fact(1, 4, NavigationBackPhase.confirm))
    check queue.nextReady().get.requestId == 1
    check queue.nextReady().get.requestId == 2
    check queue.nextReady().isNone
    # A consumer failure never schedules an implicit retry.
    check not queue.record(context(), fact(2, 5, NavigationBackPhase.confirm))

  test "root delegates back to host and close invalidates pending callbacks":
    let queue = newNativeNavigation(101, 2)
    var rootContext = context()
    var rootFact = fact()
    rootContext.navigation = page(1)
    rootFact.navigation = page(1)
    check not queue.record(rootContext, rootFact)
    check queue.record(context(), fact())
    queue.close()
    check queue.pending == 0
    check not queue.record(context(), fact(sequence = 2, phase = NavigationBackPhase.confirm))
    check queue.nextReady().isNone

  test "queue constructor refuses missing ownership or unbounded capacity":
    expect UiError: discard newNativeNavigation(0, 2)
    expect UiError: discard newNativeNavigation(101, 0)
    expect UiError: discard newNativeNavigation(101, 2, capacity = 0)
    expect UiError: discard newNativeNavigation(101, 2, capacity = 257)

  test "accepted removal retires its requests without reopening old identities":
    let queue = newNativeNavigation(101, 2, capacity = 1)
    check queue.record(context(), fact())
    queue.retire(55)
    check queue.pending == 0
    check not queue.record(context(), fact(sequence = 2, phase = NavigationBackPhase.confirm))
    check not queue.record(context(), fact(sequence = 2))
    check queue.record(context(), fact(2, 2))

  test "consumer revalidation rejects facts claimed before a binding changed":
    let queue = newNativeNavigation(101, 2)
    check queue.record(context(), fact())
    check queue.record(context(), fact(sequence = 2, phase = NavigationBackPhase.confirm))
    let claimed = queue.nextReady().get
    var changed = context()
    inc changed.bindingGeneration
    check claimed.backFactReason(changed, 10000).len > 0
    check queue.nextReady().isNone

  test "shared event ordering can claim a particular confirmed request":
    let queue = newNativeNavigation(101, 2)
    check queue.record(context(), fact(1, 1))
    check queue.record(context(), fact(2, 2))
    check queue.record(context(), fact(2, 3, NavigationBackPhase.confirm))
    check queue.record(context(), fact(1, 4, NavigationBackPhase.confirm))
    check queue.claim(2).get.requestId == 2
    check queue.pending == 1
    check queue.claim(2).isNone
    check queue.claim(1).get.requestId == 1
    check queue.pending == 0

  test "an unknown or unconfirmed queued event cannot consume another request":
    let queue = newNativeNavigation(101, 2)
    check queue.record(context(), fact())
    check queue.claim(1).isNone
    check queue.claim(99).isNone
    check queue.pending == 1
    check queue.record(context(), fact(sequence = 2, phase = NavigationBackPhase.confirm))
    check queue.claim(1).isSome
    check not queue.record(context(), fact(sequence = 3, phase = NavigationBackPhase.cancel))

  test "fact snapshots cannot mutate pending request identity":
    let queue = newNativeNavigation(11, 22)
    # Independent accepted values; changing the owned export cannot cancel it.
    let context = NavigationContext(sessionId: 11, mountGeneration: 22,
      handle: 33, bindingGeneration: 44, acceptedRevision: 1,
      navigation: HostNavigationProps(routerId: 55, historyRevision: 1,
        currentEntryId: 2, previousEntryId: 1, depth: 2))
    var fact = NavigationBackFact(sessionId: 11, mountGeneration: 22,
      handle: 33, bindingGeneration: 44, observedRevision: 1, sequence: 1,
      requestId: 1, navigation: context.navigation, phase: NavigationBackPhase.begin)
    check queue.record(context, fact)
    var exported = queue.facts()
    exported[0].requestId = 99
    fact.sequence = 2
    fact.phase = NavigationBackPhase.confirm
    check queue.record(context, fact)
    check queue.claim(1).isSome
    check queue.pending == 0
