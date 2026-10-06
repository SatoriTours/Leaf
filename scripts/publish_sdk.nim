## Resolve release channels and publish verified SDK assets with the GitHub CLI.
import std/[json, os, osproc, parseopt, streams, strutils]
import ../src/leaf/checksum
when defined(posix): import std/posix
when defined(windows): import std/winlean

const Targets* = ["linux-x86_64", "macos-x86_64", "macos-aarch64", "windows-x86_64"]

type GithubCallback* = proc(args: seq[string], payload: JsonNode): JsonNode {.closure.}

proc drain(handle: FileHandle): string =
  ## Read both pipes independently so diagnostics cannot corrupt API JSON or
  ## fill stderr's pipe while stdout is being consumed.
  var buffer: array[4096, char]
  while true:
    var count: int
    when defined(posix):
      var descriptor = TPollfd(fd: cint(handle), events: POLLIN)
      if posix.poll(addr descriptor, 1, 0) <= 0 or
          (descriptor.revents and (POLLIN or POLLHUP)) == 0: break
      count = int(posix.read(descriptor.fd, addr buffer[0], buffer.len))
    elif defined(windows):
      var available, received: int32
      let pipe = Handle(handle)
      if not peekNamedPipe(pipe, lpTotalBytesAvail = addr available) or available == 0: break
      if winlean.readFile(pipe, addr buffer[0], min(available, int32(buffer.len)), addr received, nil) == 0: break
      count = int(received)
    else:
      {.error: "GitHub CLI output requires POSIX or Windows".}
    if count <= 0: break
    let offset = result.len
    result.setLen(offset + count)
    copyMem(addr result[offset], addr buffer[0], count)

proc releaseInfo*(refName, sha: string): JsonNode =
  if sha.len != 40 or not sha.allCharsInSet({'0'..'9', 'a'..'f'}):
    raise newException(ValueError, "commit must be a full Git SHA")
  if refName == "refs/heads/main":
    return %*{"channel": "beta", "version": "beta." & sha[0..<12],
             "tag": "beta", "commit": sha}
  const prefix = "refs/tags/v"
  if refName.startsWith(prefix):
    let parts = refName[prefix.len..^1].split('.')
    var valid = parts.len == 3
    for part in parts:
      if part.len == 0 or not part.allCharsInSet({'0'..'9'}): valid = false
    if valid:
      let tag = refName["refs/tags/".len..^1]
      return %*{"channel": "release", "version": tag, "tag": tag, "commit": sha}
  raise newException(ValueError, "only main and vX.Y.Z tags can publish an SDK")

proc github*(args: seq[string], payload: JsonNode = nil): JsonNode =
  var command = args
  if payload != nil: command.add(["--input", "-"])
  let process = startProcess("gh", args = command, options = {poUsePath})
  defer: process.close()
  if payload != nil: process.inputStream.write($payload)
  process.inputStream.close()
  var output, diagnostics: string
  while true:
    output.add(drain(process.outputHandle))
    diagnostics.add(drain(process.errorHandle))
    if process.peekExitCode() != -1:
      output.add(drain(process.outputHandle))
      diagnostics.add(drain(process.errorHandle))
      break
    sleep(5)
  let code = process.waitForExit()
  if code != 0:
    raise newException(IOError, "gh exited with status " & $code & ": " & diagnostics.strip())
  if args.len > 0 and args[0] == "api":
    if output.strip().len == 0: return nil
    return parseJson(output)
  %output

