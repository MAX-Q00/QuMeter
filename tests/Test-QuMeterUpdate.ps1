# Tests for version compare, release parsing, hash verify, and file install.
#   pwsh -NoProfile -File tests/Test-QuMeterUpdate.ps1
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
. (Join-Path $root 'QuMeterCore.ps1')
$script:failed = 0; $script:passed = 0
function Assert-True($cond, $name) { if ($cond) { $script:passed++; Write-Host "  PASS  $name" } else { $script:failed++; Write-Host "  FAIL  $name" } }
function Assert-Eq($a, $e, $name) { if ("$a" -eq "$e") { $script:passed++; Write-Host "  PASS  $name" } else { $script:failed++; Write-Host "  FAIL  $name  expected=[$e] actual=[$a]" } }
$tmp = Join-Path $here 'tmp-out/update'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

Write-Host '=== Version source of truth ==='
Assert-Eq (Get-QmVersion) '2.2.0' 'Get-QmVersion reads $script:QmVersion'
Assert-Eq (Get-QmPublisher) 'QuSpace Studios LLC' 'publisher constant'
Assert-Eq (Get-QmProductName) 'QuMeter' 'product name'
Assert-True ((Get-QmCopyrightText -Ascii) -match 'QuSpace Studios LLC') 'ASCII copyright mentions publisher'
Assert-True ((Get-QmFeedbackMailto) -match 'mailto:dylan@quspace.studio') 'feedback mailto uses studio email'
Assert-True ((Get-QmFeedbackMailto) -match 'QuMeter%20feedback%20%28v2\.2\.0%29') 'mailto subject includes version'
Assert-Eq (Get-QmFeedbackIssuesUrl) 'https://github.com/MAX-Q00/QuMeter/issues/new' 'GitHub issues URL'

Write-Host '=== Version compare and asset names ==='
Assert-Eq (ConvertTo-QmVersionString (ConvertTo-QmVersion 'v2.2.0')) '2.2.0' 'strips leading v'
Assert-Eq (ConvertTo-QmVersionString (ConvertTo-QmVersion '2.1')) '2.1' 'two-part version'
Assert-Eq (ConvertTo-QmVersionString (ConvertTo-QmVersion '2')) '2.0' 'one-part version becomes 2.0'
Assert-Eq (Compare-QmVersion '2.1.2' '2.2.0') -1 '2.1.2 is older than 2.2.0'
Assert-Eq (Compare-QmVersion '2.2.0' '2.2.0') 0 'equal versions'
Assert-Eq (Compare-QmVersion '2.10.0' '2.9.9') 1 '2.10.0 is newer than 2.9.9'
Assert-Eq (Get-QmReleaseZipName '2.2.0') 'QuMeter-2.2.0.zip' 'release zip name'
Assert-Eq (Get-QmReleaseZipName 'v2.2.0') 'QuMeter-2.2.0.zip' 'release zip name from tag'

Write-Host '=== GitHub release JSON ==='
$digest = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
$json = @"
{
  "tag_name": "v2.3.0",
  "name": "QuMeter 2.3.0",
  "body": "SHA256: $digest",
  "html_url": "https://github.com/MAX-Q00/QuMeter/releases/tag/v2.3.0",
  "assets": [
    {
      "name": "QuMeter-2.3.0.zip",
      "browser_download_url": "https://github.com/MAX-Q00/QuMeter/releases/download/v2.3.0/QuMeter-2.3.0.zip",
      "size": 12345,
      "digest": "sha256:$digest"
    }
  ]
}
"@
$rel = ConvertFrom-QmGithubRelease $json
Assert-Eq $rel.Version '2.3.0' 'parses tag version'
Assert-Eq $rel.ExpectedZipName 'QuMeter-2.3.0.zip' 'expected zip name'
Assert-Eq $rel.AssetName 'QuMeter-2.3.0.zip' 'picks the versioned zip asset'
Assert-Eq $rel.AssetSize 12345 'asset size'
Assert-Eq $rel.Sha256 $digest 'sha256 from asset digest'
Assert-Eq $null (ConvertFrom-QmGithubRelease '{"message":"Not Found"}') 'not-found JSON is null'
Assert-Eq $null (ConvertFrom-QmGithubRelease '') 'empty JSON is null'

