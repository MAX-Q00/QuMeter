# QuMeterCore.ps1 - shared automation logic for QuMeter (GUI Automate tab, headless engine).
# Windows PowerShell 5.1 compatible. No third-party modules.
# Published by QuSpace Studios LLC
# (c) 2026 QuSpace Studios LLC
$script:QmCoreRoot = $PSScriptRoot
if (-not $script:QmCoreRoot) { $script:QmCoreRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
# Single source of truth for the app version. Bump this before tagging a GitHub release.
$script:QmVersion = '2.2.4'
$script:QmPublisher = 'QuSpace Studios LLC'
$script:QmProductName = 'QuMeter'
$script:QmCopyrightYear = '2026'
$script:QmFeedbackEmail = 'dylan@quspace.studio'
$script:QmGitHubIssuesUrl = 'https://github.com/MAX-Q00/QuMeter/issues/new'

function Get-QmVersion { $script:QmVersion }
function Get-QmPublisher { $script:QmPublisher }
function Get-QmProductName { $script:QmProductName }
function Get-QmCopyrightText {
    param([switch]$Ascii)
    if ($Ascii) { return "(c) $($script:QmCopyrightYear) $($script:QmPublisher)" }
    return ('{0} {1} {2}' -f [char]0x00A9, $script:QmCopyrightYear, $script:QmPublisher)
}
function Get-QmFeedbackMailto {
    $subject = [uri]::EscapeDataString("QuMeter feedback (v$(Get-QmVersion))")
    return "mailto:$($script:QmFeedbackEmail)?subject=$subject"
}
function Get-QmFeedbackIssuesUrl { $script:QmGitHubIssuesUrl }
function Join-QmWinPath {
    # Join for Windows paths that may not exist on this machine (drive letters on a Linux test host); Join-Path would fail.
    param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][string]$Child)
    return ($Base.TrimEnd('\','/') + '\' + $Child.TrimStart('\','/'))
}

# ---------------------------------------------------------------- packaged / data dirs (MSIX)
$script:QmPackageProbeDone = $false
$script:QmIsPackagedCache = $false
if (-not ('QmPackageIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class QmPackageIdentity {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern int GetCurrentPackageFullName(ref int length, StringBuilder name);
  public static bool IsPackaged() {
    int len = 0;
    int hr = GetCurrentPackageFullName(ref len, null);
    // APPMODEL_ERROR_NO_PACKAGE = 15700 (0x3D54) when not packaged; other codes mean packaged (buffer too small etc.)
    return hr != 15700;
  }
}
'@ -ErrorAction SilentlyContinue
}

function Get-QmAppDir {
    if ($script:QmCoreRoot) { return $script:QmCoreRoot }
    return (Get-Location).Path
}

function Test-QmAppDirWritable {
    param([string]$AppDir = (Get-QmAppDir))
    if ([string]::IsNullOrWhiteSpace($AppDir)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $AppDir)) { return $false }
        $probe = Join-Path $AppDir ('.qm-write-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Test-QmIsPackaged {
    if ($env:QUMETER_FORCE_PACKAGED -eq '1') { return $true }
    if ($env:QUMETER_FORCE_PACKAGED -eq '0') { return $false }
    if ($script:QmPackageProbeDone) { return [bool]$script:QmIsPackagedCache }
    $script:QmPackageProbeDone = $true
    $script:QmIsPackagedCache = $false
    try {
        if ('QmPackageIdentity' -as [type]) {
            $script:QmIsPackagedCache = [QmPackageIdentity]::IsPackaged()
        }
    } catch {
        $script:QmIsPackagedCache = $false
    }
    return [bool]$script:QmIsPackagedCache
}

function Test-QmUseDataDir {
    if ($env:QUMETER_DATA_DIR) { return $true }
    if (Test-QmIsPackaged) { return $true }
    return -not (Test-QmAppDirWritable)
}

function Get-QmDataDir {
    if ($env:QUMETER_DATA_DIR) {
        $d = $env:QUMETER_DATA_DIR.Trim()
        if ($d) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            return $d
        }
    }
    if (Test-QmUseDataDir) {
        $local = $env:LOCALAPPDATA
        if (-not $local) { $local = Join-Path $env:USERPROFILE 'AppData\Local' }
        $d = Join-Path $local 'QuMeter'
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        return $d
    }
    return (Get-QmAppDir)
}

function Get-QmUserDataFileNamesForMigration {
    @('settings.json', 'config.json', 'devices.txt', 'mps-import.json', 'e-automate.mapping.json')
}

function Get-QmLegacyDataRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(
        (Join-Path $env:USERPROFILE 'QuMeter'),
        (Join-Path $env:LOCALAPPDATA 'Programs\QuMeter'),
        (Join-Path $env:USERPROFILE 'QuMeterAuto')
    )) {
        if ($p -and (Test-Path -LiteralPath $p)) { [void]$roots.Add($p) }
    }
    return ,$roots
}

function Initialize-QmDataDir {
    # Seed mapping from the install dir and migrate legacy user data into %LOCALAPPDATA%\QuMeter (non-destructive).
    param(
        [string]$AppDir = (Get-QmAppDir),
        [string]$DataDir = (Get-QmDataDir),
        [string[]]$LegacyRoots
    )
    if (-not (Test-QmUseDataDir)) { return $DataDir }
    if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

    # Migrate legacy user data first so a customized mapping is not shadowed by the package default.
    $roots = @($LegacyRoots)
    if ($roots.Count -eq 0) { $roots = @(Get-QmLegacyDataRoots) }
    foreach ($legacy in $roots) {
        if ([string]::IsNullOrWhiteSpace($legacy)) { continue }
        if ([string]::Equals($legacy, $DataDir, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Test-Path -LiteralPath $legacy)) { continue }
        foreach ($name in (Get-QmUserDataFileNamesForMigration)) {
            $src = Join-Path $legacy $name
            $dst = Join-Path $DataDir $name
            if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
                try { Copy-Item -LiteralPath $src -Destination $dst -Force } catch { }
            }
        }
        foreach ($subdir in @('output', 'logs')) {
            $srcDir = Join-Path $legacy $subdir
            $dstDir = Join-Path $DataDir $subdir
            if (-not (Test-Path -LiteralPath $srcDir)) { continue }
            if (-not (Test-Path -LiteralPath $dstDir)) {
                try { Copy-Item -LiteralPath $srcDir -Destination $dstDir -Recurse -Force } catch { }
            }
        }
    }

    $mapName = 'e-automate.mapping.json'
    $destMap = Join-Path $DataDir $mapName
    if (-not (Test-Path -LiteralPath $destMap)) {
        $srcMap = Join-Path $AppDir $mapName
        if (Test-Path -LiteralPath $srcMap) {
            Copy-Item -LiteralPath $srcMap -Destination $destMap -Force
        }
    }
    return $DataDir
}

