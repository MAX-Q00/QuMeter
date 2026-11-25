# Builds an unsigned Store-ready QuMeter MSIX (and optionally a separately test-signed copy).
# Published by QuSpace Studios LLC
# (c) 2026 QuSpace Studios LLC
#   pwsh -NoProfile -File scripts/New-QuMeterMsix.ps1 [-OutDir ...] [-TestSign]
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $env:USERPROFILE 'Documents\QuMeter-Store'),
    [switch]$TestSign
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
. (Join-Path $root 'QuMeterCore.ps1')

$version = Get-QmVersion
$pkgVersion = "$version.0"
if ($pkgVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { $pkgVersion = '2.2.4.0' }
$msixName = "QuMeter_${pkgVersion}_x64.msix"
$msixPath = Join-Path $OutDir $msixName

function Find-QmMakeAppx {
    $cmd = Get-Command makeappx.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (Test-Path -LiteralPath $kits) {
        $hit = Get-ChildItem -LiteralPath $kits -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\makeappx\.exe$' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    throw 'makeappx.exe not found. Install the Windows 10/11 SDK.'
}

function Find-QmSignTool {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (Test-Path -LiteralPath $kits) {
        $hit = Get-ChildItem -LiteralPath $kits -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Find-QmCsc {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (Test-Path -LiteralPath $csc) { return $csc }
    throw 'csc.exe not found (need .NET Framework 4.x developer pack / Framework64).'
}

# 1) Assets + icon
& (Join-Path $root 'scripts\New-QuMeterAssets.ps1') -OutRoot $root

# 2) QuSnmp.dll
$csc = Find-QmCsc
$dll = Join-Path $root 'QuSnmp.dll'
$cs = Join-Path $root 'QuSnmp.cs'
if (Test-Path -LiteralPath $dll) { Remove-Item -LiteralPath $dll -Force }
& $csc /nologo /target:library /optimize+ /out:"$dll" /reference:System.dll /reference:System.Core.dll "$cs"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dll)) { throw "Failed to compile QuSnmp.dll (exit $LASTEXITCODE)" }

# 3) QuMeter.exe (net48 WinExe)
$ico = Join-Path $root 'QuMeter.ico'
if (-not (Test-Path -LiteralPath $ico)) { throw "QuMeter.ico missing at $ico" }
$proj = Join-Path $root 'packaging\launcher\QuMeter.csproj'
$outExeDir = Join-Path $root 'packaging\launcher\bin'
if (-not (Test-Path -LiteralPath $outExeDir)) { New-Item -ItemType Directory -Path $outExeDir -Force | Out-Null }
$builtExe = Join-Path $outExeDir 'QuMeter.exe'
dotnet build $proj -c Release -p:OutputPath="$outExeDir\" -v q
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $builtExe)) { throw "Failed to build QuMeter.exe (exit $LASTEXITCODE)" }
Copy-Item -LiteralPath $builtExe -Destination (Join-Path $root 'QuMeter.exe') -Force

# 4) Stage package payload
$stage = Join-Path ([IO.Path]::GetTempPath()) ('QuMeter-msix-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    $payload = @(
        'QuMeter.exe', 'QuMeter.ico', 'QuMeter.bat',
        'QuMeter.ps1', 'QuMeterCore.ps1', 'QuMeterEngine.ps1', 'QuMeterUpdate.ps1',
        'QuSnmp.ps1', 'QuSnmp.cs', 'QuSnmp.dll',
        'e-automate.mapping.json', 'README.md'
    )
    foreach ($f in $payload) {
        $src = Join-Path $root $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $stage $f) -Force
        }
    }
    $manifestSrc = Join-Path $root 'packaging\msix\AppxManifest.xml'
    Copy-Item -LiteralPath $manifestSrc -Destination (Join-Path $stage 'AppxManifest.xml') -Force
    $assetsSrc = Join-Path $root 'packaging\msix\Assets'
    Copy-Item -LiteralPath $assetsSrc -Destination (Join-Path $stage 'Assets') -Recurse -Force

    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    if (Test-Path -LiteralPath $msixPath) { Remove-Item -LiteralPath $msixPath -Force }

    $makeappx = Find-QmMakeAppx
    & $makeappx pack /d $stage /p $msixPath /o
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $msixPath)) {
        throw "makeappx failed (exit $LASTEXITCODE)"
    }

    Write-Host "Packed unsigned Store MSIX: $msixPath"
    Write-Host "Size $((Get-Item -LiteralPath $msixPath).Length) bytes"

    # Verify package layout
    & $makeappx unpack /p $msixPath /d (Join-Path $stage '_verify') /o | Out-Null
    $verifyManifest = Join-Path $stage '_verify\AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $verifyManifest)) { throw 'makeappx verify unpack failed (no AppxManifest.xml)' }
    $verifyExe = Join-Path $stage '_verify\QuMeter.exe'
    if (-not (Test-Path -LiteralPath $verifyExe)) { throw 'makeappx verify unpack failed (no QuMeter.exe)' }
    Write-Host 'Verified package contains AppxManifest.xml and QuMeter.exe'

    if ($TestSign) {
        $signtool = Find-QmSignTool
        if (-not $signtool) { throw 'signtool.exe not found (needed for -TestSign)' }
        [xml]$manifestXml = Get-Content -LiteralPath $manifestSrc -Encoding UTF8
        $publisher = [string]$manifestXml.Package.Identity.Publisher
        if ([string]::IsNullOrWhiteSpace($publisher)) { throw 'AppxManifest.xml Identity Publisher is missing' }
        $pfx = Join-Path $OutDir 'QuMeter-test.pfx'
        $cer = Join-Path $OutDir 'QuMeter-test.cer'
        $pwdText = 'QuMeterTest!'
        $secure = ConvertTo-SecureString -String $pwdText -Force -AsPlainText
        $needNewCert = $true
        if (Test-Path -LiteralPath $pfx) {
            try {
                $existingCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
                $existingCert.Import($pfx, $pwdText, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet)
                $existingSubject = [string]$existingCert.Subject
                $existingCert.Reset()
                if ([string]::Equals($existingSubject, $publisher, [StringComparison]::OrdinalIgnoreCase)) {
                    $needNewCert = $false
                }
            } catch {
                $needNewCert = $true
            }
        }
        if ($needNewCert) {
            if (Test-Path -LiteralPath $pfx) { Remove-Item -LiteralPath $pfx -Force }
            if (Test-Path -LiteralPath $cer) { Remove-Item -LiteralPath $cer -Force }
            $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $publisher -CertStoreLocation 'Cert:\CurrentUser\My'
            Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secure | Out-Null
            Export-Certificate -Cert $cert -FilePath $cer | Out-Null
            Write-Host "Created test certificate with Subject=$publisher"
        }
        $testMsix = Join-Path $OutDir ("QuMeter_${pkgVersion}_x64_test.msix")
        Copy-Item -LiteralPath $msixPath -Destination $testMsix -Force
        & $signtool sign /fd SHA256 /a /f $pfx /p $pwdText $testMsix
        if ($LASTEXITCODE -ne 0) { throw "signtool failed (exit $LASTEXITCODE)" }
        Write-Host "Test-signed copy: $testMsix (unsigned Store package left untouched)"
    }
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'This script does not upload to Partner Center.'
Write-Host "Store package: $msixPath"
