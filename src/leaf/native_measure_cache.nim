## Bounded platform-neutral intrinsic measurement cache.
import std/[tables, deques, options]
import ./[core, native_layout]
const MaxMeasureEntries* = 2048 # Holds a thousand-control working set across both layout constraints.
type
  MeasureKey* = tuple[kind: NodeKind, label, placeholder: string, state: uint8, width, height: float64]
  MeasureCache* = object
    entries: Table[MeasureKey, DipSize]
    order: Deque[MeasureKey]
    bytes: int
proc weight(key: MeasureKey): int = key.label.len + key.placeholder.len + sizeof(MeasureKey)
proc len*(cache: MeasureCache): int = cache.entries.len
proc keyBytes*(cache: MeasureCache): int = cache.bytes
proc clear*(cache: var MeasureCache) =
  cache.entries.clear()
  cache.order.clear()
  cache.bytes = 0
proc get*(cache: MeasureCache, key: MeasureKey): Option[DipSize] =
  if key in cache.entries: some(cache.entries[key]) else: none(DipSize)
proc put*(cache: var MeasureCache, key: MeasureKey, value: DipSize) =
  if key in cache.entries:
    cache.entries[key] = value
    return
  let size = key.weight
  if size > MaxTreeBytes: return
  while cache.entries.len >= MaxMeasureEntries or cache.bytes + size > MaxTreeBytes:
    let old = cache.order.popFirst()
    cache.entries.del(old)
    cache.bytes -= old.weight
  cache.entries[key] = value
  cache.order.addLast(key)
  cache.bytes += size
