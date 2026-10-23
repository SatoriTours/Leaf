## Pure, backend-neutral list metadata. No host wire types, no Backend, no
## Runtime, no platform objects: `host_protocol` re-exports these names and
## `backend` stores them, so both sides share one definition instead of a
## cyclic import or a structural duplicate.
import std/math

type
  HostHeightMode* {.pure.} = enum uniform, variable
  HostListProps* = object
    ## Owned, complete list description carried by one entity/update.
    sourceGeneration*: uint64
    itemCount*: int
    heightMode*: HostHeightMode
    rowHeight*, estimate*: float64
    overscan*: int

const
  MaxListOverscan* = 32
  MaxListDimension* = 1_000_000.0
    ## Same upper bound `virtualList` enforces for row height and estimate.

proc finite(value: float64): bool =
  ## IEEE NaN/Inf must never travel as list geometry; comparisons like
  ## `NaN <= 0` are false and would silently accept them.
  classify(value) notin {fcNan, fcInf, fcNegInf}

proc invalidReason*(props: HostListProps, itemLimit: int): string =
  ## "" when the metadata is internally consistent and inside the accepted
  ## budgets. Callers reject the candidate before it reaches a backend; the
  ## message is the structured reason. The checks are self-contained so a
  ## platform factory feeding the wire cannot bypass the Node-level producer.
  if props.itemCount < 0 or props.itemCount > itemLimit:
    return "list item count " & $props.itemCount & " is outside 0.." & $itemLimit
  if props.sourceGeneration == 0:
    return "list source generation must be non-zero"
  if props.overscan < 0 or props.overscan > MaxListOverscan:
    return "list overscan is outside 0.." & $MaxListOverscan
  if not finite(props.rowHeight):
    return "list row height must be finite"
  if not finite(props.estimate):
    return "list estimate must be finite"
  if props.estimate <= 0 or props.estimate > MaxListDimension:
    return "list estimate is outside (0, " & $MaxListDimension & "]"
  case props.heightMode
  of HostHeightMode.uniform:
    if props.rowHeight <= 0 or props.rowHeight > MaxListDimension:
      return "uniform list row height is outside (0, " & $MaxListDimension & "]"
  of HostHeightMode.variable:
    if props.rowHeight != 0:
      return "variable list cannot carry a uniform row height"
  ""
