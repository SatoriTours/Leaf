## Real archives and installers; file URLs keep tests independent of networking.
import std/[unittest, os, strutils, tempfiles, json, strtabs, streams]
import ../../scripts/[package_sdk, smoke_sdk, verify_sdk_install]
import ../../src/leaf/[checksum, archives]
import ../nim/archive_reader
when defined(windows): import std/winlean

# Probe the environment at a real native-process boundary, then execute real
# OpenSSL. This checks scoped environment propagation even on non-Windows hosts.
if getEnv("LEAF_TEST_OPENSSL_DELEGATE").len>0 and paramCount()>0 and
    paramStr(1) in ["crl2pkcs7", "pkcs7", "x509"]:
  let arguments=commandLineParams()
  let utf8=getEnv("OPENSSL_WIN32_UTF8")
  let trace=open(getEnv("LEAF_TEST_OPENSSL_TRACE"),fmAppend)
  trace.writeLine($( %*{"arguments":arguments,"utf8":utf8} ))
  trace.close()
  if utf8!="1":
    stderr.writeLine("OpenSSL child requires scoped OPENSSL_WIN32_UTF8=1; actual=[" & utf8 & "]")
    quit(97)
  let executed=runCommand(getEnv("LEAF_TEST_OPENSSL_DELEGATE"),arguments)
  stdout.write(executed.output)
  quit(executed.exitCode)

# A real child of this test binary exercises merged stdout/stderr without
# requiring another tool or bypassing runCommand's process implementation.
if paramCount()==1 and paramStr(1)=="--sdk-output-child":
  stdout.write("EARLY|")
  stdout.flushFile()
  sleep(50)
  stdout.write(repeat('A',131089))
  stdout.flushFile()
  stderr.write(repeat('B',131117))
  stderr.flushFile()
  stdout.write("|OUT-TAIL|")
  stdout.flushFile()
  stderr.write("|ERR-TAIL|")
  stderr.flushFile()
  quit(23)

type ShortReadStream = ref object of StreamObj
  data: string
  position: int

proc readShortChunk(stream: Stream, buffer: pointer, length: int): int {.gcsafe.} =
  let source=ShortReadStream(stream)
  result=min(length,min(3,source.data.len-source.position))
  if result>0:
    copyMem(buffer,unsafeAddr source.data[source.position],result)
    source.position+=result



# Test fixture utilities; never recursively remove a directory link's target.
proc removeFixtureDirectoryLink(path: string) =
  if not symlinkExists(path):
    raise newException(ValueError,"Refusing to unlink an ordinary fixture path: " & path)
  when defined(windows):
    # RemoveDirectoryW unlinks a junction itself, without walking its target.
    if removeDirectoryW(newWideCString(path)) == 0:
      raiseOSError(osLastError(),path)
  else:removeFile(path)

proc runPowerShellFixture(pwsh, script: string, arguments: seq[string]): CommandResult =
  let failureFile=script & ".failure.txt"
  let marker="$ErrorActionPreference = 'Stop'"
  let body=readFile(script)
  doAssert body.count(marker)==1
  # Stream.readAll can stop on a short Windows pipe read. Persist the full
  # exception separately so early stdout cannot hide the actual assertion.
  let diagnostics="""
$PSStyle.OutputRendering = 'PlainText'
$ErrorView = 'NormalView'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$LeafFailureFile = __FAILURE_FILE__
trap {
    $message = 'FIXTURE FAILURE: ' + $_.Exception.Message
    $details = $message + "`n" + $_.InvocationInfo.PositionMessage + "`n"
    if ($FixtureRoot) { $details += "FixtureRoot=[$FixtureRoot]; full=[$([IO.Path]::GetFullPath($FixtureRoot))]`n" }
    if ($GitRoot) { $details += "GitRoot=[$GitRoot]; full=[$([IO.Path]::GetFullPath($GitRoot))]`n" }
    [IO.File]::WriteAllText($LeafFailureFile, $details, [Text.UTF8Encoding]::new($false))
    [Console]::Error.WriteLine($message)
    exit 1
}
function AssertEqual($Actual, $Expected, $Message) {
    if ($Actual -ne $Expected) { throw "$Message; actual=[$Actual]; expected=[$Expected]" }
}
function AssertFixturePath($Actual, $Expected, $Message) {
    # Windows GetFullPath expands existing 8.3 names as well as separators.
    # Keep raw spellings in failures; compare the same managed representation.
    $actualFull = [IO.Path]::GetFullPath($Actual)
    $expectedFull = [IO.Path]::GetFullPath($Expected)
    AssertEqual $actualFull $expectedFull "$Message; raw actual=[$Actual]; raw expected=[$Expected]"
}
""".replace("__FAILURE_FILE__","'" & failureFile.replace("'","''") & "'")
  writeFile(script,body.replace(marker,marker & "\n" & diagnostics))
  result=runCommand(pwsh,@["-NoProfile","-File",script] & arguments)
  if fileExists(failureFile):result.output.add("\n" & readFile(failureFile))

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