function Get-QmStoreUpdateMessage {
    return 'Updates for this install are managed through the Microsoft Store.'
}

# ---------------------------------------------------------------- config
function Get-QmDefaultConfig {
    [ordered]@{
        community     = 'public'
        version       = 'v2c'
        port          = 161
        timeoutMs     = 1500
        retries       = 1
        concurrency   = 32
        targets       = @()
        targetFile    = ''
        outputFolder  = 'output'
        mpsDropFolder = ''
        logFolder     = 'logs'
        mappingFile   = 'e-automate.mapping.json'
        eaFormat      = 'basic'
        eaSource      = 'SNMP'
        eaRemarks     = 'Imported by QuMeter'
        excludeNoSerial = $true
        retentionDays = 90
        schedule      = [ordered]@{
            taskName   = 'QuMeter Auto'
            frequency  = 'Daily'
            time       = '06:00'
            dayOfWeek  = 'Monday'
            dayOfMonth = '1'
            runAs      = 'CurrentUser'   # CurrentUser | SYSTEM | Account
            runAsUser  = ''
        }
    }
}

function ConvertTo-QmHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-QmHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-QmHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = @()
        foreach ($i in $InputObject) { $list += ,(ConvertTo-QmHashtable $i) }
        return ,$list
    }
    return $InputObject
}

function Merge-QmConfig {
    param($Defaults, $Overrides)
    $out = [ordered]@{}
    foreach ($k in $Defaults.Keys) { $out[$k] = $Defaults[$k] }
    if ($null -eq $Overrides) { return $out }
    foreach ($k in $Overrides.Keys) {
        $d = $out[$k]; $v = $Overrides[$k]
        if ($d -is [System.Collections.IDictionary] -and $v -is [System.Collections.IDictionary]) { $out[$k] = Merge-QmConfig $d $v }
        elseif ($null -ne $v) { $out[$k] = $v }
    }
    return $out
}

function ConvertTo-QmTargetList {
    param($Value)
    $list = @()
    if ($null -eq $Value) { return ,$list }
    $items = @()
    if ($Value -is [string]) { $items = $Value -split '\r\n|\n|\r' } else { $items = @($Value) }
    foreach ($i in $items) {
        $s = "$i".Trim()
        if ($s) { $list += $s }
    }
    return ,$list
}

function Read-QmConfig {
    param([string]$Path)
    $cfg = Get-QmDefaultConfig
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($raw.Trim()) {
            $obj = ConvertTo-QmHashtable ($raw | ConvertFrom-Json)
            $cfg = Merge-QmConfig $cfg $obj
        }
    }
    $cfg.targets = ConvertTo-QmTargetList $cfg.targets
    foreach ($k in @('port','timeoutMs','retries','concurrency','retentionDays')) { $cfg[$k] = [int]$cfg[$k] }
    $cfg.schedule.dayOfMonth    = "$($cfg.schedule.dayOfMonth)"
    # never keep a secret in config.json even if someone typed one in; drop leftover deploy blocks from older versions
    foreach ($bad in @('apiKey','password','apikey','deploy')) { if ($cfg.Contains($bad)) { $cfg.Remove($bad) } }
    return $cfg
}

function Save-QmConfig {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Path)
    $copy = Merge-QmConfig ([ordered]@{}) $Config
    foreach ($bad in @('apiKey','password','apikey','deploy')) { if ($copy.Contains($bad)) { $copy.Remove($bad) } }
    $copy.targets = [string[]](ConvertTo-QmTargetList $copy.targets)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $copy | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Import-QmLegacyConfig {
    # Pull settings from an old QuMeter Auto folder (config.json + devices.txt).
    param([Parameter(Mandatory)][string]$LegacyDir)
    $cfgPath = Join-Path $LegacyDir 'config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $null }
    $cfg = Read-QmConfig $cfgPath
    $devPath = $null
    if ($cfg.targetFile) {
        $devPath = $cfg.targetFile
        if (-not [System.IO.Path]::IsPathRooted($devPath)) { $devPath = Join-Path $LegacyDir $devPath }
    }
    if ($devPath -and (Test-Path -LiteralPath $devPath)) {
        $lines = Get-Content -LiteralPath $devPath | ForEach-Object { ($_ -replace '#.*$','').Trim() } | Where-Object { $_ }
        $cfg.targets = ConvertTo-QmTargetList (@($cfg.targets) + @($lines))
    }
    $cfg.targetFile = ''
    foreach ($k in @('outputFolder','logFolder','mpsDropFolder')) {
        $v = "$($cfg[$k])"
        if ($v -and -not [System.IO.Path]::IsPathRooted($v)) { $cfg[$k] = Join-Path $LegacyDir $v }
    }
    $cfg.mappingFile = 'e-automate.mapping.json'
    return $cfg
}

function Test-QmTimeString { param([string]$Time) return ($Time -match '^([01]?\d|2[0-3]):[0-5]\d$') }

function Test-QmConfig {
    # Returns a list of human-readable problems (empty = OK).
    param([Parameter(Mandatory)]$Config, [string]$Root)
    $errs = New-Object System.Collections.Generic.List[string]
    $hasTargets = (@($Config.targets).Count -gt 0)
    if (-not $hasTargets -and $Config.targetFile) {
        $tf = $Config.targetFile
        if ($Root -and -not [System.IO.Path]::IsPathRooted($tf)) { $tf = Join-Path $Root $tf }
        $hasTargets = Test-Path -LiteralPath $tf
    }
    if (-not $hasTargets) { $errs.Add('No printers listed. Add IPs, ranges, or CIDR blocks.') }
    if (@('v1','v2c') -notcontains "$($Config.version)") { $errs.Add("SNMP version must be v1 or v2c (got '$($Config.version)').") }
    if (-not "$($Config.community)") { $errs.Add('SNMP community is empty.') }
    if ([int]$Config.port -lt 1 -or [int]$Config.port -gt 65535) { $errs.Add('Port must be 1-65535.') }
    if ([int]$Config.timeoutMs -lt 100) { $errs.Add('Timeout must be at least 100 ms.') }
    if ([int]$Config.retentionDays -lt 0) { $errs.Add('Retention days cannot be negative (0 = keep forever).') }
    if (-not "$($Config.outputFolder)") { $errs.Add('Output folder is empty.') }
    if (@('basic','advanced') -notcontains "$($Config.eaFormat)") { $errs.Add('e-automate format must be basic or advanced.') }
    $s = $Config.schedule
    if (-not (Test-QmTimeString $s.time)) { $errs.Add("Schedule time must be HH:mm (got '$($s.time)').") }
    if (@('Daily','Weekly','Monthly') -notcontains "$($s.frequency)") { $errs.Add('Frequency must be Daily, Weekly, or Monthly.') }
    if ($s.frequency -eq 'Weekly' -and @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday') -notcontains "$($s.dayOfWeek)") { $errs.Add('Pick a day of the week.') }
    if ($s.frequency -eq 'Monthly') {
        $d = "$($s.dayOfMonth)"
        if ($d -ne 'Last' -and -not ($d -match '^\d+$' -and [int]$d -ge 1 -and [int]$d -le 28)) { $errs.Add('Day of month must be 1-28 or Last.') }
    }
    if (-not "$($s.taskName)") { $errs.Add('Task name is empty.') }
    return ,$errs
}

function Resolve-QmPath {
    param([string]$Path, [string]$Root)
    if (-not $Path) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $Root $Path)
}

