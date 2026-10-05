import std/[unittest, options, json]
import leaf/process_metrics

suite "Independent process resource observations":
  test "missing or malformed resident counters remain unavailable":
    check parseLinuxMemoryStatus("Name:\tfixture\n").rssKiB.isNone
    check parseLinuxMemoryStatus("VmRSS:\tunknown kB\n").rssKiB.isNone
    check parseLinuxMemoryStatus("VmRSS:\t-1 kB\n").rssKiB.isNone
    check parseLinuxMemoryStatus("VmRSS:\t12 MB\n").rssKiB.isNone
    let values = parseLinuxMemoryStatus("VmRSS:\t123 kB\nVmHWM:\t456 kB\n")
    check values.rssKiB.get == 123
    check values.peakRssKiB.get == 456

  test "live allocations and process CPU are observed without inventing unavailable RSS":
    let before = collectObservation()
    var owned = newString(4 * 1024 * 1024)
    for i in countup(0, owned.len - 1, 4096): owned[i] = 'x'
    let after = collectObservation()
    check owned.len == 4 * 1024 * 1024
    check after.heapBytes >= before.heapBytes + uint64(owned.len)
    check after.cpuSeconds >= before.cpuSeconds
    let data = resourceRecord(before, after)
    check data["heap_after_gc_bytes"].getBiggestInt == BiggestInt(after.heapBytes)
    when defined(linux):
      check before.rssKiB.isSome
      check after.rssKiB.isSome
      check after.peakRssKiB.get >= after.rssKiB.get
      check data["rss_after_gc_kib"].kind == JInt
    else:
      check data["rss_after_gc_kib"].kind == JNull
