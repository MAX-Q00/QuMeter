# Creates or updates a Desktop shortcut for QuMeter.
# Published by QuSpace Studios LLC
# (c) 2026 QuSpace Studios LLC
#   pwsh -NoProfile -File scripts/Install-QuMeterShortcut.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = Get-Location }
. (Join-Path $root 'QuMeterCore.ps1')

$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop) { throw 'Could not resolve the Desktop folder.' }
$lnkPath = Join-Path $desktop 'QuMeter.lnk'
$bat = Join-Path $root 'QuMeter.bat'
$ps1 = Join-Path $root 'QuMeter.ps1'
$shell = New-Object -ComObject WScript.Shell
$s = $shell.CreateShortcut($lnkPath)
if (Test-Path -LiteralPath $bat) {
    $s.TargetPath = $bat
    $s.Arguments = ''
} else {
    $s.TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`""
}
$s.WorkingDirectory = $root
$s.WindowStyle = 7
$s.Description = "$(Get-QmProductName) - published by $(Get-QmPublisher)"
$s.Save()
Write-Host "Shortcut written: $lnkPath"
Write-Host "Description: $($s.Description)"