# ---------------------------------------------------------------- status (engine -> GUI)
function Read-QmStatus {
    # Parses logs\status.json. Also unwraps leftover signed envelopes from older versions (payload is the status JSON).
    param([Parameter(Mandatory)][string]$Json)
    $obj = $Json | ConvertFrom-Json
    if ($null -eq $obj) { throw 'Status file is empty.' }
    $names = @($obj.PSObject.Properties.Name)
    if ($names -contains 'payload' -and $obj.payload -and ($names -contains 'format' -or $names -contains 'hmac' -or $names -contains 'signed')) {
        return ($obj.payload | ConvertFrom-Json)
    }
    return $obj
}

function ConvertTo-QmStatusText {
    # One-paragraph human summary of a status object.
    param($Status)
    if (-not $Status) { return 'No status available.' }
    $run = $Status.run
    $lines = @()
    $state = if ($run.success) { 'SUCCESS' } elseif ($run.partial) { 'COMPLETED WITH ERRORS' } else { 'FAILED' }
    $lines += "Last run: $state  ($($run.trigger))"
    $lines += "Started: $($run.startedAt)   Finished: $($run.finishedAt)   ($($run.durationSec)s)"
    $lines += "Instance: $($Status.instance.computer)  $($Status.instance.installDir)  as $($Status.instance.user)  v$($Status.instance.version)"
    if ($Status.counts) { $lines += "Printers: $($Status.counts.hosts) queried, $($Status.counts.ok) OK ($($Status.counts.withSerial) with serial), $($Status.counts.timeout) timed out, $($Status.counts.error) errors" }
    if ($run.error) { $lines += "ERROR [$($run.errorStage)]: $($run.error)" }
    foreach ($w in @($Status.writeErrors)) { if ($w) { $lines += "WRITE ERROR: $w" } }
    foreach ($w in @($Status.warnings)) { if ($w) { $lines += "Warning: $w" } }
    if ($Status.files) {
        foreach ($p in @('general','eautomate','mps')) { if ($Status.files.$p) { $lines += "File: $($Status.files.$p)" } }
    }
    return ($lines -join "`r`n")
}

# ---------------------------------------------------------------- scheduled task XML
function ConvertTo-QmXmlText { param([string]$s) return [System.Security.SecurityElement]::Escape("$s") }

function Get-QmEngineArguments {
    param([Parameter(Mandatory)][string]$InstallDir)
    if (Test-QmIsPackaged) { return '--engine' }
    $engine = Join-QmWinPath $InstallDir 'QuMeterEngine.ps1'
    $cfg = Join-QmWinPath $InstallDir 'config.json'
    return "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$engine`" -ConfigPath `"$cfg`""
}

function New-QmTaskXml {
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)][string]$InstallDir,
        [ValidateSet('CurrentUser','SYSTEM','Account')][string]$RunAs = 'SYSTEM',
        [string]$UserId,
        [datetime]$StartDate = [datetime]::Today
    )
    $t = [TimeSpan]::Parse("$($Schedule.time)")
    $start = $StartDate.Date.Add($t).ToString('yyyy-MM-ddTHH:mm:ss')
    switch ("$($Schedule.frequency)") {
        'Weekly'  { $sched = "<ScheduleByWeek><DaysOfWeek><$($Schedule.dayOfWeek) /></DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek>" }
        'Monthly' {
            $months = (@('January','February','March','April','May','June','July','August','September','October','November','December') | ForEach-Object { "<$_ />" }) -join ''
            $sched = "<ScheduleByMonth><DaysOfMonth><Day>$(ConvertTo-QmXmlText $Schedule.dayOfMonth)</Day></DaysOfMonth><Months>$months</Months></ScheduleByMonth>"
        }
        default   { $sched = '<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>' }
    }
    switch ($RunAs) {
        'SYSTEM'  { $principal = '<UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel>' }
        'Account' {
            if (-not $UserId) { throw 'A run-as account name is required.' }
            $principal = "<UserId>$(ConvertTo-QmXmlText $UserId)</UserId><LogonType>Password</LogonType><RunLevel>HighestAvailable</RunLevel>"
        }
        default {
            if (-not $UserId) { $UserId = "$env:USERDOMAIN\$env:USERNAME" }
            $principal = "<UserId>$(ConvertTo-QmXmlText $UserId)</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel>"
        }
    }
    $desc = "QuMeter Auto $script:QmVersion, published by $script:QmPublisher - reads printer lifetime meters over SNMP and writes dated general / e-automate / MPS CSV files. Installed in $InstallDir."
    if (Test-QmIsPackaged) {
        $cmd = 'QuMeter.exe'
        $args = Get-QmEngineArguments -InstallDir $InstallDir
    } else {
        $cmd = '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
        $args = Get-QmEngineArguments -InstallDir $InstallDir
    }
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>QuSpace Studios LLC</Author>
    <Description>$(ConvertTo-QmXmlText $desc)</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$start</StartBoundary>
      <Enabled>true</Enabled>
      $sched
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">$principal</Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(ConvertTo-QmXmlText $cmd)</Command>
      <Arguments>$(ConvertTo-QmXmlText $args)</Arguments>
      <WorkingDirectory>$(ConvertTo-QmXmlText $InstallDir)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Get-QmScheduleText {
    param($Schedule)
    switch ("$($Schedule.frequency)") {
        'Weekly'  { "every $($Schedule.dayOfWeek) at $($Schedule.time)" }
        'Monthly' { if ("$($Schedule.dayOfMonth)" -eq 'Last') { "on the last day of each month at $($Schedule.time)" } else { "on day $($Schedule.dayOfMonth) of each month at $($Schedule.time)" } }
        default   { "daily at $($Schedule.time)" }
    }
}