proc publish*(info: JsonNode, repository: string, assets: seq[string],
              gh: GithubCallback = github): bool =
  let api = "repos/" & repository
  let beta = info["channel"].getStr() == "beta"
  let commit = info["commit"].getStr()
  let tag = info["tag"].getStr()
  if beta and gh(@["api", api & "/commits/main"], nil)["sha"].getStr() != commit:
    stdout.writeLine("Skipping stale beta build; main has advanced.")
    return false
  let title = "Leaf " & info["version"].getStr()
  let notes = "Leaf developer SDK (" & info["channel"].getStr() & ").\n\nCommit: `" &
    commit & "`\n\nIncludes CLI, Leaf sources, Nim 2.2.6 and the native GPUI bridge. " &
    "The Windows installer also downloads MinGW. See docs/installation.md for system prerequisites and installation commands."
  let pages = gh(@["api", "--paginate", "--slurp", api & "/releases?per_page=100"], nil)
  var existing: JsonNode
  for page in pages:
    for item in page:
      if existing == nil and item["tag_name"].getStr() == tag: existing = item
  if not beta and existing != nil:
    if not existing.getOrDefault("draft").getBool():
      raise newException(ValueError, "published release already exists; refusing to overwrite " & tag)
    if existing.getOrDefault("target_commitish").getStr() != commit:
      raise newException(ValueError, "existing release draft belongs to a different commit")
  if beta:
    let refs = gh(@["api", api & "/git/matching-refs/tags/beta"], nil)
    var hasBeta = false
    for item in refs:
      if item["ref"].getStr() == "refs/tags/beta": hasBeta = true
    if hasBeta:
      discard gh(@["api", "--method", "PATCH", api & "/git/refs/tags/beta"],
        %*{"sha": commit, "force": true})
    else:
      discard gh(@["api", "--method", "POST", api & "/git/refs"],
        %*{"ref": "refs/tags/beta", "sha": commit})
  if existing == nil:
    existing = gh(@["api", "--method", "POST", api & "/releases"], %*{
      "tag_name": tag, "target_commitish": commit, "name": title, "body": notes,
      "draft": true, "prerelease": beta, "make_latest": "false"})
  var command = @["release", "upload", tag]
  command.add(assets)
  command.add(["--repo", repository, "--clobber"])
  discard gh(command, nil)
  discard gh(@["api", "--method", "PATCH", api & "/releases/" & $existing["id"].getInt()], %*{
    "name": title, "body": notes, "draft": false, "prerelease": beta,
    "make_latest": (if beta: "false" else: "legacy")})
  true

proc checkedAssets*(directory: string): seq[string] =
  for target in Targets:
    let extension = if target.startsWith("windows"): ".zip" else: ".tar.gz"
    let archive = directory / ("leaf-sdk-" & target & extension)
    let checksum = archive & ".sha256"
    if not fileExists(archive) or not fileExists(checksum):
      raise newException(ValueError, "missing verified SDK artifact: " & archive)
    let actual = sha256File(archive)
    let words = readFile(checksum).splitWhitespace()
    if words.len == 0 or words[0] != actual:
      raise newException(ValueError, "SDK checksum mismatch: " & archive)
    result.add([archive, checksum])

proc main(): int =
  var refName = getEnv("GITHUB_REF")
  var sha = getEnv("GITHUB_SHA")
  var repository = getEnv("GITHUB_REPOSITORY")
  var assets = ""
  var metadata = false
  try:
    var parser = initOptParser(commandLineParams(), shortNoVal = {'h'},
      longNoVal = @["metadata", "help"])
    for kind, key, value in parser.getopt():
      case kind
      of cmdLongOption, cmdShortOption:
        case key
        of "ref": refName = value
        of "sha": sha = value
        of "repository": repository = value
        of "assets": assets = value
        of "metadata":
          if value.len > 0: raise newException(ValueError, "--metadata takes no value")
          metadata = true
        of "help", "h":
          stdout.writeLine("Usage: publish_sdk [--ref REF] [--sha SHA] [--repository REPOSITORY] [--metadata] [--assets DIRECTORY]")
          return 0
        else: raise newException(ValueError, "unrecognized argument: " & key)
      of cmdArgument: raise newException(ValueError, "unrecognized argument: " & key)
      of cmdEnd: discard
    let info = releaseInfo(refName, sha)
    if metadata:
      stdout.writeLine($info)
      let output = getEnv("GITHUB_OUTPUT")
      if output.len > 0:
        let stream = open(output, fmAppend)
        defer: stream.close()
        for key, value in info: stream.writeLine(key & "=" & value.getStr())
    else:
      if assets.len == 0 or repository.len == 0:
        raise newException(ValueError, "--assets and --repository are required")
      discard publish(info, repository, checkedAssets(assets))
  except CatchableError as error:
    stderr.writeLine("SDK publication failed: " & error.msg)
    return 1

when isMainModule: quit(main())
