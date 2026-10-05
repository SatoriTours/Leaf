## Read only a bounded executable header, never the entire application image.
import std/os
import ./core

proc nativeBinary*(path, target: string, library = false): string =
  if target notin ["linux", "macos", "windows"]: fail("unsupported target: " & target)
  let file = open(path, fmRead)
  defer: file.close()
  var bytes = newString(int(min(getFileSize(path), 1_048_576'i64)))
  bytes.setLen(file.readBuffer((if bytes.len == 0: nil else: addr bytes[0]), bytes.len))
  proc little(offset, count: int): uint32 =
    if offset < 0 or offset > bytes.len - count: return 0
    for i in 0..<count: result = result or (uint32(ord(bytes[offset + i])) shl (i * 8))
  var machine: uint32
  case target
  of "linux":
    if bytes.len >= 64 and bytes[0..6] == "\x7fELF\x02\x01\x01" and
        (if library: little(16, 2) == 3 else: little(16, 2) in [2'u32, 3'u32]) and little(52, 2) == 64:
      machine = little(18, 2)
  of "macos":
    if bytes.len >= 32 and bytes[0..3] == "\xcf\xfa\xed\xfe" and (if library: little(12, 4) == 6 else: little(12, 4) == 2):
      machine = little(4, 4)
  of "windows":
    if bytes.len >= 64 and bytes[0..1] == "MZ":
      let offset = int(little(60, 4))
      if offset >= 64 and offset <= bytes.len - 24 and bytes[offset..<offset + 4] == "PE\0\0":
        let optionalSize = int(little(offset + 20, 2))
        let flags = little(offset + 22, 2)
        if optionalSize >= 112 and optionalSize <= bytes.len - offset - 24 and
            little(offset + 24, 2) == 0x20b and (flags and 2) != 0 and (if library: (flags and 0x2000) != 0 else: (flags and 0x2000) == 0):
          machine = little(offset + 4, 2)
  else: discard
  if (target == "linux" and machine == 62) or (target == "macos" and machine == 0x01000007) or (target == "windows" and machine == 0x8664): result = "x86_64"
  elif (target == "linux" and machine == 183) or (target == "macos" and machine == 0x0100000c) or (target == "windows" and machine == 0xaa64): result = "aarch64"
  else: fail("binary " & path & " is not a supported " & target & " native executable")