# ---------------------------------------------------------------- local task (this PC)
function Install-QmLocalTask {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$AppDir, [pscredential]$RunAsCredential)
    $s = $Config.schedule
    $user = $null
    if ($s.runAs -eq 'Account') {
        if (-not $RunAsCredential) { throw 'Run-as account credentials are required.' }
        $user = $RunAsCredential.UserName
    } elseif ($s.runAs -eq 'CurrentUser') { $user = "$env:USERDOMAIN\$env:USERNAME" }
    $xml = New-QmTaskXml -Schedule $s -InstallDir $AppDir -RunAs $s.runAs -UserId $user
    if ($s.runAs -eq 'Account') {
        Register-ScheduledTask -Xml $xml -TaskName $s.taskName -User $user -Password $RunAsCredential.GetNetworkCredential().Password -Force | Out-Null
    } else {
        Register-ScheduledTask -Xml $xml -TaskName $s.taskName -Force | Out-Null
    }
    return Get-QmLocalTaskStatus -TaskName $s.taskName
}

function Remove-QmLocalTask {
    param([Parameter(Mandatory)][string]$TaskName)
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        return $true
    }
    return $false
}

function Format-QmTaskResult {
    param($Code)
    if ($null -eq $Code -or "$Code" -eq '') { return '' }
    $n = [int64]0
    if (-not [int64]::TryParse("$Code", [ref]$n)) { return "$Code" }
    $u = [uint32]($n -band 0xFFFFFFFF)
    $known = @{ 0 = 'success'; 1 = 'engine error (see status/log)'; 2 = 'completed with errors (see status)'; 267009 = 'currently running'; 267011 = 'has not run yet'; 267014 = 'terminated by user'; 2147750687 = 'already running'; 2147942402 = 'file not found' }
    $txt = $known[[int64]$u]
    return ('0x{0:X} {1}' -f $u, $txt).Trim()
}

function Get-QmLocalTaskStatus {
    param([Parameter(Mandatory)][string]$TaskName)
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return [pscustomobject]@{ Exists = $false; State = 'Not installed'; LastRunTime = $null; LastResult = ''; NextRunTime = $null; RunAs = '' } }
    $i = $t | Get-ScheduledTaskInfo
    return [pscustomobject]@{ Exists = $true; State = "$($t.State)"; LastRunTime = $i.LastRunTime; LastResult = (Format-QmTaskResult $i.LastTaskResult); NextRunTime = $i.NextRunTime; RunAs = "$($t.Principal.UserId)" }
}

# --- MPS fleet-list import (xlsx/csv) ---

function ConvertTo-QmMpsHeaderKey {
    param([string]$Header)
    if ($null -eq $Header) { return '' }
    $s = $Header.Trim().ToLowerInvariant()
    $s = $s -replace '[_\-]+', ' '
    $s = $s -replace '[^a-z0-9 ]', ''
    $s = $s -replace '\s+', ' '
    return $s.Trim()
}

function Get-QmMpsFieldMap {
    # Known MPS / fleet-report header aliases. Keys are Normalize-QmMpsHeader results.
    $map = @{}
    $pairs = @{
        CustomerCode = @(
            'customer code', 'customercode', 'cust code', 'account code', 'customer id',
            'account id', 'cust id', 'customer no', 'customer number', 'account number'
        )
        Customer = @(
            'customer description', 'customer', 'customer name', 'customer desc',
            'account', 'account name', 'customername', 'company', 'company name',
            'client', 'client name', 'site customer'
        )
        Brand = @('brand', 'manufacturer', 'make', 'vendor', 'mfr', 'mfg')
        Model = @('model', 'model name', 'modelname', 'product', 'product name', 'productname')
        Serial = @(
            'serialnumber', 'serial number', 'serial', 'serial no', 'serialno',
            'serial num', 'serialnum', 's n', 'sn'
        )
        AssetNumber = @(
            'assetnumber', 'asset number', 'asset', 'asset no', 'assetno',
            'equipment number', 'equipment no', 'equip no', 'equipmentnumber', 'equip number'
        )
        Ip = @(
            'ip address', 'ipaddress', 'ip', 'ip addr', 'ipv4', 'host ip',
            'printer ip', 'ipaddressv4', 'tcp ip address', 'tcpip address'
        )
        Contact = @('contact', 'contact name', 'contactname')
        SystemName = @(
            'sytem name', 'system name', 'systemname', 'hostname', 'host name',
            'sysname', 'device name', 'devicename', 'dns name', 'computer name', 'host'
        )
        Office = @('office', 'location', 'site', 'branch', 'office name')
        Department = @('department', 'dept', 'department name')
        LastUpdate = @(
            'last update', 'last updated', 'lastupdated', 'last seen', 'lastseen',
            'updated', 'date updated', 'last meter date'
        )
        DaysStale = @('days stale', 'daysstale', 'stale days', 'days since update', 'days since last update')
        Total = @('total count', 'totalcount', 'total pages', 'totalpages', 'total', 'lifetime', 'lifetime total')
        Mono = @('mono count', 'monocount', 'mono pages', 'monopages', 'mono', 'bw', 'b w', 'black', 'black white')
        Color = @('color count', 'colorcount', 'color pages', 'colorpages', 'color', 'colour', 'colour count')
    }
    foreach ($field in $pairs.Keys) {
        foreach ($alias in $pairs[$field]) { $map[$alias] = $field }
    }
    return $map
}

function ConvertTo-QmMpsColumnIndex {
    param([string[]]$Headers)
    $map = Get-QmMpsFieldMap
    $index = @{}
    for ($i = 0; $i -lt $Headers.Count; $i++) {
        $key = ConvertTo-QmMpsHeaderKey $Headers[$i]
        if (-not $key) { continue }
        if ($map.ContainsKey($key) -and -not $index.ContainsKey($map[$key])) {
            $index[$map[$key]] = $i
        }
    }
    return $index
}

