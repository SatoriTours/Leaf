## Independent test reader: Zippy's DEFLATE decoder plus gzip/TAR framing checks.
## Does not use Leaf's archive writer, CRC implementation or path collection.
import std/[os, strutils, tables]
import ../../src/leaf/vendor/zippy/zippy/crc
include ../../src/leaf/vendor/zippy/zippy/inflate

proc invalid(message: string) {.noreturn.} =
  raise newException(ValueError, "Invalid test archive: " & message)

proc little32(data: string, offset: int): uint32 =
  if offset < 0 or offset + 4 > data.len: invalid("truncated gzip trailer")
  for i in 0..<4: result = result or (uint32(ord(data[offset + i])) shl (8 * i))

proc readGzip*(data: string): string =
  var position = 0
  while position < data.len:
    if data.len - position < 18 or data[position..<position + 3] != "\x1f\x8b\x08":
      invalid("missing gzip member")
    let start = position
    let flags = ord(data[position + 3])
    if (flags and 0xe0) != 0: invalid("reserved gzip flags")
    position += 10
    if (flags and 4) != 0:
      if position + 2 > data.len: invalid("truncated gzip extra length")
      let size = ord(data[position]) or (ord(data[position + 1]) shl 8)
      position += 2 + size
      if position > data.len: invalid("truncated gzip extra field")
    for flag in [8, 16]:
      if (flags and flag) != 0:
        while position < data.len and data[position] != '\0': inc position
        if position >= data.len: invalid("unterminated gzip header")
        inc position
    if (flags and 2) != 0:
      if position + 2 > data.len: invalid("truncated gzip header CRC")
      let expected = ord(data[position]) or (ord(data[position + 1]) shl 8)
      if int(crc32(data[start..<position]) and 0xffff) != expected: invalid("gzip header CRC")
      position += 2
    var reader = BitStreamReader(src: cast[ptr UncheckedArray[uint8]](data.cstring),
      len: data.len, pos: position)
    var decoded: string
    var outputPosition = 0
    var finalBlock = false
    while not finalBlock:
      finalBlock = reader.readBits(1) != 0
      let kind = reader.readBits(2)
      case kind
      of 0: inflateNoCompression(decoded, reader, outputPosition)
      of 1: inflateBlock(decoded, reader, outputPosition, true)
      of 2: inflateBlock(decoded, reader, outputPosition, false)
      else: invalid("reserved DEFLATE block")
      if reader.bitsBuffered < 0: invalid("truncated DEFLATE stream")
    decoded.setLen(outputPosition)
    position = reader.pos - reader.bitsBuffered div 8
    if little32(data, position) != crc32(decoded): invalid("gzip member CRC")
    if little32(data, position + 4) != uint32(uint64(decoded.len) and 0xffffffff'u64):
      invalid("gzip member size")
    position += 8
    result.add(decoded)
  if position == 0: invalid("empty gzip stream")

proc tarString(data: string, start, size: int): string =
  result = data[start..<start + size]
  let nul = result.find('\0')
  if nul >= 0: result.setLen(nul)

proc tarNumber(data: string, start, size: int): int =
  let value = tarString(data, start, size).strip()
  if value.len == 0: return 0
  try: result = parseOctInt(value)
  except ValueError: invalid("invalid TAR number")
  if result < 0: invalid("negative TAR number")

proc safePath(name: string): string =
  if name.len == 0 or name[0] in {'/', '\\'} or '\\' in name or ':' in name or '\0' in name:
    invalid("unsafe TAR path")
  for part in name.split('/'):
    if part == "..": invalid("TAR path traversal")
  result = name

proc paxFields(data: string): Table[string, string] =
  var position = 0
  while position < data.len:
    let space = data.find(' ', position)
    if space < 0: invalid("PAX length")
    var size: int
    try: size = parseInt(data[position..<space])
    except ValueError: invalid("PAX length")
    if size <= space - position + 2 or size > data.len - position: invalid("PAX record bounds")
    let finish = position + size
    if data[finish - 1] != '\n': invalid("PAX terminator")
    let equal = data.find('=', space + 1)
    if equal < 0 or equal >= finish - 1: invalid("PAX field")
    result[data[space + 1..<equal]] = data[equal + 1..<finish - 1]
    position = finish

proc extractTar*(path, destination: string) =
  if dirExists(destination) or fileExists(destination) or symlinkExists(destination):
    invalid("destination already exists")
  let data = readGzip(readFile(path))
  var position = 0
  var pax: Table[string, string]
  var ended = false
  try:
    createDir(destination)
    while position < data.len:
      if data.len - position < 512: invalid("truncated TAR header")
      let header = data[position..<position + 512]
      if header == repeat('\0', 512):
        if data.len - position < 1024: invalid("missing TAR end marker")
        for byte in data[position..<data.len]:
          if byte != '\0': invalid("data after TAR end marker")
        ended = true
        break
      var sum = 0
      for i, byte in header: sum += (if i in 148..155: 32 else: ord(byte))
      if sum != tarNumber(header, 148, 8): invalid("TAR header checksum")
      let size = tarNumber(header, 124, 12)
      position += 512
      if size > data.len - position: invalid("truncated TAR contents")
      let payload = data[position..<position + size]
      let kind = header[156]
      if kind == 'x':
        pax = paxFields(payload)
      else:
        var name = tarString(header, 0, 100)
        let prefix = tarString(header, 345, 155)
        if prefix.len > 0: name = prefix & "/" & name
        name = safePath(pax.getOrDefault("path", name))
        pax.clear()
        let output = destination / name
        case kind
        of '5': createDir(output)
        of '0', '\0':
          createDir(output.parentDir)
          writeFile(output, payload)
          when defined(posix):
            let mode = tarNumber(header, 100, 8)
            var permissions: set[FilePermission]
            for (bit, permission) in [(0o400, fpUserRead), (0o200, fpUserWrite), (0o100, fpUserExec),
                (0o040, fpGroupRead), (0o020, fpGroupWrite), (0o010, fpGroupExec),
                (0o004, fpOthersRead), (0o002, fpOthersWrite), (0o001, fpOthersExec)]:
              if (mode and bit) != 0: permissions.incl(permission)
            setFilePermissions(output, permissions)
        else: invalid("unsupported TAR entry")
      let padding = (512 - size mod 512) mod 512
      if padding > data.len - position - size: invalid("truncated TAR padding")
      position += size + padding
    if not ended: invalid("missing TAR end marker")
    if pax.len > 0: invalid("orphan PAX record")
  except CatchableError:
    if dirExists(destination): removeDir(destination)
    raise
