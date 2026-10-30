## Internal monotonic120Hz pacing. No wall clock, polling or catch-up frames.
const FrameIntervalNs* = 1_000_000_000'i64 div 120

proc nextFrameDeadline*(previous, now: int64): int64 =
  if previous < 0 or now < 0:
    raise newException(ValueError, "negative frame clock")
  if previous > now: return previous
  let steps = if previous == 0: 1'i64 else: (now - previous) div FrameIntervalNs + 1
  let base = if previous == 0: now else: previous
  if steps > (high(int64) - base) div FrameIntervalNs:
    raise newException(ValueError, "frame deadline exhausted")
  base + steps * FrameIntervalNs

proc frameDue100ns*(deadline, now: int64): int64 =
  if deadline < 0 or now < 0:
    raise newException(ValueError, "negative frame clock")
  if deadline <= now: return -1
  let delta = deadline - now
  -(delta div 100 + int64(ord(delta mod 100 != 0)))