function Test-QmMpsHeaderRow {
    param($ColumnIndex)
    if (-not $ColumnIndex) { return $false }
    if ($ColumnIndex.ContainsKey('Ip')) { return $true }
    $hasCustomer = $ColumnIndex.ContainsKey('Customer') -or $ColumnIndex.ContainsKey('CustomerCode')
    $hasDevice = $ColumnIndex.ContainsKey('Serial') -or $ColumnIndex.ContainsKey('Model')
    return [bool]($hasCustomer -and $hasDevice)
}

function Find-QmMpsHeaderRow {
    param([object[]]$Rows, [int]$MaxScan = 40)
    $limit = [math]::Min($Rows.Count, $MaxScan)
    $best = $null
    $bestScore = -1
    for ($i = 0; $i -lt $limit; $i++) {
        $headers = @($Rows[$i] | ForEach-Object { "$_" })
        $idx = ConvertTo-QmMpsColumnIndex $headers
        if (-not (Test-QmMpsHeaderRow $idx)) { continue }
        $score = $idx.Keys.Count
        if ($idx.ContainsKey('Ip')) { $score += 10 }
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = [pscustomobject]@{ Index = $i; Headers = $headers; Columns = $idx }
        }
    }
    return $best
}

function Test-QmIpv4Address {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $t = $Value.Trim()
    if ($t -match '^(.+):(\d+)$') { $t = $Matches[1] }
    if ($t -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    foreach ($p in $t.Split('.')) {
        $n = 0
        if (-not [int]::TryParse($p, [ref]$n)) { return $false }
        if ($n -lt 0 -or $n -gt 255) { return $false }
    }
    return $true
}

function ConvertTo-QmIpv4Address {
    param([string]$Value)
    if (-not (Test-QmIpv4Address $Value)) { return '' }
    $t = $Value.Trim()
    if ($t -match '^(.+):(\d+)$') { $t = $Matches[1] }
    $parts = $t.Split('.') | ForEach-Object { [int]$_ }
    return ($parts -join '.')
}

function ConvertFrom-QmExcelDayNumber {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $t = $Value.Trim()
    if ($t -notmatch '^\d+(\.\d+)?$') { return $t }
    $n = 0.0
    if (-not [double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $t }
    if ($n -lt 20000 -or $n -gt 80000) { return $t }
    try {
        return ([DateTime]::FromOADate($n)).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    } catch { return $t }
}

function Get-QmMpsCell {
    param($Row, $Columns, [string]$Field)
    if (-not $Columns -or -not $Columns.ContainsKey($Field)) { return '' }
    $i = [int]$Columns[$Field]
    if ($i -lt 0 -or $i -ge $Row.Count) { return '' }
    return ([string]$Row[$i]).Trim()
}

function New-QmMpsImportRow {
    param($Row, $Columns)
    $ipRaw = Get-QmMpsCell $Row $Columns 'Ip'
    $ip = ConvertTo-QmIpv4Address $ipRaw
    $customer = Get-QmMpsCell $Row $Columns 'Customer'
    $code = Get-QmMpsCell $Row $Columns 'CustomerCode'
    if ([string]::IsNullOrWhiteSpace($customer)) { $customer = $code }
    if ([string]::IsNullOrWhiteSpace($customer)) { $customer = 'Unnamed customer' }
    $last = Get-QmMpsCell $Row $Columns 'LastUpdate'
    if ($last) { $last = ConvertFrom-QmExcelDayNumber $last }
    return [pscustomobject]@{
        Customer     = $customer
        CustomerCode = $code
        Brand        = Get-QmMpsCell $Row $Columns 'Brand'
        Model        = Get-QmMpsCell $Row $Columns 'Model'
        Serial       = Get-QmMpsCell $Row $Columns 'Serial'
        AssetNumber  = Get-QmMpsCell $Row $Columns 'AssetNumber'
        Ip           = $ip
        IpRaw        = $ipRaw
        HasIp        = -not [string]::IsNullOrWhiteSpace($ip)
        Contact      = Get-QmMpsCell $Row $Columns 'Contact'
        SystemName   = Get-QmMpsCell $Row $Columns 'SystemName'
        Office       = Get-QmMpsCell $Row $Columns 'Office'
        Department   = Get-QmMpsCell $Row $Columns 'Department'
        LastUpdate   = $last
        DaysStale    = Get-QmMpsCell $Row $Columns 'DaysStale'
        Total        = Get-QmMpsCell $Row $Columns 'Total'
        Mono         = Get-QmMpsCell $Row $Columns 'Mono'
        Color        = Get-QmMpsCell $Row $Columns 'Color'
    }
}

function Test-QmMpsRowEmpty {
    param($Row)
    foreach ($v in @($Row)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return $false }
    }
    return $true
}

function ConvertTo-QmMpsImportRows {
    param([object[]]$TableRows)
    $found = Find-QmMpsHeaderRow -Rows $TableRows
    if (-not $found) {
        throw 'This file does not look like an MPS list. A header row with an IP column (or customer plus model/serial) was not found.'
    }
    if (-not $found.Columns.ContainsKey('Ip')) {
        throw 'This file has no IP address column, so QuMeter cannot build a scan list from it.'
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $skippedBlank = 0
    $dataStart = [int]$found.Index + 1
    for ($i = $dataStart; $i -lt $TableRows.Count; $i++) {
        $line = @($TableRows[$i])
        if (Test-QmMpsRowEmpty $line) { $skippedBlank++; continue }
        $row = New-QmMpsImportRow $line $found.Columns
        $hasAny = $row.HasIp -or $row.Serial -or $row.Model -or ($row.Customer -and $row.Customer -ne 'Unnamed customer') -or $row.CustomerCode -or $row.AssetNumber
        if (-not $hasAny) { $skippedBlank++; continue }
        $rows.Add($row)
    }
    $withIp = @($rows | Where-Object { $_.HasIp }).Count
    $noIp = $rows.Count - $withIp
    return [pscustomobject]@{
        Rows          = $rows.ToArray()
        HeaderIndex   = [int]$found.Index
        Headers       = @($found.Headers)
        SkippedBlank  = $skippedBlank
        WithIpCount   = $withIp
        NoIpCount     = $noIp
    }
}

function ConvertTo-QmObjectList {
    param($Value)
    $list = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Value) { return ,$list }
    if ($Value -is [string] -or $Value -is [System.Collections.IDictionary]) {
        $list.Add($Value)
        return ,$list
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $list.Add($Value)
        return ,$list
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { $list.Add($item) }
        return ,$list
    }
    $list.Add($Value)
    return ,$list
}

function Get-QmMpsIpSearchLabel { return 'IP Search/No Customer' }
function Get-QmMpsAllCustomersLabel { return 'All customers' }

function Test-QmMpsIpSearchMode {
    param([string]$Customer)
    return [string]$Customer -eq (Get-QmMpsIpSearchLabel)
}

function Test-QmMpsAllCustomersMode {
    param([string]$Customer)
    return [string]::IsNullOrWhiteSpace($Customer) -or $Customer -eq (Get-QmMpsAllCustomersLabel)
}

function Test-QmPlaceholderTargetText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $t = $Text.Trim()
    return [bool]($t -match '^(System\.(String|Object)\[\]|System\.\w+(\[\])+)$')
}

