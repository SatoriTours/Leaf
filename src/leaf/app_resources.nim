## Host-owned read-only assets and private writable paths. Pass this service to
## application code explicitly; an Activity, cwd or process-global root is never
## the owner. Calls may allocate and perform I/O, outside UI publish/accept.
import std/[os, strutils, unicode]
import ./[core, project, ui_thread]
import ./vendor/checksums/sha2

type
  AssetReader* = proc(relative: string, maxBytes: int): string {.closure.}
  HostResources* = ref object
    reader: AssetReader
    dataRoot, cacheRoot: string
    thread: ThreadIdProc
    owner: uint64
    closed: bool

const MaxResourcePathBytes* = 4096

proc systemThread(): uint64 {.raises: [].} =
  when compileOption("threads"): uint64(getThreadId())
  else: 1'u64

proc requireOwner(host: HostResources) =
  if host == nil: fail("resource host is nil")
  if host.thread() != host.owner: fail("resources require their owning thread")

proc requireOpen(host: HostResources) =
  host.requireOwner()
  if host.closed: fail("resource host is closed")

proc relativePath(value: string): string =
  if value.len > MaxResourcePathBytes: fail("resource path exceeds 4096 bytes")
  portableRelative(value)

proc directoryRoot(value: string): string =
  if value.len == 0 or '\0' in value or validateUtf8(value) != -1 or
      not value.isAbsolute or not dirExists(value):
    fail("resource roots must be existing absolute directories")
  realPath(value)

proc guardedPath(root, relative: string): string =
  discard relativePath(relative)
  result = root / relative
  var existing = result
  while not fileExists(existing) and not dirExists(existing) and not symlinkExists(existing):
    let parent = existing.parentDir
    if parent == existing: fail("resource path has no existing parent")
    existing = parent
  # Inspect the nearest existing prefix even for a not-yet-created database or
  # extraction path. resolve(mustExist=false) alone would skip this check.
  let canonical = realPath(existing)
  if not within(root, canonical): fail("resource symlink escapes root")
  if existing == result: result = canonical

proc newHostResources*(reader: AssetReader, dataDirectory, cacheDirectory: string,
    currentThread: ThreadIdProc = systemThread): HostResources =
  if reader == nil or currentThread == nil: fail("resource host requires a reader and thread source")
  let dataRoot = directoryRoot(dataDirectory)
  let cacheRoot = directoryRoot(cacheDirectory)
  HostResources(reader: reader, dataRoot: dataRoot, cacheRoot: cacheRoot,
    thread: currentThread, owner: currentThread())

proc close*(host: HostResources) =
  host.requireOwner()
  host.closed = true
  host.reader = nil # Captured platform contexts may now be released by the Host.

proc readAsset*(host: HostResources, relative: string,
    maxBytes: int = MaxStringBytes): string =
  host.requireOpen()
  discard relativePath(relative)
  if maxBytes < 0 or maxBytes > MaxStringBytes: fail("invalid resource byte budget")
  result = host.reader(relative, maxBytes)
  if result.len > maxBytes: fail("resource exceeds byte budget")

proc dataPath*(host: HostResources, relative: string): string =
  host.requireOpen()
  guardedPath(host.dataRoot, relative)

proc readBoundedFile(path: string, maxBytes: int): string =
  if not fileExists(path): fail("resource file is missing")
  let input = open(path, fmRead)
  defer: input.close()
  let length = input.getFileSize()
  if length < 0 or length > int64(maxBytes): fail("resource exceeds byte budget")
  result = newString(int(length))
  if length > 0 and input.readBuffer(addr result[0], int(length)) != int(length):
    fail("resource file changed while reading")
  var extra: char
  if input.readBuffer(addr extra, 1) != 0: fail("resource file changed while reading")

proc directoryResources*(assetDirectory, dataDirectory, cacheDirectory: string): HostResources =
  let source = directoryRoot(assetDirectory)
  newHostResources(proc(relative: string, maxBytes: int): string =
    readBoundedFile(guardedPath(source, relative), maxBytes),
    dataDirectory, cacheDirectory)

proc asset*(host: HostResources, relative: string,
    maxBytes: int = MaxStringBytes): string =
  ## Explicit extraction for APIs that require a path. Content-addressed files
  ## are never overwritten. This UI-thread cache does not coordinate writers in
  ## other processes and has no automatic eviction policy.
  let content = host.readAsset(relative, maxBytes)
  var hasher = initSha_256()
  hasher.update(content)
  let name = ".leaf-assets/" & $hasher.digest() & "/" & relative
  # Internal prefix extends the validated caller path; avoid imposing the
  # caller's 4096-byte limit on the added cache prefix.
  if name.len > MaxResourcePathBytes: fail("extracted resource path exceeds 4096 bytes")
  result = guardedPath(host.cacheRoot, name)
  if fileExists(result):
    if readBoundedFile(result, maxBytes) != content: fail("extracted resource content differs")
    return
  createDir(result.parentDir)
  result = guardedPath(host.cacheRoot, name)
  writeFile(result, content)
  setFilePermissions(result, {fpUserRead})
