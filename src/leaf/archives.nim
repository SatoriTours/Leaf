## Streamed portable release archives, with bounded per-file compression.
import std/[os, strutils, sets, unicode]
import ./[core, project, archive_crc, package_files]
import ./vendor/zippy/zippy

const GzipChunk = 1_048_576
const ZipCompressionLimit* = 16_777_216
type
  ArchiveEntry* = object
    source*, name*: string
    directory*, executable*: bool
  ZipRecord = object
    name: string
    offset, size, compressed: uint64
    crc: uint32
    methodCode, version, flags: uint16
    mode: uint32

proc little(data: var string, value: uint64, width: int) =
  for i in 0..<width: data.add(char((value shr (i * 8)) and 255))

proc validate(entries: seq[ArchiveEntry]) =
  if entries.len > 10_000: fail("archive exceeds 10000 entries")
  var names: HashSet[string]
  for entry in entries:
    let name = if entry.directory and entry.name.endsWith('/'): entry.name[0..^2] else: entry.name
    discard portableRelative(name)
    if name.split('/').len > 64: fail("archive path exceeds depth 64")
    if name.len > 65_534: fail("archive filename exceeds ZIP limits")
    let normalized = unicode.toLower(name)
    if normalized in names: fail("case-insensitive archive path collision: " & name)
    names.incl(normalized)
    if not entry.directory:
      if symlinkExists(entry.source) or not fileExists(entry.source): fail("archive requires regular files: " & entry.source)
      if getFileInfo(entry.source, followSymlink = false).kind != pcFile: fail("archive requires regular files")

proc gzipMember(data: string): string =
  # Deterministic gzip header, then an independent standard DEFLATE stream.
  result = "\x1f\x8b\x08\0\0\0\0\0\0\xff"
  result.add(compress(data, dataFormat = dfDeflate))
  var crc: Crc32
  crc.update(data)
  result.little(uint64(crc.digest()), 4)
  result.little(uint64(data.len), 4)

proc tarHeader(name: string, size: uint64, mode: int, kind: char, prefix = ""): string =
  var header = newString(512)
  proc put(offset, width: int, text: string) =
    if text.len > width: fail("tar header field is too long")
    for i, c in text: header[offset + i] = c
  proc octal(offset, width: int, value: uint64) =
    var digits = ""
    var remainder = value
    while remainder > 0:
      digits = char(ord('0') + int(remainder and 7)) & digits
      remainder = remainder shr 3
    if digits.len >= width: fail("tar numeric field exceeds header limits")
    put(offset, width, repeat('0', width - 1 - digits.len) & digits)
  put(0, 100, name)
  octal(100, 8, uint64(mode))
  octal(108, 8, 0); octal(116, 8, 0)
  octal(124, 12, size); octal(136, 12, 0)
  put(148, 8, "        ")
  header[156] = kind
  put(257, 6, "ustar\0"); put(263, 2, "00")
  put(345, 155, prefix)
  var sum: uint64
  for c in header: sum += uint64(ord(c))
  octal(148, 7, sum)
  header[155] = ' '
  result = move(header)

proc paxField(key, value: string): string =
  let body = " " & key & "=" & value & "\n"
  var length = body.len + 1
  while ($length).len + body.len != length: length = ($length).len + body.len
  $length & body

proc writeTarGzip*(entries: seq[ArchiveEntry], path: string) =
  entries.validate()
  let output = open(path, fmWrite)
  defer: output.close()
  var buffer = newStringOfCap(GzipChunk)
  proc emit(data: string) =
    var position = 0
    while position < data.len:
      checkCancelled()
      let count = min(GzipChunk - buffer.len, data.len - position)
      buffer.add(data[position..<position + count])
      position += count
      if buffer.len == GzipChunk:
        output.write(gzipMember(buffer))
        buffer.setLen(0)
  proc padding(size: uint64) =
    let count = int((512 - (size mod 512)) mod 512)
    if count > 0: emit(newString(count))
  for i, entry in entries:
    checkCancelled()
    let name = if entry.directory and not entry.name.endsWith('/'): entry.name & "/" else: entry.name
    let size = if entry.directory: 0'u64 else: uint64(getFileSize(entry.source))
    var headerName = name
    var prefix = ""
    if name.len > 100:
      for split in 0..<name.len - 1:
        if name[split] == '/' and split <= 155 and name.len - split - 1 <= 100:
          prefix = name[0..<split]
          headerName = name[split + 1..^1]
    var pax = ""
    if headerName.len > 100:
      pax.add(paxField("path", name))
      headerName = "entry-" & $i
    if size > 0o77777777777'u64: pax.add(paxField("size", $size))
    if pax.len > 0:
      emit(tarHeader("PaxHeaders/" & $i, uint64(pax.len), 0o644, 'x'))
      emit(pax); padding(uint64(pax.len))
    emit(tarHeader(headerName, (if size > 0o77777777777'u64: 0'u64 else: size),
      (if entry.directory or entry.executable: 0o755 else: 0o644), (if entry.directory: '5' else: '0'), prefix))
    if not entry.directory:
      let input = open(entry.source, fmRead)
      try:
        var bytes = newString(65_536)
        var remaining = size
        while remaining > 0:
          checkCancelled()
          let count = input.readBuffer(addr bytes[0], int(min(remaining, uint64(bytes.len))))
          if count == 0: fail("archive source shrank: " & entry.source)
          emit(bytes[0..<count])
          remaining -= uint64(count)
        if getFileSize(entry.source) != int64(size): fail("archive source changed size: " & entry.source)
      finally: input.close()
      padding(size)
  emit(newString(1024))
  if buffer.len > 0: output.write(gzipMember(buffer))

