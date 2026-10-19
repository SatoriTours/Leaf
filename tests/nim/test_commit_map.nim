## Contract tests for the internal flat CommitMap. Behaviour is the assertion;
## allocation counters are observed only when the harness asks for them.
import std/[unittest, hashes, options, algorithm]
import leaf/[core, commit_map]

var destructions {.global.} = 0

type Payload = object
  marker: int
  counter: ptr int

proc `=destroy`(value: var Payload) =
  if value.counter != nil: inc value.counter[]

proc `=copy`(dest: var Payload, source: Payload) =
  if dest.counter != nil: inc dest.counter[]
  dest.marker = source.marker
  dest.counter = source.counter

proc `=sink`(dest: var Payload, source: Payload) =
  if dest.counter != nil: inc dest.counter[]
  dest.marker = source.marker
  dest.counter = source.counter

proc payload(marker: int): Payload = Payload(marker: marker, counter: addr destructions)

proc allocCount(): int =
  when defined(nimAllocStats):
    let stats = getAllocStats()
    for name, value in fieldPairs(stats):
      when name == "allocCount": result = value
  else: 0

proc requireNoAlloc(label: string, body: proc()) =
  when defined(nimAllocStats):
    let before = allocCount()
    body()
    let after = allocCount()
    checkpoint(label & " allocations=" & $(after - before))
    check after - before == 0
  else:
    checkpoint(label & " allocation counting disabled")
    body()

proc snapshot[K, V](map: CommitMap[K, V]): seq[(K, V)] =
  for key, value in map.pairs: result.add((key, value))
  result.sort(proc(a, b: (K, V)): int = cmp($a[0], $b[0]))

