## Test-only initialization marker; real ABI is imported unchanged.
import leaf/native_ffi
export native_ffi

var initializationCount: cint
inc initializationCount
let initializationOwner = getThreadId()

proc leaf_boundary_marker*(threadId: cint): cint {.exportc, dynlib, cdecl, raises: [].} =
  if getThreadId() != initializationOwner or getThreadId() != int(threadId):
    return -200
  initializationCount * 1000 + 1
