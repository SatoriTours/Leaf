## Internal opt-in diagnostic counters; cycles are never converted to time.
## Pure accounting is portable so validation can run without a Windows desktop.
proc cycleDelta*(ending,starting:uint64):uint64 =
  if ending<starting:raise newException(ValueError,"Canvas CPU cycle counter moved backwards")
  ending-starting

proc frameworkCycles*(inclusive,resource,draw:uint64):uint64 =
  if resource>inclusive or draw>inclusive-resource:
    raise newException(ValueError,"Canvas CPU cycle stages overlap their enclosing commit")
  inclusive-resource-draw

when defined(windows):
  proc currentThread():pointer {.importc:"GetCurrentThread",header:"<windows.h>".}
  proc queryCycles(handle:pointer,cycles:ptr uint64):int32 {.stdcall,importc:"QueryThreadCycleTime",dynlib:"kernel32.dll".}
  proc queryUiCycles*():uint64 =
    if queryCycles(currentThread(),addr result)==0:
      raise newException(ValueError,"QueryThreadCycleTime unavailable")
