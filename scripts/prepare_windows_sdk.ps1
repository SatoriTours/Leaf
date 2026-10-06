# Fetch Nim's documented MinGW distribution and retain the complete toolchain.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$work = Join-Path $env:RUNNER_TEMP 'leaf-mingw'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$archive = Join-Path $work 'mingw64.7z'
Invoke-WebRequest -UseBasicParsing 'https://nim-lang.org/download/mingw64.7z' -OutFile $archive
$checksumFile = Join-Path $work 'mingw64.7z.sha256'
Invoke-WebRequest -UseBasicParsing 'https://nim-lang.org/download/mingw64.7z.sha256' -OutFile $checksumFile
$checksum = ((Get-Content -LiteralPath $checksumFile -Raw).Trim() -split '\s+')[0]
if ($checksum -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -Algorithm SHA256 $archive).Hash -ne $checksum) {
    throw 'MinGW distribution checksum mismatch.'
}
& 7z x $archive "-o$work/extracted" -y
if ($LASTEXITCODE -ne 0) { throw 'MinGW extraction failed.' }
$gcc = Get-ChildItem (Join-Path $work 'extracted') -Recurse -Filter gcc.exe |
    Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
if (-not $gcc) { throw 'MinGW gcc.exe missing.' }
$gcc.Directory.FullName >> $env:GITHUB_PATH
('LEAF_CC_ROOT=' + $gcc.Directory.Parent.FullName) >> $env:GITHUB_ENV