suite "SDK command output collection":
  test "nonzero short reads preserve all bytes until EOF":
    for payload in ["", "prefix 中文\0suffix", repeat('X',17003)]:
      let input=ShortReadStream(data:payload,readDataImpl:readShortChunk)
      let collected=readCommandOutput(input)
      checkpoint "Expected bytes: " & $payload.len & "; received: " & $collected.len
      let complete=collected==payload
      check complete
  test "real child drains delayed large stdout and stderr and preserves nonzero exit":
    let executed=runCommand(getAppFilename(),@["--sdk-output-child"])
    check executed.exitCode==23
    check executed.output.len==262232
    check executed.output=="EARLY|" & repeat('A',131089) & repeat('B',131117) &
      "|OUT-TAIL||ERR-TAIL|"

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


suite "Relocated SDK real path boundaries":
  setup:
    let base=createTempDir("leaf path 中文 spaces ", "")
    let sdk=base/"SDK with spaces 中文"
    let sibling=base/"SDK with spaces 中文-sibling"
    createDir(sdk/"toolchain")
    createDir(sibling)
    writeFile(sdk/"toolchain"/"nim", "compiler")
    writeFile(sibling/"nim", "external compiler")
  teardown:
    removeDir(base)
  test "real descendants accepted and sibling prefixes rejected":
    check within(sdk/"toolchain"/"nim",sdk)
    check within(sdk,sdk)
    check not within(sibling/"nim",sdk)
    check not within(base/"absent",sdk)
    check not within(sdk/"missing-file",sdk)
  test "different root aliases resolve to the same SDK":
    let alias=base/"SDK alias 中文"
    defer:
      if symlinkExists(alias):removeFixtureDirectoryLink(alias)
    when defined(windows):
      let junction=runCommand("cmd.exe",@["/d","/c","mklink","/J",alias,sdk])
      checkpoint junction.output
      check junction.exitCode==0
    else:createSymlink(sdk,alias)
    check within(sdk/"toolchain"/"nim",alias)
    check within(alias/"toolchain"/"nim",sdk)
  test "real directory link escape and outside files remain rejected":
    let escaped=sdk/"escaped-directory"
    defer:
      if symlinkExists(escaped):removeFixtureDirectoryLink(escaped)
    when defined(windows):
      let junction=runCommand("cmd.exe",@["/d","/c","mklink","/J",escaped,sibling])
      checkpoint junction.output
      check junction.exitCode==0
    else:createSymlink(sibling,escaped)
    check not within(escaped/"nim",sdk)
    check not within(sibling/"nim",sdk)
  when not defined(windows):
    test "real file symlink escape is rejected":
      createSymlink(sibling/"nim",sdk/"escaped-file")
      check not within(sdk/"escaped-file",sdk)

