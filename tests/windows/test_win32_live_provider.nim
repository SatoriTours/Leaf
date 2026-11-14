when not defined(windows): {.error:"Live provider contracts require Windows".}
when not defined(leafProtocolProbes):
  {.error:"Live provider contracts require -d:leafProtocolProbes (owner re-entrancy probes)".}
import std/unittest
import leaf/backends/win32/live_provider
{.compile:"live_provider_contract.c".}
proc runContract():cint {.importc:"run_live_provider_contract",nodecl.}
suite "dedicated status and alert provider lifecycle":
  test "accepted semantics only, no duplicate transitions, thread safety and stale references":
    check runContract()==0