function ConvertTo-QmFlatList {
    param($Value)
    $out = New-Object System.Collections.Generic.List[object]
    function Add-QmFlatItem {
        param($Item)
        if ($null -eq $Item) { return }
        if ($Item -is [string]) {
            if (Test-QmPlaceholderTargetText $Item) { return }
            $out.Add($Item)
            return
        }
        if ($Item -is [System.Management.Automation.PSCustomObject] -or $Item -is [System.Collections.IDictionary]) {
            $out.Add($Item)
            return
        }
        if ($Item.GetType().FullName -eq 'QuMeterSnmp.PrinterReading') {
            $out.Add($Item)
            return
        }
        if ($Item -is [System.Collections.IEnumerable]) {
            foreach ($child in $Item) { Add-QmFlatItem $child }
            return
        }
        $out.Add($Item)
    }
    Add-QmFlatItem $Value
    return ,$out
}

function ConvertTo-QmMultilineText {
    param($Value)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in (ConvertTo-QmFlatList $Value)) {
        $s = [string]$item
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if (Test-QmPlaceholderTargetText $s) { continue }
        $lines.Add($s)
    }
    if ($lines.Count -eq 0) { return '' }
    return [string]::Join("`r`n", $lines.ToArray())
}

function Repair-QmTargetText {
    param($Text)
    if ($null -eq $Text) { return '' }
    if ($Text -isnot [string]) { return (ConvertTo-QmMultilineText $Text) }
    if (Test-QmPlaceholderTargetText $Text) { return '' }
    return [string]$Text
}

function Get-QmMpsCustomerFilterItems {
    param($Rows)
    $items = New-Object System.Collections.Generic.List[string]
    [void]$items.Add((Get-QmMpsIpSearchLabel))
    $rowList = ConvertTo-QmObjectList $Rows
    if ($rowList.Count -eq 0) { return ,$items }
    [void]$items.Add((Get-QmMpsAllCustomersLabel))
    foreach ($name in (ConvertTo-QmFlatList (Get-QmMpsCustomerNames $Rows))) {
        $s = [string]$name
        if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$items.Add($s) }
    }
    return ,$items
}

function Get-QmMpsDefaultCustomer {
    param([bool]$HasImport)
    if ($HasImport) { return (Get-QmMpsAllCustomersLabel) }
    return (Get-QmMpsIpSearchLabel)
}

function Test-QmMpsShouldSwitchToIpSearch {
    param([string]$CurrentCustomer, [string]$TargetText, [bool]$HasImport, [bool]$Programmatic = $false, [bool]$OnFocus = $false)
    if ($Programmatic) { return $false }
    if (-not $HasImport) { return $false }
    if (Test-QmMpsIpSearchMode $CurrentCustomer) { return $false }
    if ($OnFocus) { return $true }
    $text = Repair-QmTargetText $TargetText
    return -not [string]::IsNullOrWhiteSpace($text)
}

function Get-QmManualScanTargetText {
    param([string]$TargetText, $Import, [string]$Customer)
    $text = Repair-QmTargetText $TargetText
    if (-not [string]::IsNullOrWhiteSpace($text)) { return [string]$text }
    if (-not $Import -or -not $Import.Rows -or (Test-QmMpsIpSearchMode $Customer)) { return '' }
    return (Get-QmMpsIpText (Get-QmMpsRowsForCustomer -Rows $Import.Rows -Customer $Customer))
}

function Test-QmMpsShouldMergeScan {
    param([string]$Customer, $Import)
    if (-not $Import -or -not $Import.Rows) { return $false }
    return -not (Test-QmMpsIpSearchMode $Customer)
}

function Add-QmReadingsToList {
    param($List, $Items)
    if ($null -eq $List) { throw 'Reading list is missing.' }
    foreach ($r in (ConvertTo-QmFlatList $Items)) {
        if ($null -eq $r) { continue }
        [void]$List.Add($r)
    }
}

function Get-QmMpsCustomerNames {

    param($Rows)
    $names = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($r in (ConvertTo-QmObjectList $Rows)) {
        $name = [string]$r.Customer
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $names.Add($name)
    }
    return @($names | Sort-Object)
}

function Get-QmMpsRowsForCustomer {
    param($Rows, [string]$Customer)
    $list = ConvertTo-QmObjectList $Rows
    if (Test-QmMpsIpSearchMode $Customer) { return ,(New-Object System.Collections.Generic.List[object]) }
    if (Test-QmMpsAllCustomersMode $Customer) { return ,$list }
    $want = $Customer.Trim()
    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($r in $list) {
        if ([string]::Equals([string]$r.Customer, $want, [StringComparison]::OrdinalIgnoreCase)) { $filtered.Add($r) }
    }
    return ,$filtered
}

function Get-QmMpsIpList {
    param($Rows)
    $ips = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($r in (ConvertTo-QmObjectList $Rows)) {
        if (-not $r.HasIp) { continue }
        $ip = [string]$r.Ip
        if ($seen.ContainsKey($ip)) { continue }
        $seen[$ip] = $true
        $ips.Add($ip)
    }
    return ,$ips
}

function Get-QmMpsIpText {
    param($Rows)
    return (ConvertTo-QmMultilineText (Get-QmMpsIpList $Rows))
}

