when defined(windows):
  import std/[os, winlean, strutils]
  proc finalPath(handle: Handle, buffer: WideCString, length, flags: uint32): uint32 {.stdcall,
    dynlib: "kernel32", importc: "GetFinalPathNameByHandleW".}
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