$bodyOnly = @"
{ "tag_name": "v2.4.1", "name": "x", "body": "QuMeter-2.4.1.zip SHA256: fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210", "assets": [ { "name": "QuMeter-2.4.1.zip", "browser_download_url": "https://example.invalid/QuMeter-2.4.1.zip", "size": 10 } ] }
"@
$rel2 = ConvertFrom-QmGithubRelease $bodyOnly
Assert-Eq $rel2.Sha256 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210' 'sha256 from release body when digest missing'

Write-Host '=== Download verify and install ==='
$payload = Join-Path $tmp 'payload'
$appdir = Join-Path $tmp 'app'
New-Item -ItemType Directory -Path $payload, $appdir -Force | Out-Null
'NEW-CORE' | Set-Content (Join-Path $payload 'QuMeterCore.ps1')
'NEW-GUI' | Set-Content (Join-Path $payload 'QuMeter.ps1')
'OLD-CORE' | Set-Content (Join-Path $appdir 'QuMeterCore.ps1')
'OLD-GUI' | Set-Content (Join-Path $appdir 'QuMeter.ps1')
'USER' | Set-Content (Join-Path $appdir 'settings.json')
'USERCFG' | Set-Content (Join-Path $appdir 'config.json')
$backup = Join-Path $tmp 'backup'
$null = Install-QmUpdateFiles -SourceDir $payload -AppDir $appdir -BackupDir $backup
Assert-Eq (Get-Content (Join-Path $appdir 'QuMeterCore.ps1') -Raw).Trim() 'NEW-CORE' 'payload file replaced'
Assert-Eq (Get-Content (Join-Path $appdir 'settings.json') -Raw).Trim() 'USER' 'settings.json preserved'
Assert-Eq (Get-Content (Join-Path $appdir 'config.json') -Raw).Trim() 'USERCFG' 'config.json preserved'
Assert-Eq (Get-Content (Join-Path $backup 'QuMeterCore.ps1') -Raw).Trim() 'OLD-CORE' 'backup kept previous app file'

$wrapped = Join-Path $tmp 'wrapped'
New-Item -ItemType Directory -Path (Join-Path $wrapped 'QuMeter-9.9.9') -Force | Out-Null
'WRAP' | Set-Content (Join-Path $wrapped 'QuMeter-9.9.9/QuMeter.ps1')
Assert-True ((Resolve-QmExtractedRoot $wrapped) -like '*QuMeter-9.9.9') 'unwraps a single top-level folder'

$file = Join-Path $tmp 'blob.bin'
[IO.File]::WriteAllBytes($file, [byte[]](1,2,3,4,5))
$okHash = Get-QmFileSha256 $file
Assert-True (Test-QmDownload -Path $file -ExpectedSize 5 -ExpectedSha256 $okHash) 'matching size and hash pass'
$bad = $false
try { Test-QmDownload -Path $file -ExpectedSize 4 | Out-Null } catch { $bad = $true }
Assert-True $bad 'size mismatch throws'
$bad = $false
try { Test-QmDownload -Path $file -ExpectedSize 5 -ExpectedSha256 ('00' * 32) | Out-Null } catch { $bad = $true }
Assert-True $bad 'hash mismatch throws'

Write-Host '=== Payload list ==='
$names = Get-QmAppPayloadFiles
Assert-True ($names -contains 'QuMeter.ps1' -and $names -contains 'QuMeterUpdate.ps1') 'payload includes GUI and updater'
Assert-True ($names -notcontains 'settings.json' -and $names -notcontains 'config.json') 'payload does not include user data'

Write-Host ''
Write-Host "Results: $($script:passed) passed, $($script:failed) failed"
if ($script:failed -gt 0) { exit 1 }