proc zipExtra(size, compressed, offset: uint64, includeOffset: bool): string =
  var body = ""
  if size >= 0xffffffff'u64: body.little(size, 8)
  if compressed >= 0xffffffff'u64: body.little(compressed, 8)
  if includeOffset and offset >= 0xffffffff'u64: body.little(offset, 8)
  if body.len > 0:
    result.little(1, 2); result.little(uint64(body.len), 2); result.add(body)

proc writeZip*(entries: seq[ArchiveEntry], path: string) =
  entries.validate()
  let output = open(path, fmWrite)
  defer: output.close()
  var records: seq[ZipRecord]
  for entry in entries:
    checkCancelled()
    var record = ZipRecord(name: (if entry.directory and not entry.name.endsWith('/'): entry.name & "/" else: entry.name),
      offset: uint64(output.getFilePos()), flags: 0x800, version: 20,
      mode: (if entry.directory: 0o40755'u32 elif entry.executable: 0o100755'u32 else: 0o100644'u32))
    var contents = ""
    if not entry.directory:
      record.size = uint64(getFileSize(entry.source))
      if record.size <= uint64(ZipCompressionLimit):
        let bytes = readFile(entry.source)
        if uint64(bytes.len) != record.size: fail("archive source changed size")
        var crc: Crc32; crc.update(bytes)
        record.crc = crc.digest()
        contents = compress(bytes, dataFormat = dfDeflate)
        record.methodCode = 8
        record.compressed = uint64(contents.len)
      else: record.compressed = record.size
    if max(record.size, max(record.compressed, record.offset)) >= 0xffffffff'u64: record.version = 45
    let extra = zipExtra(record.size, record.compressed, record.offset, false)
    var header = ""
    header.little(0x04034b50, 4); header.little(uint64(record.version), 2)
    header.little(uint64(record.flags), 2); header.little(uint64(record.methodCode), 2)
    header.little(0, 2); header.little(0x21, 2) # 1980-01-01
    header.little(uint64(record.crc), 4)
    header.little(min(record.compressed, 0xffffffff'u64), 4); header.little(min(record.size, 0xffffffff'u64), 4)
    header.little(uint64(record.name.len), 2); header.little(uint64(extra.len), 2)
    output.write(header & record.name & extra)
    if not entry.directory:
      if record.methodCode == 8: output.write(contents)
      else:
        let input = open(entry.source, fmRead)
        try:
          var bytes = newString(65_536)
          var remaining = record.size
          var crc: Crc32
          while remaining > 0:
            checkCancelled()
            let count = input.readBuffer(addr bytes[0], int(min(remaining, uint64(bytes.len))))
            if count == 0: fail("archive source shrank: " & entry.source)
            crc.update(bytes.toOpenArray(0, count - 1))
            if output.writeBuffer(addr bytes[0], count) != count: raise newException(IOError, "archive write failed")
            remaining -= uint64(count)
          if getFileSize(entry.source) != int64(record.size): fail("archive source changed size")
          record.crc = crc.digest()
        finally: input.close()
      if record.methodCode == 0:
        # The artifact is a seekable file. Patch only CRC after one streaming
        # pass; this avoids descriptor-width ambiguity for ZIP64 offsets.
        let finish = output.getFilePos()
        output.setFilePos(int64(record.offset) + 14)
        var checksum = ""
        checksum.little(uint64(record.crc), 4)
        output.write(checksum)
        output.setFilePos(finish)
    records.add(record)
  let directoryOffset = uint64(output.getFilePos())
  for record in records:
    let extra = zipExtra(record.size, record.compressed, record.offset, true)
    var header = ""
    header.little(0x02014b50, 4); header.little(0x300'u64 or uint64(record.version), 2)
    header.little(uint64(record.version), 2); header.little(uint64(record.flags), 2)
    header.little(uint64(record.methodCode), 2); header.little(0, 2); header.little(0x21, 2)
    header.little(uint64(record.crc), 4)
    header.little(min(record.compressed, 0xffffffff'u64), 4); header.little(min(record.size, 0xffffffff'u64), 4)
    header.little(uint64(record.name.len), 2); header.little(uint64(extra.len), 2)
    header.little(0, 2); header.little(0, 2); header.little(0, 2)
    header.little((uint64(record.mode) shl 16) or (if record.name.endsWith('/'): 16'u64 else: 0'u64), 4)
    header.little(min(record.offset, 0xffffffff'u64), 4)
    output.write(header & record.name & extra)
  let directorySize = uint64(output.getFilePos()) - directoryOffset
  var tail = ""
  if directoryOffset >= 0xffffffff'u64 or directorySize >= 0xffffffff'u64:
    let zip64Offset = uint64(output.getFilePos())
    tail.little(0x06064b50, 4); tail.little(44, 8); tail.little(0x32d, 2); tail.little(45, 2)
    tail.little(0, 4); tail.little(0, 4)
    tail.little(uint64(records.len), 8); tail.little(uint64(records.len), 8)
    tail.little(directorySize, 8); tail.little(directoryOffset, 8)
    tail.little(0x07064b50, 4); tail.little(0, 4); tail.little(zip64Offset, 8); tail.little(1, 4)
  tail.little(0x06054b50, 4); tail.little(0, 2); tail.little(0, 2)
  tail.little(uint64(records.len), 2); tail.little(uint64(records.len), 2)
  tail.little(min(directorySize, 0xffffffff'u64), 4); tail.little(min(directoryOffset, 0xffffffff'u64), 4)
  tail.little(0, 2)
  output.write(tail)
