# QuMeterCore.ps1 - shared automation logic for QuMeter (GUI Automate tab, headless engine).
# Windows PowerShell 5.1 compatible. No third-party modules.
# Published by QuSpace Studios LLC
# (c) 2026 QuSpace Studios LLC
$script:QmCoreRoot = $PSScriptRoot
if (-not $script:QmCoreRoot) { $script:QmCoreRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
# Single source of truth for the app version. Bump this before tagging a GitHub release.
$script:QmVersion = '2.2.0'
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
        excludeNoSerial = $false
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
    $psExe = '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
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
      <Command>$(ConvertTo-QmXmlText $psExe)</Command>
      <Arguments>$(ConvertTo-QmXmlText (Get-QmEngineArguments -InstallDir $InstallDir))</Arguments>
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

# Update helpers (GitHub Releases check / install). Safe to load in the headless engine; nothing runs on import.
$script:QmUpdatePath = Join-Path $script:QmCoreRoot 'QuMeterUpdate.ps1'
if (Test-Path -LiteralPath $script:QmUpdatePath) { . $script:QmUpdatePath }