function ConvertTo-QmImportedReading {
    param($Row)
    $r = New-Object QuMeterSnmp.PrinterReading
    $r.Ip = [string]$Row.Ip
    $r.Model = [string]$Row.Model
    $r.Serial = [string]$Row.Serial
    $r.Total = [string]$Row.Total
    $r.Mono = [string]$Row.Mono
    $r.Color = [string]$Row.Color
    if ($Row.HasIp) { $r.Status = 'Imported' } else { $r.Status = 'No IP' }
    $r.SysDescr = [string]$Row.SystemName
    if (-not $Row.HasIp -and $Row.IpRaw) {
        $r.ErrorMessage = "No usable IP ($($Row.IpRaw))"
    } elseif (-not $Row.HasIp) {
        $r.ErrorMessage = 'No IP in the imported list'
    }
    if ($r.PSObject.Properties.Name -contains 'Customer' -or ($r | Get-Member -Name Customer -ErrorAction SilentlyContinue)) {
        $r.Customer = [string]$Row.Customer
        $r.CustomerCode = [string]$Row.CustomerCode
        $r.Brand = [string]$Row.Brand
        $r.AssetNumber = [string]$Row.AssetNumber
        $r.SystemName = [string]$Row.SystemName
        $r.Office = [string]$Row.Office
        $r.Department = [string]$Row.Department
        $r.Contact = [string]$Row.Contact
        $r.LastUpdate = [string]$Row.LastUpdate
        $r.DaysStale = [string]$Row.DaysStale
    }
    return $r
}

function Copy-QmMpsFieldsToReading {
    param($Reading, $Row, [switch]$PreferExisting)
    if ($null -eq $Reading -or $null -eq $Row) { return $Reading }
    $setIf = {
        param($name, $value, $prefer)
        if ([string]::IsNullOrWhiteSpace([string]$value)) { return }
        $cur = [string]$Reading.$name
        if ($prefer -and -not [string]::IsNullOrWhiteSpace($cur)) { return }
        $Reading.$name = [string]$value
    }
    & $setIf 'Customer' $Row.Customer $false
    & $setIf 'CustomerCode' $Row.CustomerCode $false
    & $setIf 'Brand' $Row.Brand $false
    & $setIf 'AssetNumber' $Row.AssetNumber $false
    & $setIf 'SystemName' $Row.SystemName $false
    & $setIf 'Office' $Row.Office $false
    & $setIf 'Department' $Row.Department $false
    & $setIf 'Contact' $Row.Contact $false
    & $setIf 'LastUpdate' $Row.LastUpdate $false
    & $setIf 'DaysStale' $Row.DaysStale $false
    & $setIf 'Model' $Row.Model $PreferExisting
    & $setIf 'Serial' $Row.Serial $PreferExisting
    if ([string]::IsNullOrWhiteSpace([string]$Reading.SysDescr) -and $Row.SystemName) { $Reading.SysDescr = [string]$Row.SystemName }
    if ($PreferExisting) {
        if ([string]::IsNullOrWhiteSpace([string]$Reading.Total) -and $Row.Total) { $Reading.Total = [string]$Row.Total }
        if ([string]::IsNullOrWhiteSpace([string]$Reading.Mono) -and $Row.Mono) { $Reading.Mono = [string]$Row.Mono }
        if ([string]::IsNullOrWhiteSpace([string]$Reading.Color) -and $Row.Color) { $Reading.Color = [string]$Row.Color }
    }
    return $Reading
}

function Merge-QmImportedReadings {
    param($ScanReadings, $ImportRows)
    $byIp = @{}
    foreach ($row in (ConvertTo-QmObjectList $ImportRows)) {
        if ($row.HasIp -and -not $byIp.ContainsKey([string]$row.Ip)) { $byIp[[string]$row.Ip] = $row }
    }
    $merged = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($r in (ConvertTo-QmObjectList $ScanReadings)) {
        if ($null -eq $r) { continue }
        $ip = [string]$r.Ip
        if ($ip -and $byIp.ContainsKey($ip)) {
            [void](Copy-QmMpsFieldsToReading -Reading $r -Row $byIp[$ip] -PreferExisting)
            $seen[$ip] = $true
        }
        $merged.Add($r)
    }
    foreach ($row in (ConvertTo-QmObjectList $ImportRows)) {
        if ($row.HasIp) {
            $ip = [string]$row.Ip
            if ($seen.ContainsKey($ip)) { continue }
        }
        $merged.Add((ConvertTo-QmImportedReading $row))
    }
    return ,$merged
}

function New-QmMpsImportResult {
    param(
        [object[]]$TableRows,
        [string]$SourceName = '',
        [string]$SheetName = ''
    )
    $parsed = ConvertTo-QmMpsImportRows -TableRows $TableRows
    $customers = @(Get-QmMpsCustomerNames $parsed.Rows)
    return [pscustomobject]@{
        SourceName   = $SourceName
        SheetName    = $SheetName
        Rows         = @($parsed.Rows)
        Customers    = $customers
        HeaderIndex  = $parsed.HeaderIndex
        Headers      = @($parsed.Headers)
        SkippedBlank = [int]$parsed.SkippedBlank
        WithIpCount  = [int]$parsed.WithIpCount
        NoIpCount    = [int]$parsed.NoIpCount
        TotalRows    = @($parsed.Rows).Count
    }
}

function Import-QmMpsListFromCsvText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$SourceName = 'memory.csv'
    )
    $csv = ConvertFrom-QmCsvText -Text $Text
    return (New-QmMpsImportResult -TableRows $csv.Rows -SourceName $SourceName)
}

