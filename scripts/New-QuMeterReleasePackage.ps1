# Builds the GitHub Release zip the QuMeter updater looks for. Does not publish a release.
# Published by QuSpace Studios LLC
# (c) 2026 QuSpace Studios LLC
#   pwsh -NoProfile -File scripts/New-QuMeterReleasePackage.ps1 [-OutDir dist]
[CmdletBinding()]
param(
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
. (Join-Path $root 'QuMeterCore.ps1')

$version = Get-QmVersion
$zipName = Get-QmReleaseZipName $version
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$zipPath = Join-Path $OutDir $zipName
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

$stage = Join-Path ([IO.Path]::GetTempPath()) ('QuMeter-pack-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    $files = @(Get-QmAppPayloadFiles) + @('e-automate.mapping.json', 'mps-import.mapping.json', '.gitignore')
    foreach ($f in $files) {
        $src = Join-Path $root $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $stage $f) -Force }
    }
    foreach ($dir in @('scripts', 'tests')) {
        $src = Join-Path $root $dir
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $stage $dir) -Recurse -Force
        }
    }
    $tmpOut = Join-Path $stage (Join-Path 'tests' 'tmp-out')
    if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Recurse -Force }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath)
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

$sha = Get-QmFileSha256 $zipPath
$shaPath = "$zipPath.sha256"
Set-Content -LiteralPath $shaPath -Value "$sha  $zipName" -Encoding ASCII
$size = (Get-Item -LiteralPath $zipPath).Length

Write-Host "Packed $zipPath"
Write-Host "Size    $size bytes"
Write-Host "SHA256  $sha"
Write-Host ""
Write-Host "This script does not publish a GitHub Release. To ship an update the app can install:"
Write-Host "  1. Set the version in QuMeterCore.ps1 (`$script:QmVersion, the only source of truth) and commit."
Write-Host "  2. Merge the change to main."
Write-Host "  3. Create an annotated tag that matches that version, for example v$version"
Write-Host ('       git tag -a v{0} -m "QuMeter {0}"' -f $version)
Write-Host "       git push origin v$version"
Write-Host "  4. On GitHub, open Releases -> Draft a new release, choose tag v$version."
Write-Host "  5. Attach this zip as a release asset. The updater looks for this exact name:"
Write-Host "       $zipName"
Write-Host "  6. Optional: attach $zipName.sha256, or paste this line in the release notes:"
Write-Host "       SHA256: $sha"
Write-Host "     GitHub also publishes an asset digest the updater will use when the API returns it."
Write-Host "  7. Publish the release (not as a draft or prerelease). The app checks /releases/latest at startup."
Write-Host "Do not put a versioned wrapper folder inside the zip; payload files belong at the zip root."
