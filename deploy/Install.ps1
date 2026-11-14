# QuMeter Auto - local installer for a deployment package.
# Run on the target machine (e.g. the PaperCut server) as Administrator:  Install.bat
#   Install.ps1 [-InstallPath C:\ProgramData\QuMeter] [-RunAs SYSTEM|Account] [-RunNow] [-Uninstall]
[CmdletBinding()]
param(
    [string]$InstallPath,
    [ValidateSet('SYSTEM','Account','')][string]$RunAs = '',
    [switch]$RunNow,
    [switch]$Uninstall,
    [switch]$KeepFiles
)
$ErrorActionPreference = 'Stop'
$pkg = $PSScriptRoot
$meta = $null
if (Test-Path -LiteralPath (Join-Path $pkg 'package.json')) { $meta = Get-Content -LiteralPath (Join-Path $pkg 'package.json') -Raw | ConvertFrom-Json }
if (-not $InstallPath) { $InstallPath = $(if ($meta -and $meta.installPath) { $meta.installPath } else { 'C:\ProgramData\QuMeter' }) }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run Install.bat as Administrator (right-click > Run as administrator).' }

$cfgPkg = Join-Path $pkg 'config.json'
$cfg = Get-Content -LiteralPath $cfgPkg -Raw -Encoding UTF8 | ConvertFrom-Json
$taskName = $(if ($cfg.schedule.taskName) { $cfg.schedule.taskName } else { 'QuMeter Auto' })

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; Write-Host "Removed task '$taskName'." }
    if (-not $KeepFiles -and (Test-Path -LiteralPath $InstallPath)) {
        foreach ($f in @('QuSnmp.cs','QuSnmp.ps1','QuMeterCore.ps1','QuMeterEngine.ps1','config.json','e-automate.mapping.json','apikey.dat','apikey.install','request.json')) {
            $p = Join-Path $InstallPath $f; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
        }
        Write-Host "Deleted program files in $InstallPath (output and logs kept)."
    }
    return
}

Write-Host "Installing QuMeter Auto to $InstallPath ..."
New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
foreach ($s in @('logs','output')) { New-Item -ItemType Directory -Path (Join-Path $InstallPath $s) -Force | Out-Null }
foreach ($f in @('QuSnmp.cs','QuSnmp.ps1','QuMeterCore.ps1','QuMeterEngine.ps1','config.json','e-automate.mapping.json')) {
    $src = Join-Path $pkg $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $InstallPath $f) -Force }
}
. (Join-Path $InstallPath 'QuSnmp.ps1')
. (Join-Path $InstallPath 'QuMeterCore.ps1')
$config = Read-QmConfig -Path (Join-Path $InstallPath 'config.json')
if (-not $RunAs) { $RunAs = $(if ($config.schedule.runAs -eq 'Account') { 'Account' } else { 'SYSTEM' }) }

$runCred = $null
if ($RunAs -eq 'Account') {
    $runCred = Get-Credential -UserName $config.schedule.runAsUser -Message 'Run-as account for the QuMeter Auto task (DOMAIN\user). The password is given to Task Scheduler only; it is not saved by QuMeter.'
    if (-not $runCred) { throw 'Cancelled.' }
}

$keyFile = Join-Path $pkg 'apikey.install'
if (Test-Path -LiteralPath $keyFile) {
    $key = ([IO.File]::ReadAllText($keyFile)).Trim()
    Install-QmMachineApiKey -Key $key -Dir $InstallPath -ExtraAccounts @($(if ($runCred) { $runCred.UserName }))
    $old = Join-Path $InstallPath 'apikey.install'; if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
    Write-Host 'API key installed (DPAPI LocalMachine, apikey.dat locked to SYSTEM/Administrators/run-as).'
    Write-Host 'IMPORTANT: delete this package folder and zip now - they contain the API key in plain text.' -ForegroundColor Yellow
}

$user = $(if ($runCred) { $runCred.UserName } else { $null })
$xml = New-QmTaskXml -Schedule $config.schedule -InstallDir $InstallPath -RunAs $RunAs -UserId $user
if ($runCred) { Register-ScheduledTask -Xml $xml -TaskName $taskName -User $user -Password $runCred.GetNetworkCredential().Password -Force | Out-Null }
else { Register-ScheduledTask -Xml $xml -TaskName $taskName -Force | Out-Null }
$st = Get-QmLocalTaskStatus -TaskName $taskName
Write-Host "Registered '$taskName' ($(Get-QmScheduleText $config.schedule)), run as $($st.RunAs). State=$($st.State) Next run=$($st.NextRunTime)"

if ($RunNow) {
    Write-Host 'Running once now to verify...'
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddMinutes(15)
    Start-Sleep -Seconds 3
    while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    $sj = Join-Path $InstallPath 'logs\status.json'
    if (Test-Path -LiteralPath $sj) {
        $env = Read-QmSignedEnvelope -Json ([IO.File]::ReadAllText($sj))
        Write-Host (ConvertTo-QmStatusText $env.Data $null)
    } else { Write-Host 'No status.json yet. Check Task Scheduler history.' -ForegroundColor Yellow }
}
Write-Host 'Done.'
