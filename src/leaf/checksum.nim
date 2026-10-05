## Fixed-memory SHA256 for release artifacts.
import ./vendor/checksums/sha2
import ./package_files

proc sha256File*(path: string): string =
  let file = open(path, fmRead)
  defer: file.close()
  var state = initSha_256()
  var buffer = newString(65_536)
  while true:
    checkCancelled()
    let count = file.readBuffer(addr buffer[0], buffer.len)
    if count == 0: break
    state.update(buffer.toOpenArray(0, count - 1))
  $state.digest()
