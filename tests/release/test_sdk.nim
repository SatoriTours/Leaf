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
    when defined(windows):
      let junction=runCommand("cmd.exe",@["/d","/c","mklink","/J",alias,sdk])
      checkpoint junction.output
      check junction.exitCode==0
    else:createSymlink(sdk,alias)
    check within(sdk/"toolchain"/"nim",alias)
    check within(alias/"toolchain"/"nim",sdk)
  test "real directory link escape and outside files remain rejected":
    let escaped=sdk/"escaped-directory"
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
Assert ($runtime.OpenSslBin -eq (Join-Path $current 'ucrt64/bin')) 'New ucrt64 runtime not selected'
Assert ($runtime.Certificates -eq (Join-Path $current 'ucrt64/etc/ssl/certs/ca-bundle.crt')) 'New CA not selected'
Assert ($runtime.SslVersion -eq '3-x64') 'Nim SSL filename suffix wrong'
# Git wrappers in bin and the native ucrt64 executable resolve the same root.
New-Item -ItemType Directory -Force (Join-Path $current 'bin') | Out-Null
foreach ($relative in @('bin/git.exe', 'ucrt64/bin/git.exe')) {
    $entry = Join-Path $current $relative
    Set-Content -LiteralPath $entry 'fixture git'
    Assert ((Get-LeafGitHttpsRuntime -GitExecutable $entry).OpenSslBin -eq $runtime.OpenSslBin) 'Git root derivation wrong'
}
$legacy = Make-Git 'Git legacy spaces' 'mingw64' 'ssl/certs'
$old = Get-LeafGitHttpsRuntime -GitExecutable (Join-Path $legacy 'cmd/git.exe')
Assert ($old.OpenSslBin -eq (Join-Path $legacy 'mingw64/bin')) 'Legacy runtime not selected'
Assert ($old.Certificates -eq (Join-Path $legacy 'mingw64/ssl/certs/ca-bundle.crt')) 'Legacy CA not selected'
$legacyEtc = Make-Git 'Git legacy etc' 'mingw64' 'etc/ssl/certs'
Assert ((Get-LeafGitHttpsRuntime -GitExecutable (Join-Path $legacyEtc 'cmd/git.exe')).Certificates -eq
    (Join-Path $legacyEtc 'mingw64/etc/ssl/certs/ca-bundle.crt')) 'Legacy etc CA not selected'
# Prefer a complete ucrt64 layout; fall back only to another complete layout.
$both = Make-Git 'Git both layouts' 'mingw64' 'ssl/certs'
Make-Git 'Git both layouts' 'ucrt64' 'etc/ssl/certs' | Out-Null
$bothGit = Join-Path $both 'cmd/git.exe'
Assert ((Get-LeafGitHttpsRuntime -GitExecutable $bothGit).OpenSslBin -eq
    (Join-Path $both 'ucrt64/bin')) 'Complete ucrt64 did not take precedence'
Remove-Item -LiteralPath (Join-Path $both 'ucrt64/bin/libcrypto-3-x64.dll')
Assert ((Get-LeafGitHttpsRuntime -GitExecutable $bothGit).OpenSslBin -eq
    (Join-Path $both 'mingw64/bin')) 'Incomplete ucrt64 did not fall back to complete mingw64'
$pathFile = Join-Path $FixtureRoot 'github_path'
$envFile = Join-Path $FixtureRoot 'github_env'
Write-LeafGitHttpsEnvironment -Runtime $runtime -PathFile $pathFile -EnvironmentFile $envFile
Assert ((Get-Content -LiteralPath $pathFile) -eq $runtime.OpenSslBin) 'Runtime PATH not transmitted'
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
      let executed=runCommand(pwsh,@["-NoProfile","-File",testScript,
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
param([string]$Helper, [string]$FixtureRoot, [string]$OpenSsl)
$ErrorActionPreference = 'Stop'
. $Helper
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$cert = Join-Path $FixtureRoot 'valid CA 中文.pem'
$key = Join-Path $FixtureRoot 'generated test key.pem'
& $OpenSsl req -x509 -newkey rsa:2048 -nodes -subj '/CN=Leaf Test CA' -days 1 -keyout $key -out $cert 2>&1 | Out-Null
Assert ($LASTEXITCODE -eq 0) 'Test certificate generation failed'
$runtime = [pscustomobject]@{
    OpenSslBin = Split-Path $OpenSsl -Parent
    OpenSslExecutable = $OpenSsl
    Certificates = $cert
    SslVersion = '3-x64'
}
$pathFile = Join-Path $FixtureRoot 'github_path'
$envFile = Join-Path $FixtureRoot 'github_env'
$previousPath = $env:PATH
Publish-LeafGitHttpsEnvironment -Runtime $runtime -PathFile $pathFile -EnvironmentFile $envFile
Assert ((Get-Content -LiteralPath $pathFile) -eq $runtime.OpenSslBin) 'Valid CA did not publish PATH'
$lines = Get-Content -LiteralPath $envFile
Assert ($lines -contains 'NIM_SSL_VERSION=3-x64') 'Valid CA did not publish SSL suffix'
Assert ($lines -contains ('SSL_CERT_FILE=' + $cert)) 'Valid CA did not publish CA path'
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
""")
      let executed=runCommand(pwsh,@["-NoProfile","-File",testScript,
        "-Helper",RepositoryRoot/"scripts/prepare_windows_https.ps1",
        "-FixtureRoot",base,"-OpenSsl",openssl])
      checkpoint executed.output
      check executed.exitCode==0
