## Internal flat map used by accepted runtime state only. Keys are framework
## handled (string/uint64/discrete handles); application hash/equality never
## runs here. Empty maps own no buckets. Capacity only changes in prepare, so
## an accepted publication just moves values into pre-sized slots: no implicit
## table growth, no key allocation and no user destructor runs.
##
## `KeySummary` replaces the old per-key HashSet used for node-key uniqueness:
## only the active key count and one xor identity are stored per key.
import std/hashes
import ./core

type
  KeySummary* = object
    ## Active host count for a logical key plus the xor of their identities.
    ## With count == 1 the xor is that identity; otherwise the key is ambiguous
    ## and the identity is never exposed as a unique owner.
    count*: int
    xorId*: uint64

  MapSlotState = enum
    slotEmpty, slotUsed, slotTombstone

  MapSlot[K, V] = object
    state: MapSlotState
    key: K
    value: V

  CommitMap*[K, V] = object
    owner*: uint64
    generation*: uint64
    identity: uint64
    slots: seq[MapSlot[K, V]]
    count*: int
    tombstones*: int

  PatchStatus = enum
    patchSealed, patchPublished, patchDiscarded, patchFinished

  PreparedMapPatch*[K, V] = ref object
    ## Owned candidate delta: keys/values are moved into the accepted map on
    ## publication, and replaced/removed accepted values move here so they are
    ## destroyed only by `finishPublished` after the whole commit accepted.
    owner: uint64
    mapIdentity: uint64
    baseGeneration: uint64
    baseCount: int
    entries: seq[(K, V)]
    removals: seq[K]
    retiredKeys: seq[K]
    retiredValues: seq[V]
    inlineKey: K
    inlineValue: V
    inlineUsed: bool
    retireCapacity: int
    retiredCount: int
    insertions: int
    status: PatchStatus

proc keyHash[K](key: K): uint64 =
  when K is string:
    result = uint64(hash(key))
  elif K is SomeInteger:
    result = uint64(hash(key))
  else:
    when compiles(uint64(key)):
      result = uint64(hash(uint64(key)))
    elif compiles(hash(key)):
      result = uint64(hash(key))
    else:
      {.error: "CommitMap key needs a framework hash".}

proc keyEq[K](left, right: K): bool =
  when K is string:
    result = left == right
  else:
    when compiles(uint64(left)):
      result = uint64(left) == uint64(right)
    else:
      result = left == right

var nextCommitMapIdentity {.global.}: uint64

proc initCommitMap*[K, V](owner: uint64 = 0): CommitMap[K, V] =
  ## Deliberately lazy: an empty map owns no bucket sequence. The identity is a
  ## process-local monotonic token, never an address: a patch can only publish
  ## into the exact map instance that prepared it.
  if nextCommitMapIdentity == high(uint64): fail("commit map identity exhausted")
  inc nextCommitMapIdentity
  result.owner = owner
  result.identity = nextCommitMapIdentity

proc len*[K, V](map: CommitMap[K, V]): int = map.count
proc isEmpty*[K, V](map: CommitMap[K, V]): bool = map.count == 0
proc capacity*[K, V](map: CommitMap[K, V]): int = map.slots.len

proc commitCapacity*(peak: int): int =
  ## S(P) = nextPowerOfTwo(max(8, P + P div 2 + 4)); checked arithmetic.
  if peak < 0: fail("commit map peak must be nonnegative")
  if peak > (high(int) - 4) div 3 * 2:
    fail("commit map capacity arithmetic overflow")
  var needed = peak + peak div 2 + 4
  if needed < 8: needed = 8
  result = 1
  while result < needed:
    if result > high(int) div 2:
      fail("commit map capacity arithmetic overflow")
    result = result shl 1

proc maxSlotIndex[K, V](map: CommitMap[K, V]): int = map.slots.len - 1

type LocateResult = object
  usedIndex: int
  insertIndex: int

proc locate[K, V](map: CommitMap[K, V], key: K): LocateResult =
  ## Linear probing with tombstones. `usedIndex` is the accepted entry, or -1.
  ## `insertIndex` is the first tombstone/empty slot for a new entry, or -1
  ## when the table is physically full.
  result.usedIndex = -1
  result.insertIndex = -1
  let mask = maxSlotIndex(map)
  if mask < 0: return
  var index = int(keyHash(key) and uint64(mask))
  var firstTombstone = -1
  var probes = 0
  while probes <= mask:
    case map.slots[index].state
    of slotEmpty:
      result.insertIndex = if firstTombstone >= 0: firstTombstone else: index
      return
    of slotTombstone:
      if firstTombstone < 0: firstTombstone = index
    of slotUsed:
      if keyEq(map.slots[index].key, key):
        result.usedIndex = index
        return
    index = (index + 1) and mask
    inc probes
  result.insertIndex = firstTombstone