suite "commit map geometry":
  test "empty map owns no buckets and rejects nothing":
    var map = initCommitMap[string, int](11)
    check map.capacity == 0
    check map.len == 0
    check map.isEmpty
    check not map.hasKey("missing")
    check map.getOrDefault("missing", -1) == -1
    var pairs = 0
    for key, value in map.pairs: inc pairs
    check pairs == 0

  test "first prepared insert uses the minimal eight buckets":
    var map = initCommitMap[string, int](11)
    let patch = map.preparePatch(@[], @[("alpha", 1)], 64)
    check map.capacity == 8
    check map.len == 0
    map.publishPrepared(patch)
    check map.len == 1
    check map.getOrDefault("alpha", -1) == 1
    finishPublished(patch)
    check map.capacity == 8

  test "capacity grows only through prepare at the documented threshold":
    var map = initCommitMap[uint64, int](1)
    # P=3 -> nextPowerOfTwo(max(8, 3+1+4)) == 8.
    map.publishPrepared(map.preparePatch(@[], @[(1'u64, 1), (2'u64, 2), (3'u64, 3)], 128))
    check map.capacity == 8
    # P=4 -> nextPowerOfTwo(max(8, 4+2+4)) == 16.
    let grown = map.preparePatch(@[], @[(4'u64, 4)], 128)
    check map.capacity == 16
    check map.len == 3
    map.publishPrepared(grown)
    check map.len == 4
    finishPublished(grown)
    # A replacement patch inside existing capacity must not grow.
    let replacement = map.preparePatch(@[], @[(2'u64, 20)], 128)
    check map.capacity == 16
    requireNoAlloc("no-growth publish"):
      proc noGrowth() =
        map.publishPrepared(replacement)
        finishPublished(replacement)
      noGrowth()
    check map.getOrDefault(2'u64, -1) == 20

  test "prepare accounts for removals before additions at the peak":
    var map = initCommitMap[uint64, int](1)
    var initial: seq[(uint64, int)]
    for i in 0..<4: initial.add((uint64(i), i))
    map.publishPrepared(map.preparePatch(@[], initial, 128))
    check map.capacity == 16
    # Remove all four and add six in the same patch: peak = max(4, 6) = 6,
    # nextPowerOfTwo(max(8, 6+3+4)) == 16, so no growth is needed.
    let patch = map.preparePatch(@[0'u64, 1'u64, 2'u64, 3'u64],
      @[(10'u64, 10), (11'u64, 11), (12'u64, 12), (13'u64, 13), (14'u64, 14), (15'u64, 15)], 128)
    check map.capacity == 16
    map.publishPrepared(patch)
    check map.len == 6
    finishPublished(patch)

  test "committed capacity is reused by later tombstones":
    var map = initCommitMap[uint64, int](1)
    var batch: seq[(uint64, int)]
    for i in 0..<20: batch.add((uint64(i), i))
    map.publishPrepared(map.preparePatch(@[], batch, 128))
    let capacity = map.capacity
    for round in 0..<6:
      var removals: seq[uint64]
      var upserts: seq[(uint64, int)]
      for i in 0..<20:
        removals.add(uint64(i))
        upserts.add((uint64(i), round * 100 + i))
      let patch = map.preparePatch(removals, upserts, 128)
      check map.capacity == capacity
      map.publishPrepared(patch)
      finishPublished(patch)
      check map.len == 20
      check map.getOrDefault(7'u64, -1) == round * 100 + 7

  test "capacity arithmetic rejects overflow instead of wrapping":
    expect UiError: discard commitCapacity(high(int))
    expect UiError: discard commitCapacity(high(int) div 2)
    check commitCapacity(0) == 8
    check commitCapacity(1) == 8
    check commitCapacity(3) == 8
    check commitCapacity(4) == 16
    check commitCapacity(8) == 16
    check commitCapacity(9) == 32

suite "commit map owned keys":
  test "dynamic string keys insert, replace and delete without losing owners":
    var map = initCommitMap[string, int](21)
    var keys: seq[string]
    for i in 0..<40: keys.add("generated-key-" & $i & "-" & $i)
    var upserts: seq[(string, int)]
    for i, key in keys: upserts.add((key, i))
    let initial = map.preparePatch(@[], upserts, 128)
    map.publishPrepared(initial)
    finishPublished(initial)
    check map.len == 40
    for i, key in keys: check map.getOrDefault(key, -1) == i
    var replacements: seq[(string, int)]
    for i in 0..<40: replacements.add((keys[i], 100 + i))
    let replaced = map.preparePatch(@[], replacements, 128)
    map.publishPrepared(replaced)
    finishPublished(replaced)
    for i, key in keys: check map.getOrDefault(key, -1) == 100 + i
    let removed = map.preparePatch(keys, @[], 128)
    map.publishPrepared(removed)
    finishPublished(removed)
    check map.len == 0
    for key in keys: check not map.hasKey(key)

  test "collision chains stay addressable":
    var map = initCommitMap[string, int](3)
    let buckets = 8
    var bucket: seq[string]
    var candidate = 0
    while bucket.len < 3:
      let key = "collision-" & $candidate
      if (hash(key) and (buckets - 1)) == 0: bucket.add(key)
      inc candidate
    var upserts: seq[(string, int)]
    for i, key in bucket: upserts.add((key, i))
    map.publishPrepared(map.preparePatch(@[], upserts, 64))
    check map.capacity == 8
    for i, key in bucket: check map.getOrDefault(key, -1) == i
    # Delete a middle link, then reinsert it: the tombstone chain must still
    # find every later member.
    let middle = bucket[1]
    map.publishPrepared(map.preparePatch(@[middle], @[], 64))
    check not map.hasKey(middle)
    for i, key in bucket:
      if key != middle: check map.getOrDefault(key, -1) == i
    map.publishPrepared(map.preparePatch(@[], @[(middle, 42)], 64))
    check map.getOrDefault(middle, -1) == 42
    for i, key in bucket:
      if key != middle: check map.getOrDefault(key, -1) == i

  test "duplicate keys and duplicate removals fail in prepare":
    var map = initCommitMap[string, int](1)
    expect UiError: discard map.preparePatch(@[], @[("same", 1), ("same", 2)], 16)
    expect UiError: discard map.preparePatch(@["same", "same"], @[], 16)
    map.publishPrepared(map.preparePatch(@[], @[("kept", 7)], 16))
    expect UiError: discard map.preparePatch(@["kept"], @[("kept", 8), ("kept", 9)], 16)
    check map.getOrDefault("kept", -1) == 7

  test "entry limit is enforced before publication":
    var map = initCommitMap[string, int](1)
    expect UiError: discard map.preparePatch(@[], @[("a", 1), ("b", 2), ("c", 3)], 2)
    map.publishPrepared(map.preparePatch(@[], @[("a", 1), ("b", 2)], 2))
    expect UiError: discard map.preparePatch(@[], @[("c", 3)], 2)
    let freed = map.preparePatch(@["a"], @[("c", 3)], 2)
    map.publishPrepared(freed)
    check map.len == 2

suite "commit map patch identity":
  test "foreign, stale and duplicate publication are rejected":
    var first = initCommitMap[string, int](31)
    var second = initCommitMap[string, int](32)
    let patch = first.preparePatch(@[], @[("a", 1)], 16)
    expect UiError: second.validatePrepared(patch)
    expect UiError: second.publishPrepared(patch)
    first.publishPrepared(patch)
    check first.len == 1
    expect UiError: first.validatePrepared(patch)
    expect UiError: first.publishPrepared(patch)
    var other = initCommitMap[string, int](31)
    let stale = other.preparePatch(@[], @[("b", 2)], 16)
    other.publishPrepared(other.preparePatch(@[], @[("c", 3)], 16))
    expect UiError: other.publishPrepared(stale)

  test "discard keeps accepted content byte-for-byte":
    var map = initCommitMap[string, int](41)
    map.publishPrepared(map.preparePatch(@[], @[("a", 1), ("b", 2), ("c", 3)], 32))
    let before = map.snapshot()
    let capacityBefore = map.capacity
    let countBefore = map.len
    let patch = map.preparePatch(@["a"], @[("d", 4), ("b", 22)], 32)
    discard patch
    let discarded = map.preparePatch(@["a"], @[("d", 4), ("b", 22)], 32)
    discardPrepared(discarded)
    check map.snapshot() == before
    check map.capacity == capacityBefore
    check map.len == countBefore
    check not map.hasKey("d")

  test "retired values survive publish and are destroyed only in finish":
    destructions = 0
    var map = initCommitMap[string, Payload](51)
    let first = map.preparePatch(@[], @[("slot", payload(1))], 16)
    # Temporary construction copies are not part of a publication window.
    destructions = 0
    map.publishPrepared(first)
    finishPublished(first)
    check destructions == 0
    check map.len == 1
    let replacing = map.preparePatch(@[], @[("slot", payload(2))], 16)
    destructions = 0
    map.publishPrepared(replacing)
    check destructions == 0
    check replacing.retiredLen == 1
    finishPublished(replacing)
    check destructions == 1
    let removing = map.preparePatch(@["slot"], @[], 16)
    destructions = 0
    map.publishPrepared(removing)
    check map.len == 0
    check destructions == 0
    check removing.retiredLen == 1
    finishPublished(removing)
    check destructions == 1

  test "clear releases every accepted value outside a publish window":
    destructions = 0
    var map = initCommitMap[string, Payload](61)
    let initial = map.preparePatch(@[],
      @[("a", payload(1)), ("b", payload(2))], 16)
    destructions = 0
    map.publishPrepared(initial)
    finishPublished(initial)
    check destructions == 0
    map.clear()
    check map.len == 0
    check map.capacity == 0
    check destructions == 2

suite "key summaries":
  test "count and xor identity replace per-key sets":
    var summary = default(KeySummary)
    summary.addKey(7)
    check summary.count == 1
    check summary.uniqueId == 7
    summary.addKey(9)
    check summary.count == 2
    check not summary.isUnique
    summary.removeKey(7)
    check summary.count == 1
    check summary.uniqueId == 9
    summary.removeKey(9)
    check summary.count == 0
    expect UiError: summary.removeKey(9)
    expect UiError: discard summary.uniqueId

suite "r1 prepare accounting":
  test "same-key remove and upsert counts the re-added key":
    var map = initCommitMap[string, int](71)
    let initial = map.preparePatch(@[], @[("a", 1), ("b", 2), ("c", 3)], 3)
    map.publishPrepared(initial)
    finishPublished(initial)
    # Removing a and re-adding a plus d leaves four live entries, so limit 3
    # must reject even though a is temporarily removed.
    expect UiError: discard map.preparePatch(@["a"], @[("a", 10), ("d", 4)], 3)
    check map.len == 3
    check map.getOrDefault("a", -1) == 1
    check not map.hasKey("d")
    let allowed = map.preparePatch(@["a"], @[("a", 10), ("d", 4)], 4)
    check allowed.insertionCount == 2
    map.publishPrepared(allowed)
    finishPublished(allowed)
    check map.len == 4
    check map.getOrDefault("a", -1) == 10
    check map.getOrDefault("d", -1) == 4
    check map.getOrDefault("b", -1) == 2

  test "overlap on an absent key is a pure insertion":
    var map = initCommitMap[string, int](72)
    let patch = map.preparePatch(@["ghost"], @[("ghost", 9)], 1)
    check patch.insertionCount == 1
    map.publishPrepared(patch)
    finishPublished(patch)
    check map.len == 1
    check map.getOrDefault("ghost", -1) == 9

  test "pure replacement and removal-free no-op do not grow accepted storage":
    var map = initCommitMap[string, int](73)
    let initial = map.preparePatch(@[], @[("a", 1), ("b", 2)], 8)
    map.publishPrepared(initial)
    finishPublished(initial)
    let capacity = map.capacity
    let replacement = map.preparePatch(@[], @[("a", 5)], 8)
    check replacement.insertionCount == 0
    check map.capacity == capacity
    map.publishPrepared(replacement)
    finishPublished(replacement)
    check map.getOrDefault("a", -1) == 5
    let beforeNoop = map.capacity
    check map.preparePatch(@[], @[], 8) == nil
    check map.capacity == beforeNoop

  test "removal frees a slot at the exact limit":
    var map = initCommitMap[string, int](74)
    let initial = map.preparePatch(@[], @[("a", 1), ("b", 2), ("c", 3)], 3)
    map.publishPrepared(initial)
    finishPublished(initial)
    let patch = map.preparePatch(@["a"], @[("d", 4)], 3)
    map.publishPrepared(patch)
    finishPublished(patch)
    check map.len == 3
    check not map.hasKey("a")
    check map.getOrDefault("d", -1) == 4

  test "large patch path uses the same overlap accounting":
    var map = initCommitMap[string, int](75)
    var initial: seq[(string, int)]
    for i in 0..<12: initial.add(("k" & $i, i))
    map.publishPrepared(map.preparePatch(@[], initial, 20))
    var removals: seq[string]
    var upserts: seq[(string, int)]
    for i in 0..<6:
      removals.add("k" & $i)
      upserts.add(("k" & $i, 100 + i))
    upserts.add(("new-0", 200))
    upserts.add(("new-1", 201))
    # 12 - 6 + 8 == 14 live entries.
    expect UiError: discard map.preparePatch(removals, upserts, 13)
    let patch = map.preparePatch(removals, upserts, 14)
    check patch.insertionCount == 8
    map.publishPrepared(patch)
    finishPublished(patch)
    check map.len == 14
    check map.getOrDefault("k0", -1) == 100
    check map.getOrDefault("new-1", -1) == 201

  test "empty-map absent removals do not allocate buckets":
    var map = initCommitMap[string, int](76)
    let patch = map.preparePatch(@["ghost"], @[], 0)
    check map.capacity == 0
    check patch != nil
    map.publishPrepared(patch)
    finishPublished(patch)
    check map.len == 0
    check map.capacity == 0

  test "no-op prepare enforces limit without growing":
    var map = initCommitMap[string, int](77)
    map.publishPrepared(map.preparePatch(@[], @[("a", 1), ("b", 2)], 4))
    check map.capacity == 8
    expect UiError: discard map.preparePatch(@[], @[], 1)
    check map.capacity == 8
    check map.len == 2

suite "r1 patch identity":
  test "patch binds to one map instance even with identical owner and count":
    var first = initCommitMap[string, int](81)
    var second = initCommitMap[string, int](81)
    let patch = first.preparePatch(@[], @[("only-first", 42)], 8)
    expect UiError: second.validatePrepared(patch)
    expect UiError: second.publishPrepared(patch)
    check first.len == 0
    check second.len == 0
    first.publishPrepared(patch)
    finishPublished(patch)
    check first.len == 1
    check second.len == 0

  test "default owner zero maps still reject a foreign patch":
    var first = initCommitMap[string, int]()
    var second = initCommitMap[string, int]()
    let patch = first.preparePatch(@[], @[("v", 1)], 8)
    expect UiError: second.publishPrepared(patch)
    check second.len == 0

  test "outside mutation and clear invalidate sealed patches":
    var map = initCommitMap[string, int](82)
    map.publishPrepared(map.preparePatch(@[], @[("a", 1)], 8))
    let afterPut = map.preparePatch(@[], @[("b", 2)], 8)
    map.putOutsideCommit("c", 3)
    expect UiError: map.validatePrepared(afterPut)
    expect UiError: map.publishPrepared(afterPut)
    let afterRemove = map.preparePatch(@[], @[("d", 4)], 8)
    map.removeOutsideCommit("c")
    expect UiError: map.validatePrepared(afterRemove)
    let afterClear = map.preparePatch(@[], @[("e", 5)], 8)
    map.clear()
    expect UiError: map.validatePrepared(afterClear)
    check map.len == 0

  test "insertion counts are part of the prepared capacity contract":
    var map = initCommitMap[string, int](83)
    map.publishPrepared(map.preparePatch(@[], @[("a", 1), ("b", 2)], 8))
    let replacement = map.preparePatch(@[], @[("a", 9), ("b", 8)], 8)
    check replacement.insertionCount == 0
    let overlapping = map.preparePatch(@["a"], @[("a", 7), ("c", 3)], 8)
    check overlapping.insertionCount == 2
    map.publishPrepared(overlapping)
    finishPublished(overlapping)
    check map.len == 3

suite "r1 no-op laziness":
  test "empty no-op prepare allocates nothing":
    var map = initCommitMap[string, int](84)
    let before = allocCount()
    let patch = map.preparePatch(@[], @[], 64)
    let after = allocCount()
    check patch == nil
    check map.capacity == 0
    check after - before == 0

  test "no-op prepare keeps a below-threshold map untouched":
    var map = initCommitMap[uint64, int](85)
    for i in 0..<4: map.putOutsideCommit(uint64(100 + i), i)
    check map.capacity == 8
    let before = allocCount()
    let patch = map.preparePatch(@[], @[], 64)
    let after = allocCount()
    check patch == nil
    check map.capacity == 8
    check map.len == 4
    check after - before == 0
