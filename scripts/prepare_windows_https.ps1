# Git for Windows 2.56 moved the native x64 runtime from mingw64 to ucrt64.
# Inspect only the installed Git root and supported OpenSSL 3 x64 layouts.
param([string]$GitExecutable)
$ErrorActionPreference = 'Stop'

function Resolve-LeafGitExecutable {
    param([string]$GitExecutable)
    if ($GitExecutable) { return $GitExecutable }
    return (Get-Command git.exe -CommandType Application | Select-Object -First 1).Source
}

function Get-LeafGitHttpsRuntime {
    param([Parameter(Mandatory)][string]$GitExecutable)
    if (-not (Test-Path -LiteralPath $GitExecutable -PathType Leaf)) {
        throw "Git HTTPS executable missing: $GitExecutable"
    }
    $gitDirectory = Split-Path ([IO.Path]::GetFullPath($GitExecutable)) -Parent
    $root = Split-Path $gitDirectory -Parent
    if ((Split-Path $gitDirectory -Leaf) -eq 'bin' -and
        (Split-Path $root -Leaf) -in @('ucrt64', 'mingw64')) {
        $root = Split-Path $root -Parent
    } elseif ((Split-Path $gitDirectory -Leaf) -notin @('bin', 'cmd')) {
        throw "Git HTTPS executable has unsupported layout: $GitExecutable"
    }
    $checked = @()
    foreach ($prefix in @('ucrt64', 'mingw64')) {
        $bin = Join-Path $root "$prefix/bin"
        $ssl = Join-Path $bin 'libssl-3-x64.dll'
        $crypto = Join-Path $bin 'libcrypto-3-x64.dll'
        $openssl = Join-Path $bin 'openssl.exe'
        $checked += $ssl, $crypto, $openssl
        $complete = $true
        foreach ($file in @($ssl, $crypto, $openssl)) {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
                (Get-Item -LiteralPath $file).Length -eq 0) { $complete = $false }
        }
        foreach ($certDir in @('etc/ssl/certs', 'ssl/certs')) {
            $certificates = Join-Path $root "$prefix/$certDir/ca-bundle.crt"
            $checked += $certificates
            if ($complete -and (Test-Path -LiteralPath $certificates -PathType Leaf) -and
                (Get-Item -LiteralPath $certificates).Length -gt 0) {
                return [pscustomobject]@{
                    OpenSslBin = $bin; Certificates = $certificates; SslVersion = '3-x64'
                    SslLibrary = $ssl; CryptoLibrary = $crypto; OpenSslExecutable = $openssl
                }
            }
        }
    }
    throw "Git HTTPS dependencies missing or empty; checked supported paths: $($checked -join ', ')"
}

function Write-LeafGitHttpsEnvironment {
    param([Parameter(Mandatory)]$Runtime, [Parameter(Mandatory)][string]$PathFile,
          [Parameter(Mandatory)][string]$EnvironmentFile)
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::AppendAllText($PathFile, $Runtime.OpenSslBin + "`n", $encoding)
    [IO.File]::AppendAllText($EnvironmentFile,
        'NIM_SSL_VERSION=' + $Runtime.SslVersion + "`n" +
        'SSL_CERT_FILE=' + $Runtime.Certificates + "`n", $encoding)
}

function Assert-LeafGitHttpsCertificates {
    param([Parameter(Mandatory)]$Runtime)
    $certificateOutput = [IO.Path]::GetTempFileName()
    $decodedCertificates = [IO.Path]::GetTempFileName()
    try {
        & $runtime.OpenSslExecutable crl2pkcs7 -nocrl -certfile $runtime.Certificates -out $certificateOutput
        if ($LASTEXITCODE -ne 0 -or (Get-Item -LiteralPath $certificateOutput).Length -eq 0) {
            throw "Git HTTPS CA bundle cannot be parsed: $($runtime.Certificates)"
        }
        # crl2pkcs7 accepts plain text and emits a nonempty, zero-certificate
        # container. Decode it and require an actual parsed X509 certificate.
        & $runtime.OpenSslExecutable pkcs7 -in $certificateOutput -print_certs -out $decodedCertificates
        if ($LASTEXITCODE -ne 0 -or (Get-Item -LiteralPath $decodedCertificates).Length -eq 0) {
            throw "Git HTTPS CA bundle contains no parsed certificates: $($runtime.Certificates)"
        }
        & $runtime.OpenSslExecutable x509 -in $decodedCertificates -noout
        if ($LASTEXITCODE -ne 0) {
            throw "Git HTTPS CA bundle contains no parsed X509 certificate: $($runtime.Certificates)"
        }
    } finally {
        Remove-Item -LiteralPath $certificateOutput, $decodedCertificates -ErrorAction SilentlyContinue
    }
}

function Publish-LeafGitHttpsEnvironment {
    param([Parameter(Mandatory)]$Runtime, [Parameter(Mandatory)][string]$PathFile,
          [Parameter(Mandatory)][string]$EnvironmentFile)
    Assert-LeafGitHttpsCertificates -Runtime $Runtime
    Write-LeafGitHttpsEnvironment -Runtime $Runtime -PathFile $PathFile -EnvironmentFile $EnvironmentFile
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $IsWindows) { throw 'Windows HTTPS preparation requires a Windows runner.' }
    $GitExecutable = Resolve-LeafGitExecutable -GitExecutable $GitExecutable
    $runtime = Get-LeafGitHttpsRuntime -GitExecutable $GitExecutable
    # Validate loading both libraries, the OpenSSL 3 executable and the CA bundle
    # before publishing environment values to later jobs/steps. No TLS bypass.
    $previousPath = $env:PATH
    $crypto = [IntPtr]::Zero
    $ssl = [IntPtr]::Zero
    try {
        $env:PATH = $runtime.OpenSslBin + [IO.Path]::PathSeparator + $previousPath
        $crypto = [Runtime.InteropServices.NativeLibrary]::Load($runtime.CryptoLibrary)
        $ssl = [Runtime.InteropServices.NativeLibrary]::Load($runtime.SslLibrary)
        [Runtime.InteropServices.NativeLibrary]::GetExport($crypto, 'OpenSSL_version_num') | Out-Null
        [Runtime.InteropServices.NativeLibrary]::GetExport($ssl, 'SSL_CTX_new') | Out-Null
        $version = & $runtime.OpenSslExecutable version
        if ($LASTEXITCODE -ne 0 -or $version -notmatch '^OpenSSL 3\.') {
            throw "Git HTTPS requires working OpenSSL 3: $version"
        }
        Publish-LeafGitHttpsEnvironment -Runtime $runtime -PathFile $env:GITHUB_PATH -EnvironmentFile $env:GITHUB_ENV
        Write-Host "Git HTTPS: $version; runtime=$($runtime.OpenSslBin); CA=$($runtime.Certificates)"
    } finally {
        if ($ssl -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($ssl) }
        if ($crypto -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($crypto) }
        $env:PATH = $previousPath
    }
}