function Import-QmMpsList {
    param([Parameter(Mandatory)][string]$Path, [string]$SheetName = '')
    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
    $ext = [System.IO.Path]::GetExtension($Path)
    if ($ext -and $ext.Equals('.xls', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Excel 97-2003 .xls files are not supported. Save the list as .xlsx or .csv and import that.'
    }
    $sourceName = [System.IO.Path]::GetFileName($Path)
    if ($ext -and $ext.Equals('.xlsx', [StringComparison]::OrdinalIgnoreCase)) {
        $sheetData = Read-QuXlsxSheetRows -Path $Path -SheetName $SheetName
        return (New-QmMpsImportResult -TableRows $sheetData.Rows -SourceName $sourceName -SheetName ([string]$sheetData.SheetName))
    }
    $text = [System.IO.File]::ReadAllText($Path)
    return (Import-QmMpsListFromCsvText -Text $text -SourceName $sourceName)
}

function Get-QmMpsImportPath {
    param([string]$AppDir)
    $root = $AppDir
    if ([string]::IsNullOrWhiteSpace($root)) { $root = Get-QmDataDir }
    return (Join-Path $root 'mps-import.json')
}

function Save-QmMpsImport {
    param($Import, [string]$Path, [string]$SelectedCustomer = '')
    $copy = [ordered]@{
        version          = 1
        sourceName       = [string]$Import.SourceName
        sheetName        = [string]$Import.SheetName
        selectedCustomer = [string]$SelectedCustomer
        skippedBlank     = [int]$Import.SkippedBlank
        withIpCount      = [int]$Import.WithIpCount
        noIpCount        = [int]$Import.NoIpCount
        rows             = $( $tmpRows = ConvertTo-QmObjectList $Import.Rows; $tmpRows.ToArray() )
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($copy | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-QmMpsImport {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { return $null }
    if (-not $obj -or -not $obj.rows) { return $null }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($r in (ConvertTo-QmObjectList $obj.rows)) {
        $ip = ConvertTo-QmIpv4Address ([string]$r.Ip)
        $customer = [string]$r.Customer
        if ([string]::IsNullOrWhiteSpace($customer)) { $customer = [string]$r.CustomerCode }
        if ([string]::IsNullOrWhiteSpace($customer)) { $customer = 'Unnamed customer' }
        $rows.Add([pscustomobject]@{
            Customer     = $customer
            CustomerCode = [string]$r.CustomerCode
            Brand        = [string]$r.Brand
            Model        = [string]$r.Model
            Serial       = [string]$r.Serial
            AssetNumber  = [string]$r.AssetNumber
            Ip           = $ip
            IpRaw        = [string]$r.IpRaw
            HasIp        = [bool](-not [string]::IsNullOrWhiteSpace($ip))
            Contact      = [string]$r.Contact
            SystemName   = [string]$r.SystemName
            Office       = [string]$r.Office
            Department   = [string]$r.Department
            LastUpdate   = [string]$r.LastUpdate
            DaysStale    = [string]$r.DaysStale
            Total        = [string]$r.Total
            Mono         = [string]$r.Mono
            Color        = [string]$r.Color
        })
    }
    return [pscustomobject]@{
        SourceName       = [string]$obj.sourceName
        SheetName        = [string]$obj.sheetName
        SelectedCustomer = [string]$obj.selectedCustomer
        Rows             = $rows.ToArray()
        Customers        = @(Get-QmMpsCustomerNames $rows)
        SkippedBlank     = [int]$obj.skippedBlank
        WithIpCount      = @($rows | Where-Object { $_.HasIp }).Count
        NoIpCount        = @($rows | Where-Object { -not $_.HasIp }).Count
        TotalRows        = $rows.Count
    }
}

function Clear-QmMpsImport {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $Path -Force }
}

function Test-QmScannedStatus {
    param([string]$Status)
    return @('OK', 'Error', 'No data', 'Timeout', 'Cancelled') -contains $Status
}

function Test-QmRespondedStatus {
    param([string]$Status)
    return @('OK', 'Error', 'No data') -contains $Status
}

# --- UI / copy helpers (testable without WinForms)
function Get-QmAutomateTabText { return 'Automate (Experimental)' }
function Get-QmAutomateExperimentalBanner { return 'The Automate Tab is Experimental and requires further testing' }
function Get-QmAutomateExperimentalArgb { return @(0xB0, 0x00, 0x20) }
function Get-QmPrimaryButtonArgb { return @(25, 135, 84) }
function Get-QmImportMpsButtonText { return 'Import list (MPS)...' }
function Get-QmEditExportMappingButtonText { return 'Edit Export Mapping...' }
function Get-QmScanProgressText([int]$Done, [int]$Total) {
    return ('{0} / {1} IPs' -f [math]::Max(0, [int]$Done), [math]::Max(0, [int]$Total))
}
function Test-QmFilterChangeCanRun([bool]$Busy) { return -not [bool]$Busy }
function Save-QmTextAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = $Path + ".$PID.tmp"
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($tmp, $Text, $utf8)
    if (Test-Path -LiteralPath $Path) {
        try {
            [System.IO.File]::Replace($tmp, $Path, $null)
        } catch {
            [System.IO.File]::Copy($tmp, $Path, $true)
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    } else {
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
}
function Get-QmAboutDescription { return 'Reads lifetime meter counts over SNMP for e-automate and MPS imports.' }
function Get-QmRunOnceEmptyCaption { return 'Add printers and save settings to run.' }
function Get-QmTipsAutoCollapseWidth { return 1100 }
function Get-QmManualGridColumnOrder {
    return @('IP','Status','Serial','Model','Total','Mono','Color','Customer','Brand','Asset','System','SysDescr','Error')
}
function Get-QmContrastRatio {
    param([int]$R1, [int]$G1, [int]$B1, [int]$R2, [int]$G2, [int]$B2)
    function Get-Lin([double]$c) {
        $s = $c / 255.0
        if ($s -le 0.04045) { return $s / 12.92 }
        return [math]::Pow((($s + 0.055) / 1.055), 2.4)
    }
    function Get-Lum([int]$r, [int]$g, [int]$b) {
        return (0.2126 * (Get-Lin $r)) + (0.7152 * (Get-Lin $g)) + (0.0722 * (Get-Lin $b))
    }
    $l1 = Get-Lum $R1 $G1 $B1
    $l2 = Get-Lum $R2 $G2 $B2
    if ($l1 -lt $l2) { $tmp = $l1; $l1 = $l2; $l2 = $tmp }
    return [math]::Round((($l1 + 0.05) / ($l2 + 0.05)), 2)
}
function Test-QmRunOnceCanRun {
    param($SavedTargets, [bool]$Running = $false)
    if ($Running) { return $false }
    return (@($SavedTargets | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0)
}
function Test-QmExportButtonsShouldEnable {
    param([bool]$Scanning, [int]$Total, [int]$Responded, [int]$OkSerial, [string]$Kind = 'general')
    if ($Scanning) { return $false }
    if ($Total -le 0 -or $Responded -le 0) { return $false }
    if ($Kind -eq 'ea' -or $Kind -eq 'mps') { return ($OkSerial -gt 0) }
    return $true
}
function Get-QmDefaultHideTips {
    param($Saved)
    if ($Saved -and ($Saved.PSObject.Properties.Name -contains 'hideTips')) { return [bool]$Saved.hideTips }
    if ($Saved -and ($Saved.PSObject.Properties.Name -contains 'tipsSeen') -and $Saved.tipsSeen) { return $true }
    return $false
}
function Test-QmTipsShouldCollapse {
    param([int]$Width, [bool]$HidePref, [bool]$PinnedOpen, [int]$Threshold = 1100)
    if ($PinnedOpen) { return $false }
    if ($HidePref) { return $true }
    return ($Width -lt $Threshold)
}

# Update helpers (GitHub Releases check / install). Safe to load in the headless engine; nothing runs on import.
$script:QmUpdatePath = Join-Path $script:QmCoreRoot 'QuMeterUpdate.ps1'
if (Test-Path -LiteralPath $script:QmUpdatePath) { . $script:QmUpdatePath }