suite "SDK fixture safety and diagnostics":
  test "directory link cleanup preserves an outside target and rejects ordinary directories":
    let base=createTempDir("leaf cleanup 中文 space ", "")
    let outside=createTempDir("leaf outside fixture 中文 ", "")
    defer:removeDir(outside)
    defer:removeDir(base)
    writeFile(outside/"sentinel.txt","outside target must survive")
    let link=base/"directory alias 中文"
    when defined(windows):
      discard checkedCommand("cmd.exe",@["/d","/c","mklink","/J",link,outside])
    else:createSymlink(outside,link)
    removeFixtureDirectoryLink(link)
    check not symlinkExists(link)
    check not dirExists(link)
    check readFile(outside/"sentinel.txt")=="outside target must survive"
    createDir(base/"ordinary")
    writeFile(base/"ordinary"/"keep.txt","ordinary directory must survive")
    expect ValueError:removeFixtureDirectoryLink(base/"ordinary")
    check readFile(base/"ordinary"/"keep.txt")=="ordinary directory must survive"
    expect ValueError:removeFixtureDirectoryLink(base/"ordinary"/"keep.txt")
    check readFile(base/"ordinary"/"keep.txt")=="ordinary directory must survive"
    # Recursive fixture cleanup after unlinking cannot touch the outside target.
    removeDir(base)
    check readFile(outside/"sentinel.txt")=="outside target must survive"
  test "PowerShell fixture path comparison accepts aliases and rejects wrong locations":
    let pwsh=findExe("pwsh")
    if pwsh.len==0:
      checkpoint "PowerShell unavailable; fixture path comparison not verified"
      skip()
    else:
      let base=createTempDir("leaf path comparison 中文 space ", "")
      defer:removeDir(base)
      for prefix in ["ucrt64", "mingw64"]:createDir(base/prefix/"bin")
      let script=base/"path_tests.ps1"
      writeFile(script,"""
param([string]$FixtureRoot)
$ErrorActionPreference = 'Stop'
$expected = Join-Path $FixtureRoot 'ucrt64/bin'
$canonical = [IO.Path]::GetFullPath($expected)
AssertFixturePath $canonical (Join-Path $FixtureRoot 'ucrt64/../ucrt64/bin') 'Equivalent existing location rejected'
AssertFixturePath $canonical $expected 'Managed full path versus fixture alias rejected'
if ($IsWindows) {
    AssertFixturePath $canonical ($expected.Replace('\', '/')) 'Windows slash spelling rejected'
}
# Wrong prefix and a sibling name must remain different after normalization.
foreach ($wrong in @('mingw64/bin', 'ucrt64-sibling/bin')) {
    $caught = $false
    try { AssertFixturePath $canonical (Join-Path $FixtureRoot $wrong) 'Wrong fixture location' }
    catch {
        $caught = $true
        if ($_.Exception.Message -notlike '*actual=*expected=*') { throw 'Path mismatch lost actual/expected details' }
    }
    if (-not $caught) { throw ('Wrong fixture location accepted: ' + $wrong) }
}
'Equivalent locations accepted; wrong prefix and sibling rejected'
""")
      let executed=runPowerShellFixture(pwsh,script,@["-FixtureRoot",base])
      checkpoint executed.output
      check executed.exitCode==0

  test "PowerShell failure persists full message after early stdout":
    let pwsh=findExe("pwsh")
    if pwsh.len==0:
      checkpoint "PowerShell unavailable; diagnostic failure regression not verified"
      skip()
    else:
      let base=createTempDir("leaf diagnostic 中文 space ", "")
      defer:removeDir(base)
      let script=base/"diagnostic_tests.ps1"
      writeFile(script,"""
param([string]$FixtureRoot)
$ErrorActionPreference = 'Stop'
'early stdout before exception'
Start-Sleep -Milliseconds 40
AssertEqual $FixtureRoot 'different target' 'diagnostic sentinel 中文'
""")
      let executed=runPowerShellFixture(pwsh,script,@["-FixtureRoot",base])
      checkpoint executed.output
      check executed.exitCode!=0
      check fileExists(script & ".failure.txt")
      check ("diagnostic sentinel 中文; actual=[" & base & "]; expected=[different target]") in executed.output
      if fileExists(script & ".failure.txt"):
        check "diagnostic sentinel 中文" in readFile(script & ".failure.txt")

