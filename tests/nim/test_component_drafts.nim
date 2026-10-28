import std/unittest
import leaf/[core, component_state]

suite "managed variable drafts":
  test "read own writes without publishing and reject consumes draft":
    let store = newStateStore(1)
    let count = store.allocateManagedState(10, 0)
    count.writeDraft(0)
    count.writeDraft(count.readDraft() + 1)
    count.writeDraft(count.readDraft() + 1)
    check count.readDraft() == 2
    check count.readAccepted() == 0
    let attempt = store.beginAttempt()
    check attempt.readCandidate(count) == 2
    store.reject(attempt)
    check count.readDraft() == 0
    let retry = store.beginAttempt()
    check retry.readCandidate(count) == 0
    store.accept(retry)

  test "separate callbacks share draft until accepted and equal values are quiet":
    let store = newStateStore(1)
    let count = store.allocateManagedState(10, 0, equal=proc(a,b:int):bool=a==b)
    proc increment() = count.writeDraft(count.readDraft() + 1)
    increment()
    increment()
    let attempt = store.beginAttempt()
    check attempt.readCandidate(count) == 2
    store.accept(attempt)
    check count.readAccepted() == 2
    count.writeDraft(2)
    let quiet = store.beginAttempt()
    check quiet.dirtyOwners.len == 0
    store.accept(quiet)

  test "legacy updater cannot enter managed slot and managed draft cannot enter legacy slot":
    let store = newStateStore(1)
    let managed = store.allocateManagedState(10, 0)
    let legacy = store.allocateState(11, 0)
    expect UiError: discard managed.queueUpdate(proc(x:int):int=x+1)
    expect UiError: discard managed.queueSet(9)
    expect UiError: legacy.writeDraft(8)
    expect UiError: discard legacy.readDraft()

  test "clearing rejected events clears drafts and disposal retires them":
    let store = newStateStore(1)
    let count = store.allocateManagedState(10, 0)
    count.writeDraft(9)
    store.clearQueued()
    check count.readDraft() == 0
    count.writeDraft(4)
    store.disposeOwner(10)
    expect UiError: discard count.readDraft()
    expect UiError: count.writeDraft(8)

  test "render and candidate phase cannot access event drafts":
    let store = newStateStore(1)
    let count = store.allocateManagedState(10, 0)
    store.setPhase(StatePhase.rendering)
    expect UiError: count.writeDraft(1)
    expect UiError: discard count.readDraft()
    store.setPhase(StatePhase.idle)
    let attempt = store.beginAttempt()
    expect UiError: count.writeDraft(1)
    store.reject(attempt)
