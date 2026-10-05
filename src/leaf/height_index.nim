## Fenwick prefix sums provide variable-height viewport lookup in O(log n).
## The index is independent of controls and platform rendering.
import std/math
import ./core

type
  HeightIndex* = object
    heights, sums: seq[float64]
  VisibleRange* = object
    first*, finish*: int  # half-open interval
    offset*, total*: float64

proc validateHeight(value: float64) =
  if classify(value) in {fcNan, fcInf, fcNegInf} or value <= 0 or value > 1_000_000:
    fail("height must be finite and positive")

proc initHeightIndex*(count: int, estimate: float64): HeightIndex =
  if count < 0 or count > MaxListItems: fail("invalid height index size")
  validateHeight(estimate)
  result.heights = newSeq[float64](count)
  result.sums = newSeq[float64](count + 1)
  for i in 0..<count:
    result.heights[i] = estimate
    result.sums[i + 1] = estimate * float64((i + 1) and -(i + 1))

proc len*(index: HeightIndex): int = index.heights.len
proc height*(index: HeightIndex, row: int): float64 = index.heights[row]

proc measure*(index: var HeightIndex, row: int, height: float64) =
  validateHeight(height)
  if row < 0 or row >= index.len: fail("height index out of bounds")
  let delta = height - index.heights[row]
  index.heights[row] = height
  var i = row + 1
  while i < index.sums.len:
    index.sums[i] += delta
    i += i and -i

proc prefix*(index: HeightIndex, finish: int): float64 =
  if finish < 0 or finish > index.len: fail("height prefix out of bounds")
  var i = finish
  while i > 0:
    result += index.sums[i]
    i -= i and -i

proc total*(index: HeightIndex): float64 = index.prefix(index.len)

proc rowAt*(index: HeightIndex, offset: float64): int =
  ## Returns len at/beyond the end. Boundaries belong to the next row.
  if offset < 0: return 0
  var step = 1
  while step <= index.len div 2: step = step shl 1
  var sum = 0.0
  while step > 0:
    let next = result + step
    if next <= index.len and sum + index.sums[next] <= offset:
      result = next
      sum += index.sums[next]
    step = step shr 1

proc visible*(index: HeightIndex, scroll, viewport: float64,
              overscan = 2): VisibleRange =
  if classify(scroll) in {fcNan, fcInf, fcNegInf} or
      classify(viewport) in {fcNan, fcInf, fcNegInf} or viewport < 0:
    fail("invalid viewport")
  if overscan < 0 or overscan > 32: fail("invalid overscan")
  result.total = index.total
  if index.len == 0 or viewport == 0: return
  let start = clamp(scroll, 0.0, max(0.0, result.total - viewport))
  let lastPixel = min(result.total, start + viewport)
  let endRow = index.rowAt(lastPixel)
  let exclusive = if index.prefix(endRow) < lastPixel: endRow + 1 else: endRow
  result.first = max(0, index.rowAt(start) - overscan)
  result.finish = min(index.len, exclusive + overscan)
  result.offset = index.prefix(result.first)
