## Private, versioned development protocol. Malformed or stale files are ignored.
import std/[os, json]
import ./diagnostics

proc writeReady*(path, token: string, pid: int) =
  atomicWrite(path, $(%*{"version": 1, "token": token, "pid": pid}))

proc isReady*(path, token: string, pid: int): bool =
  try:
    if not fileExists(path) or getFileSize(path) > 4096: return false
    let value = parseFile(path)
    result = value["version"].getInt == 1 and value["token"].getStr == token and value["pid"].getInt == pid
  except CatchableError: discard

proc writeStatus*(path: string, revision: int, message: string) =
  atomicWrite(path, $(%*{"version": 1, "revision": revision, "message": message}))

proc readStatus*(path: string): tuple[valid: bool, revision: int, message: string] =
  try:
    if not fileExists(path) or getFileSize(path) > 1_048_576: return
    let value = parseFile(path)
    if value["version"].getInt != 1: return
    result = (true, value["revision"].getInt, value["message"].getStr)
  except CatchableError: discard
