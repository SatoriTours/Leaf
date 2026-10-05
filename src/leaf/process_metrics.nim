## Observations for standalone measurement tools. No timers or UI hooks.
import std/[options, strutils, times, json]

type
  MemoryStatus* = object
    rssKiB*, peakRssKiB*: Option[uint64]
  ProcessObservation* = object
    rssKiB*, peakRssKiB*: Option[uint64]
    heapBytes*, reservedHeapBytes*: uint64
    cpuSeconds*: float64

proc parseLinuxMemoryStatus*(status: string): MemoryStatus =
  for line in status.splitLines:
    let fields = line.splitWhitespace()
    if fields.len != 3 or fields[2] != "kB": continue
    if fields[0] notin ["VmRSS:", "VmHWM:"]: continue
    if fields[1].len == 0 or fields[1][0] == '-': continue
    try:
      let value = some(uint64(parseBiggestUInt(fields[1])))
      if fields[0] == "VmRSS:": result.rssKiB = value
      else: result.peakRssKiB = value
    except ValueError: discard

proc observeProcess*(): ProcessObservation =
  # Nim allocator counters describe this thread's managed heap, not native GPUI
  # allocations or the process resident set. Keep both measurements distinct.
  result.heapBytes = uint64(getOccupiedMem())
  result.reservedHeapBytes = uint64(getTotalMem())
  result.cpuSeconds = cpuTime()
  when defined(linux):
    try:
      let memory = parseLinuxMemoryStatus(readFile("/proc/self/status"))
      result.rssKiB = memory.rssKiB
      result.peakRssKiB = memory.peakRssKiB
    except IOError: discard
  # Other OSes remain unavailable until their public ABI and actual behavior
  # have been verified. A requested RSS gate must reject these null fields.

proc collectObservation*(): ProcessObservation =
  GC_fullCollect()
  observeProcess()

proc optional(value: Option[uint64]): JsonNode =
  if value.isSome: %value.get else: newJNull()

proc resourceRecord*(before, afterGc: ProcessObservation): JsonNode =
  %*{"rss_start_kib": optional(before.rssKiB),
    "rss_after_gc_kib": optional(afterGc.rssKiB),
    "peak_rss_kib": optional(afterGc.peakRssKiB),
    "heap_start_bytes": before.heapBytes,
    "heap_after_gc_bytes": afterGc.heapBytes,
    "reserved_heap_after_gc_bytes": afterGc.reservedHeapBytes,
    "cpu_seconds": max(0.0, afterGc.cpuSeconds - before.cpuSeconds)}
