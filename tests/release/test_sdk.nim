## Real archives and installers; file URLs keep tests independent of networking.
import std/[unittest, os, strutils, tempfiles, json, strtabs]
import ../../scripts/[package_sdk, smoke_sdk, verify_sdk_install]
import ../../src/leaf/[checksum, archives]
import ../nim/archive_reader

type Fixture = object
  base, target, bridge, cli, nimRoot, output, extension: string

proc fixture(): Fixture =
  result.base = createTempDir("leaf sdk test ", "")
  let system = when defined(windows): "windows" elif defined(macosx): "macos" else: "linux"
  let architecture = when defined(arm64): "aarch64" else: "x86_64"
  result.target = system & "-" & architecture
  result.extension = when defined(windows): ".zip" else: ".tar.gz"
  result.nimRoot = result.base / "nim"
  for directory in ["bin", "lib", "config"]: createDir(result.nimRoot / directory)
  writeFile(result.nimRoot / (when defined(windows): "bin/nim.exe" else: "bin/nim"), "compiler")
  writeFile(result.nimRoot / "lib/system.nim", "discard")
  writeFile(result.nimRoot / "config/nim.cfg", "#config")
  result.cli = result.base / (when defined(windows): "leaf.exe" else: "leaf")
  writeFile(result.cli, "#!/bin/sh\necho 'Leaf v1.2.3 (release, abcdef)'\n")
  setFilePermissions(result.cli, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  result.bridge = result.base / bridgeName(result.target)
  writeFile(result.bridge, "bridge")
  result.output = result.base / "downloads/releases/latest/download"

proc packageOptions(f: Fixture, channel = "release"): PackageOptions =
  PackageOptions(nimRoot: f.nimRoot, cli: f.cli, bridge: f.bridge, target: f.target,
    version: "v1.2.3", channel: channel, commit: "abcdef", output: f.output)

proc package(f: Fixture, channel = "release"): string =
  when not defined(windows):
    writeFile(f.cli, "#!/bin/sh\n" &
      "if [ \"$1\" = --verify-sdk ]; then\n" &
      "    [ \"$2\" = " & channel & " ] && [ \"$3\" = " & f.target &
      " ] && { [ -z \"$4\" ] || [ \"$4\" = v1.2.3 ]; }\n" &
      "    exit $?\nfi\n" &
      "echo 'Leaf v1.2.3 (" & channel & ", abcdef)'\n")
  packageSdk(f.packageOptions(channel))

proc install(f: Fixture, channel = "release", shell = "sh"): CommandResult =
  let environment = processEnvironment()
  environment["HOME"] = f.base / "home"
  runCommand(shell, @[RepositoryRoot / "install.sh", "--channel", channel,
    "--prefix", f.base / "installed SDK", "--bin-dir", f.base / "bin",
    "--download-base", fileUrl(f.base / "downloads"), "--no-path"], environment = environment)

suite "SDK archive and native installer":
  setup:
    var f = fixture()
  teardown:
    removeDir(f.base)

  when not defined(windows):
    test "install under bash":
      let shell = getEnv("LEAF_TEST_BASH", findExe("bash"))
      if shell.len == 0: skip()
      else:
        discard f.package()
        let installed = f.install(shell = shell)
        checkpoint installed.output
        check installed.exitCode == 0
        check "v1.2.3" in checkedCommand(f.base / "bin/leaf", @["--version"])

    test "archive install and channel switch":
      let archive = f.package()
      let unpacked = f.base / "unpacked"
      extractTar(archive, unpacked)
      for item in ["src/leaf.nim", "src/leaf/templates/scaffold/main.nim", "LICENSE",
                   "toolchain/nim/lib/system.nim", "lib/" & bridgeName(f.target), "bin/leaf"]:
        check fileExists(unpacked / "leaf-sdk" / item)
      check parseFile(unpacked / "leaf-sdk/sdk.json")["channel"].getStr == "release"
      check sha256File(archive) == readFile(archive & ".sha256").splitWhitespace()[0]
      let installed = f.install()
      checkpoint installed.output
      check installed.exitCode == 0
      let entry = f.base / "bin/leaf"
      let first = expandFilename(entry)
      check "v1.2.3" in checkedCommand(entry)
      f.output = f.base / "downloads/releases/download/beta"
      discard f.package("beta")
      let beta = f.install("beta")
      checkpoint beta.output
      check beta.exitCode == 0
      check expandFilename(entry) != first
      check parseFile(expandFilename(entry).parentDir.parentDir / "sdk.json")["channel"].getStr == "beta"

    test "bad checksum keeps previous installation":
      let archive = f.package()
      let installed = f.install()
      checkpoint installed.output
      check installed.exitCode == 0
      let old = expandFilename(f.base / "bin/leaf")
      writeFile(archive, "broken download")
      let failed = f.install()
      check failed.exitCode != 0
      check "checksum" in failed.output.toLowerAscii
      check expandFilename(f.base / "bin/leaf") == old
      check fileExists(old)

    test "bad archive keeps previous installation":
      let archive = f.package()
      let installed = f.install()
      checkpoint installed.output
      check installed.exitCode == 0
      let old = expandFilename(f.base / "bin/leaf")
      let bad = f.base / "malformed"
      writeFile(bad, "unrelated content")
      writeTarGzip(@[ArchiveEntry(source: bad, name: "unexpected/file")], archive)
      writeFile(archive & ".sha256", sha256File(archive) & "\n")
      check f.install().exitCode != 0
      check expandFilename(f.base / "bin/leaf") == old

    test "wrong channel keeps previous installation":
      discard f.package()
      let installed = f.install()
      checkpoint installed.output
      check installed.exitCode == 0
      let old = expandFilename(f.base / "bin/leaf")
      discard f.package("beta")
      let failed = f.install()
      check failed.exitCode != 0
      check "metadata" in failed.output
      check expandFilename(f.base / "bin/leaf") == old

    test "unsupported platform fails before installing":
      let tools = f.base / "tools"
      createDir(tools)
      let uname = tools / "uname"
      writeFile(uname, "#!/bin/sh\necho unsupported\n")
      setFilePermissions(uname, {fpUserRead, fpUserWrite, fpUserExec})
      let environment = processEnvironment()
      environment["PATH"] = tools & PathSep & getEnv("PATH")
      let failed = runCommand("sh", @[RepositoryRoot / "install.sh", "--prefix", f.base / "untouched"],
        environment = environment)
      check failed.exitCode != 0
      check "unsupported" in failed.output
      check not dirExists(f.base / "untouched")

    test "linked toolchain files and directories become relocatable regular files":
      let external = f.base / "external"
      createDir(external / "modules")
      writeFile(external / "system.nim", "linked system")
      writeFile(external / "modules/helper.nim", "linked helper")
      removeFile(f.nimRoot / "lib/system.nim")
      createSymlink(external / "system.nim", f.nimRoot / "lib/system.nim")
      createSymlink(external / "modules", f.nimRoot / "lib/modules")
      let archive = f.package()
      let unpacked = f.base / "unpacked"
      extractTar(archive, unpacked)
      let library = unpacked / "leaf-sdk/toolchain/nim/lib"
      check readFile(library / "system.nim") == "linked system"
      check readFile(library / "modules/helper.nim") == "linked helper"
      check not symlinkExists(library / "system.nim")
      check not symlinkExists(library / "modules")

  test "incomplete toolchain does not publish archive":
    removeFile(f.nimRoot / "lib/system.nim")
    expect ValueError: discard f.package()
    check not dirExists(f.output)

  test "CLI options preserve separated and equals forms":
    let options = parsePackageOptions(@["--nim-root", f.nimRoot, "--cli=" & f.cli,
      "--bridge", f.bridge, "--target", f.target, "--version=v1.2.3", "--channel", "release",
      "--commit", "abcdef", "--output", f.output])
    check options.nimRoot == f.nimRoot
    check options.cli == f.cli
    check options.output == f.output
    let verify = parseVerifyOptions(@["--target=" & f.target, "--channel", "release", "--version", "v1.2.3", "--headless-only"])
    check verify.target == f.target
    check verify.headlessOnly
    expect ValueError: discard parsePackageOptions(@["--target"])
    expect ValueError: discard parseVerifyOptions(@["--headless-only=yes"])