proc hasKey*[K, V](map: CommitMap[K, V], key: K): bool =
  map.locate(key).usedIndex >= 0

proc getOrDefault*[K, V](map: CommitMap[K, V], key: K): V =
  let index = map.locate(key).usedIndex
  if index >= 0: map.slots[index].value else: default(V)

proc getOrDefault*[K, V](map: CommitMap[K, V], key: K, default: V): V =
  let index = map.locate(key).usedIndex
  if index >= 0: map.slots[index].value else: default

iterator pairs*[K, V](map: CommitMap[K, V]): (K, V) =
  for index in 0..<map.slots.len:
    if map.slots[index].state == slotUsed:
      yield (map.slots[index].key, map.slots[index].value)

iterator keys*[K, V](map: CommitMap[K, V]): K =
  for index in 0..<map.slots.len:
    if map.slots[index].state == slotUsed:
      yield map.slots[index].key

iterator values*[K, V](map: CommitMap[K, V]): V =
  for index in 0..<map.slots.len:
    if map.slots[index].state == slotUsed:
      yield map.slots[index].value

proc grow[K, V](map: var CommitMap[K, V], target: int) =
  ## Prepare-only O(N) rebuild. Accepted logical content is unchanged; a
  ## rejected candidate may keep the enlarged physical capacity.
  if target <= map.slots.len: return
  var slots = newSeq[MapSlot[K, V]](target)
  let mask = target - 1
  for index in 0..<map.slots.len:
    if map.slots[index].state != slotUsed: continue
    var targetIndex = int(keyHash(map.slots[index].key) and uint64(mask))
    while slots[targetIndex].state == slotUsed:
      targetIndex = (targetIndex + 1) and mask
    slots[targetIndex].state = slotUsed
    slots[targetIndex].key = move(map.slots[index].key)
    slots[targetIndex].value = move(map.slots[index].value)
  map.slots = move(slots)
  map.tombstones = 0

proc insertScratch[K, V](map: var CommitMap[K, V], key: K, value: V) =
  ## Prepare-only scratch insertion for duplicate/membership accounting.
  let occupied = map.count + map.tombstones
  if map.slots.len == 0 or (occupied + 1) * 2 > map.slots.len:
    map.grow(commitCapacity(occupied + 1))
  let location = map.locate(key)
  if location.usedIndex >= 0:
    map.slots[location.usedIndex].value = value
    inc map.generation
    return
  doAssert location.insertIndex >= 0
  let slot = addr map.slots[location.insertIndex]
  if slot.state == slotTombstone: dec map.tombstones
  slot.state = slotUsed
  slot.key = key
  slot.value = value
  inc map.count
  inc map.generation

proc duplicateRemoval[K](removals: openArray[K], index: int): bool =
  for i in 0..<index:
    if keyEq(removals[i], removals[index]): return true
  false

proc duplicateUpsert[K, V](upserts: openArray[(K, V)], index: int): bool =
  for i in 0..<index:
    if keyEq(upserts[i][0], upserts[index][0]): return true
  false

proc inRemovals[K](removals: openArray[K], key: K): bool =
  for candidate in removals:
    if keyEq(candidate, key): return true
  false

