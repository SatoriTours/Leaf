import std/[json, os, strutils, unittest]
import ../../scripts/publish_sdk

type Call = tuple[args: seq[string], payload: JsonNode]

suite "SDK publication":
  test "release accepts only exact version tags and complete lowercase SHAs":
    let info = releaseInfo("refs/tags/v1.2.3", repeat('a', 40))
    check info["channel"].getStr() == "release"
    check info["version"].getStr() == "v1.2.3"
    for refName in ["refs/tags/v1.2.3-beta", "refs/tags/v1", "refs/heads/feature",
                    "refs/tags/v1.2.3\n", "refs/tags/v1.2.", "refs/tags/v.2.3"]:
      expect ValueError: discard releaseInfo(refName, repeat('a', 40))
    for sha in ["untrusted-sha", repeat('A', 40), repeat('a', 39), repeat('a', 40) & "\n"]:
      expect ValueError: discard releaseInfo("refs/heads/main", sha)

  test "main has a distinct beta identity":
    check releaseInfo("refs/heads/main", repeat('b', 40)) == %*{
      "channel": "beta", "version": "beta." & repeat('b', 12),
      "tag": "beta", "commit": repeat('b', 40)}

  test "stale beta does not mutate tags or releases":
    var calls: seq[Call]
    let gh: GithubCallback = proc(args: seq[string], payload: JsonNode): JsonNode =
      calls.add((args, payload))
      %*{"sha": repeat('c', 40)}
    check not publish(releaseInfo("refs/heads/main", repeat('b', 40)), "owner/repo", @[], gh)
    check calls.len == 1
    check calls[0].args == @["api", "repos/owner/repo/commits/main"]

  test "interrupted stable release resumes the same private draft":
    var calls: seq[Call]
    let gh: GithubCallback = proc(args: seq[string], payload: JsonNode): JsonNode =
      calls.add((args, payload))
      if "--slurp" in args:
        return %*[@[], [{"id": 42, "tag_name": "v1.2.3", "draft": true,
                        "target_commitish": repeat('a', 40)}]]
      if args[0] == "release": return %"uploaded"
      %*{"id": 42}
    check publish(releaseInfo("refs/tags/v1.2.3", repeat('a', 40)), "owner/repo", @["sdk.zip"], gh)
    check calls.len == 3
    check calls[1].args == @["release", "upload", "v1.2.3", "sdk.zip", "--repo", "owner/repo", "--clobber"]
    check calls[^1].payload["make_latest"].getStr() == "legacy"
    check not calls[^1].payload["draft"].getBool()
    check calls[^1].args[^1] == "repos/owner/repo/releases/42"

  test "published stable release and a draft from another commit cannot be overwritten":
    for draft in [false, true]:
      var calls: seq[Call]
      let gh: GithubCallback = proc(args: seq[string], payload: JsonNode): JsonNode =
        calls.add((args, payload))
        %*[[{"id": 42, "tag_name": "v1.2.3", "draft": draft,
             "target_commitish": repeat('c', 40)}]]
      expect ValueError:
        discard publish(releaseInfo("refs/tags/v1.2.3", repeat('a', 40)), "owner/repo", @[], gh)
      check calls.len == 1

  test "new stable release remains a draft until upload succeeds":
    var calls: seq[Call]
    let gh: GithubCallback = proc(args: seq[string], payload: JsonNode): JsonNode =
      calls.add((args, payload))
      if "--slurp" in args: return %*[@[]]
      if args[0] == "release": raise newException(IOError, "upload interrupted")
      %*{"id": 42}
    expect IOError:
      discard publish(releaseInfo("refs/tags/v1.2.3", repeat('a', 40)), "owner/repo", @[], gh)
    check calls.len == 3
    check calls[1].payload["draft"].getBool()
    check calls[1].payload["target_commitish"].getStr() == repeat('a', 40)
    check calls[1].payload["make_latest"].getStr() == "false"
    check calls[^1].args[0] == "release"

  test "beta creates or updates its exact tag and stays prerelease and never latest":
    for existingTag in [false, true]:
      var calls: seq[Call]
      let gh: GithubCallback = proc(args: seq[string], payload: JsonNode): JsonNode =
        calls.add((args, payload))
        if args[^1].endsWith("/commits/main"): return %*{"sha": repeat('b', 40)}
        if "--slurp" in args: return %*[@[]]
        if args[^1].endsWith("/git/matching-refs/tags/beta"):
          if existingTag: return %*[{"ref": "refs/tags/beta"}]
          return %*[{"ref": "refs/tags/beta-old"}]
        %*{"id": 42}
      check publish(releaseInfo("refs/heads/main", repeat('b', 40)), "owner/repo", @[], gh)
      check calls[^1].payload["prerelease"].getBool()
      check calls[^1].payload["make_latest"].getStr() == "false"
      check calls[3].payload["sha"].getStr() == repeat('b', 40)
      if existingTag:
        check calls[3].args[2] == "PATCH"
        check calls[3].payload["force"].getBool()
      else:
        check calls[3].args[2] == "POST"
        check calls[3].payload["ref"].getStr() == "refs/tags/beta"

  test "release lookup failure remains visible before any mutation":
    var calls: seq[Call]
    let gh: GithubCallback = proc(args: seq[string], payload: JsonNode): JsonNode =
      calls.add((args, payload))
      raise newException(IOError, "permission denied")
    expect IOError:
      discard publish(releaseInfo("refs/tags/v1.2.3", repeat('a', 40)), "owner/repo", @[], gh)
    check calls.len == 1

  when defined(posix):
    test "GitHub adapter preserves JSON stdout, payload input and command failures":
      let directory = getTempDir() / ("leaf-gh-tests-" & $getCurrentProcessId())
      createDir(directory)
      let oldPath = getEnv("PATH")
      defer:
        putEnv("PATH", oldPath)
        removeDir(directory)
      let executable = directory / "gh"
      writeFile(executable, """#!/bin/sh
printf 'diagnostic\n' >&2
if [ "$2" = fail ]; then exit 7; fi
if [ "$2" = input ]; then
  /bin/cat
elif [ "$1" = api ]; then
  printf '{"id":42}\n'
else
  printf 'uploaded\n'
fi
""")
      setFilePermissions(executable, {fpUserRead, fpUserWrite, fpUserExec})
      putEnv("PATH", directory)
      check github(@["api", "test"]) == %*{"id": 42}
      check github(@["release", "upload"]).getStr() == "uploaded\n"
      check github(@["api", "input"], %*{"sha": repeat('a', 40)}) == %*{"sha": repeat('a', 40)}
      expect IOError: discard github(@["api", "fail"])

  test "all platform archives require matching checksums":
    let directory = getTempDir() / ("leaf-publish-tests-" & $getCurrentProcessId())
    createDir(directory)
    defer: removeDir(directory)
    const abcSha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    for target in Targets:
      let extension = if target.startsWith("windows"): ".zip" else: ".tar.gz"
      let archive = directory / ("leaf-sdk-" & target & extension)
      writeFile(archive, "abc")
      writeFile(archive & ".sha256", abcSha256 & "  " & archive.extractFilename() & "\n")
    let assets = checkedAssets(directory)
    check assets.len == 8
    check assets[6].endsWith("leaf-sdk-windows-x86_64.zip")
    writeFile(assets[0], "tampered")
    expect ValueError: discard checkedAssets(directory)
    writeFile(assets[0], "abc")
    writeFile(assets[1], "")
    expect ValueError: discard checkedAssets(directory)
    writeFile(assets[1], abcSha256)
    removeFile(assets[7])
    expect ValueError: discard checkedAssets(directory)
