when defined(windows):
  import std/[os, winlean, strutils]
  proc finalPath(handle: Handle, buffer: WideCString, length, flags: uint32): uint32 {.stdcall,
    dynlib: "kernel32", importc: "GetFinalPathNameByHandleW".}
  proc getShortPath(path, buffer: WideCString, length: uint32): uint32 {.stdcall,
    dynlib: "kernel32", importc: "GetShortPathNameW".}

  proc compilerPath*(path: string): string =
    # The bundled GCC uses ANSI paths internally, including its cc1 lookup.
    # Use a filesystem alias for compiler arguments while keeping public paths
    # and the installed SDK in their original Unicode directories.
    result = path
    var unicode = false
    for character in path:
      if ord(character) > 127: unicode = true
    if not unicode: return
    var existing = absolutePath(path)
    var missing: seq[string]
    while not fileExists(existing) and not dirExists(existing):
      let parent = existing.parentDir
      if parent == existing or parent.len == 0: return
      missing.add(existing.extractFilename)
      existing = parent
    let wide = newWideCString(existing)
    let length = getShortPath(wide, nil, 0)
    if length == 0 or length > 32768: return
    let buffer = newWideCString(int(length) + 1)
    let received = getShortPath(wide, buffer, length + 1)
    if received == 0 or received > length: return
    result = $buffer
    for i in countdown(missing.high, 0): result = result / missing[i]

  proc realPath*(path: string): string =
    let handle = createFileW(newWideCString(path), 0, 7, nil, 3, 0x02000000, 0)
    if handle == INVALID_HANDLE_VALUE: raiseOSError(osLastError())
    defer: discard closeHandle(handle)
    let length = finalPath(handle, nil, 0, 0)
    if length == 0 or length > 32768: raiseOSError(osLastError())
    let buffer = newWideCString(int(length) + 1)
    let received = finalPath(handle, buffer, length + 1, 0)
    if received == 0 or received > length: raiseOSError(osLastError())
    result = $buffer
    if result.startsWith("\\\\?\\UNC\\"): result = "\\\\" & result[8..^1]
    elif result.startsWith("\\\\?\\"): result = result[4..^1]