proc preparePatch*[K, V](map: var CommitMap[K, V], removals: sink seq[K],
    upserts: sink seq[(K, V)], limit: int): PreparedMapPatch[K, V] =
  ## Validate and size the accepted map for this candidate delta. Allocations
  ## and the possible O(N) rebuild happen here, never in publication. Ordinary
  ## local patches are tiny, so duplicate/membership checks stay allocation
  ## free; only large deltas build a scratch index.
  if limit < 0: fail("commit map limit must be nonnegative")
  # A no-op never sizes or grows accepted storage. It still honours the limit
  # so a caller cannot use it as an accepted-state probe that hides overrun.
  if removals.len == 0 and upserts.len == 0:
    if map.count > limit: fail("commit map entry limit exceeded")
    return nil
  const SmallPatch = 8
  let small = removals.len <= SmallPatch and upserts.len <= SmallPatch
  var removalIndex = initCommitMap[K, int](0)
  if not small:
    for key in removals:
      if removalIndex.hasKey(key): fail("duplicate commit map removal")
      removalIndex.insertScratch(key, 0)
  else:
    for index in 0..<removals.len:
      if duplicateRemoval(removals, index): fail("duplicate commit map removal")
  var upsertIndex = initCommitMap[K, int](0)
  var removedExisting = 0
  var added = 0
  if small:
    for key in removals:
      if map.hasKey(key): inc removedExisting
    for index in 0..<upserts.len:
      if duplicateUpsert(upserts, index): fail("duplicate commit map upsert")
      let key = upserts[index][0]
      let present = map.hasKey(key)
      # Removals apply first: a key that is removed and re-added is removed
      # (counted once) and then inserted again (counted once), so the net live
      # count is unchanged but the patch has a real insertion slot.
      if inRemovals(removals, key) or not present:
        inc added
  else:
    for key in removalIndex.keys:
      if map.hasKey(key): inc removedExisting
    for entry in upserts:
      let key = entry[0]
      if upsertIndex.hasKey(key): fail("duplicate commit map upsert")
      upsertIndex.insertScratch(key, 0)
      let present = map.hasKey(key)
      if removalIndex.hasKey(key) or not present:
        inc added
  let finalCount = map.count - removedExisting + added
  if finalCount < 0: fail("commit map final count underflow")
  if finalCount > limit: fail("commit map entry limit exceeded")
  let peak = max(map.count, finalCount)
  # Capacity changes only when this patch inserts entries. Replacements and
  # removals never need a new bucket, so a no-growth delta leaves the accepted
  # geometry untouched regardless of the map's current load.
  if added > 0:
    var target = commitCapacity(peak)
    # Tombstones occupy probe slots even though they are not accepted entries.
    if peak + map.tombstones > target:
      target = commitCapacity(peak + map.tombstones)
    # A patch cannot need more physical room than occupied + its insertions.
    if map.count + map.tombstones + added > target:
      target = commitCapacity(map.count + map.tombstones + added)
    if target > map.slots.len: map.grow(target)
    doAssert map.slots.len > 0
    doAssert map.count + map.tombstones + added <= map.slots.len
  let retireCapacity = removals.len + upserts.len
  result = PreparedMapPatch[K, V](owner: map.owner, mapIdentity: map.identity,
    baseGeneration: map.generation, baseCount: map.count,
    retireCapacity: retireCapacity, insertions: added, status: patchSealed)
  # Retirement storage is bounded by the patch: every removal and every
  # replaced entry retires at most one value. A single slot stays inline;
  # larger patches pre-own a sequence so publication never allocates.
  if retireCapacity > 1:
    result.retiredKeys = newSeq[K](retireCapacity)
    result.retiredValues = newSeq[V](retireCapacity)
  result.entries = move(upserts)
  result.removals = move(removals)

template retire[K, V](patch: PreparedMapPatch[K, V], key, value: untyped) =
  if patch.retireCapacity > 1:
    patch.retiredKeys[patch.retiredCount] = move(key)
    patch.retiredValues[patch.retiredCount] = move(value)
  else:
    patch.inlineKey = move(key)
    patch.inlineValue = move(value)
    patch.inlineUsed = true
  inc patch.retiredCount

proc retireKey[K, V](patch: PreparedMapPatch[K, V], key: K) =
  if patch.retireCapacity > 1:
    patch.retiredKeys[patch.retiredCount] = key
  else:
    patch.inlineKey = key
    patch.inlineUsed = true
  inc patch.retiredCount

proc validatePrepared*[K, V](map: CommitMap[K, V], patch: PreparedMapPatch[K, V]) =
  if patch == nil: fail("missing prepared commit patch")
  if patch.mapIdentity != map.identity or patch.owner != map.owner:
    fail("foreign commit patch")
  if patch.status != patchSealed: fail("commit patch is not sealed")
  if patch.baseGeneration != map.generation or patch.baseCount != map.count:
    fail("stale commit patch")
  if patch.insertions < 0: fail("invalid commit patch insertion count")
  if patch.insertions > 0:
    if map.slots.len == 0: fail("commit patch has no prepared capacity")
    if map.count + map.tombstones + patch.insertions > map.slots.len:
      fail("commit patch exceeds prepared capacity")

proc retiredLen*[K, V](patch: PreparedMapPatch[K, V]): int =
  if patch == nil: 0 else: patch.retiredCount

proc insertionCount*[K, V](patch: PreparedMapPatch[K, V]): int =
  if patch == nil: 0 else: patch.insertions

