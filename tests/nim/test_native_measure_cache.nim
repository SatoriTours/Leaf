import std/[unittest, options, strutils]
import leaf/[core, native_layout, native_measure_cache]
proc key(i: int, label="x", placeholder=""): MeasureKey =
  (NodeKind.input, label & $i, placeholder, 0'u8, float64(i), 100.0)
suite "bounded native measurement cache":
  test "stable thousand-control working set survives a second sequential pass":
    var cache: MeasureCache
    for i in 0..<1000:
      cache.put(key(i), DipSize(width: float64(i), height: 20))
    for i in 0..<1000:
      check cache.get(key(i)).isSome

  test "old entries are evicted at the bound while the newest entry stays available":
    var cache: MeasureCache
    for i in 0..<MaxMeasureEntries + 1:
      cache.put(key(i), DipSize(width: float64(i), height: 20))
      check cache.len <= MaxMeasureEntries
    check cache.get(key(0)).isNone
    check cache.get(key(MaxMeasureEntries)).get.width == float64(MaxMeasureEntries)
    cache.clear()
    check cache.len == 0
    check cache.keyBytes == 0
  test "long distinct model texts and placeholders stay within the tree byte budget":
    var cache: MeasureCache
    let large = repeat('x', MaxStringBytes - 8)
    for i in 0..<20:
      cache.put(key(i, large, large), DipSize(width: float64(i), height: 20))
      check cache.keyBytes <= MaxTreeBytes
      check cache.len <= MaxMeasureEntries
    check cache.get(key(0, large, large)).isNone
    check cache.get(key(19, large, large)).get.width == 19
  test "placeholder is part of the effective measurement identity":
    var cache: MeasureCache
    cache.put(key(1, "", "short"), DipSize(width: 100, height: 20))
    cache.put(key(1, "", "long"), DipSize(width: 200, height: 20))
    check cache.get(key(1, "", "short")).get.width == 100
    check cache.get(key(1, "", "long")).get.width == 200
