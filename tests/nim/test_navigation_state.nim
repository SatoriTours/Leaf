import std/unittest
import leaf/[core, component_state, navigation_state]

suite "transactional navigation history":
  test "select preserves depth while push, replace and pop have explicit history":
    let root = initialNavigation(41, 4, 0)
    let selected = root.selectRoute(1)
    check selected.depth == 1
    check selected.current.routeIndex == 1
    check selected.selectRoute(1) == selected
    let pushed = selected.pushRoute(2).pushRoute(2)
    check pushed.depth == 3
    check pushed.entries[1].id != pushed.entries[2].id
    let replaced = pushed.replaceRoute(3)
    check replaced.depth == 3
    check replaced.current.routeIndex == 3
    check replaced.current.id != pushed.current.id
    let popped = replaced.popRoute()
    check popped.current == pushed.entries[1]
    check popped.popRoute().current == selected.current
    check root.popRoute() == root
    check root.depth == 1

  test "entry identity is never reused after accepted pops":
    let original = initialNavigation(41, 3, 0).pushRoute(1)
    let next = original.popRoute().pushRoute(1)
    check next.current.id > original.current.id
    check next.revision > original.revision
    check original.current.routeIndex == 1

  test "history snapshots and exported entries cannot modify their source":
    let original = initialNavigation(41, 3, 0).pushRoute(1)
    var escaped = original.entries
    escaped[0].routeIndex = 2
    escaped[1].id = 999
    let changed = snapshotNavigation(original).replaceRoute(2)
    check original.entries[0].routeIndex == 0
    check original.current.id != 999
    check original.current.routeIndex == 1
    check changed.current.routeIndex == 2

  test "root back belongs to the host and zero request identity is invalid":
    let root = initialNavigation(41, 3, 0)
    check root.proposeBack(1).requestId == 0
    check root.acceptBack(default(NavigationBackProposal)) == root
    expect UiError: discard root.proposeBack(0)

  test "a back proposal is read only and confirms exactly once":
    let previous = initialNavigation(41, 3, 0).pushRoute(1).pushRoute(2)
    let proposal = previous.proposeBack(71)
    check proposal.requestId == 71
    check previous.depth == 3
    let accepted = previous.acceptBack(proposal)
    check accepted.depth == 2
    check accepted.current == previous.entries[1]
    check accepted.lastBackRequest == 71
    check accepted.acceptBack(proposal) == accepted
    check accepted.proposeBack(71).requestId == 0
    check accepted.proposeBack(70).requestId == 0
    check accepted.proposeBack(72).requestId == 72

  test "changed address, history or router rejects old platform proposals":
    let previous = initialNavigation(41, 4, 0).pushRoute(1).pushRoute(2)
    let proposal = previous.proposeBack(71)
    for changed in [previous.selectRoute(3), previous.replaceRoute(2),
        previous.pushRoute(3), previous.popRoute(),
        initialNavigation(42, 4, 0).pushRoute(1).pushRoute(2)]:
      check changed.acceptBack(proposal) == changed

  test "every proposal identity fact is checked before popping":
    let previous = initialNavigation(41, 3, 0).pushRoute(1)
    let proposal = previous.proposeBack(71)
    var invalid = proposal
    invalid.routerId = 42
    check previous.acceptBack(invalid) == previous
    invalid = proposal
    invalid.requestId = 0
    check previous.acceptBack(invalid) == previous
    invalid = proposal
    inc invalid.revision
    check previous.acceptBack(invalid) == previous
    invalid = proposal
    inc invalid.fromEntryId
    check previous.acceptBack(invalid) == previous
    invalid = proposal
    inc invalid.toEntryId
    check previous.acceptBack(invalid) == previous
    invalid = proposal
    inc invalid.depth
    check previous.acceptBack(invalid) == previous

  test "route validation precedes transitions and retained size is bounded":
    expect UiError: discard initialNavigation(0, 3, 0)
    expect UiError: discard initialNavigation(41, 0, 0)
    expect UiError: discard initialNavigation(41, MaxNodes + 1, 0)
    expect UiError: discard initialNavigation(41, 3, -1)
    expect UiError: discard initialNavigation(41, 3, 3)
    let root = initialNavigation(41, 3, 0)
    for index in [-1, 3, high(int)]:
      expect UiError: discard root.selectRoute(index)
      expect UiError: discard root.pushRoute(index)
      expect UiError: discard root.replaceRoute(index)
    var full = root
    for index in 1..<MaxNodes: full = full.pushRoute(index mod 3)
    check full.depth == MaxNodes
    expect UiError: discard full.pushRoute(0)
    check full.depth == MaxNodes
    check full.replaceRoute(2).depth == MaxNodes
    check full.popRoute().depth == MaxNodes - 1

  test "several queued history operations compose inside one candidate":
    let store = newStateStore(1)
    let history = store.allocateState(10, initialNavigation(41, 4, 0),
      equal = proc(a, b: NavigationState): bool = a == b,
      snapshot = snapshotNavigation)
    discard history.queueUpdate(proc(value: NavigationState): NavigationState =
      value.pushRoute(1))
    discard history.queueUpdate(proc(value: NavigationState): NavigationState =
      value.pushRoute(2).replaceRoute(3))
    let attempt = store.beginAttempt()
    check history.readAccepted().depth == 1
    check attempt.readCandidate(history).depth == 3
    check attempt.readCandidate(history).current.routeIndex == 3
    store.accept(attempt)
    check history.readAccepted().entries[1].routeIndex == 1
    check history.readAccepted().current.routeIndex == 3

  test "rejected candidate leaves the accepted stack and back receipt unchanged":
    let store = newStateStore(1)
    let original = initialNavigation(41, 3, 0).pushRoute(1).pushRoute(2)
    let history = store.allocateState(10, original, snapshot = snapshotNavigation)
    let proposal = original.proposeBack(71)
    discard history.queueUpdate(proc(value: NavigationState): NavigationState =
      value.acceptBack(proposal))
    let attempt = store.beginAttempt()
    check attempt.readCandidate(history).depth == 2
    check history.readAccepted() == original
    store.reject(attempt)
    check history.readAccepted() == original
    let ordinary = store.beginAttempt()
    check ordinary.readCandidate(history) == original
    store.accept(ordinary)
    # A retry must be explicitly queued; rejection has no hidden automatic pop.
    discard history.queueUpdate(proc(value: NavigationState): NavigationState =
      value.acceptBack(proposal))
    let retry = store.beginAttempt()
    store.accept(retry)
    check history.readAccepted().depth == 2
    check history.readAccepted().lastBackRequest == 71

  test "an updater failure cannot publish earlier history edits in its batch":
    let store = newStateStore(1)
    let original = initialNavigation(41, 3, 0)
    let history = store.allocateState(10, original, snapshot = snapshotNavigation)
    discard history.queueUpdate(proc(value: NavigationState): NavigationState =
      value.pushRoute(1))
    discard history.queueUpdate(proc(value: NavigationState): NavigationState =
      value.pushRoute(3))
    expect UiError: discard store.beginAttempt()
    check history.readAccepted() == original
    let ordinary = store.beginAttempt()
    check ordinary.readCandidate(history) == original
    store.accept(ordinary)

  test "disposed history rejects new navigation without resurrecting pages":
    let store = newStateStore(1)
    let history = store.allocateState(10, initialNavigation(41, 3, 0),
      snapshot = snapshotNavigation)
    store.disposeOwner(10)
    check history.queueUpdate(proc(value: NavigationState): NavigationState =
      value.pushRoute(1)) == StateWriteResult.disposed
