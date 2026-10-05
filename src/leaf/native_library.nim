## Public platform loader; importing it opens no libraries.
import std/dynlib
when defined(windows):
  proc loadLibraryWide(path: WideCString): LibHandle {.
    importc: "LoadLibraryW", header: "<windows.h>", stdcall.}

proc openNativeLibrary*(path: string): LibHandle =
  # Native filenames cannot contain NUL; never silently load a truncated name.
  for character in path:
    if character == '\0': return nil
  when defined(windows):
    let wide = newWideCString(path)
    result = loadLibraryWide(wide)
  else:
    result = loadLib(path)