proc publishValidated*[K, V](map: var CommitMap[K, V],
    patch: PreparedMapPatch[K, V]) {.raises: [].} =
  ## Publication for a patch already validated during prepare. Moves keys and
  ## values into pre-sized slots and retires replaced values instead of
  ## destroying them. No allocation, no application destructor.
  if patch == nil: return
  # These are proven by `validatePrepared` before publication; a violated
  # internal invariant is a fail-stop defect, never a silent skip.
  doAssert patch.status == patchSealed
  doAssert patch.mapIdentity == map.identity
  doAssert patch.baseGeneration == map.generation and patch.baseCount == map.count
  if patch.insertions > 0:
    doAssert map.slots.len > 0
    doAssert map.count + map.tombstones + patch.insertions <= map.slots.len
  for index in 0..<patch.removals.len:
    var key = move(patch.removals[index])
    let location = map.locate(key)
    if location.usedIndex < 0:
      patch.retireKey(move(key))
      continue
    let slot = addr map.slots[location.usedIndex]
    var oldKey = move(slot.key)
    var oldValue = move(slot.value)
    patch.retire(oldKey, oldValue)
    slot.state = slotTombstone
    inc map.tombstones
    dec map.count
  for index in 0..<patch.entries.len:
    var key = move(patch.entries[index][0])
    var value = move(patch.entries[index][1])
    let location = map.locate(key)
    if location.usedIndex >= 0:
      let slot = addr map.slots[location.usedIndex]
      var oldKey = move(slot.key)
      var oldValue = move(slot.value)
      patch.retire(oldKey, oldValue)
      slot.state = slotUsed
      slot.key = move(key)
      slot.value = move(value)
    else:
      # Capacity was proven during prepare. A missing slot here is an internal
      # invariant violation and must stop the process, not drop the value.
      doAssert location.insertIndex >= 0
      let slot = addr map.slots[location.insertIndex]
      if slot.state == slotTombstone: dec map.tombstones
      inc map.count
      slot.state = slotUsed
      slot.key = move(key)
      slot.value = move(value)
  patch.entries.setLen(0)
  patch.removals.setLen(0)
  patch.status = patchPublished
  inc map.generation

proc publishPrepared*[K, V](map: var CommitMap[K, V],
    patch: PreparedMapPatch[K, V]) =
  map.validatePrepared(patch)
  map.publishValidated(patch)

proc finishPublished*[K, V](patch: PreparedMapPatch[K, V]) {.raises: [].} =
  ## Accepted commit is fully visible; release retired keys/values now. This is
  ## the only place a replaced accepted value may run its destructor.
  if patch == nil: return
  patch.retiredKeys.setLen(0)
  patch.retiredValues.setLen(0)
  if patch.inlineUsed:
    patch.inlineKey = default(K)
    patch.inlineValue = default(V)
    patch.inlineUsed = false
  patch.retiredCount = 0
  patch.entries.setLen(0)
  patch.removals.setLen(0)
  if patch.status == patchPublished: patch.status = patchFinished

proc discardPrepared*[K, V](patch: PreparedMapPatch[K, V]) {.raises: [].} =
  ## Rejected candidate: accepted content was never touched. Candidate-owned
  ## values may be released immediately; retirement stays empty.
  if patch == nil or patch.status != patchSealed: return
  patch.entries.setLen(0)
  patch.removals.setLen(0)
  patch.retiredKeys.setLen(0)
  patch.retiredValues.setLen(0)
  patch.inlineKey = default(K)
  patch.inlineValue = default(V)
  patch.inlineUsed = false
  patch.retiredCount = 0
  patch.status = patchDiscarded

proc putOutsideCommit*[K, V](map: var CommitMap[K, V], key: K, value: V) =
  ## Initialization/owner-setup mutation outside any publication window. May
  ## allocate; accepted publication never calls this.
  let occupied = map.count + map.tombstones
  if map.slots.len == 0 or (occupied + 1) * 2 > map.slots.len:
    map.grow(commitCapacity(occupied + 1))
  let location = map.locate(key)
  if location.usedIndex >= 0:
    map.slots[location.usedIndex].value = value
    inc map.generation
    return
  doAssert location.insertIndex >= 0
  let slot = addr map.slots[location.insertIndex]
  if slot.state == slotTombstone: dec map.tombstones
  slot.state = slotUsed
  slot.key = key
  slot.value = value
  inc map.count
  inc map.generation

proc removeOutsideCommit*[K, V](map: var CommitMap[K, V], key: K) {.raises: [].} =
  ## Teardown mutation outside any publication window: destroys the value here.
  let location = map.locate(key)
  if location.usedIndex >= 0:
    let slot = addr map.slots[location.usedIndex]
    slot.state = slotTombstone
    slot.key = default(K)
    slot.value = default(V)
    inc map.tombstones
    dec map.count
  inc map.generation

proc clear*[K, V](map: var CommitMap[K, V]) {.raises: [].} =
  ## Terminal/owner teardown outside a publication window.
  map.slots.setLen(0)
  map.count = 0
  map.tombstones = 0
  inc map.generation

proc addKey*(summary: var KeySummary, id: uint64) =
  if summary.count == high(int): fail("key summary count overflow")
  inc summary.count
  summary.xorId = summary.xorId xor id

proc removeKey*(summary: var KeySummary, id: uint64) =
  if summary.count <= 0: fail("key summary underflow")
  dec summary.count
  summary.xorId = summary.xorId xor id

proc isUnique*(summary: KeySummary): bool = summary.count == 1

proc uniqueId*(summary: KeySummary): uint64 =
  if summary.count != 1: fail("key summary is not unique")
  summary.xorId
