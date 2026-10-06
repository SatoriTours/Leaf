# One-command, per-user Windows SDK installation. Compatible with PowerShell 5.1+.
[CmdletBinding()]
param(
    [ValidateSet('release', 'beta')][string]$Channel = 'release',
    [string]$Version = '',
    [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'Leaf'),
    [string]$BinDir = '',
    [string]$DownloadBase = 'https://github.com/SatoriTours/Leaf',
    [switch]$NoPath
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$staging = $null
$entryTemp = $null
try {
    $hostArchitecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($env:OS -ne 'Windows_NT' -or $hostArchitecture -ne 'AMD64' -or
        -not [Environment]::Is64BitOperatingSystem) { throw 'Supported Windows target: x86_64.' }
    if ($Version -and ($Channel -ne 'release' -or $Version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$')) {
        throw '-Version requires the release channel and a vX.Y.Z tag.'
    }
    if ($DownloadBase -notmatch '^(https|file)://') { throw 'DownloadBase must use HTTPS (or file:// for offline installation).' }
    if (-not $BinDir) { $BinDir = Join-Path $Prefix 'bin' }
    $Prefix = [IO.Path]::GetFullPath($Prefix)
    $BinDir = [IO.Path]::GetFullPath($BinDir)
    $versions = Join-Path $Prefix 'versions'
    New-Item -ItemType Directory -Force -Path $versions, $BinDir | Out-Null
    $id = [Guid]::NewGuid().ToString('N')
    $staging = Join-Path $versions ('.install-' + $id)
    New-Item -ItemType Directory -Path $staging | Out-Null
    $asset = 'leaf-sdk-windows-x86_64.zip'
    if ($Channel -eq 'beta') { $baseUrl = "$DownloadBase/releases/download/beta" }
    elseif ($Version) { $baseUrl = "$DownloadBase/releases/download/$Version" }
    else { $baseUrl = "$DownloadBase/releases/latest/download" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    function Get-LeafDownload([string]$Url, [string]$Destination) {
        if ($Url.StartsWith('file://')) { Copy-Item -LiteralPath ([Uri]$Url).LocalPath -Destination $Destination }
        else { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination }
    }
    $archive = Join-Path $staging $asset
    Get-LeafDownload "$baseUrl/$asset" $archive
    Get-LeafDownload "$baseUrl/$asset.sha256" (Join-Path $staging 'checksum')
    $expected = ((Get-Content -LiteralPath (Join-Path $staging 'checksum') -Raw).Trim() -split '\s+')[0]
    if ($expected -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash -ne $expected) {
        throw 'Checksum mismatch; existing installation kept.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if (-not $name.StartsWith('leaf-sdk/') -or $name -match '(^|/)\.\.(/|$)|:' -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw 'Invalid SDK archive entry.'
            }
        }
    } finally { $zip.Dispose() }
    Expand-Archive -LiteralPath $archive -DestinationPath $staging
    $sdk = Join-Path $staging 'leaf-sdk'
    foreach ($file in @('bin/leaf.exe', 'src/leaf.nim', 'sdk.json', 'lib/leaf_gpui.dll',
                       'toolchain/nim/bin/nim.exe', 'toolchain/nim/lib/system.nim')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sdk $file) -PathType Leaf)) { throw "SDK file missing: $file" }
    }
    $metadata = Get-Content -LiteralPath (Join-Path $sdk 'sdk.json') -Raw | ConvertFrom-Json
    if ($metadata.schema -ne 1 -or $metadata.channel -ne $Channel -or $metadata.target -ne 'windows-x86_64' -or
        ($Version -and $metadata.version -ne $Version)) { throw 'SDK metadata does not match the requested version or target.' }
    & (Join-Path $sdk 'bin/leaf.exe') --version
    if ($LASTEXITCODE -ne 0) { throw 'SDK executable cannot run on this system.' }
    # Fetch MinGW from its original distributor rather than republishing GCC binaries.
    if ($DownloadBase.StartsWith('file://')) { $ccBase = "$DownloadBase/toolchains" }
    else { $ccBase = 'https://nim-lang.org/download' }
    $ccArchive = Join-Path $staging 'mingw64.7z'
    $ccChecksum = Join-Path $staging 'mingw64.7z.sha256'
    Get-LeafDownload "$ccBase/mingw64.7z" $ccArchive
    Get-LeafDownload "$ccBase/mingw64.7z.sha256" $ccChecksum
    $ccHash = ((Get-Content -LiteralPath $ccChecksum -Raw).Trim() -split '\s+')[0]
    if ($ccHash -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -Algorithm SHA256 $ccArchive).Hash -ne $ccHash) {
        throw 'MinGW checksum mismatch; existing installation kept.'
    }
    $ccExtract = Join-Path $staging 'c-compiler'
    New-Item -ItemType Directory -Path $ccExtract | Out-Null
    & "$env:SystemRoot\System32\tar.exe" -xf $ccArchive -C $ccExtract
    if ($LASTEXITCODE -ne 0) { throw 'MinGW extraction failed.' }
    $ccRoot = Join-Path $ccExtract 'mingw64'
    if (-not (Test-Path -LiteralPath (Join-Path $ccRoot 'bin/gcc.exe'))) { throw 'MinGW compiler missing.' }
    Move-Item -LiteralPath $ccRoot -Destination (Join-Path $sdk 'toolchain/mingw')
    $installed = Join-Path $versions ($Channel + '-' + $id)
    Move-Item -LiteralPath $sdk -Destination $installed
    $entryTemp = Join-Path $BinDir ('.leaf-' + $id + '.cmd')
    # Read the UTF-8 executable path after switching cmd's code page, and restore it.
    # This works for Chinese usernames in PowerShell 5.1 and PowerShell 7 alike.
    $exePath = (Join-Path $installed 'bin/leaf.exe').Replace('%', '%%')
    $command = '@echo off' + "`r`n" + 'setlocal DisableDelayedExpansion' + "`r`n" +
        'for /f "tokens=2 delims=:" %%a in (''chcp'') do set "_leaf_cp=%%a"' + "`r`n" +
        'chcp 65001 >nul' + "`r`n" + '"' + $exePath + '" %*' + "`r`n" +
        'set "_leaf_exit=%ERRORLEVEL%"' + "`r`n" + 'chcp %_leaf_cp% >nul' + "`r`n" + 'exit /b %_leaf_exit%' + "`r`n"
    [IO.File]::WriteAllText($entryTemp, $command, (New-Object Text.UTF8Encoding $false))
    $entryPath = Join-Path $BinDir 'leaf.cmd'
    if (Test-Path -LiteralPath $entryPath) { [IO.File]::Replace($entryTemp, $entryPath, $null) }
    else { [IO.File]::Move($entryTemp, $entryPath) }
    $entryTemp = $null
    if (-not $NoPath) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($BinDir -notin ($userPath -split ';')) {
            [Environment]::SetEnvironmentVariable('Path', "$BinDir;$userPath", 'User')
        }
        if ($BinDir -notin ($env:PATH -split ';')) { $env:PATH = "$BinDir;$env:PATH" }
    }
    Write-Host "Installed $Channel SDK: $installed"
    Write-Host "Command: $entryPath"
} finally {
    if ($entryTemp -and (Test-Path -LiteralPath $entryTemp)) { Remove-Item -LiteralPath $entryTemp -Force }
    if ($staging -and (Test-Path -LiteralPath $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
