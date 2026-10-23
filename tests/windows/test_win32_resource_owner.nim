## State-sequence regression for the private Win32 resource carrier.
##
## Pure data: no native calls, no second backend. It proves the authority model
## the backend relies on: a window entry is the single per-window authority, a
## successful credential is recorded on that stable entry as its first step, a
## later operation failure keeps the entry (and the group) enumerable, and a work
## set rebuilt from the registry returns the *same* refs. It is not an OOM/native
## RED and does not replace the native park/exception regression.
import std/unittest
import leaf/[core, backend]
import leaf/backends/win32/resource_owner

proc fakeWindow(id: int): pointer = cast[pointer](uint(id))

suite "Win32 native resource carrier":
  test "credentialed ends survive a later failure and re-enumerate exactly":
    var registry: ResRegistry
    let group = newGroup(7'u64, "sig|row")
    let a = newEntry(fakeWindow(1), fakeWindow(0), NodeHandle(1), 11'u,
      101'u64, true, token = 1001'u64)
    let b = newEntry(fakeWindow(2), fakeWindow(1), NodeHandle(2), 12'u,
      102'u64, true, token = 1002'u64)
    let c = newEntry(fakeWindow(3), fakeWindow(2), NodeHandle(3), 0'u, 0'u64,
      false, token = 1003'u64)
    group.attachEntry(a)
    group.attachEntry(b)
    group.attachEntry(c)
    check group.entryCount == 3
    registry.reservePublish()
    check registry.publishOwner(group, gpParking)
    check registry.liveGroups == 1
    check group.phase == gpParking
    # A successful BOOL notes the credential on the stable entry first.
    noteSubclassRemoved(a)
    check a.phase == epSubclassRemoved
    noteWindowEnded(a)
    check a.phase == epEnded
    # A later operation fails: the group stays the single owner and the work set
    # is rebuilt from the registry, not from a local copy.
    group.phase = gpFailed
    group.primary = newException(UiError, "later operation failed")
    var rebuilt: seq[ResEntry]
    for g in registry.groups:
      for entry in g.entries:
        if entry.phase != epEnded: rebuilt.add(entry)
    check rebuilt.len == 2
    check rebuilt[0] == b
    check rebuilt[1] == c
    # The stable binding token travels with the same entry, never a copy.
    check rebuilt[0].token == 1002'u64
    check rebuilt[1].token == 1003'u64
    check a.token == 1001'u64
    check group.outstanding == 2
    # Replaying the already-recorded credentials is idempotent.
    noteWindowEnded(a)
    noteSubclassRemoved(a)
    check a.phase == epEnded
    check group.outstanding == 2
    noteWindowEnded(b)
    noteWindowEnded(c)
    check group.allEnded
    check registry.removeGroup(group)
    check registry.liveGroups == 0

  test "one stable group token across parked, borrowing and failed phases":
    var registry: ResRegistry
    let parked = newGroup(9'u64, "sig|row")
    let entry = newEntry(fakeWindow(10), fakeWindow(0), NodeHandle(10), 0'u,
      0'u64, false, token = 2001'u64)
    parked.attachEntry(entry)
    registry.reservePublish()
    check registry.publishOwner(parked, gpParking)
    parked.phase = gpParked
    # Only the same owner + signature may claim the reusable group; the phase
    # change keeps the same group and entry refs.
    check registry.takeParked(8'u64, "sig|row") == nil
    check registry.takeParked(9'u64, "other") == nil
    let claimed = registry.takeParked(9'u64, "sig|row")
    check claimed == parked
    check claimed.phase == gpBorrowing
    check claimed.entries[0] == entry
    check claimed.entries[0].token == 2001'u64
    # A failed borrow changes only the phase; the group is not reusable again.
    claimed.phase = gpFailed
    check claimed.primary == nil
    check registry.takeParked(9'u64, "sig|row") == nil
    # A later cleanup ends the entry and drops the group.
    noteWindowEnded(entry)
    check claimed.allEnded
    check registry.removeGroup(claimed)
    check registry.liveGroups == 0
