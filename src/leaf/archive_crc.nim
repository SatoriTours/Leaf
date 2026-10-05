## Incremental IEEE CRC32; release writers never retain a whole large file.
const CrcTable = block:
  var table: array[256, uint32]
  for i in 0..<256:
    var value = uint32(i)
    for bit in 0..<8:
      value = if (value and 1) != 0: (value shr 1) xor 0xedb88320'u32 else: value shr 1
    table[i] = value
  table
type Crc32* = object
  value: uint32
proc update*(state: var Crc32, data: openArray[char]) =
  var value = not state.value
  for c in data: value = (value shr 8) xor CrcTable[(value xor uint32(ord(c))) and 255]
  state.value = not value
proc digest*(state: Crc32): uint32 = state.value
