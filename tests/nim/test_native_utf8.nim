## Differential coverage of the C boundary against the standard UTF-8 decoder.
import std/[unittest, unicode, random]
import leaf/[native_ffi, core]

proc copyStatus(value: string): int32 =
  var output: NativeBytes
  let data = if value.len == 0: nil else: cast[ptr uint8](unsafeAddr value[0])
  result = leaf_native_utf8_copy(data, csize_t(value.len), addr output)
  if result == NativeOk:
    doAssert output.length == csize_t(value.len)
    if value.len != 0:
      doAssert equalMem(output.data, data, value.len)
  leaf_native_bytes_release(addr output)

suite "native UTF-8 byte ownership":
  test "all Unicode scalar values are accepted; surrogates are rejected":
    for scalar in 0 .. 0x10ffff:
      let value = Rune(scalar).toUTF8
      let status = copyStatus(value)
      if scalar in 0xd800 .. 0xdfff:
        doAssert status == NativeInvalidUtf8
      else:
        doAssert status == NativeOk

  test "malformed corpus agrees with scalar decoding and canonical encoding":
    var rng = initRand(20261023)
    for iteration in 0 ..< 50000:
      var bytes = newString(rng.rand(12))
      for b in bytes.mitems: b = char(rng.rand(255))
      # Nim 2.2.6 validateUtf8 checks structure but accepts overlong triples,
      # surrogate encodings and out-of-range four-byte sequences. Decode and
      # re-encode canonically, checking scalar range as an independent oracle.
      var valid = validateUtf8(bytes) < 0
      if valid:
        var canonical = ""
        for scalar in bytes.runes:
          if int(scalar) > 0x10ffff or int(scalar) in 0xd800 .. 0xdfff:
            valid = false
          canonical.add(scalar.toUTF8)
        valid = valid and canonical == bytes
      let expected = if valid: NativeOk else: NativeInvalidUtf8
      doAssert copyStatus(bytes) == expected

  test "the existing one MiB string budget is enforced before dereference":
    check copyStatus(newString(MaxStringBytes)) == NativeOk
    check copyStatus(newString(MaxStringBytes + 1)) == NativeLimit
    var output: NativeBytes
    check leaf_native_utf8_copy(cast[ptr uint8](1), high(csize_t), addr output) == NativeLimit
    check output.data == nil and output.length == 0
