## Probe only the link capability used by a fixture; never hide other errors.
import std/[os, tempfiles]
when defined(windows): import std/winlean

proc canCreateSymlink*(root: string, directory: bool): bool =
  let probe = createTempDir("leaf-symlink-capability-", "", root)
  let target = probe / "target"
  let link = probe / "link"
  try:
    if directory: createDir(target)
    else: writeFile(target, "capability probe")
    try:
      createSymlink(target, link)
    except OSError as error:
      when defined(windows):
        if error.errorCode == 1314: return false # ERROR_PRIVILEGE_NOT_HELD
      raise
    result = true
  finally:
    if symlinkExists(link):
      when defined(windows):
        if directory:
          if removeDirectoryW(newWideCString(link)) == 0:
            raiseOSError(osLastError(), link)
        else: removeFile(link)
      else: removeFile(link)
    removeDir(probe)
