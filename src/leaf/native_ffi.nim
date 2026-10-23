## Owned, length-delimited UTF-8 for native platform adapters. The allocator is
## C malloc/free: no Nim refs or strings escape, and allocation failure has a
## status rather than a catchable exception crossing the ABI.
from ./core import MaxStringBytes

type
  NativeBytes* {.bycopy.} = object
    data*: ptr uint8
    length*: csize_t

const
  NativeOk* = 0'i32
  NativeInvalidArgument* = 1'i32
  NativeInvalidUtf8* = 2'i32
  NativeLimit* = 3'i32
  NativeNoMemory* = 4'i32

proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>", raises: [].}
proc cFree(data: pointer) {.importc: "free", header: "<stdlib.h>", raises: [].}

proc scalarUtf8(data: ptr UncheckedArray[uint8], length: int): bool {.raises: [].} =
  var i = 0
  while i < length:
    let lead = data[i]
    if lead < 0x80:
      inc i
      continue
    var count: int
    var secondLow = 0x80'u8
    var secondHigh = 0xbf'u8
    case lead
    of 0xc2..0xdf: count = 2
    of 0xe0:
      count = 3
      secondLow = 0xa0
    of 0xe1..0xec, 0xee..0xef: count = 3
    of 0xed:
      count = 3
      secondHigh = 0x9f # Surrogates are not Unicode scalar values.
    of 0xf0:
      count = 4
      secondLow = 0x90
    of 0xf1..0xf3: count = 4
    of 0xf4:
      count = 4
      secondHigh = 0x8f
    else: return false
    if length - i < count: return false
    if data[i + 1] < secondLow or data[i + 1] > secondHigh: return false
    for offset in 2 ..< count:
      if data[i + offset] < 0x80 or data[i + offset] > 0xbf: return false
    i += count
  true

proc leaf_native_utf8_copy*(input: ptr uint8, length: csize_t,
    output: ptr NativeBytes): int32 {.exportc, dynlib, cdecl, raises: [].} =
  if output == nil or output.data != nil or output.length != 0:
    return NativeInvalidArgument
  if length > csize_t(MaxStringBytes): return NativeLimit
  if length == 0: return NativeOk
  if input == nil: return NativeInvalidArgument
  if not scalarUtf8(cast[ptr UncheckedArray[uint8]](input), int(length)):
    return NativeInvalidUtf8
  let owned = cMalloc(length)
  if owned == nil: return NativeNoMemory
  copyMem(owned, input, int(length))
  output[] = NativeBytes(data: cast[ptr uint8](owned), length: length)
  NativeOk

proc leaf_native_bytes_release*(value: ptr NativeBytes) {.exportc, dynlib, cdecl, raises: [].} =
  if value == nil: return
  let owned = value.data
  value[] = NativeBytes()
  cFree(owned)