suite "Windows HTTPS preparation":
  test "new and legacy Git layouts and missing dependencies":
    let pwsh=findExe("pwsh")
    if pwsh.len==0:
      checkpoint "PowerShell unavailable; HTTPS layout regression not verified"
      skip()
    else:
      let base=createTempDir("leaf HTTPS 中文 space ", "")
      defer:removeDir(base)
      let testScript=base/"https_tests.ps1"
      writeFile(testScript, """
param([string]$Helper, [string]$FixtureRoot)
$ErrorActionPreference = 'Stop'
. $Helper
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Make-Git($Name, $Prefix, $CertDir) {
    $root = Join-Path $FixtureRoot $Name
    $bin = Join-Path $root "$Prefix/bin"
    $cert = Join-Path $root "$Prefix/$CertDir/ca-bundle.crt"
    New-Item -ItemType Directory -Force $bin, (Split-Path $cert -Parent), (Join-Path $root 'cmd') | Out-Null
    foreach ($file in @('libssl-3-x64.dll', 'libcrypto-3-x64.dll', 'openssl.exe')) {
        Set-Content -LiteralPath (Join-Path $bin $file) 'fixture bytes'
    }
    Set-Content -LiteralPath $cert 'fixture CA bytes'
    Set-Content -LiteralPath (Join-Path $root 'cmd/git.exe') 'fixture git'
    return $root
}
function Reject($Git, $Reason) {
    $caught = $false
    try { Get-LeafGitHttpsRuntime -GitExecutable $Git | Out-Null }
    catch { $caught = $true; Assert ($_.Exception.Message -like '*HTTPS*') "Missing HTTPS diagnostic: $_" }
    Assert $caught $Reason
}
$current = Make-Git 'Git 中文 spaces new' 'ucrt64' 'etc/ssl/certs'
$git = Join-Path $current 'cmd/git.exe'
$runtime = Get-LeafGitHttpsRuntime -GitExecutable $git
AssertFixturePath ($runtime.OpenSslBin) ((Join-Path $current 'ucrt64/bin')) 'New ucrt64 runtime not selected'
AssertFixturePath ($runtime.Certificates) ((Join-Path $current 'ucrt64/etc/ssl/certs/ca-bundle.crt')) 'New CA not selected'
AssertEqual ($runtime.SslVersion) ('3-x64') 'Nim SSL filename suffix wrong'
# Git wrappers in bin and the native ucrt64 executable resolve the same root.
New-Item -ItemType Directory -Force (Join-Path $current 'bin') | Out-Null
foreach ($relative in @('bin/git.exe', 'ucrt64/bin/git.exe')) {
    $entry = Join-Path $current $relative
    Set-Content -LiteralPath $entry 'fixture git'
    AssertFixturePath ((Get-LeafGitHttpsRuntime -GitExecutable $entry).OpenSslBin) ($runtime.OpenSslBin) 'Git root derivation wrong'
}
$legacy = Make-Git 'Git legacy spaces' 'mingw64' 'ssl/certs'
$old = Get-LeafGitHttpsRuntime -GitExecutable (Join-Path $legacy 'cmd/git.exe')
AssertFixturePath ($old.OpenSslBin) ((Join-Path $legacy 'mingw64/bin')) 'Legacy runtime not selected'
AssertFixturePath ($old.Certificates) ((Join-Path $legacy 'mingw64/ssl/certs/ca-bundle.crt')) 'Legacy CA not selected'
$legacyEtc = Make-Git 'Git legacy etc' 'mingw64' 'etc/ssl/certs'
AssertFixturePath ((Get-LeafGitHttpsRuntime -GitExecutable (Join-Path $legacyEtc 'cmd/git.exe')).Certificates) `
    (Join-Path $legacyEtc 'mingw64/etc/ssl/certs/ca-bundle.crt') 'Legacy etc CA not selected'
# Prefer a complete ucrt64 layout; fall back only to another complete layout.
$both = Make-Git 'Git both layouts' 'mingw64' 'ssl/certs'
Make-Git 'Git both layouts' 'ucrt64' 'etc/ssl/certs' | Out-Null
$bothGit = Join-Path $both 'cmd/git.exe'
AssertFixturePath ((Get-LeafGitHttpsRuntime -GitExecutable $bothGit).OpenSslBin) `
    (Join-Path $both 'ucrt64/bin') 'Complete ucrt64 did not take precedence'
Remove-Item -LiteralPath (Join-Path $both 'ucrt64/bin/libcrypto-3-x64.dll')
AssertFixturePath ((Get-LeafGitHttpsRuntime -GitExecutable $bothGit).OpenSslBin) `
    (Join-Path $both 'mingw64/bin') 'Incomplete ucrt64 did not fall back to complete mingw64'
$pathFile = Join-Path $FixtureRoot 'github_path'
$envFile = Join-Path $FixtureRoot 'github_env'
Write-LeafGitHttpsEnvironment -Runtime $runtime -PathFile $pathFile -EnvironmentFile $envFile
AssertEqual ((Get-Content -LiteralPath $pathFile)) ($runtime.OpenSslBin) 'Runtime PATH not transmitted'
$lines = Get-Content -LiteralPath $envFile
Assert ($lines -contains 'NIM_SSL_VERSION=3-x64') 'Nim SSL suffix not transmitted'
Assert ($lines -contains ('SSL_CERT_FILE=' + $runtime.Certificates)) 'CA not transmitted'
# Validate complete pairs and certificates; never silently skip TLS.
Remove-Item -LiteralPath (Join-Path $current 'ucrt64/bin/libcrypto-3-x64.dll')
Reject $git 'Missing crypto accepted'
Set-Content -LiteralPath (Join-Path $current 'ucrt64/bin/libcrypto-3-x64.dll') '' -NoNewline
Reject $git 'Empty crypto accepted'
Set-Content -LiteralPath (Join-Path $current 'ucrt64/bin/libcrypto-3-x64.dll') 'fixture bytes'
Remove-Item -LiteralPath (Join-Path $current 'ucrt64/etc/ssl/certs/ca-bundle.crt')
Reject $git 'Missing CA accepted'
# Do not mix a ucrt64 ssl DLL with a mingw64 crypto DLL or certificate.
New-Item -ItemType Directory -Force (Join-Path $current 'mingw64/bin') | Out-Null
Set-Content -LiteralPath (Join-Path $current 'mingw64/bin/libcrypto-3-x64.dll') 'fixture bytes'
Reject $git 'Mixed incomplete profiles accepted'
Remove-Item -LiteralPath (Join-Path $legacy 'mingw64/bin/libssl-3-x64.dll')
Reject (Join-Path $legacy 'cmd/git.exe') 'Missing ssl accepted'
'Windows HTTPS layout/validation/environment regression passed'
""")
      let executed=runPowerShellFixture(pwsh,testScript,@[
        "-Helper",RepositoryRoot/"scripts/prepare_windows_https.ps1","-FixtureRoot",base])
      checkpoint executed.output
      check executed.exitCode==0

  test "real OpenSSL rejects invalid CA before publishing environment":
    let pwsh=findExe("pwsh")
    let openssl=findExe("openssl")
    if pwsh.len==0 or openssl.len==0:
      checkpoint "PowerShell/OpenSSL unavailable; real CA regression not verified"
      skip()
    else:
      let base=createTempDir("leaf CA 中文 space ", "")
      defer:removeDir(base)
      let testScript=base/"ca_tests.ps1"
      writeFile(testScript, """
param([string]$Helper, [string]$FixtureRoot, [string]$OpenSsl, [string]$OpenSslProbe)
$ErrorActionPreference = 'Stop'
. $Helper
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Set-CallerUtf8($Value) {
    if ($null -eq $Value) { Remove-Item Env:OPENSSL_WIN32_UTF8 -ErrorAction SilentlyContinue }
    else { $env:OPENSSL_WIN32_UTF8 = $Value }
}
$cert = Join-Path $FixtureRoot 'valid CA 中文.pem'
$key = Join-Path $FixtureRoot 'generated test key.pem'
$generationUtf8 = [Environment]::GetEnvironmentVariable('OPENSSL_WIN32_UTF8', 'Process')
try {
    $env:OPENSSL_WIN32_UTF8 = '1'
    $generationOutput = & $OpenSsl req -x509 -newkey rsa:2048 -nodes -subj '/CN=Leaf Test CA' -days 1 -keyout $key -out $cert 2>&1 | Out-String
} finally {
    Set-CallerUtf8 $generationUtf8
}
Assert ($LASTEXITCODE -eq 0) ("Test certificate generation failed; exit=[$LASTEXITCODE]; executable=[$OpenSsl]; cert=[$cert]; output=[$generationOutput]")
AssertEqual ([Environment]::GetEnvironmentVariable('OPENSSL_WIN32_UTF8', 'Process')) ($generationUtf8) 'Certificate generation did not restore caller UTF8 setting'
Assert ((Test-Path Env:OPENSSL_WIN32_UTF8) -eq ($null -ne $generationUtf8)) 'Certificate generation changed UTF8 environment presence'
Assert (Test-Path -LiteralPath $key -PathType Leaf) 'Chinese-directory key was not generated'
$runtime = [pscustomobject]@{
    OpenSslBin = Split-Path $OpenSsl -Parent
    OpenSslExecutable = $OpenSsl
    Certificates = $cert
    SslVersion = '3-x64'
}
$pathFile = Join-Path $FixtureRoot 'github_path'
$envFile = Join-Path $FixtureRoot 'github_env'
$previousPath = $env:PATH
# The fixture-generation flag must already have been restored. The product
# must independently enable UTF-8 for each native certificate validation call.
$originalUtf8 = [Environment]::GetEnvironmentVariable('OPENSSL_WIN32_UTF8', 'Process')
# Also validate the direct production invocation, before using the native
# environment probe to verify all calls and both caller environment states.
Assert-LeafGitHttpsCertificates -Runtime $runtime
AssertEqual ([Environment]::GetEnvironmentVariable('OPENSSL_WIN32_UTF8', 'Process')) ($originalUtf8) 'Direct OpenSSL validation changed caller UTF8 setting'
$env:LEAF_TEST_OPENSSL_DELEGATE = $OpenSsl
$env:LEAF_TEST_OPENSSL_TRACE = Join-Path $FixtureRoot 'native calls.jsonl'
$runtime.OpenSslExecutable = $OpenSslProbe
$certContent = [IO.File]::ReadAllText($cert)
try {
foreach ($callerUtf8 in @($null, 'caller original value')) {
    Set-CallerUtf8 $callerUtf8
    foreach ($file in @($pathFile, $envFile, $env:LEAF_TEST_OPENSSL_TRACE)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    $runtime.Certificates = $cert
Publish-LeafGitHttpsEnvironment -Runtime $runtime -PathFile $pathFile -EnvironmentFile $envFile
AssertEqual ([Environment]::GetEnvironmentVariable('OPENSSL_WIN32_UTF8', 'Process')) ($callerUtf8) 'Valid CA did not restore caller UTF8 setting'
Assert ((Test-Path Env:OPENSSL_WIN32_UTF8) -eq ($null -ne $callerUtf8)) 'Valid CA changed UTF8 environment presence'
AssertEqual ([IO.File]::ReadAllText($cert)) ($certContent) 'Validation changed Chinese certificate contents'
$calls = @(Get-Content -LiteralPath $env:LEAF_TEST_OPENSSL_TRACE | ForEach-Object { $_ | ConvertFrom-Json })
AssertEqual ($calls.Count) (3) 'Valid CA did not execute all three real OpenSSL checks'
AssertEqual (($calls | ForEach-Object { $_.arguments[0] }) -join ',') ('crl2pkcs7,pkcs7,x509') 'Certificate validation sequence wrong'
AssertEqual ($calls[0].arguments[3]) ($cert) 'Chinese certificate argv not preserved'
AssertEqual ((Get-Content -LiteralPath $pathFile)) ($runtime.OpenSslBin) 'Valid CA did not publish PATH'
$lines = Get-Content -LiteralPath $envFile
Assert ($lines -contains 'NIM_SSL_VERSION=3-x64') 'Valid CA did not publish SSL suffix'
Assert ($lines -contains ('SSL_CERT_FILE=' + $cert)) 'Valid CA did not publish CA path'
Assert (-not ($lines -match '^OPENSSL_WIN32_UTF8=')) 'UTF8 switch leaked into GITHUB_ENV'
Assert ($env:PATH -ceq $previousPath) 'Valid CA changed process PATH'
'Valid X509 CA accepted using real OpenSSL'
$invalid = @(
    @{ Name = 'garbage'; Text = "fixture CA bytes`n" },
    @{ Name = 'comments'; Text = "# CA bundle comment only`n# no certificates`n" },
    @{ Name = 'malformed PEM'; Text = "-----BEGIN CERTIFICATE-----`ninvalid`n-----END CERTIFICATE-----`n" }
)
foreach ($case in $invalid) {
    $runtime.Certificates = Join-Path $FixtureRoot ($case.Name + ' 中文.pem')
    Set-Content -LiteralPath $runtime.Certificates $case.Text -NoNewline
    # Both absent files and existing runner files must remain untouched.
    foreach ($existing in @($false, $true)) {
        foreach ($file in @($pathFile, $envFile)) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
        }
        if ($existing) {
            Set-Content -LiteralPath $pathFile 'existing PATH' -NoNewline
            Set-Content -LiteralPath $envFile 'EXISTING_ENV=preserved' -NoNewline
        }
        $caught = $false
        try { Publish-LeafGitHttpsEnvironment -Runtime $runtime -PathFile $pathFile -EnvironmentFile $envFile }
        catch {
            $caught = $true
            Assert ($_.Exception.Message -like '*HTTPS CA*') "Missing CA diagnostic: $_"
        }
        Assert $caught ($case.Name + ' incorrectly accepted')
        AssertEqual ([Environment]::GetEnvironmentVariable('OPENSSL_WIN32_UTF8', 'Process')) ($callerUtf8) ($case.Name + ' did not restore caller UTF8 setting')
        Assert ((Test-Path Env:OPENSSL_WIN32_UTF8) -eq ($null -ne $callerUtf8)) ($case.Name + ' changed UTF8 environment presence')
        Assert ($env:PATH -ceq $previousPath) ($case.Name + ' changed process PATH')
        if ($existing) {
            Assert ([IO.File]::ReadAllText($pathFile) -ceq 'existing PATH') ($case.Name + ' appended PATH')
            Assert ([IO.File]::ReadAllText($envFile) -ceq 'EXISTING_ENV=preserved') ($case.Name + ' appended ENV')
        } else {
            Assert (-not (Test-Path -LiteralPath $pathFile)) ($case.Name + ' created PATH')
            Assert (-not (Test-Path -LiteralPath $envFile)) ($case.Name + ' created ENV')
        }
    }
    ($case.Name + ' rejected; PATH/ENV unchanged')
}
$allCalls = @(Get-Content -LiteralPath $env:LEAF_TEST_OPENSSL_TRACE | ForEach-Object { $_ | ConvertFrom-Json })
Assert (@($allCalls | Where-Object { $_.utf8 -cne '1' }).Count -eq 0) 'Invalid CA checks failed before reaching real OpenSSL with scoped UTF8'
('Scoped UTF8 restored after success/rejections; original=[' + $callerUtf8 + ']')
}
} finally {
    Set-CallerUtf8 $originalUtf8
}
""")
      let executed=runPowerShellFixture(pwsh,testScript,@[
        "-Helper",RepositoryRoot/"scripts/prepare_windows_https.ps1",
        "-FixtureRoot",base,"-OpenSsl",openssl,"-OpenSslProbe",getAppFilename()])
      checkpoint executed.output
      check executed.exitCode==0

  test "real Application discovery selects first Git path and honors explicit override":
    let pwsh=findExe("pwsh")
    if pwsh.len==0:
      checkpoint "PowerShell unavailable; multiple Git Application discovery not verified"
      skip()
    else:
      let base=createTempDir("leaf Git discovery 中文 space ", "")
      defer:removeDir(base)
      let gitRoot=base/"Git 中文 spaces"
      for directory in ["bin", "cmd", "mingw64/bin"]:
        let bin=gitRoot/directory
        createDir(bin)
        let git=bin/"git.exe"
        writeFile(git,"#!/bin/sh\nexit 0\n")
        when not defined(windows):
          setFilePermissions(git,{fpUserRead,fpUserWrite,fpUserExec})
      let testScript=base/"discovery_tests.ps1"
      writeFile(testScript, """
param([string]$Helper, [string]$GitRoot)
$ErrorActionPreference = 'Stop'
. $Helper
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$bins = @('bin', 'cmd', 'mingw64/bin') | ForEach-Object { Join-Path $GitRoot $_ }
$expected = Join-Path $bins[0] 'git.exe'
$previousPath = $env:PATH
try {
    $env:PATH = $bins -join [IO.Path]::PathSeparator
    # Genuine Application objects discovered from executable fixture files,
    # not mocked Get-Command objects or joined path strings.
    $applications = @(Get-Command git.exe -CommandType Application)
    AssertEqual ($applications.Count) (3) 'Fixture did not discover all three Git Applications'
    AssertFixturePath ($applications[0].Source) ($expected) 'Application order differs from PATH order'
    'Discovered three real Git Applications: ' + ($applications.Source -join '; ')
    $selected = Resolve-LeafGitExecutable
    Assert ($selected -is [string]) 'Discovery did not return one path string'
    AssertFixturePath ($selected) ($expected) 'Discovery did not select first Application before taking Source'
    Assert (Test-Path -LiteralPath $selected -PathType Leaf) 'Selected Git path does not exist'
    # Feed discovery into the unchanged supported-layout selector.
    $runtimeBin = Join-Path $GitRoot 'mingw64/bin'
    $cert = Join-Path $GitRoot 'mingw64/etc/ssl/certs/ca-bundle.crt'
    New-Item -ItemType Directory -Force (Split-Path $cert -Parent) | Out-Null
    foreach ($file in @('libssl-3-x64.dll', 'libcrypto-3-x64.dll', 'openssl.exe')) {
        Set-Content -LiteralPath (Join-Path $runtimeBin $file) 'layout fixture bytes'
    }
    Set-Content -LiteralPath $cert 'layout fixture CA bytes'
    AssertFixturePath ((Get-LeafGitHttpsRuntime -GitExecutable $selected).OpenSslBin) ($runtimeBin) 'Discovered Git did not resolve legacy layout'
    'First Application selected; legacy layout resolved'
    $env:PATH = @($bins[1], $bins[0], $bins[2]) -join [IO.Path]::PathSeparator
    AssertFixturePath ((Resolve-LeafGitExecutable)) ((Join-Path $bins[1] 'git.exe')) 'Reordered PATH did not select its first Application'
    $env:PATH = $bins[2]
    AssertFixturePath ((Resolve-LeafGitExecutable)) ((Join-Path $bins[2] 'git.exe')) 'Single Application discovery failed'
    $env:PATH = ''
    AssertEqual ((Resolve-LeafGitExecutable -GitExecutable $expected)) ($expected) 'Explicit GitExecutable was not preserved with empty PATH'
    'Reordered/single discovery and explicit override passed'
} finally {
    $env:PATH = $previousPath
}
""")
      let executed=runPowerShellFixture(pwsh,testScript,@[
        "-Helper",RepositoryRoot/"scripts/prepare_windows_https.ps1","-GitRoot",gitRoot])
      checkpoint executed.output
      check executed.exitCode==0
