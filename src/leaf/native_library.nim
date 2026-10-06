## Public platform loader; importing it opens no libraries.
import std/dynlib
when defined(windows):
  import std/os
  proc loadLibraryWide(path: WideCString): LibHandle {.
    importc: "LoadLibraryW", header: "<windows.h>", stdcall.}

proc openNativeLibrary*(path: string, error: var string): LibHandle =
  error = ""
  # Native filenames cannot contain NUL; never silently load a truncated name.
  for character in path:
    if character == '\0':
      error = "native library path contains NUL"
      return nil
  when defined(windows):
    let wide = newWideCString(path)
    result = loadLibraryWide(wide)
    if result == nil:
      let code = osLastError()
      error = "Windows error " & $int(code) & ": " & osErrorMsg(code)
  else:
    result = loadLib(path)
    if result == nil: error = "native library could not be opened"

proc openNativeLibrary*(path: string): LibHandle =
  var error: string
  openNativeLibrary(path, error)
