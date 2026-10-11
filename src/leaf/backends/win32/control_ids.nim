## Command IDs are never reused within a host lifetime, including failed creates.
import ../../core
type ControlIdPool* = object
  issued: uint32
proc allocate*(pool: var ControlIdPool): uint16 =
  if pool.issued >= uint32(high(uint16)): fail("native control ID space exhausted; recreate the host")
  inc pool.issued
  uint16(pool.issued)
